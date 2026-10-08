"""Resource limits for a single parse (audit SRV-01).

A crafted PDF can make pdfminer burn minutes of CPU (a 65 KB file inflating to
64 MB of content-stream operators took 202 s). Threads can't be cancelled, so every
parse runs in a short-lived child process with:

* ``RLIMIT_CPU``  - CPU seconds (``PARSER_CPU_LIMIT_SECONDS``, default 30);
* a wall-clock timeout after which the child is killed
  (``PARSER_PARSE_TIMEOUT_SECONDS``, default 60);
* ``RLIMIT_AS``   - address-space cap (``PARSER_MEMORY_LIMIT_MB``, default 768;
  best effort, not enforced on macOS);
* a bounded zlib inflate for pdfminer streams (``PARSER_MAX_INFLATE_MB``, default
  32 total per parse; real statements inflate under 2 MB).

Before any extraction, ``check_document_limits`` rejects files over
``PARSER_MAX_PDF_MB`` (default 15) or ``PARSER_MAX_PAGES`` (default 30) pages.

Limit breaches are permanent contract errors (422): ``PARSE_TIMEOUT`` (CPU or wall
clock) and ``PDF_TOO_LARGE`` (size, pages, inflate budget, memory). Real statements
parse in about 1 s of CPU with at most 8 pages, so the defaults leave a wide margin.

``PARSER_ISOLATION=inline`` runs the parse in-process (tests, debugging); the size,
page and inflate checks still apply but CPU/wall/memory limits do not.
"""

from __future__ import annotations

import logging
import multiprocessing
import os
import signal
import threading
import traceback
import zlib
from collections.abc import Callable
from pathlib import Path
from typing import Any

from ccs_parser.domain.parsing.models import ParserError

logger = logging.getLogger(__name__)

DEFAULT_MAX_PAGES = 30
DEFAULT_MAX_PDF_MB = 15.0
DEFAULT_CPU_LIMIT_SECONDS = 30
DEFAULT_PARSE_TIMEOUT_SECONDS = 60.0
DEFAULT_MEMORY_LIMIT_MB = 768
DEFAULT_MAX_INFLATE_MB = 32.0

_MB = 1024 * 1024


def _env_number(name: str, default: float) -> float:
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def max_pages() -> int:
    return int(_env_number("PARSER_MAX_PAGES", DEFAULT_MAX_PAGES))


def max_pdf_bytes() -> int:
    return int(_env_number("PARSER_MAX_PDF_MB", DEFAULT_MAX_PDF_MB) * _MB)


def cpu_limit_seconds() -> int:
    return max(1, int(_env_number("PARSER_CPU_LIMIT_SECONDS", DEFAULT_CPU_LIMIT_SECONDS)))


def parse_timeout_seconds() -> float:
    return _env_number("PARSER_PARSE_TIMEOUT_SECONDS", DEFAULT_PARSE_TIMEOUT_SECONDS)


def memory_limit_bytes() -> int:
    return int(_env_number("PARSER_MEMORY_LIMIT_MB", DEFAULT_MEMORY_LIMIT_MB) * _MB)


def max_inflate_bytes() -> int:
    return int(_env_number("PARSER_MAX_INFLATE_MB", DEFAULT_MAX_INFLATE_MB) * _MB)


def isolation_enabled() -> bool:
    return (os.environ.get("PARSER_ISOLATION") or "process").strip().lower() not in {"inline", "off", "0", "false"}


# ---------------------------------------------------------------- document checks


def _too_large(message: str) -> ParserError:
    return ParserError("PDF_TOO_LARGE", message)


def count_pages(pdf_path: Path, passwords: list[str | None]) -> int | None:
    """Page count from the page tree (no content is decoded). None when unreadable."""
    try:
        from pypdf import PdfReader  # noqa: PLC0415

        reader = PdfReader(str(pdf_path))
        if reader.is_encrypted:
            opened = False
            for password in ["", *[p for p in passwords if p]]:
                try:
                    if reader.decrypt(password):
                        opened = True
                        break
                except Exception:  # noqa: BLE001
                    continue
            if not opened:
                return None
        return len(reader.pages)
    except Exception:  # noqa: BLE001 - corrupt/encrypted files are classified later by the parse
        return None


def check_document_limits(pdf_path: Path, passwords: list[str | None]) -> None:
    """Reject oversize files and documents with too many pages before extraction."""
    size = Path(pdf_path).stat().st_size
    limit = max_pdf_bytes()
    if size > limit:
        raise _too_large(f"PDF is {size // _MB} MB; the limit is {limit // _MB} MB.")
    pages = count_pages(pdf_path, passwords)
    if pages is not None and pages > max_pages():
        raise _too_large(f"PDF has {pages} pages; the limit is {max_pages()}.")


# ---------------------------------------------------------------- inflate guard


class InflateBudgetExceeded(Exception):
    """Raised by the bounded zlib shim; mapped to PDF_TOO_LARGE."""


class _BoundedZlib:
    """Drop-in for the ``zlib`` module as used by ``pdfminer.pdftypes``.

    ``decompress`` stops as soon as the per-parse inflate budget is exhausted
    instead of materialising a decompression bomb.
    """

    error = zlib.error

    def __init__(self, budget: int) -> None:
        self.budget = budget
        self.used = 0
        # Sticky: legacy parsers swallow broad exceptions, so the caller checks this
        # flag after the parse instead of relying on the exception reaching it.
        self.exhausted = False
        self._lock = threading.Lock()

    def _charge(self, n: int) -> None:
        with self._lock:
            self.used += n
            if self.used > self.budget:
                self.exhausted = True
                raise InflateBudgetExceeded(f"inflated streams exceed {self.budget // _MB} MB")

    def decompress(self, data: bytes, wbits: int = zlib.MAX_WBITS, bufsize: int = zlib.DEF_BUF_SIZE) -> bytes:
        d = zlib.decompressobj(wbits)
        remaining = self.budget - self.used + 1
        out = d.decompress(data, max(remaining, 1))
        self._charge(len(out))
        if d.unconsumed_tail:
            # Output was cut at the budget: the stream is larger than allowed.
            self._charge(self.budget + 1)
        out += d.flush()
        if not d.eof:
            # Mirror zlib.decompress: an incomplete stream is an error (pdfminer then
            # falls back to decompress_corrupted, which uses decompressobj below).
            raise zlib.error("Error -5 while decompressing data: incomplete or truncated stream")
        return out

    def decompressobj(self, *args: Any, **kwargs: Any) -> Any:
        return _BoundedDecompressObj(self, zlib.decompressobj(*args, **kwargs))

    def __getattr__(self, name: str) -> Any:
        return getattr(zlib, name)


class _BoundedDecompressObj:
    def __init__(self, owner: _BoundedZlib, inner: Any) -> None:
        self._owner = owner
        self._inner = inner

    def decompress(self, data: bytes, max_length: int = 0) -> bytes:
        out = self._inner.decompress(data, max_length) if max_length else self._inner.decompress(data)
        self._owner._charge(len(out))
        return out

    def flush(self, *args: Any) -> bytes:
        out = self._inner.flush(*args)
        self._owner._charge(len(out))
        return out

    def __getattr__(self, name: str) -> Any:
        return getattr(self._inner, name)


def install_inflate_guard(budget: int | None = None) -> _BoundedZlib:
    """Route pdfminer's stream inflation through a bounded zlib (per process)."""
    import pdfminer.pdftypes as pdftypes  # noqa: PLC0415

    shim = _BoundedZlib(budget if budget is not None else max_inflate_bytes())
    pdftypes.zlib = shim  # type: ignore[attr-defined]
    return shim


_INFLATE_MESSAGE = "Decompressed PDF streams exceed the parser's limit."


# ---------------------------------------------------------------- isolation


def _apply_rlimits(cpu_seconds: int, memory_bytes: int) -> None:
    try:
        import resource  # noqa: PLC0415
    except ImportError:  # pragma: no cover - non-POSIX
        return
    try:
        resource.setrlimit(resource.RLIMIT_CPU, (cpu_seconds, cpu_seconds + 2))
    except (ValueError, OSError) as exc:  # pragma: no cover
        logger.warning("could not set RLIMIT_CPU: %s", exc)
    try:
        resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))
    except (ValueError, OSError):
        # macOS doesn't support lowering RLIMIT_AS; Linux (Cloud Run) does.
        pass


def _frames(exc: BaseException) -> str:
    """File:line:function frames only. Exception messages may quote PDF text, so never include them."""
    tb = traceback.extract_tb(exc.__traceback__)[-8:]
    return " <- ".join(f"{Path(f.filename).name}:{f.lineno}:{f.name}" for f in reversed(tb))


def _parser_env() -> dict[str, str]:
    return {k: v for k, v in os.environ.items() if k.startswith("PARSER_")}


def _child_main(conn: Any, fn: Callable[..., Any], args: tuple, kwargs: dict, cpu_seconds: int, memory_bytes: int,
                inflate_bytes: int, parser_env: dict[str, str]) -> None:
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    # forkserver children inherit the server's environment from when it started;
    # apply the request-time PARSER_* settings (limits read inside the parse).
    for key in [k for k in os.environ if k.startswith("PARSER_")]:
        os.environ.pop(key, None)
    os.environ.update(parser_env)
    _apply_rlimits(cpu_seconds, memory_bytes)
    shim = install_inflate_guard(inflate_bytes)
    try:
        result = fn(*args, **kwargs)
        message: tuple = ("ok", result)
    except ParserError as exc:
        message = ("parser_error", exc.code, exc.message)
    except InflateBudgetExceeded:
        message = ("too_large", _INFLATE_MESSAGE)
    except MemoryError:
        message = ("too_large", "PDF needs more memory than the parser allows.")
    except BaseException as exc:  # noqa: BLE001 - reported to the parent as an internal error
        message = ("error", type(exc).__name__, _frames(exc))
    if shim.exhausted:
        # Whatever the parse returned or raised, part of the PDF was never read.
        message = ("too_large", _INFLATE_MESSAGE)
    try:
        conn.send(message)
    finally:
        conn.close()


class ParseCrashed(RuntimeError):
    """The isolated parse failed with a non-contract error (a parser bug). Surfaces as 500."""


_CONTEXT: Any = None
_CONTEXT_LOCK = threading.Lock()


def _context() -> Any:
    """forkserver: children fork from a clean, pre-warmed server (no inherited threads)."""
    global _CONTEXT
    with _CONTEXT_LOCK:
        if _CONTEXT is None:
            methods = multiprocessing.get_all_start_methods()
            ctx = multiprocessing.get_context("forkserver" if "forkserver" in methods else "spawn")
            if ctx.get_start_method() == "forkserver":
                ctx.set_forkserver_preload(["ccs_parser.service"])
            _CONTEXT = ctx
        return _CONTEXT


def _timeout_error(seconds: float) -> ParserError:
    return ParserError("PARSE_TIMEOUT", f"Parsing exceeded the parser's time limit ({seconds:.0f} s).")


def run_isolated(fn: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    """Run ``fn(*args, **kwargs)`` in a child process under the configured limits.

    ``fn`` must be importable by reference (a module-level function). Returns its
    result or raises ``ParserError`` (contract errors, PARSE_TIMEOUT, PDF_TOO_LARGE)
    or ``ParseCrashed``.
    """
    cpu_seconds = cpu_limit_seconds()
    wall_seconds = parse_timeout_seconds()
    ctx = _context()
    parent_conn, child_conn = ctx.Pipe(duplex=False)
    proc = ctx.Process(
        target=_child_main,
        args=(child_conn, fn, args, kwargs, cpu_seconds, memory_limit_bytes(), max_inflate_bytes(), _parser_env()),
        daemon=True,
    )
    proc.start()
    child_conn.close()
    message: tuple | None = None
    try:
        if parent_conn.poll(wall_seconds):
            try:
                message = parent_conn.recv()
            except EOFError:
                message = None  # child died before reporting (CPU limit, OOM kill, crash)
        else:
            logger.warning("parse exceeded %.0fs wall clock; killing child pid=%s", wall_seconds, proc.pid)
            proc.kill()
            proc.join(5)
            raise _timeout_error(wall_seconds)
    finally:
        parent_conn.close()
    proc.join(5)
    if proc.is_alive():  # pragma: no cover - defensive
        proc.kill()
        proc.join(5)

    if message is None:
        exitcode = proc.exitcode
        sigxcpu = getattr(signal, "SIGXCPU", None)
        if exitcode in {-signal.SIGKILL, -(sigxcpu or -1)}:
            logger.warning("parse child killed by signal %s (resource limit)", -exitcode if exitcode else exitcode)
            raise _timeout_error(cpu_seconds)
        raise ParseCrashed(f"parse process exited unexpectedly (exit code {exitcode})")

    kind = message[0]
    if kind == "ok":
        return message[1]
    if kind == "parser_error":
        raise ParserError(message[1], message[2])
    if kind == "too_large":
        raise _too_large(message[1])
    raise ParseCrashed(f"{message[1]} in parse process at {message[2]}")


def run_parse(fn: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    """Run a parse under limits: isolated by default, in-process when PARSER_ISOLATION=inline."""
    if isolation_enabled():
        return run_isolated(fn, *args, **kwargs)
    import pdfminer.pdftypes as pdftypes  # noqa: PLC0415

    previous = pdftypes.zlib  # type: ignore[attr-defined]
    shim = install_inflate_guard()
    try:
        try:
            result = fn(*args, **kwargs)
        except InflateBudgetExceeded as exc:
            raise _too_large(_INFLATE_MESSAGE) from exc
        except ParserError as exc:
            if shim.exhausted:
                raise _too_large(_INFLATE_MESSAGE) from exc
            raise
        if shim.exhausted:
            raise _too_large(_INFLATE_MESSAGE)
        return result
    finally:
        pdftypes.zlib = previous  # type: ignore[attr-defined]

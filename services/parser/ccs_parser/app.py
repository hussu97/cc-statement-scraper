"""FastAPI app: ``POST /parse`` (contract parse-v1) and ``GET /health``."""

from __future__ import annotations

import hmac
import logging
import os
import tempfile
import time
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import unquote, urlsplit

import httpx
from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from ccs_parser import CONTRACT_VERSION, PARSER_VERSION
from ccs_parser.contract import ParseRequest
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.sentry import init_sentry, set_bank_tag
from ccs_parser.service import parse_document

logger = logging.getLogger("ccs_parser")

DOWNLOAD_TIMEOUT_SECONDS = 30.0
DEFAULT_MAX_DOWNLOAD_MB = 25

# Permanent (422) error codes from the contract.
PERMANENT_CODES = frozenset(
    {
        "PDF_DECRYPT_FAILED",
        "UNSUPPORTED_BANK",
        "UNSUPPORTED_LAYOUT",
        "BANK_UNDETECTED",
        "DOWNLOAD_FAILED",
        "INVALID_REQUEST",
    }
)


class ServiceError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


def error_response(status_code: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status_code, content={"error": {"code": code, "message": message}})


def status_for_parser_error(code: str) -> int:
    return 422 if code in PERMANENT_CODES else 500


# ------------------------------------------------------------------ config


def _max_download_bytes() -> int:
    try:
        mb = float(os.environ.get("PARSER_MAX_DOWNLOAD_MB") or DEFAULT_MAX_DOWNLOAD_MB)
    except ValueError:
        mb = DEFAULT_MAX_DOWNLOAD_MB
    return int(mb * 1024 * 1024)


def _allowed_hosts() -> set[str]:
    raw = os.environ.get("PARSER_ALLOWED_HOSTS") or ""
    return {h.strip().lower() for h in raw.split(",") if h.strip()}


def _is_production() -> bool:
    return (os.environ.get("SENTRY_ENVIRONMENT") or "").strip().lower() == "production"


# ------------------------------------------------------------------ auth


def require_parser_secret(x_parser_secret: str | None = Header(default=None)) -> None:
    expected = os.environ.get("PARSER_SECRET") or ""
    provided = x_parser_secret or ""
    # Fail closed when the service has no secret configured.
    if not expected or not hmac.compare_digest(provided.encode("utf-8"), expected.encode("utf-8")):
        raise ServiceError(401, "UNAUTHORIZED", "Missing or invalid X-Parser-Secret.")


# ------------------------------------------------------------------ download


def validate_document_url(url: str) -> None:
    try:
        parts = urlsplit(url)
    except ValueError:
        raise ServiceError(422, "DOWNLOAD_FAILED", "document_url is not a valid URL.")
    allow_http = (os.environ.get("PARSER_ALLOW_HTTP") or "").lower() in {"1", "true", "yes"}
    if parts.scheme != "https" and not (allow_http and parts.scheme == "http"):
        raise ServiceError(422, "DOWNLOAD_FAILED", "document_url must use https.")
    host = (parts.hostname or "").lower()
    if not host:
        raise ServiceError(422, "DOWNLOAD_FAILED", "document_url has no host.")
    allowed = _allowed_hosts()
    if allowed and host not in allowed:
        raise ServiceError(422, "DOWNLOAD_FAILED", "document_url host is not allowed.")


def download_document(url: str, dest: Path, *, transport: httpx.BaseTransport | None = None) -> int:
    """Stream ``url`` into ``dest``. Returns bytes written.

    4xx responses, oversize bodies and invalid URLs are permanent (422
    DOWNLOAD_FAILED). Timeouts, connection errors, 429 and 5xx are transient (502).
    """
    validate_document_url(url)
    max_bytes = _max_download_bytes()
    written = 0
    try:
        with httpx.Client(timeout=DOWNLOAD_TIMEOUT_SECONDS, follow_redirects=False, transport=transport) as client:
            with client.stream("GET", url) as response:
                status = response.status_code
                if status == 429 or status >= 500:
                    raise ServiceError(502, "DOWNLOAD_FAILED", f"Storage responded with HTTP {status}.")
                if status != 200:
                    raise ServiceError(422, "DOWNLOAD_FAILED", f"Storage responded with HTTP {status}.")
                declared = response.headers.get("content-length")
                if declared and declared.isdigit() and int(declared) > max_bytes:
                    raise ServiceError(422, "DOWNLOAD_FAILED", "Document exceeds the maximum download size.")
                with dest.open("wb") as fh:
                    for chunk in response.iter_bytes():
                        written += len(chunk)
                        if written > max_bytes:
                            raise ServiceError(422, "DOWNLOAD_FAILED", "Document exceeds the maximum download size.")
                        fh.write(chunk)
    except httpx.TimeoutException:
        raise ServiceError(502, "DOWNLOAD_FAILED", "Timed out downloading the document.")
    except httpx.HTTPError as exc:
        raise ServiceError(502, "DOWNLOAD_FAILED", f"Error downloading the document ({type(exc).__name__}).")
    if written == 0:
        raise ServiceError(422, "DOWNLOAD_FAILED", "Downloaded document is empty.")
    return written


def _filename_from_url(url: str) -> str | None:
    try:
        name = PurePosixPath(unquote(urlsplit(url).path)).name
    except ValueError:
        return None
    return name or None


# ------------------------------------------------------------------ app


def create_app() -> FastAPI:
    init_sentry()
    production = _is_production()
    app = FastAPI(
        title="ccs-parser",
        version=PARSER_VERSION,
        docs_url=None if production else "/docs",
        redoc_url=None,
        openapi_url=None if production else "/openapi.json",
    )

    @app.exception_handler(ServiceError)
    def _service_error(_: Request, exc: ServiceError) -> JSONResponse:
        return error_response(exc.status_code, exc.code, exc.message)

    @app.exception_handler(ParserError)
    def _parser_error(_: Request, exc: ParserError) -> JSONResponse:
        status = status_for_parser_error(exc.code)
        code = exc.code if status == 422 else "INTERNAL_ERROR"
        return error_response(status, code, exc.message)

    @app.exception_handler(RequestValidationError)
    def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        fields = sorted({".".join(str(p) for p in err.get("loc", ()) if p != "body") for err in exc.errors()})
        return error_response(422, "INVALID_REQUEST", f"Invalid request body: {', '.join(f for f in fields if f)}")

    @app.exception_handler(Exception)
    def _unhandled(_: Request, exc: Exception) -> JSONResponse:
        logger.exception("unhandled error: %s", type(exc).__name__)
        return error_response(500, "INTERNAL_ERROR", "Internal parser error.")

    @app.get("/health")
    def health() -> dict[str, Any]:
        return {"status": "ok", "parser_version": PARSER_VERSION, "contract_version": CONTRACT_VERSION}

    @app.post("/parse", dependencies=[Depends(require_parser_secret)])
    def parse(body: ParseRequest) -> JSONResponse:
        # Sync on purpose: pdfplumber is blocking, so FastAPI runs this in its threadpool.
        started = time.monotonic()
        set_bank_tag(body.bank_code_hint)
        filename = body.filename or _filename_from_url(body.document_url)
        with tempfile.TemporaryDirectory(prefix="ccs-parser-") as tmp:
            pdf_path = Path(tmp) / "document.pdf"
            size = download_document(body.document_url, pdf_path)
            try:
                result = parse_document(
                    pdf_path,
                    filename=filename,
                    bank_code_hint=body.bank_code_hint,
                    settings=body.settings,
                )
            except ParserError as exc:
                logger.warning("parse failed | code=%s hint=%s bytes=%d", exc.code, body.bank_code_hint, size)
                raise
        set_bank_tag(result["bank_code"])
        logger.info(
            "parsed | bank=%s kind=%s statements=%d lines=%d bytes=%d ms=%d",
            result["bank_code"],
            result["document_kind"],
            len(result["statements"]),
            sum(len(s["lines"]) for s in result["statements"]),
            size,
            int((time.monotonic() - started) * 1000),
        )
        return JSONResponse(result)

    if not production:

        @app.get("/debug-sentry", dependencies=[Depends(require_parser_secret)])
        def debug_sentry() -> None:
            raise RuntimeError("ccs-parser Sentry test error")

    return app


logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(name)s %(message)s")
app = create_app()

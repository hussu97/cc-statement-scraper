from __future__ import annotations

import logging
import threading

from ccs_platform.db.models.operations import JobLog
from ccs_platform.db.session import get_session_local

# Loggers to capture — only ccs_platform and playwright output is useful.
# SQLAlchemy, httpx, and other infra loggers are excluded.
_CAPTURE_PREFIXES = ("ccs_platform.", "playwright.", "asyncio")

_thread_local = threading.local()


def set_current_job_id(job_id: int | None) -> None:
    _thread_local.job_id = job_id


def get_current_job_id() -> int | None:
    return getattr(_thread_local, "job_id", None)


class JobDBLogHandler(logging.Handler):
    """Captures log records emitted by the current job thread and writes them to job_logs."""

    def filter(self, record: logging.LogRecord) -> bool:
        if get_current_job_id() is None:
            return False
        if record.levelno < logging.INFO:
            return False
        return any(record.name.startswith(prefix) for prefix in _CAPTURE_PREFIXES)

    def emit(self, record: logging.LogRecord) -> None:
        job_id = get_current_job_id()
        if job_id is None:
            return
        try:
            message = self.format(record)
            with get_session_local()() as db:
                db.add(
                    JobLog(
                        job_id=job_id,
                        level=record.levelname.lower(),
                        logger=record.name[:128],
                        message=message[:4000],
                    )
                )
                db.commit()
        except Exception:  # noqa: BLE001
            pass  # never let logging errors affect the job


_handler: JobDBLogHandler | None = None
_handler_lock = threading.Lock()


def install_handler() -> None:
    """Install the DB log handler into the root logger (idempotent)."""
    global _handler  # noqa: PLW0603
    with _handler_lock:
        if _handler is not None:
            return
        _handler = JobDBLogHandler()
        _handler.setFormatter(logging.Formatter("%(message)s"))
        logging.getLogger().addHandler(_handler)

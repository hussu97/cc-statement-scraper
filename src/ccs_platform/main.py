from __future__ import annotations

from contextlib import asynccontextmanager
import logging
import time
from threading import Thread
import uuid

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from ccs_platform.core.logging import configure_logging
from ccs_platform.core.metrics import METRICS
from ccs_platform.core.settings import get_settings
from ccs_platform.db import db_session, init_db
from ccs_platform.api.v1.router import router as api_v1_router
from ccs_platform.application.jobs.runner import JobRunner
from ccs_platform.application.jobs.dispatch import build_job_dispatcher
from ccs_platform.application.bootstrap.seed import seed_defaults
from ccs_platform.adapters.storage import build_storage_adapter
from ccs_platform.application.jobs.worker_loop import WorkerLoop

logger = logging.getLogger(__name__)


def _extract_api_token(request: Request) -> str | None:
    auth_header = request.headers.get("Authorization")
    if auth_header:
        scheme, _, token = auth_header.partition(" ")
        if scheme.lower() == "bearer" and token.strip():
            return token.strip()

    token_header = request.headers.get("X-Admin-Token")
    if token_header and token_header.strip():
        return token_header.strip()
    return None


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    configure_logging(level_name=settings.log_level)

    if settings.api_auth_enabled() and not settings.api_auth_token:
        raise RuntimeError(
            "API auth is enabled but CCS_PLATFORM_API_AUTH_TOKEN is not set."
        )

    init_db()
    with db_session() as db:
        seed_defaults(db)

    storage = build_storage_adapter(settings)
    runner = JobRunner(settings=settings, storage=storage)
    dispatcher = build_job_dispatcher(settings=settings, runner=runner)

    app.state.settings = settings
    app.state.storage = storage
    app.state.job_runner = runner
    app.state.job_dispatcher = dispatcher

    loop = None
    thread = None
    if settings.embedded_worker and settings.job_dispatch_backend.strip().lower() != "inprocess":
        loop = WorkerLoop(settings=settings, job_runner=runner)
        thread = Thread(target=loop.run_forever, daemon=True)
        thread.start()

    try:
        yield
    finally:
        if loop is not None:
            loop.stop()
        if thread is not None:
            thread.join(timeout=2)
        runner.shutdown()


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title=settings.app_name, lifespan=lifespan)

    origins = [token.strip() for token in settings.cors_allow_origins.split(",") if token.strip()]
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins if origins else ["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(api_v1_router, prefix=settings.api_prefix)

    api_prefix = settings.api_prefix.rstrip("/")
    exempt_paths = settings.api_auth_exempt_path_set()

    @app.middleware("http")
    async def guard_and_log_requests(request: Request, call_next):
        request_id = request.headers.get(settings.request_id_header) or uuid.uuid4().hex
        start = time.perf_counter()
        response = None
        status_code = 500

        try:
            if settings.api_auth_enabled():
                path = request.url.path
                is_api_path = path == api_prefix or path.startswith(f"{api_prefix}/")
                if is_api_path and path not in exempt_paths:
                    token = _extract_api_token(request)
                    if token != settings.api_auth_token:
                        response = JSONResponse(status_code=401, content={"detail": "Unauthorized"})

            if response is None:
                response = await call_next(request)

            status_code = response.status_code
            response.headers[settings.request_id_header] = request_id
            return response
        except Exception:
            logger.exception(
                "Unhandled request error | request_id=%s method=%s path=%s",
                request_id,
                request.method,
                request.url.path,
            )
            raise
        finally:
            duration_ms = (time.perf_counter() - start) * 1000.0
            if settings.request_logging_enabled:
                logger.info(
                    "HTTP request | request_id=%s method=%s path=%s status=%s duration_ms=%.2f",
                    request_id,
                    request.method,
                    request.url.path,
                    status_code,
                    duration_ms,
                )
            METRICS.record_request(
                method=request.method,
                path=request.url.path,
                status_code=status_code,
                duration_ms=duration_ms,
            )

    return app


app = create_app()

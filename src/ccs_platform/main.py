from __future__ import annotations

from contextlib import asynccontextmanager
from threading import Thread

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from ccs_platform.core.settings import get_settings
from ccs_platform.db import db_session, init_db
from ccs_platform.api.v1.router import router as api_v1_router
from ccs_platform.application.jobs.runner import JobRunner
from ccs_platform.application.bootstrap.seed import seed_defaults
from ccs_platform.adapters.storage import build_storage_adapter
from ccs_platform.application.jobs.worker_loop import WorkerLoop


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()

    init_db()
    with db_session() as db:
        seed_defaults(db)

    storage = build_storage_adapter(settings)
    runner = JobRunner(settings=settings, storage=storage)

    app.state.settings = settings
    app.state.storage = storage
    app.state.job_runner = runner

    loop = None
    thread = None
    if settings.embedded_worker:
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

    return app


app = create_app()

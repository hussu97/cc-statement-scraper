from __future__ import annotations

import signal

from ccs_platform.core.settings import get_settings
from ccs_platform.db import db_session, init_db
from ccs_platform.application.jobs.runner import JobRunner
from ccs_platform.application.bootstrap.seed import seed_defaults
from ccs_platform.adapters.storage import build_storage_adapter
from ccs_platform.application.jobs.worker_loop import WorkerLoop


def run_worker() -> None:
    settings = get_settings()

    init_db()
    with db_session() as db:
        seed_defaults(db)

    storage = build_storage_adapter(settings)
    runner = JobRunner(settings=settings, storage=storage)
    loop = WorkerLoop(settings=settings, job_runner=runner)

    def _stop(*_args):
        loop.stop()

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    try:
        loop.run_forever()
    finally:
        runner.shutdown()


if __name__ == "__main__":
    run_worker()

from __future__ import annotations

import typer
import uvicorn

from ccs_platform.main import app
from ccs_platform.worker.main import run_worker


cli = typer.Typer(help="CCS platform backend and worker commands")


@cli.command("api")
def run_api(host: str = "127.0.0.1", port: int = 8000, reload: bool = False) -> None:
    uvicorn.run("ccs_platform.main:app", host=host, port=port, reload=reload)


@cli.command("worker")
def run_worker_cmd() -> None:
    run_worker()


if __name__ == "__main__":
    cli()

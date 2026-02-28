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


@cli.command("hash-password")
def hash_password(
    password: str = typer.Option(..., prompt=True, hide_input=True, confirmation_prompt=True),
) -> None:
    """Generate a bcrypt hash for a login password.

    Paste the output into CCS_PLATFORM_LOGIN_HASH_<NAME> in your .env file.
    The plaintext password is never stored or logged.
    """
    import bcrypt

    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12)).decode()
    typer.echo(hashed)


if __name__ == "__main__":
    cli()

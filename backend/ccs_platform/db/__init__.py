from ccs_platform.db.base import Base
from ccs_platform.db import models
from ccs_platform.db.session import get_db, db_session, init_db, get_engine, get_session_local


def __getattr__(name: str):
    if name == "engine":
        return get_engine()
    if name == "SessionLocal":
        return get_session_local()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


__all__ = [
    "Base",
    "SessionLocal",
    "db_session",
    "engine",
    "get_db",
    "get_engine",
    "get_session_local",
    "init_db",
    "models",
]

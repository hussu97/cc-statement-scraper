from __future__ import annotations

import logging
import sys


def configure_logging(*, level_name: str) -> None:
    level = getattr(logging, level_name.upper(), logging.INFO)
    root_logger = logging.getLogger()
    root_logger.setLevel(level)

    # Always ensure there is a StreamHandler on root writing to stderr.
    # logging.basicConfig() is a no-op when root already has handlers (e.g.
    # after uvicorn has run its own dictConfig), so we add ours explicitly.
    has_stderr_handler = any(
        isinstance(h, logging.StreamHandler)
        and getattr(h, "stream", None) is sys.stderr
        for h in root_logger.handlers
    )
    if not has_stderr_handler:
        handler = logging.StreamHandler(sys.stderr)
        handler.setLevel(level)
        handler.setFormatter(
            logging.Formatter("%(asctime)s | %(levelname)s | %(name)s | %(message)s")
        )
        root_logger.addHandler(handler)
    else:
        for h in root_logger.handlers:
            h.setLevel(level)

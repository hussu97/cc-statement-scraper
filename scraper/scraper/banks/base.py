from __future__ import annotations

"""Shared protocol that every bank adapter module must satisfy.

Each bank adapter lives in ``adapters/banks/browser/banks/<name>.py`` and
exposes three module-level functions.  This module formalises that contract
using :class:`typing.Protocol` so that the dispatcher in ``downloader.py``
can be statically type-checked and new adapters get a clear surface to
implement.
"""

import logging
from pathlib import Path
from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class LoginFn(Protocol):
    """Called once to authenticate a browser session for a bank."""

    def __call__(
        self,
        page: Any,
        logger: logging.Logger,
        credentials: dict[str, str] | None = None,
    ) -> None: ...


@runtime_checkable
class LoginSelectorVisibleFn(Protocol):
    """Returns ``True`` when the bank's login form is currently visible."""

    def __call__(self, page: Any) -> bool: ...


@runtime_checkable
class DownloadLatestStatementFn(Protocol):
    """Navigates to statements and triggers downloads; returns file count."""

    def __call__(
        self,
        page: Any,
        incoming_dir: Path,
        logger: logging.Logger,
        bank_cfg: dict[str, Any],
    ) -> int: ...


class BankAdapter:
    """Thin struct that groups the three functions for a single bank.

    Construct one per bank code and register it in the dispatcher table
    instead of maintaining three separate ``dict[str, Callable]`` maps.

    Example::

        from ccs_platform.adapters.banks.browser.banks import fab
        from ccs_platform.adapters.banks.browser.base import BankAdapter

        FAB = BankAdapter(
            code="FAB",
            login=fab.login,
            login_selector_visible=fab.login_selector_visible,
            download_latest_statement=fab.download_latest_statement,
        )
    """

    __slots__ = ("code", "login", "login_selector_visible", "download_latest_statement")

    def __init__(
        self,
        *,
        code: str,
        login: LoginFn,
        login_selector_visible: LoginSelectorVisibleFn,
        download_latest_statement: DownloadLatestStatementFn,
    ) -> None:
        self.code = code.upper()
        self.login = login
        self.login_selector_visible = login_selector_visible
        self.download_latest_statement = download_latest_statement

    def __repr__(self) -> str:
        return f"BankAdapter(code={self.code!r})"

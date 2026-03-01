from __future__ import annotations

"""Shared protocol that every bank adapter module must satisfy.

Each bank adapter lives in ``adapters/banks/browser/banks/<name>.py`` and
exposes three module-level functions.  This module formalises that contract
using :class:`typing.Protocol` so that the dispatcher in ``downloader.py``
can be statically type-checked and new adapters get a clear surface to
implement.
"""

import logging
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Protocol, runtime_checkable


class AuthPollAction(Enum):
    """Action returned by an adapter's ``on_auth_poll_tick`` hook.

    The polling loop in ``_wait_for_authenticated_session`` inspects this
    value after each tick to decide what to do next.
    """

    CONTINUE = "CONTINUE"
    """No special action; proceed with the standard checks."""

    AUTHENTICATED = "AUTHENTICATED"
    """The adapter has positively confirmed authentication; return page immediately."""

    RETRY_LOGIN = "RETRY_LOGIN"
    """Re-invoke ``adapter.login`` (without credentials), then continue polling."""

    WAIT = "WAIT"
    """Skip the rest of this iteration and sleep before the next tick."""


@dataclass
class AuthPollState:
    """Mutable state bag passed to ``on_auth_poll_tick`` on every iteration.

    The polling loop owns this object and updates the numeric fields before
    each call.  Adapters may read all fields and may freely mutate ``extra``
    to store private per-bank state across ticks.
    """

    elapsed_seconds: float = 0.0
    prompted_for_mfa: bool = False
    relogin_attempts: int = 0
    last_login_attempt_unix: float = 0.0
    portal_url: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)


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
    """Thin struct that groups the three required functions plus optional hooks
    for a single bank.

    Construct one per bank code and register it via ``discover_adapters()``
    instead of maintaining three separate ``dict[str, Callable]`` maps.

    Required parameters
    -------------------
    code
        Uppercase bank code, e.g. ``"FAB"``.
    login
        Authenticate a browser session.
    login_selector_visible
        Return ``True`` when the bank's login form is visible.
    download_latest_statement
        Navigate to statements and trigger downloads; return file count.

    Optional hook parameters
    ------------------------
    is_authenticated_session
        Return ``True`` when the page represents a confirmed post-login state.
        Default: always ``False`` (falls through to generic keyword checks).
    is_login_screen
        Return ``True`` when the page is the bank's login screen.
        Default: always ``False``.
    is_login_failure
        Return ``True`` when the page shows a login failure.
        Default: delegates to ``shared.is_login_failure``.
    on_auth_poll_tick
        Called once per polling iteration.  Returns an :class:`AuthPollAction`
        that controls the loop's next step.  Default: ``CONTINUE``.
    skip_mfa_user_prompt
        When ``True`` the interactive "approve in banking app" prompt is
        suppressed (ADCB handles OTP automatically).  Default: ``False``.
    skip_keyword_fallback
        When ``True`` the generic ``POST_LOGIN_KEYWORDS`` check is skipped.
        Default: ``False``.
    skip_login_selector_fallback
        When ``True`` the login-selector-visible + keyword fallback is skipped.
        Default: ``False``.
    browser_launch_overrides
        Return a ``dict`` with optional keys ``channel_candidates`` (list of
        channel strings or ``None``) and ``init_scripts`` (list of JS strings)
        to inject into the browser context.  Default: empty dict.
    """

    __slots__ = (
        "code",
        "login",
        "login_selector_visible",
        "download_latest_statement",
        "is_authenticated_session",
        "is_login_screen",
        "is_login_failure",
        "on_auth_poll_tick",
        "skip_mfa_user_prompt",
        "skip_keyword_fallback",
        "skip_login_selector_fallback",
        "browser_launch_overrides",
    )

    def __init__(
        self,
        *,
        code: str,
        login: LoginFn,
        login_selector_visible: LoginSelectorVisibleFn,
        download_latest_statement: DownloadLatestStatementFn,
        # Optional hooks
        is_authenticated_session: Callable[[Any, str], bool] | None = None,
        is_login_screen: Callable[[str], bool] | None = None,
        is_login_failure: Callable[[str], bool] | None = None,
        on_auth_poll_tick: Callable[[Any, str, logging.Logger, AuthPollState], AuthPollAction] | None = None,
        skip_mfa_user_prompt: bool = False,
        skip_keyword_fallback: bool = False,
        skip_login_selector_fallback: bool = False,
        browser_launch_overrides: Callable[[], dict[str, Any]] | None = None,
    ) -> None:
        from scraper.banks.shared import is_login_failure as _default_is_login_failure  # local import to avoid circular

        self.code = code.upper()
        self.login = login
        self.login_selector_visible = login_selector_visible
        self.download_latest_statement = download_latest_statement

        self.is_authenticated_session: Callable[[Any, str], bool] = (
            is_authenticated_session if is_authenticated_session is not None else (lambda page, text: False)
        )
        self.is_login_screen: Callable[[str], bool] = (
            is_login_screen if is_login_screen is not None else (lambda text: False)
        )
        self.is_login_failure: Callable[[str], bool] = (
            is_login_failure if is_login_failure is not None else _default_is_login_failure
        )
        self.on_auth_poll_tick: Callable[[Any, str, logging.Logger, AuthPollState], AuthPollAction] = (
            on_auth_poll_tick if on_auth_poll_tick is not None
            else (lambda page, text, logger, state: AuthPollAction.CONTINUE)
        )
        self.skip_mfa_user_prompt: bool = skip_mfa_user_prompt
        self.skip_keyword_fallback: bool = skip_keyword_fallback
        self.skip_login_selector_fallback: bool = skip_login_selector_fallback
        self.browser_launch_overrides: Callable[[], dict[str, Any]] = (
            browser_launch_overrides if browser_launch_overrides is not None else (lambda: {})
        )

    def __repr__(self) -> str:
        return f"BankAdapter(code={self.code!r})"

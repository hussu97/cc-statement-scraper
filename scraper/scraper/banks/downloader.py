from __future__ import annotations

import logging
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Optional

from scraper.banks.adapters import discover_adapters
from scraper.banks.base import AuthPollAction, AuthPollState
from scraper.banks.shared import (
    BrowserDownloadError,
    POST_LOGIN_KEYWORDS,
    build_logger,
    count_new_or_updated_pdfs,
    is_mfa_pending,
    safe_screenshot,
    snapshot_pdf_state,
    text_snapshot,
)
from scraper.banks.bank_config import AppConfig

CHROMIUM_SINGLETON_FILES = ("SingletonLock", "SingletonCookie", "SingletonSocket")

BANK_ADAPTERS = discover_adapters()

# Legacy aliases kept for callers that still reference the individual dicts.
LOGIN_HANDLERS = {code: adapter.login for code, adapter in BANK_ADAPTERS.items()}
LOGIN_SELECTOR_VISIBLE = {
    code: adapter.login_selector_visible for code, adapter in BANK_ADAPTERS.items()
}
DOWNLOAD_HANDLERS = {
    code: adapter.download_latest_statement for code, adapter in BANK_ADAPTERS.items()
}


def _login_selector_visible(page: Any, bank_code: str) -> bool:
    adapter = BANK_ADAPTERS.get(bank_code.upper())
    if adapter is None:
        return False
    try:
        return adapter.login_selector_visible(page)
    except Exception:  # noqa: BLE001
        return False


def _execute_bank_login(page: Any, bank_code: str, logger: logging.Logger, credentials: dict[str, str]) -> None:
    adapter = BANK_ADAPTERS.get(bank_code.upper())
    if adapter is None:
        raise BrowserDownloadError(f"Unsupported bank code for browser flow: {bank_code}")
    adapter.login(page, logger, credentials)


def _execute_bank_download(
    page: Any,
    bank_code: str,
    incoming_dir,
    logger: logging.Logger,
    bank_cfg: dict,
) -> int:
    adapter = BANK_ADAPTERS.get(bank_code.upper())
    if adapter is None:
        raise BrowserDownloadError(f"Unsupported bank code for browser flow: {bank_code}")
    return adapter.download_latest_statement(page, incoming_dir, logger, bank_cfg)


def _wait_for_authenticated_session(
    *,
    page,
    bank_code: str,
    timeout_seconds: int,
    scheduled: bool,
    logger: logging.Logger,
    portal_url: str | None = None,
    cancel_check: Optional[Callable[[], None]] = None,
) -> Any:
    def _active_page(current_page: Any) -> Any:
        try:
            if not current_page.is_closed():
                return current_page
        except Exception:  # noqa: BLE001
            return current_page

        try:
            candidates = [p for p in current_page.context.pages if not p.is_closed()]
        except Exception:  # noqa: BLE001
            candidates = []

        if candidates:
            newest = candidates[-1]
            logger.info("%s: switched to active page after tab/window transition", bank_code)
            return newest

        raise BrowserDownloadError(f"{bank_code}: browser page was closed during authentication flow")

    adapter = BANK_ADAPTERS.get(bank_code.upper())
    if adapter is None:
        raise BrowserDownloadError(f"Unsupported bank code for browser flow: {bank_code}")

    start = time.time()
    state = AuthPollState(
        last_login_attempt_unix=start,
        portal_url=portal_url,
    )

    while time.time() - start < timeout_seconds:
        if cancel_check is not None:
            cancel_check()

        page = _active_page(page)
        state.elapsed_seconds = time.time() - start

        text = text_snapshot(page)
        low = text.lower()

        # --- Adapter tick hook ---
        action = adapter.on_auth_poll_tick(page, low, logger, state)

        if action is AuthPollAction.AUTHENTICATED:
            logger.info("%s: authenticated session confirmed by adapter tick hook", bank_code)
            return page

        if action is AuthPollAction.RETRY_LOGIN:
            adapter.login(page, logger)
            state.relogin_attempts += 1
            state.last_login_attempt_unix = time.time()
            time.sleep(2)
            continue

        if action is AuthPollAction.WAIT:
            page = _active_page(page)
            page.wait_for_timeout(1200)
            continue

        # action is CONTINUE — proceed with generic checks

        # Refresh text after tick hook (hook may have navigated)
        text = text_snapshot(page)
        low = text.lower()

        # --- Login failure check ---
        if adapter.is_login_failure(low):
            raise BrowserDownloadError(f"{bank_code}: login failed ({text[:200]})")

        # --- MFA pending check ---
        if is_mfa_pending(low):
            if adapter.skip_mfa_user_prompt:
                if not state.prompted_for_mfa:
                    logger.info("%s: MFA/OTP challenge detected; waiting for completion.", bank_code)
                    state.prompted_for_mfa = True
            elif not state.prompted_for_mfa:
                logger.info("%s: MFA/app approval detected; waiting for confirmation.", bank_code)
                if not scheduled:
                    if sys.stdin is not None and sys.stdin.isatty():
                        try:
                            input(
                                f"[{bank_code}] Approve login in banking app/device, then press Enter to continue... "
                            )
                        except EOFError:
                            pass
                    else:
                        logger.info(
                            "%s: non-interactive session detected; continuing to poll for MFA completion",
                            bank_code,
                        )
                state.prompted_for_mfa = True
            time.sleep(2)
            continue

        # --- Adapter auth detection ---
        if adapter.is_authenticated_session(page, low):
            logger.info("%s: authenticated session detected", bank_code)
            return page

        # --- Adapter login screen detection ---
        if adapter.is_login_screen(low):
            time.sleep(2)
            continue

        # --- Generic keyword fallback: login-selector + keywords ---
        if not adapter.skip_login_selector_fallback and not _login_selector_visible(page, bank_code):
            if any(keyword in low for keyword in POST_LOGIN_KEYWORDS):
                logger.info("%s: authenticated session detected", bank_code)
                return page

        # --- Generic keyword fallback: aggressive POST_LOGIN_KEYWORDS check ---
        if not adapter.skip_keyword_fallback:
            if any(keyword in low for keyword in POST_LOGIN_KEYWORDS) and "welcome" not in low:
                logger.info("%s: proceeding with post-login navigation", bank_code)
                return page

        time.sleep(2)

    raise BrowserDownloadError(f"{bank_code}: timed out waiting for authenticated session")


def _manual_download_fallback(
    *,
    bank_code: str,
    scheduled: bool,
    logger: logging.Logger,
) -> None:
    if scheduled:
        return

    logger.info(
        "%s: automatic statement download not detected; please download latest statement manually in the opened session.",
        bank_code,
    )
    try:
        input(
            f"[{bank_code}] If statement did not auto-download, download it manually now, then press Enter... "
        )
    except EOFError:
        pass


def _clear_stale_chromium_profile_artifacts(profile_dir: Path, bank_code: str, logger: logging.Logger) -> None:
    for artifact_name in CHROMIUM_SINGLETON_FILES:
        artifact_path = profile_dir / artifact_name
        try:
            if artifact_path.exists() or artifact_path.is_symlink():
                artifact_path.unlink(missing_ok=True)
                logger.warning(
                    "%s: removed stale Chromium profile artifact %s",
                    bank_code,
                    artifact_name,
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "%s: unable to remove profile artifact %s (%s)",
                bank_code,
                artifact_name,
                exc,
            )


def _launch_bank_context(
    *,
    playwright: Any,
    profile_dir: Path,
    headless: bool,
    incoming_dir: Path,
    bank_code: str,
    logger: logging.Logger,
    proxy_url: str | None = None,
    geo_latitude: float = 25.2048,
    geo_longitude: float = 55.2708,
    timezone_id: str = "Asia/Dubai",
    locale: str = "en-AE",
) -> Any:
    def _missing_chrome_channel_error(exc: Exception) -> bool:
        low = str(exc).lower()
        return (
            "chromium distribution 'chrome' is not found" in low
            or "channel \"chrome\"" in low
            or ("executable doesn't exist" in low and "chrome" in low)
        )

    adapter = BANK_ADAPTERS.get(bank_code.upper())
    overrides = adapter.browser_launch_overrides() if adapter is not None else {}
    launch_channel_candidates: list[str | None] = overrides.get("channel_candidates", [None])
    extra_init_scripts: list[str] = overrides.get("init_scripts", [])

    max_attempts = 3
    for attempt in range(1, max_attempts + 1):
        try:
            launch_kwargs: dict[str, Any] = {
                "user_data_dir": str(profile_dir),
                "headless": headless,
                "accept_downloads": True,
                "downloads_path": str(incoming_dir),
                "geolocation": {"latitude": geo_latitude, "longitude": geo_longitude},
                "permissions": ["geolocation"],
                "timezone_id": timezone_id,
                "locale": locale,
            }
            if proxy_url:
                launch_kwargs["proxy"] = {"server": proxy_url}
                logger.info("%s: routing browser traffic via proxy %s", bank_code, proxy_url)
            # Strip the automation flag globally — it's the single most obvious bot signal.
            launch_kwargs["args"] = ["--disable-blink-features=AutomationControlled"]

            context = None
            launch_error: Exception | None = None
            for channel in launch_channel_candidates:
                kwargs = dict(launch_kwargs)
                if channel is not None:
                    kwargs["channel"] = channel
                try:
                    context = playwright.chromium.launch_persistent_context(**kwargs)
                    break
                except Exception as channel_exc:  # noqa: BLE001
                    launch_error = channel_exc
                    if channel is not None and _missing_chrome_channel_error(channel_exc):
                        logger.warning(
                            "%s: chrome channel unavailable, falling back to bundled Chromium",
                            bank_code,
                        )
                        continue
                    raise

            if context is None:
                if launch_error is not None:
                    raise launch_error
                raise BrowserDownloadError(f"{bank_code}: failed to launch browser context")

            # Global: patch navigator.webdriver and window.chrome.runtime for all banks.
            # navigator.languages is intentionally left to the locale setting (en-AE) —
            # overriding it here would contradict the locale we set at context level.
            context.add_init_script(
                """
                Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
                window.chrome = window.chrome || { runtime: {} };
                """
            )
            for script in extra_init_scripts:
                context.add_init_script(script)

            return context
        except Exception as exc:  # noqa: BLE001
            message = str(exc).lower()
            lock_error = (
                "processsingleton" in message
                or "profile is already in use" in message
                or "singletonlock" in message
            )
            if not lock_error:
                raise
            if attempt >= max_attempts:
                raise BrowserDownloadError(
                    f"{bank_code}: Chromium profile is locked at {profile_dir}. "
                    "Close other Chrome instances using this profile and retry."
                ) from exc
            logger.warning(
                "%s: profile lock detected (attempt %d/%d); retrying",
                bank_code,
                attempt,
                max_attempts,
            )
            # Stale singleton artifacts are common after abrupt process exits.
            _clear_stale_chromium_profile_artifacts(profile_dir, bank_code, logger)
            time.sleep(float(attempt))

    raise BrowserDownloadError(f"{bank_code}: failed to launch browser context")


def _run_cancel_monitor(
    *,
    cancel_check: Callable[[], None],
    context_holder: list,
    stop_event: threading.Event,
    logger: logging.Logger,
    bank_code: str,
) -> None:
    """Background thread: polls cancel_check every 2 s and closes the browser context if cancelled."""
    while not stop_event.wait(2.0):
        try:
            cancel_check()
        except Exception:  # noqa: BLE001
            ctx = context_holder[0]
            if ctx is not None:
                try:
                    logger.warning("%s: cancellation detected; closing browser context", bank_code)
                    ctx.close()
                except Exception:  # noqa: BLE001
                    pass
            return


def run_end_to_end_downloads(
    *,
    app_config: AppConfig,
    scheduled: bool,
    login_timeout_minutes: int = 20,
    headless: bool = False,
    credentials: dict[str, str] | None = None,
    proxy_url: str | None = None,
    geo_latitude: float = 25.2048,
    geo_longitude: float = 55.2708,
    timezone_id: str = "Asia/Dubai",
    locale: str = "en-AE",
    cancel_check: Optional[Callable[[], None]] = None,
) -> dict[str, str]:
    try:
        from playwright.sync_api import sync_playwright
    except Exception as exc:  # noqa: BLE001
        raise BrowserDownloadError(
            "Playwright is not available. Install dependencies and run 'playwright install chromium'."
        ) from exc

    app_config.paths.incoming_dir.mkdir(parents=True, exist_ok=True)
    logger = build_logger(app_config.paths.root)

    results: dict[str, str] = {}
    timeout_seconds = login_timeout_minutes * 60

    with sync_playwright() as playwright:
        for bank_code, bank_cfg in app_config.banks.items():
            tracked_dirs = [app_config.paths.incoming_dir]
            before = snapshot_pdf_state(tracked_dirs)
            portal_url = bank_cfg.get("portal_url")
            profile_dir = app_config.paths.state_dir / "browser_profiles" / bank_code
            profile_dir.mkdir(parents=True, exist_ok=True)
            run_stamp = datetime.now().strftime("%Y%m%d%H%M%S")
            context = None
            page = None
            context_holder: list = [None]
            cancel_monitor_stop = threading.Event()
            cancel_monitor_thread: threading.Thread | None = None

            if cancel_check is not None:
                cancel_monitor_thread = threading.Thread(
                    target=_run_cancel_monitor,
                    kwargs={
                        "cancel_check": cancel_check,
                        "context_holder": context_holder,
                        "stop_event": cancel_monitor_stop,
                        "logger": logger,
                        "bank_code": bank_code,
                    },
                    daemon=True,
                )
                cancel_monitor_thread.start()

            logger.info("%s: opening portal %s", bank_code, portal_url)

            try:
                context = _launch_bank_context(
                    playwright=playwright,
                    profile_dir=profile_dir,
                    headless=headless,
                    incoming_dir=app_config.paths.incoming_dir,
                    bank_code=bank_code,
                    logger=logger,
                    proxy_url=proxy_url,
                    geo_latitude=geo_latitude,
                    geo_longitude=geo_longitude,
                    timezone_id=timezone_id,
                    locale=locale,
                )
                context_holder[0] = context
                page = context.pages[0] if context.pages else context.new_page()

                page.goto(portal_url, wait_until="domcontentloaded", timeout=60000)
                page.wait_for_timeout(1200)
                safe_screenshot(
                    page,
                    app_config.paths.root / "logs" / f"{run_stamp}_{bank_code}_login_page.png",
                    logger,
                )

                _execute_bank_login(page, bank_code, logger, credentials or {})
                page = _wait_for_authenticated_session(
                    page=page,
                    bank_code=bank_code,
                    timeout_seconds=timeout_seconds,
                    scheduled=scheduled,
                    logger=logger,
                    portal_url=portal_url,
                    cancel_check=cancel_check,
                )

                safe_screenshot(
                    page,
                    app_config.paths.root / "logs" / f"{run_stamp}_{bank_code}_post_auth.png",
                    logger,
                )

                auto_downloads = _execute_bank_download(
                    page=page,
                    bank_code=bank_code,
                    incoming_dir=app_config.paths.incoming_dir,
                    logger=logger,
                    bank_cfg=bank_cfg,
                )

                if auto_downloads == 0:
                    explicit_month_request = bool(
                        bank_cfg.get("requested_months") or bank_cfg.get("requested_month")
                    )
                    if explicit_month_request:
                        logger.info(
                            "%s: zero downloads for explicit requested months; skipping manual fallback",
                            bank_code,
                        )
                    else:
                        _manual_download_fallback(
                            bank_code=bank_code,
                            scheduled=scheduled,
                            logger=logger,
                        )

                after = snapshot_pdf_state(tracked_dirs)
                downloaded = count_new_or_updated_pdfs(before, after)

                if downloaded > 0:
                    results[bank_code] = f"SUCCESS downloaded={downloaded}"
                    logger.info("%s: completed with %d downloaded PDF(s)", bank_code, downloaded)
                else:
                    results[bank_code] = "NO_NEW_DOWNLOAD_DETECTED"
                    logger.info("%s: no new PDF detected", bank_code)

                safe_screenshot(
                    page,
                    app_config.paths.root / "logs" / f"{run_stamp}_{bank_code}_final.png",
                    logger,
                )

            except BrowserDownloadError as exc:
                results[bank_code] = f"FAILED {exc}"
                logger.error("%s: %s", bank_code, exc)
                if page is not None:
                    safe_screenshot(
                        page,
                        app_config.paths.root / "logs" / f"{run_stamp}_{bank_code}_error.png",
                        logger,
                    )
            except Exception as exc:  # noqa: BLE001
                results[bank_code] = f"FAILED unexpected_error={exc}"
                logger.exception("%s: unexpected automation error", bank_code)
                if page is not None:
                    safe_screenshot(
                        page,
                        app_config.paths.root / "logs" / f"{run_stamp}_{bank_code}_exception.png",
                        logger,
                    )
            finally:
                cancel_monitor_stop.set()
                context_holder[0] = None
                if cancel_monitor_thread is not None:
                    cancel_monitor_thread.join(timeout=3)
                if context is not None:
                    try:
                        context.close()
                    except Exception:  # noqa: BLE001
                        logger.warning("%s: failed to close browser context cleanly", bank_code)

    return results


# Backwards-compatible alias
run_manual_auth_downloads = run_end_to_end_downloads

from __future__ import annotations

import logging
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from ccs_platform.adapters.banks.browser.banks import adcb, enbd, fab, sib
from ccs_platform.adapters.banks.browser.shared import (
    BrowserDownloadError,
    POST_LOGIN_KEYWORDS,
    build_logger,
    count_new_or_updated_pdfs,
    is_login_failure,
    is_mfa_pending,
    safe_screenshot,
    snapshot_pdf_state,
    text_snapshot,
)
from ccs_platform.core.bank_config import AppConfig

LoginHandler = Callable[[Any, logging.Logger], None]
LoginSelectorVisible = Callable[[Any], bool]
DownloadHandler = Callable[[Any, Any, logging.Logger, dict], int]
CHROMIUM_SINGLETON_FILES = ("SingletonLock", "SingletonCookie", "SingletonSocket")


LOGIN_HANDLERS: dict[str, LoginHandler] = {
    "FAB": fab.login,
    "ADCB": adcb.login,
    "ENBD": enbd.login,
    "SIB": sib.login,
}

LOGIN_SELECTOR_VISIBLE: dict[str, LoginSelectorVisible] = {
    "FAB": fab.login_selector_visible,
    "ADCB": adcb.login_selector_visible,
    "ENBD": enbd.login_selector_visible,
    "SIB": sib.login_selector_visible,
}

DOWNLOAD_HANDLERS: dict[str, DownloadHandler] = {
    "FAB": fab.download_latest_statement,
    "ADCB": adcb.download_latest_statement,
    "ENBD": enbd.download_latest_statement,
    "SIB": sib.download_latest_statement,
}


def _login_selector_visible(page: Any, bank_code: str) -> bool:
    handler = LOGIN_SELECTOR_VISIBLE.get(bank_code.upper())
    if handler is None:
        return False
    try:
        return handler(page)
    except Exception:  # noqa: BLE001
        return False


def _execute_bank_login(page: Any, bank_code: str, logger: logging.Logger) -> None:
    handler = LOGIN_HANDLERS.get(bank_code.upper())
    if handler is None:
        raise BrowserDownloadError(f"Unsupported bank code for browser flow: {bank_code}")
    handler(page, logger)


def _execute_bank_download(
    page: Any,
    bank_code: str,
    incoming_dir,
    logger: logging.Logger,
    bank_cfg: dict,
) -> int:
    handler = DOWNLOAD_HANDLERS.get(bank_code.upper())
    if handler is None:
        raise BrowserDownloadError(f"Unsupported bank code for browser flow: {bank_code}")
    return handler(page, incoming_dir, logger, bank_cfg)


def _wait_for_authenticated_session(
    *,
    page,
    bank_code: str,
    timeout_seconds: int,
    scheduled: bool,
    logger: logging.Logger,
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

    start = time.time()
    prompted_for_mfa = False
    code = bank_code.upper()
    otp_challenge_started_unix: float | None = None
    attempted_otp_codes: set[str] = set()
    adcb_relogin_attempts = 0
    had_adcb_challenge = False
    adcb_last_login_attempt_unix = start

    while time.time() - start < timeout_seconds:
        page = _active_page(page)

        if code == "FAB":
            fab.handle_continue_gate(page, logger)

        text = text_snapshot(page)
        low = text.lower()

        if code == "ADCB":
            if adcb.is_otp_screen(low):
                if otp_challenge_started_unix is None:
                    otp_challenge_started_unix = time.time()
                    attempted_otp_codes.clear()
                had_adcb_challenge = True
            else:
                otp_challenge_started_unix = None
                attempted_otp_codes.clear()

        if is_login_failure(low):
            raise BrowserDownloadError(f"{bank_code}: login failed ({text[:200]})")

        if code == "ADCB" and adcb.handle_concurrent_session_gate(page, logger, low):
            had_adcb_challenge = True
            page = _active_page(page)
            page.wait_for_timeout(1000)
            continue

        if code == "ADCB" and adcb.try_auto_otp(
            page,
            logger,
            low,
            not_before_unix=otp_challenge_started_unix,
            attempted_codes=attempted_otp_codes,
        ):
            page = _active_page(page)
            page.wait_for_timeout(1200)
            continue

        if is_mfa_pending(low):
            if code == "ADCB":
                if not prompted_for_mfa:
                    logger.info("%s: MFA/OTP challenge detected; waiting for completion.", bank_code)
                    prompted_for_mfa = True
                had_adcb_challenge = True
            elif not scheduled and not prompted_for_mfa:
                logger.info("%s: MFA/app approval detected; waiting for confirmation.", bank_code)
                try:
                    input(
                        f"[{bank_code}] Approve login in banking app/device, then press Enter to continue... "
                    )
                except EOFError:
                    pass
                prompted_for_mfa = True
            time.sleep(2)
            continue

        if code == "FAB":
            if fab.is_authenticated_session(page, low):
                logger.info("%s: authenticated session detected", bank_code)
                return page
            if fab.is_login_screen(low):
                time.sleep(2)
                continue
        elif code == "ADCB":
            if adcb.is_authenticated_session(page, low):
                logger.info("%s: authenticated session detected", bank_code)
                return page
            if adcb.is_login_screen(low):
                if (
                    had_adcb_challenge
                    and adcb_relogin_attempts < 2
                    and time.time() - adcb_last_login_attempt_unix >= 8
                ):
                    logger.info("%s: returned to login after challenge; retrying login", bank_code)
                    adcb.login(page, logger)
                    adcb_relogin_attempts += 1
                    adcb_last_login_attempt_unix = time.time()
                    time.sleep(2)
                    continue
                time.sleep(2)
                continue

        if not _login_selector_visible(page, bank_code):
            if any(keyword in low for keyword in POST_LOGIN_KEYWORDS):
                logger.info("%s: authenticated session detected", bank_code)
                return page

        if code != "ADCB" and any(keyword in low for keyword in POST_LOGIN_KEYWORDS) and "welcome" not in low:
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
) -> Any:
    max_attempts = 3
    for attempt in range(1, max_attempts + 1):
        try:
            return playwright.chromium.launch_persistent_context(
                user_data_dir=str(profile_dir),
                headless=headless,
                accept_downloads=True,
                downloads_path=str(incoming_dir),
            )
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


def run_end_to_end_downloads(
    *,
    app_config: AppConfig,
    scheduled: bool,
    login_timeout_minutes: int = 20,
    headless: bool = False,
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
            tracked_dirs = [app_config.paths.incoming_dir, app_config.paths.downloads_dir]
            before = snapshot_pdf_state(tracked_dirs)
            portal_url = bank_cfg.get("portal_url")
            profile_dir = app_config.paths.state_dir / "browser_profiles" / bank_code
            profile_dir.mkdir(parents=True, exist_ok=True)
            run_stamp = datetime.now().strftime("%Y%m%d%H%M%S")
            context = None
            page = None

            logger.info("%s: opening portal %s", bank_code, portal_url)

            try:
                context = _launch_bank_context(
                    playwright=playwright,
                    profile_dir=profile_dir,
                    headless=headless,
                    incoming_dir=app_config.paths.incoming_dir,
                    bank_code=bank_code,
                    logger=logger,
                )
                page = context.pages[0] if context.pages else context.new_page()

                page.goto(portal_url, wait_until="domcontentloaded", timeout=60000)
                page.wait_for_timeout(1200)
                safe_screenshot(
                    page,
                    app_config.paths.root / "logs" / f"{run_stamp}_{bank_code}_login_page.png",
                    logger,
                )

                _execute_bank_login(page, bank_code, logger)
                page = _wait_for_authenticated_session(
                    page=page,
                    bank_code=bank_code,
                    timeout_seconds=timeout_seconds,
                    scheduled=scheduled,
                    logger=logger,
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
                if context is not None:
                    try:
                        context.close()
                    except Exception:  # noqa: BLE001
                        logger.warning("%s: failed to close browser context cleanly", bank_code)

    return results


# Backwards-compatible alias
run_manual_auth_downloads = run_end_to_end_downloads

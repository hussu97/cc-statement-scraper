from __future__ import annotations

import logging
import os
import re
from datetime import datetime
from pathlib import Path
from typing import Any


class BrowserDownloadError(Exception):
    pass


LOGIN_MFA_PATTERNS = [
    re.compile(r"authenticate on your registered device", re.IGNORECASE),
    re.compile(r"authorise with the app", re.IGNORECASE),
    re.compile(r"smart\s*pass", re.IGNORECASE),
    re.compile(r"one[-\s]?time\s*password", re.IGNORECASE),
]

LOGIN_FAILURE_PATTERNS = [
    re.compile(r"invalid username/password", re.IGNORECASE),
    re.compile(r"incorrect.*password", re.IGNORECASE),
    re.compile(r"unable to carry out your instructions", re.IGNORECASE),
    re.compile(r"login failed", re.IGNORECASE),
    re.compile(r"invalid.*credentials", re.IGNORECASE),
    re.compile(r"not authorized to login to this portal", re.IGNORECASE),
]

POST_LOGIN_KEYWORDS = [
    "account",
    "accounts",
    "cards",
    "credit card",
    "statement",
    "logout",
    "dashboard",
    "transactions",
]

NAV_KEYWORDS = [
    "credit card",
    "cards",
    "card",
    "statements",
    "e-statement",
    "estatement",
    "download",
]

DOWNLOAD_KEYWORDS = [
    "download",
    "pdf",
    "statement",
    "e-statement",
    "view",
]


def build_logger(root: Path) -> logging.Logger:
    logs_dir = root / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_path = logs_dir / f"download-run-{ts}.log"

    logger = logging.getLogger(f"ccs.downloader.{ts}")
    logger.setLevel(logging.INFO)
    logger.propagate = False

    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(logging.Formatter("%(asctime)s | %(levelname)s | %(message)s"))

    file_handler = logging.FileHandler(log_path)
    file_handler.setFormatter(logging.Formatter("%(asctime)s | %(levelname)s | %(message)s"))

    logger.addHandler(stream_handler)
    logger.addHandler(file_handler)
    logger.info("Downloader log file: %s", log_path)

    return logger


def snapshot_pdf_state(directories: list[Path]) -> dict[str, int]:
    state: dict[str, int] = {}
    for directory in directories:
        if not directory.exists():
            continue
        for path in directory.iterdir():
            if not path.is_file():
                continue
            if path.suffix.lower() != ".pdf":
                continue
            try:
                state[str(path.resolve())] = path.stat().st_mtime_ns
            except FileNotFoundError:
                continue
    return state


def count_new_or_updated_pdfs(before: dict[str, int], after: dict[str, int]) -> int:
    count = 0
    for path, mtime_ns in after.items():
        if path not in before or mtime_ns > before[path]:
            count += 1
    return count


def require_env(var_name: str, env: dict[str, str] | None = None) -> str:
    value = (env or os.environ).get(var_name)
    if not value:
        raise BrowserDownloadError(f"Missing required environment variable: {var_name}")
    return value


def is_mfa_pending(text: str) -> bool:
    return any(pattern.search(text) for pattern in LOGIN_MFA_PATTERNS)


def is_login_failure(text: str) -> bool:
    return any(pattern.search(text) for pattern in LOGIN_FAILURE_PATTERNS)


def text_snapshot(page: Any) -> str:
    try:
        return page.locator("body").inner_text(timeout=4000)
    except Exception:  # noqa: BLE001
        return ""


def safe_screenshot(page: Any, path: Path, logger: logging.Logger) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(path), full_page=True)
        logger.info("Saved screenshot: %s", path)
    except Exception as exc:  # noqa: BLE001
        logger.info("Screenshot failed (%s): %s", path, exc)


def click_keyword(page: Any, keyword: str, logger: logging.Logger, scope: Any | None = None) -> bool:
    root = scope if scope is not None else page
    selectors = [
        f"button:has-text('{keyword}')",
        f"a:has-text('{keyword}')",
        f"[role='button']:has-text('{keyword}')",
        f"[aria-label*='{keyword}' i]",
        f"[title*='{keyword}' i]",
    ]

    for selector in selectors:
        locator = root.locator(selector)
        try:
            count = min(locator.count(), 8)
        except Exception:  # noqa: BLE001
            count = 0

        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                item.click(timeout=2000)
                page.wait_for_timeout(1200)
                logger.info("Clicked keyword '%s' via selector %s", keyword, selector)
                return True
            except Exception:  # noqa: BLE001
                continue

    return False


def attempt_navigation_to_statements(page: Any, logger: logging.Logger) -> None:
    for keyword in NAV_KEYWORDS:
        click_keyword(page, keyword, logger)


def save_download(download: Any, incoming_dir: Path, bank_code: str, logger: logging.Logger) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    suggested = download.suggested_filename or f"{bank_code}_statement.pdf"
    destination = incoming_dir / f"{bank_code}_{timestamp}_{suggested}"
    download.save_as(str(destination))
    logger.info("Saved download: %s", destination)
    return destination


def attempt_download_capture(page: Any, incoming_dir: Path, bank_code: str, logger: logging.Logger) -> int:
    downloaded_count = 0

    candidate_selectors = [
        "a[href$='.pdf']",
        "a[download]",
        "button[aria-label*='download' i]",
        "[title*='download' i]",
        "[class*='download' i]",
    ]

    for selector in candidate_selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 12)
        except Exception:  # noqa: BLE001
            count = 0

        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                with page.expect_download(timeout=5000) as download_info:
                    item.click(timeout=2500)
                save_download(download_info.value, incoming_dir, bank_code, logger)
                downloaded_count += 1
                if downloaded_count >= 2:
                    return downloaded_count
            except Exception:  # noqa: BLE001
                continue

    controls = page.locator("button, a, [role='button'], input[type='button']")
    try:
        count = min(controls.count(), 150)
    except Exception:  # noqa: BLE001
        count = 0

    for idx in range(count):
        item = controls.nth(idx)
        try:
            text = (item.inner_text() or "").strip().lower()
        except Exception:  # noqa: BLE001
            continue

        if not text:
            continue
        if not any(keyword in text for keyword in DOWNLOAD_KEYWORDS):
            continue

        try:
            if not item.is_visible():
                continue
            with page.expect_download(timeout=5000) as download_info:
                item.click(timeout=2500)
            save_download(download_info.value, incoming_dir, bank_code, logger)
            downloaded_count += 1
            if downloaded_count >= 2:
                return downloaded_count
        except Exception:  # noqa: BLE001
            continue

    return downloaded_count

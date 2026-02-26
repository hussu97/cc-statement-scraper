from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any

from ccs_platform.adapters.banks.browser.shared import click_keyword, require_env, save_download


LOGIN_SCREEN_PATTERNS = [
    re.compile(r"welcome to fab", re.IGNORECASE),
    re.compile(r"unlock account\s*/\s*forgot password", re.IGNORECASE),
    re.compile(r"not registered for online banking", re.IGNORECASE),
]

TEXT_DIRECTION_MARKS = re.compile(r"[\u200e\u200f\u202a-\u202e]")
MONTH_INDEX = {
    "jan": 1,
    "january": 1,
    "feb": 2,
    "february": 2,
    "mar": 3,
    "march": 3,
    "apr": 4,
    "april": 4,
    "may": 5,
    "jun": 6,
    "june": 6,
    "jul": 7,
    "july": 7,
    "aug": 8,
    "august": 8,
    "sep": 9,
    "sept": 9,
    "september": 9,
    "oct": 10,
    "october": 10,
    "nov": 11,
    "november": 11,
    "dec": 12,
    "december": 12,
}

DOWNLOAD_EVENT_TIMEOUT_MS = 12000
LATE_DOWNLOAD_WAIT_MS = 5000


def _normalize_requested_months(value: Any) -> list[str]:
    if isinstance(value, str):
        token = value.strip()
        return [token] if token else []
    if isinstance(value, list):
        tokens: list[str] = []
        seen: set[str] = set()
        for item in value:
            token = str(item or "").strip()
            if not token or token in seen:
                continue
            seen.add(token)
            tokens.append(token)
        return tokens
    return []


def _parse_requested_month(value: str | None) -> tuple[int | None, int | None]:
    raw = (value or "").strip().lower()
    if not raw or raw == "latest":
        return None, None
    if not re.match(r"^\d{4}-\d{2}$", raw):
        return None, None
    year = int(raw[:4])
    month = int(raw[5:7])
    if month < 1 or month > 12:
        return None, None
    return year, month


def _parse_month_value(text: str) -> int | None:
    low = text.lower().strip()
    if not low:
        return None

    num = re.search(r"\b(0?[1-9]|1[0-2])\b", low)
    if num:
        return int(num.group(1))

    for key, value in MONTH_INDEX.items():
        if key in low:
            return value

    return None


def _option_score(option: dict[str, Any]) -> int | None:
    text = str(option.get("text") or "").strip()
    value = str(option.get("value") or "").strip()
    low = f"{text} {value}".lower()

    year_match = re.search(r"\b(19|20)\d{2}\b", low)
    month_value = _parse_month_value(low)

    if year_match and month_value:
        return int(year_match.group(0)) * 100 + month_value

    # Numeric value fallback (e.g. 202602)
    compact_match = re.search(r"\b((?:19|20)\d{2})(0[1-9]|1[0-2])\b", low.replace("-", "").replace("/", ""))
    if compact_match:
        return int(compact_match.group(1)) * 100 + int(compact_match.group(2))

    return None


def login(page: Any, logger: logging.Logger) -> None:
    username = require_env("FAB_USERNAME")
    password = require_env("FAB_PASSWORD")

    page.fill("#login-userName", username)
    page.fill("#login-password", password)
    page.click("#submitLogin")
    logger.info("FAB: login submitted")


def login_selector_visible(page: Any) -> bool:
    return page.locator("#login-userName").first.is_visible()


def is_login_screen(text: str) -> bool:
    return any(pattern.search(text) for pattern in LOGIN_SCREEN_PATTERNS)


def is_authenticated_session(page: Any, low_text: str) -> bool:
    url = page.url.lower()
    if "/dashboard" in url or "/cards/" in url:
        return True
    if "my products" in low_text and "dashboard" in low_text and "logout" in low_text:
        return True
    return False


def handle_continue_gate(page: Any, logger: logging.Logger) -> bool:
    selectors = [
        "button:has-text('Continue')",
        "[role='button']:has-text('Continue')",
    ]
    for selector in selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 3)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                item.click(timeout=2500)
                page.wait_for_timeout(1200)
                logger.info("FAB: clicked safer-experience Continue gate")
                return True
            except Exception:  # noqa: BLE001
                continue
    return False


def _normalize_text(value: str) -> str:
    cleaned = TEXT_DIRECTION_MARKS.sub("", value or "")
    return " ".join(cleaned.lower().split())


def _click_exact_control_text(
    root: Any,
    target_text: str,
    logger: logging.Logger,
    *,
    click: bool = True,
) -> bool:
    target = _normalize_text(target_text)
    controls = root.locator("button, a, [role='button'], input[type='button'], input[type='submit']")
    try:
        count = min(controls.count(), 180)
    except Exception:  # noqa: BLE001
        return False

    for idx in range(count):
        item = controls.nth(idx)
        try:
            if not item.is_visible():
                continue
            text = (item.inner_text() or "").strip()
            if not text:
                text = (item.get_attribute("value") or "").strip()
            if not text:
                text = (item.get_attribute("title") or "").strip()
            if not text:
                text = (item.get_attribute("aria-label") or "").strip()
            normalized = _normalize_text(text)
            if normalized != target:
                continue
            if click:
                item.click(timeout=2500)
                logger.info("FAB: clicked control '%s'", text)
            else:
                logger.info("FAB: found control '%s'", text)
            return True
        except Exception:  # noqa: BLE001
            continue

    return False


def _navigate_to_cards_activity(page: Any, logger: logging.Logger, bank_cfg: dict) -> bool:
    handle_continue_gate(page, logger)
    if "cards/cardsactivity" in page.url.lower():
        return True

    if "/dashboard" not in page.url.lower():
        click_keyword(page, "Dashboard", logger)
        page.wait_for_timeout(1200)
        handle_continue_gate(page, logger)

    last4_values = [
        str(card.get("last4", "")).strip()
        for card in bank_cfg.get("cards", [])
        if str(card.get("last4", "")).strip()
    ]

    for last4 in last4_values:
        locator = page.locator(f"text={last4}")
        try:
            count = min(locator.count(), 6)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                item.click(timeout=2500)
                page.wait_for_timeout(1800)
                logger.info("FAB: clicked dashboard card candidate with last4=%s", last4)
                if "cards/cardsactivity" in page.url.lower():
                    return True
            except Exception:  # noqa: BLE001
                continue

    if click_keyword(page, "CASHBACK CARD", logger):
        page.wait_for_timeout(1800)
        if "cards/cardsactivity" in page.url.lower():
            return True

    portal_url = str(bank_cfg.get("portal_url", "")).strip()
    if portal_url:
        base_url = portal_url.split("/PersonalBankingWeb")[0]
        target = f"{base_url}/PersonalBankingWeb/cards/cardsActivity"
        try:
            page.goto(target, wait_until="domcontentloaded", timeout=30000)
            page.wait_for_timeout(1800)
            handle_continue_gate(page, logger)
            if "cards/cardsactivity" in page.url.lower():
                logger.info("FAB: reached cardsActivity via direct URL fallback")
                return True
        except Exception:  # noqa: BLE001
            pass

    return False


def _resolve_popup_scope(page: Any, logger: logging.Logger) -> Any:
    scope_selectors = [
        "[role='dialog']:visible",
        ".modal:visible",
        ".modal-dialog:visible",
        ".ui-dialog:visible",
        ".ngdialog:visible",
        ".popup:visible",
    ]

    for selector in scope_selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 3)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if item.is_visible():
                    logger.info("FAB: popup scope detected via %s", selector)
                    return item
            except Exception:  # noqa: BLE001
                continue

    tenure_select = page.locator("select[name='estatementTenure']:visible")
    try:
        if tenure_select.count() > 0:
            logger.info("FAB: popup scope anchored by estatementTenure select")
            return tenure_select.first.locator("xpath=ancestor::div[1]")
    except Exception:  # noqa: BLE001
        pass

    logger.info("FAB: popup scope not detected; using full page")
    return page


def _select_estatement_tenure(
    page: Any,
    logger: logging.Logger,
    *,
    target_year: int | None = None,
    target_month: int | None = None,
    strict_target: bool = False,
) -> bool:
    select = page.locator("select[name='estatementTenure']")
    try:
        if select.count() == 0:
            return False
        field = select.first
        if not field.is_visible():
            return False
    except Exception:  # noqa: BLE001
        return False

    try:
        options = field.evaluate(
            """
            (el) => Array.from(el.options).map((opt) => ({
                value: opt.value || "",
                text: (opt.textContent || "").trim(),
                disabled: opt.disabled
            }))
            """
        )
    except Exception:  # noqa: BLE001
        return False

    candidates: list[tuple[int, dict[str, Any]]] = []
    for option in options:
        text = (option.get("text") or "").strip()
        low = text.lower()
        if option.get("disabled"):
            continue
        if not text:
            continue
        if "please select" in low:
            continue
        score = _option_score(option)
        if score is None:
            continue
        candidates.append((score, option))

    if not candidates:
        return False

    target_score = None
    if target_year is not None and target_month is not None:
        target_score = target_year * 100 + target_month

    selected = None
    if target_score is not None:
        for score, option in candidates:
            if score == target_score:
                selected = option
                break
        if selected is None and strict_target:
            logger.info(
                "FAB: target statement period not found in dropdown year=%s month=%s",
                target_year,
                target_month,
            )
            return False

    if selected is None:
        candidates.sort(key=lambda x: x[0], reverse=True)
        selected = candidates[0][1]

    try:
        if selected["value"]:
            field.select_option(selected["value"])
        else:
            field.select_option(label=selected["text"])
        logger.info("FAB: selected popup option %s", selected["text"])
        return True
    except Exception:  # noqa: BLE001
        return False


def _select_latest_estatement_tenure(page: Any, logger: logging.Logger) -> bool:
    return _select_estatement_tenure(page, logger)


def _try_popup_download(popup_scope: Any, page: Any, incoming_dir: Path, logger: logging.Logger) -> Path | None:
    def _capture_from_locator(locator: Any, description: str) -> Path | None:
        try:
            count = min(locator.count(), 3)
        except Exception:  # noqa: BLE001
            count = 0

        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
            except Exception:  # noqa: BLE001
                continue

            for force_click in [False, True]:
                try:
                    try:
                        item.scroll_into_view_if_needed(timeout=1200)
                    except Exception:  # noqa: BLE001
                        pass

                    with page.expect_download(timeout=DOWNLOAD_EVENT_TIMEOUT_MS) as download_info:
                        if force_click:
                            item.click(timeout=2500, force=True)
                        else:
                            item.click(timeout=2500)
                    logger.info(
                        "FAB: triggered statement download via %s (force=%s)",
                        description,
                        force_click,
                    )
                    return save_download(download_info.value, incoming_dir, "FAB", logger)
                except Exception as exc:  # noqa: BLE001
                    # FAB can emit the download event late; wait once before another click.
                    if "timeout" in str(exc).lower():
                        try:
                            late_download = page.wait_for_event("download", timeout=LATE_DOWNLOAD_WAIT_MS)
                            logger.info(
                                "FAB: captured late download event after timeout via %s (force=%s)",
                                description,
                                force_click,
                            )
                            return save_download(late_download, incoming_dir, "FAB", logger)
                        except Exception:  # noqa: BLE001
                            continue
                    continue
        return None

    primary_controls = [
        (
            popup_scope.get_by_role("button", name=re.compile(r"download\s+as\s*\.pdf", re.IGNORECASE)),
            "role=button Download as .pdf",
        ),
        (popup_scope.locator("button:has-text('Download as .pdf')"), "button Download as .pdf"),
        (popup_scope.locator("a:has-text('Download as .pdf')"), "link Download as .pdf"),
        (popup_scope.locator("[role='button']:has-text('Download as .pdf')"), "role button Download as .pdf"),
    ]
    for locator, description in primary_controls:
        path = _capture_from_locator(locator, description)
        if path is not None:
            return path

    # FAB sometimes binds the click handler to an ancestor element.
    try:
        with page.expect_download(timeout=DOWNLOAD_EVENT_TIMEOUT_MS) as download_info:
            clicked = popup_scope.evaluate(
                """
                (root) => {
                  const isVisible = (el) => {
                    const cs = window.getComputedStyle(el);
                    const r = el.getBoundingClientRect();
                    return cs.visibility !== 'hidden' && cs.display !== 'none' && r.width > 0 && r.height > 0;
                  };
                  const nodes = Array.from(root.querySelectorAll('*'));
                  for (const node of nodes) {
                    const text = ((node.innerText || node.textContent || '') + '').replace(/\\s+/g, ' ').trim();
                    if (!/download\\s+as\\s*\\.?pdf/i.test(text)) continue;
                    let cur = node;
                    while (cur && cur !== root) {
                      const tag = (cur.tagName || '').toLowerCase();
                      const role = (cur.getAttribute && cur.getAttribute('role')) || '';
                      const hasHandler = !!(
                        (cur.getAttribute && cur.getAttribute('onclick')) ||
                        (cur.getAttribute && cur.getAttribute('ng-click')) ||
                        (cur.getAttribute && cur.getAttribute('data-ng-click'))
                      );
                      if ((tag === 'button' || tag === 'a' || role === 'button' || hasHandler) && isVisible(cur)) {
                        cur.click();
                        return true;
                      }
                      cur = cur.parentElement;
                    }
                  }
                  return false;
                }
                """
            )
        if not clicked:
            raise RuntimeError("Download-as-PDF control was not found")
        logger.info("FAB: triggered statement download via JS ancestor click fallback")
        return save_download(download_info.value, incoming_dir, "FAB", logger)
    except Exception:  # noqa: BLE001
        try:
            late_download = page.wait_for_event("download", timeout=LATE_DOWNLOAD_WAIT_MS)
            logger.info("FAB: captured late download event via JS fallback path")
            return save_download(late_download, incoming_dir, "FAB", logger)
        except Exception:  # noqa: BLE001
            pass

    fallback_controls = [
        (popup_scope.locator("button:has-text('Download PDF')"), "button Download PDF"),
        (popup_scope.locator("a:has-text('Download PDF')"), "link Download PDF"),
        (popup_scope.locator("button:has-text('Download')"), "button Download"),
    ]
    for locator, description in fallback_controls:
        path = _capture_from_locator(locator, description)
        if path is not None:
            return path

    return None


def _open_download_statements_modal(page: Any, logger: logging.Logger) -> bool:
    for _ in range(4):
        if _click_exact_control_text(page, "DOWNLOAD STATEMENTS", logger):
            page.wait_for_timeout(1200)
            return True
        if click_keyword(page, "Download Statements", logger):
            page.wait_for_timeout(1200)
            return True
        page.wait_for_timeout(700)
    return False


def _wait_for_popup_download_control(popup_scope: Any, page: Any, logger: logging.Logger) -> None:
    checks = [
        (
            popup_scope.get_by_role("button", name=re.compile(r"download\s+as\s*\.pdf", re.IGNORECASE)),
            "role=button Download as .pdf",
        ),
        (popup_scope.locator("button:has-text('Download as .pdf')"), "button Download as .pdf"),
        (popup_scope.locator("a:has-text('Download as .pdf')"), "link Download as .pdf"),
        (popup_scope.locator("button:has-text('Download PDF')"), "button Download PDF"),
        (popup_scope.locator("button:has-text('Download')"), "button Download"),
    ]
    for locator, description in checks:
        try:
            if locator.count() > 0:
                locator.first.wait_for(state="visible", timeout=7000)
                logger.info("FAB: download control ready via %s", description)
                return
        except Exception:  # noqa: BLE001
            continue

    # Fallback to page-level checks when popup scope is stale/re-rendered.
    for selector in [
        "button:has-text('Download as .pdf')",
        "a:has-text('Download as .pdf')",
        "[role='button']:has-text('Download as .pdf')",
        "button:has-text('Download PDF')",
        "button:has-text('Download')",
    ]:
        locator = page.locator(selector)
        try:
            if locator.count() > 0:
                locator.first.wait_for(state="visible", timeout=7000)
                logger.info("FAB: download control ready via page selector %s", selector)
                return
        except Exception:  # noqa: BLE001
            continue

    page.wait_for_timeout(500)


def _wait_for_popup_idle(page: Any, popup_scope: Any, logger: logging.Logger) -> None:
    busy_selectors = [
        "[aria-busy='true']",
        ".mat-progress-spinner",
        ".mat-spinner",
        ".loading",
        ".spinner",
        ".overlay-loader",
    ]

    for selector in busy_selectors:
        targets = [popup_scope.locator(selector), page.locator(selector)] if popup_scope is not page else [page.locator(selector)]
        for locator in targets:
            try:
                if locator.count() > 0 and locator.first.is_visible():
                    locator.first.wait_for(state="hidden", timeout=5000)
                    logger.info("FAB: waited for popup busy state to clear via %s", selector)
            except Exception:  # noqa: BLE001
                continue


def _download_control_enabled(popup_scope: Any, page: Any) -> bool:
    checks = [
        popup_scope.get_by_role("button", name=re.compile(r"download\s+as\s*\.pdf", re.IGNORECASE)),
        popup_scope.locator("button:has-text('Download as .pdf')"),
        popup_scope.locator("a:has-text('Download as .pdf')"),
        popup_scope.locator("[role='button']:has-text('Download as .pdf')"),
        popup_scope.locator("button:has-text('Download PDF')"),
        popup_scope.locator("button:has-text('Download')"),
        page.get_by_role("button", name=re.compile(r"download\s+as\s*\.pdf", re.IGNORECASE)),
        page.locator("button:has-text('Download as .pdf')"),
        page.locator("a:has-text('Download as .pdf')"),
    ]
    for locator in checks:
        try:
            count = min(locator.count(), 2)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                is_disabled = bool(item.get_attribute("disabled"))
                aria_disabled = (item.get_attribute("aria-disabled") or "").strip().lower() == "true"
                if not is_disabled and not aria_disabled:
                    return True
            except Exception:  # noqa: BLE001
                continue
    return False


def _wait_after_download(page: Any, logger: logging.Logger) -> None:
    for selector in [
        ".mat-snack-bar-container",
        "[role='alert']",
        ".toast",
        ".notification",
    ]:
        locator = page.locator(selector)
        try:
            if locator.count() > 0 and locator.first.is_visible():
                locator.first.wait_for(state="hidden", timeout=4000)
        except Exception:  # noqa: BLE001
            continue
    page.wait_for_timeout(900)


def _download_requested_months(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    requested_months: list[str],
) -> tuple[int, dict[str, Any]]:
    diagnostics: dict[str, Any] = {
        "requested_months": requested_months,
        "downloaded": [],
        "skipped_unavailable": [],
        "failed": [],
    }

    downloaded = 0
    popup_scope = _resolve_popup_scope(page, logger)

    for month_token in requested_months:
        logger.info("FAB: processing requested statement month=%s", month_token)
        target_year, target_month = _parse_requested_month(month_token)
        if target_year is None or target_month is None:
            diagnostics["failed"].append({"month": month_token, "reason": "invalid_month_token"})
            continue

        try:
            has_tenure = page.locator("select[name='estatementTenure']:visible").count() > 0
        except Exception:  # noqa: BLE001
            has_tenure = False

        if not has_tenure:
            if not _open_download_statements_modal(page, logger):
                diagnostics["failed"].append(
                    {"month": month_token, "reason": "download_statements_modal_not_opened"}
                )
                continue
            popup_scope = _resolve_popup_scope(page, logger)

        selected = _select_estatement_tenure(
            page,
            logger,
            target_year=target_year,
            target_month=target_month,
            strict_target=True,
        )
        if not selected:
            diagnostics["skipped_unavailable"].append(
                {"month": month_token, "reason": "statement_period_not_available"}
            )
            continue

        page.wait_for_timeout(500)
        path: Path | None = None
        for attempt in range(2):
            popup_scope = _resolve_popup_scope(page, logger)
            _wait_for_popup_idle(page, popup_scope, logger)
            _wait_for_popup_download_control(popup_scope, page, logger)
            if not _download_control_enabled(popup_scope, page):
                page.wait_for_timeout(900)
                _wait_for_popup_idle(page, popup_scope, logger)
            path = _try_popup_download(popup_scope, page, incoming_dir, logger)
            if path is None and popup_scope is not page:
                path = _try_popup_download(page, page, incoming_dir, logger)
            if path is not None:
                break
            if attempt == 0:
                logger.info("FAB: retrying download click for month=%s after first attempt", month_token)
                page.wait_for_timeout(1200)

        if path is None:
            diagnostics["failed"].append(
                {"month": month_token, "reason": "download_control_not_found_or_failed"}
            )
            continue

        downloaded += 1
        diagnostics["downloaded"].append({"month": month_token, "path": str(path)})
        _wait_after_download(page, logger)

    return downloaded, diagnostics


def download_latest_statement(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    bank_cfg: dict,
) -> int:
    if not _navigate_to_cards_activity(page, logger, bank_cfg):
        logger.info("FAB: cardsActivity not reached")
        return 0

    logger.info("FAB: cardsActivity reached=True current_url=%s", page.url)

    if not _open_download_statements_modal(page, logger):
        logger.info("FAB: DOWNLOAD STATEMENTS control not found on cardsActivity")
        bank_cfg["download_diagnostics"] = {
            "requested_months": [],
            "downloaded": [],
            "skipped_unavailable": [],
            "failed": [{"month": "latest", "reason": "download_statements_modal_not_opened"}],
        }
        return 0

    popup_scope = _resolve_popup_scope(page, logger)
    page.wait_for_timeout(700)

    requested_months = _normalize_requested_months(bank_cfg.get("requested_months"))
    requested_month = str(bank_cfg.get("requested_month") or "").strip()
    if not requested_months and requested_month and requested_month.lower() != "latest":
        requested_months = [requested_month]

    if requested_months:
        downloaded, diagnostics = _download_requested_months(
            page,
            incoming_dir,
            logger,
            requested_months,
        )
        bank_cfg["download_diagnostics"] = diagnostics
        return downloaded

    _select_latest_estatement_tenure(page, logger)

    # FAB may render/generate the PDF action with a short delay after tenure selection.
    for _ in range(3):
        path = _try_popup_download(popup_scope, page, incoming_dir, logger)
        if path is not None:
            bank_cfg["download_diagnostics"] = {
                "requested_months": ["latest"],
                "downloaded": [{"month": "latest", "path": str(path)}],
                "skipped_unavailable": [],
                "failed": [],
            }
            return 1
        if popup_scope is not page:
            path = _try_popup_download(page, page, incoming_dir, logger)
            if path is not None:
                bank_cfg["download_diagnostics"] = {
                    "requested_months": ["latest"],
                    "downloaded": [{"month": "latest", "path": str(path)}],
                    "skipped_unavailable": [],
                    "failed": [],
                }
                return 1
        page.wait_for_timeout(900)

    bank_cfg["download_diagnostics"] = {
        "requested_months": ["latest"],
        "downloaded": [],
        "skipped_unavailable": [],
        "failed": [{"month": "latest", "reason": "download_control_not_found_or_failed"}],
    }
    return 0

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any

from ccs_platform.adapters.banks.browser.shared import attempt_download_capture, require_env, save_download, text_snapshot


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


def _month_token(year: int, month: int) -> str:
    return f"{year:04d}-{month:02d}"


def _click_first_visible(page: Any, selectors: list[str], *, timeout: int = 3000) -> bool:
    for selector in selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 6)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                item.click(timeout=timeout)
                return True
            except Exception:  # noqa: BLE001
                continue
    return False


def _type_human(page: Any, selectors: list[str], value: str, *, mask: bool = False) -> bool:
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
                page.wait_for_timeout(140)
                item.press("Meta+A")
                item.press("Backspace")
                page.wait_for_timeout(90)
                page.keyboard.type(value, delay=85)
                page.wait_for_timeout(120)
                if not mask:
                    typed = (item.input_value() or "").strip()
                    if typed != value:
                        continue
                return True
            except Exception:  # noqa: BLE001
                continue
    return False


def _dismiss_cookie_banner(page: Any, logger: logging.Logger) -> None:
    selectors = [
        "a.cc-btn.cc-dismiss",
        "a.cc-btn:has-text('Accept')",
        "button:has-text('Accept')",
    ]
    if _click_first_visible(page, selectors, timeout=2200):
        logger.info("MASHREQ: dismissed cookie banner")
        page.wait_for_timeout(350)


def _click_control_by_terms(
    page: Any,
    *,
    include_terms: list[str],
    logger: logging.Logger,
    action_name: str,
    attempts: int = 6,
) -> bool:
    lowered_terms = [term.strip().lower() for term in include_terms if term.strip()]
    if not lowered_terms:
        return False

    for _ in range(max(1, attempts)):
        try:
            clicked = page.evaluate(
                """
                (payload) => {
                  const includeTerms = payload.include_terms || [];
                  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
                  const isVisible = (el) => {
                    if (!el) return false;
                    const style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden') return false;
                    const rect = el.getBoundingClientRect();
                    return rect.width > 0 && rect.height > 0;
                  };
                  const roots = Array.from(document.querySelectorAll('button, a, [role="button"], [role="link"], div, span, li'));
                  for (const node of roots) {
                    if (!isVisible(node)) continue;
                    const text = normalize(node.innerText || node.textContent || node.getAttribute('aria-label') || node.getAttribute('title') || '');
                    if (!text) continue;
                    if (!includeTerms.every((term) => text.includes(term))) continue;

                    let clickable = node;
                    for (let depth = 0; depth < 7 && clickable; depth += 1) {
                      try {
                        clickable.click();
                        return true;
                      } catch (e) {
                        clickable = clickable.parentElement;
                      }
                    }
                  }
                  return false;
                }
                """,
                {"include_terms": lowered_terms},
            )
            if clicked:
                logger.info("MASHREQ: clicked %s via terms=%s", action_name, lowered_terms)
                page.wait_for_timeout(1200)
                return True
        except Exception:  # noqa: BLE001
            pass
        page.wait_for_timeout(650)
    return False


def is_unauthorized_screen(low_text: str) -> bool:
    return "not authorized to login to this portal" in low_text


def is_login_screen(low_text: str) -> bool:
    if "welcome to mashreq online banking" in low_text and "sign in" in low_text:
        return True
    if "username" in low_text and "password" in low_text and "create credentials" in low_text:
        return True
    return False


def is_authenticated_session(page: Any, low_text: str) -> bool:
    url = page.url.lower()
    if "/onlinebanking/dashboard" in url or "/onlinebanking/product/" in url:
        return True
    if "sign out" in low_text and ("overview" in low_text or "cards" in low_text):
        return True
    return False


def login(page: Any, logger: logging.Logger) -> None:
    username = require_env("MASHREQ_USERNAME")
    password = require_env("MASHREQ_PASSWORD")

    page.wait_for_timeout(650)
    _dismiss_cookie_banner(page, logger)

    try:
        page.mouse.move(220, 180)
        page.wait_for_timeout(120)
        page.mouse.move(420, 240)
    except Exception:  # noqa: BLE001
        pass

    username_typed = _type_human(
        page,
        [
            "input#username",
            "input#userName",
            "input[name='username']",
            "input[name='userName']",
            "input[name='userid']",
            "input[name='userId']",
            "input[autocomplete='username']",
            "input[type='text'][name*='user' i]",
            "input[type='text']",
        ],
        username,
    )
    password_typed = _type_human(
        page,
        [
            "input#password",
            "input[name='password']",
            "input[type='password']",
        ],
        password,
        mask=True,
    )

    if not username_typed or not password_typed:
        raise RuntimeError("MASHREQ: login input fields not detected")

    page.wait_for_timeout(260)
    submitted = _click_first_visible(
        page,
        [
            "button[type='submit']",
            "button:has-text('Sign In')",
            "button:has-text('Login')",
            "[role='button']:has-text('Sign In')",
            "[role='button']:has-text('Login')",
            "input[type='submit']",
        ],
    )
    if not submitted:
        submitted = _click_control_by_terms(
            page,
            include_terms=["sign", "in"],
            logger=logger,
            action_name="login submit",
            attempts=2,
        )
    if not submitted:
        raise RuntimeError("MASHREQ: login submit control not detected")

    logger.info("MASHREQ: login submitted")


def login_selector_visible(page: Any) -> bool:
    selectors = [
        "input#username",
        "input#userName",
        "input[name='username']",
        "input[name='userName']",
        "input[name='userid']",
        "input[name='userId']",
        "input[type='password']",
    ]
    for selector in selectors:
        locator = page.locator(selector)
        try:
            if locator.count() > 0 and locator.first.is_visible():
                return True
        except Exception:  # noqa: BLE001
            continue

    low = text_snapshot(page).lower()
    return is_login_screen(low)


def _open_cards_page(page: Any, logger: logging.Logger) -> bool:
    _dismiss_cookie_banner(page, logger)
    selectors = [
        "a:has-text('Cards')",
        "[role='link']:has-text('Cards')",
        "button:has-text('Cards')",
        "[role='button']:has-text('Cards')",
    ]
    if _click_first_visible(page, selectors):
        page.wait_for_timeout(1600)
        logger.info("MASHREQ: opened Cards page via selector click")
        return True

    return _click_control_by_terms(
        page,
        include_terms=["cards"],
        logger=logger,
        action_name="Cards side panel",
    )


def _open_card_details(page: Any, logger: logging.Logger, bank_cfg: dict[str, Any]) -> bool:
    target_last4 = "0353"
    cards = bank_cfg.get("cards", [])
    if isinstance(cards, list):
        for card in cards:
            last4 = str((card or {}).get("last4") or "").strip()
            if last4:
                target_last4 = last4
                break

    card_selectors = [
        f"text={target_last4}",
        f"a:has-text('{target_last4}')",
        f"button:has-text('{target_last4}')",
        f"[role='button']:has-text('{target_last4}')",
    ]
    if _click_first_visible(page, card_selectors):
        page.wait_for_timeout(1800)
        logger.info("MASHREQ: opened card details for last4=%s via selector click", target_last4)
        return True

    return _click_control_by_terms(
        page,
        include_terms=[target_last4],
        logger=logger,
        action_name=f"card ending {target_last4}",
    )


def _is_statement_download_page(page: Any) -> bool:
    try:
        payload = page.evaluate(
            """
            () => {
              const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
              const isVisible = (el) => {
                if (!el) return false;
                const style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden') return false;
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
              };

              const bodyText = normalize(document.body ? document.body.innerText : '');
              const hasSentOn = bodyText.includes('sent on');

              let rowWithDownload = 0;
              const rows = Array.from(document.querySelectorAll('table tbody tr, table tr, [role="row"], .mat-row, .MuiTableRow-root'));
              for (const row of rows) {
                if (!isVisible(row)) continue;
                const controls = Array.from(row.querySelectorAll('a[href], button, [role="button"], [aria-label], [title]'));
                let hasDownload = false;
                for (const control of controls) {
                  if (!isVisible(control)) continue;
                  const text = normalize(control.innerText || control.textContent || control.getAttribute('aria-label') || control.getAttribute('title') || '');
                  if (text.includes('download') || text.includes('pdf')) {
                    hasDownload = true;
                    break;
                  }
                }
                if (hasDownload) rowWithDownload += 1;
              }

              return {hasSentOn, rowWithDownload};
            }
            """
        )
        return bool(payload.get("hasSentOn")) and int(payload.get("rowWithDownload") or 0) > 0
    except Exception:  # noqa: BLE001
        return False


def _open_estatements(page: Any, logger: logging.Logger) -> bool:
    for _ in range(5):
        _dismiss_cookie_banner(page, logger)

        _click_control_by_terms(
            page,
            include_terms=["card details"],
            logger=logger,
            action_name="Card Details tab",
            attempts=1,
        )

        selectors = [
            "button:has-text('E-Statement')",
            "button:has-text('E-Statements')",
            "a:has-text('E-Statement')",
            "a:has-text('E-Statements')",
            "[role='button']:has-text('E-Statement')",
            "[role='button']:has-text('E-Statements')",
        ]
        clicked = _click_first_visible(page, selectors, timeout=2600)
        if not clicked:
            clicked = _click_control_by_terms(
                page,
                include_terms=["e-statement"],
                logger=logger,
                action_name="E-Statement control",
                attempts=2,
            )
        if not clicked:
            clicked = _click_control_by_terms(
                page,
                include_terms=["statement"],
                logger=logger,
                action_name="Statement control",
                attempts=1,
            )

        page.wait_for_timeout(1400)
        if _is_statement_download_page(page):
            logger.info("MASHREQ: statement download table is visible")
            return True

    return False


def _scan_statement_month_tokens(page: Any) -> list[str]:
    try:
        tokens = page.evaluate(
            """
            () => {
              const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
              const isVisible = (el) => {
                if (!el) return false;
                const style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden') return false;
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
              };

              const bodyText = normalize(document.body ? document.body.innerText : '');
              if (!bodyText.includes('sent on')) {
                return [];
              }

              const monthMap = {
                jan: 1, january: 1,
                feb: 2, february: 2,
                mar: 3, march: 3,
                apr: 4, april: 4,
                may: 5,
                jun: 6, june: 6,
                jul: 7, july: 7,
                aug: 8, august: 8,
                sep: 9, sept: 9, september: 9,
                oct: 10, october: 10,
                nov: 11, november: 11,
                dec: 12, december: 12,
              };

              const tokenFromText = (text) => {
                const line = normalize(text);
                if (!line) return null;

                let m = line.match(/\b(\d{1,2})[\/-](\d{1,2})[\/-]((?:19|20)?\d{2})\b/);
                if (m) {
                  const month = Number(m[2]);
                  let year = Number(m[3]);
                  if (year < 100) year += 2000;
                  if (month >= 1 && month <= 12) {
                    return `${year.toString().padStart(4, '0')}-${month.toString().padStart(2, '0')}`;
                  }
                }

                m = line.match(/\b(\d{1,2})\s+([a-z]{3,9})\s+((?:19|20)?\d{2})\b/);
                if (m) {
                  const month = monthMap[m[2]];
                  let year = Number(m[3]);
                  if (year < 100) year += 2000;
                  if (month && year >= 1900) {
                    return `${year.toString().padStart(4, '0')}-${month.toString().padStart(2, '0')}`;
                  }
                }
                return null;
              };

              const seen = new Set();
              const out = [];
              const rows = Array.from(document.querySelectorAll('table tbody tr, table tr, [role="row"], .mat-row, .MuiTableRow-root'));
              for (const row of rows) {
                if (!isVisible(row)) continue;

                const controls = Array.from(row.querySelectorAll('a[href], button, [role="button"], [aria-label], [title]'));
                let hasDownload = false;
                for (const control of controls) {
                  if (!isVisible(control)) continue;
                  const txt = normalize(control.innerText || control.textContent || control.getAttribute('aria-label') || control.getAttribute('title') || '');
                  if (txt.includes('download') || txt.includes('pdf')) {
                    hasDownload = true;
                    break;
                  }
                }
                if (!hasDownload) continue;

                const token = tokenFromText(row.innerText || row.textContent || '');
                if (!token || seen.has(token)) continue;
                seen.add(token);
                out.push(token);
              }

              out.sort();
              return out;
            }
            """
        )
    except Exception:  # noqa: BLE001
        return []

    if not isinstance(tokens, list):
        return []
    return [str(token) for token in tokens if re.match(r"^\d{4}-\d{2}$", str(token))]


def _wait_for_estatement_rows(page: Any, logger: logging.Logger) -> bool:
    for _ in range(18):
        if _is_statement_download_page(page):
            tokens = _scan_statement_month_tokens(page)
            logger.info("MASHREQ: detected statement rows for months=%s", tokens)
            return True

        _open_estatements(page, logger)
        page.wait_for_timeout(700)

    logger.info("MASHREQ: statement rows were not detected on E-Statements page")
    return False


def _row_has_download_for_month(page: Any, month_token: str) -> bool:
    try:
        result = page.evaluate(
            """
            (payload) => {
              const monthToken = payload.month_token;
              const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
              const isVisible = (el) => {
                if (!el) return false;
                const style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden') return false;
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
              };

              const bodyText = normalize(document.body ? document.body.innerText : '');
              if (!bodyText.includes('sent on')) return false;

              const monthMap = {
                jan: 1, january: 1,
                feb: 2, february: 2,
                mar: 3, march: 3,
                apr: 4, april: 4,
                may: 5,
                jun: 6, june: 6,
                jul: 7, july: 7,
                aug: 8, august: 8,
                sep: 9, sept: 9, september: 9,
                oct: 10, october: 10,
                nov: 11, november: 11,
                dec: 12, december: 12,
              };
              const tokenFromText = (text) => {
                const line = normalize(text);
                if (!line) return null;

                let m = line.match(/\b(\d{1,2})[\/-](\d{1,2})[\/-]((?:19|20)?\d{2})\b/);
                if (m) {
                  const month = Number(m[2]);
                  let year = Number(m[3]);
                  if (year < 100) year += 2000;
                  if (month >= 1 && month <= 12) {
                    return `${year.toString().padStart(4, '0')}-${month.toString().padStart(2, '0')}`;
                  }
                }

                m = line.match(/\b(\d{1,2})\s+([a-z]{3,9})\s+((?:19|20)?\d{2})\b/);
                if (m) {
                  const month = monthMap[m[2]];
                  let year = Number(m[3]);
                  if (year < 100) year += 2000;
                  if (month && year >= 1900) {
                    return `${year.toString().padStart(4, '0')}-${month.toString().padStart(2, '0')}`;
                  }
                }

                return null;
              };

              const rows = Array.from(document.querySelectorAll('table tbody tr, table tr, [role="row"], .mat-row, .MuiTableRow-root'));
              for (const row of rows) {
                if (!isVisible(row)) continue;
                if (tokenFromText(row.innerText || row.textContent || '') !== monthToken) continue;

                const controls = Array.from(row.querySelectorAll('a[href], button, [role="button"], [aria-label], [title]'));
                for (const control of controls) {
                  if (!isVisible(control)) continue;
                  const txt = normalize(control.innerText || control.textContent || control.getAttribute('aria-label') || control.getAttribute('title') || '');
                  if (txt.includes('download') || txt.includes('pdf')) {
                    return true;
                  }
                }
              }
              return false;
            }
            """,
            {"month_token": month_token},
        )
        return bool(result)
    except Exception:  # noqa: BLE001
        return False


def _click_month_download_and_capture(
    page: Any,
    *,
    month_token: str,
    incoming_dir: Path,
    logger: logging.Logger,
) -> Path | None:
    try:
        with page.expect_download(timeout=20000) as download_info:
            clicked = page.evaluate(
                """
                (payload) => {
                  const monthToken = payload.month_token;
                  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim().toLowerCase();
                  const isVisible = (el) => {
                    if (!el) return false;
                    const style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden') return false;
                    const rect = el.getBoundingClientRect();
                    return rect.width > 0 && rect.height > 0;
                  };

                  const bodyText = normalize(document.body ? document.body.innerText : '');
                  if (!bodyText.includes('sent on')) return false;

                  const monthMap = {
                    jan: 1, january: 1,
                    feb: 2, february: 2,
                    mar: 3, march: 3,
                    apr: 4, april: 4,
                    may: 5,
                    jun: 6, june: 6,
                    jul: 7, july: 7,
                    aug: 8, august: 8,
                    sep: 9, sept: 9, september: 9,
                    oct: 10, october: 10,
                    nov: 11, november: 11,
                    dec: 12, december: 12,
                  };
                  const tokenFromText = (text) => {
                    const line = normalize(text);
                    if (!line) return null;

                    let m = line.match(/\b(\d{1,2})[\/-](\d{1,2})[\/-]((?:19|20)?\d{2})\b/);
                    if (m) {
                      const month = Number(m[2]);
                      let year = Number(m[3]);
                      if (year < 100) year += 2000;
                      if (month >= 1 && month <= 12) {
                        return `${year.toString().padStart(4, '0')}-${month.toString().padStart(2, '0')}`;
                      }
                    }

                    m = line.match(/\b(\d{1,2})\s+([a-z]{3,9})\s+((?:19|20)?\d{2})\b/);
                    if (m) {
                      const month = monthMap[m[2]];
                      let year = Number(m[3]);
                      if (year < 100) year += 2000;
                      if (month && year >= 1900) {
                        return `${year.toString().padStart(4, '0')}-${month.toString().padStart(2, '0')}`;
                      }
                    }

                    return null;
                  };

                  const rows = Array.from(document.querySelectorAll('table tbody tr, table tr, [role="row"], .mat-row, .MuiTableRow-root'));
                  for (const row of rows) {
                    if (!isVisible(row)) continue;
                    if (tokenFromText(row.innerText || row.textContent || '') !== monthToken) continue;

                    const controls = Array.from(row.querySelectorAll('a[href], button, [role="button"], [aria-label], [title]'));
                    const scored = [];
                    for (const control of controls) {
                      if (!isVisible(control)) continue;
                      const txt = normalize(control.innerText || control.textContent || control.getAttribute('aria-label') || control.getAttribute('title') || '');
                      let score = 0;
                      if (txt.includes('download')) score += 20;
                      if (txt.includes('pdf')) score += 15;
                      if (txt.includes('statement')) score += 10;
                      if (score > 0) scored.push([score, control]);
                    }
                    if (!scored.length) continue;

                    scored.sort((a, b) => b[0] - a[0]);
                    let node = scored[0][1];
                    for (let depth = 0; depth < 6 && node; depth += 1) {
                      try {
                        node.click();
                        return true;
                      } catch (e) {
                        node = node.parentElement;
                      }
                    }
                  }

                  return false;
                }
                """,
                {"month_token": month_token},
            )
            if not clicked:
                return None

        path = save_download(download_info.value, incoming_dir, "MASHREQ", logger)
        page.wait_for_timeout(900)
        return path
    except Exception:  # noqa: BLE001
        return None


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

    available = set(_scan_statement_month_tokens(page))
    for month_token in requested_months:
        year, month = _parse_requested_month(month_token)
        if year is None or month is None:
            diagnostics["failed"].append({"month": month_token, "reason": "invalid_month_token"})
            continue

        normalized_token = _month_token(year, month)
        if normalized_token not in available:
            diagnostics["skipped_unavailable"].append(
                {"month": normalized_token, "reason": "statement_period_not_available"}
            )
            continue

        if not _row_has_download_for_month(page, normalized_token):
            diagnostics["failed"].append(
                {"month": normalized_token, "reason": "download_control_not_found"}
            )
            continue

        path = _click_month_download_and_capture(
            page,
            month_token=normalized_token,
            incoming_dir=incoming_dir,
            logger=logger,
        )
        if path is None:
            diagnostics["failed"].append(
                {"month": normalized_token, "reason": "download_control_not_found_or_failed"}
            )
            continue

        downloaded += 1
        diagnostics["downloaded"].append({"month": normalized_token, "path": str(path)})

    return downloaded, diagnostics


def download_latest_statement(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    bank_cfg: dict,
) -> int:
    if not _open_cards_page(page, logger):
        logger.info("MASHREQ: could not open Cards page")
        return attempt_download_capture(page, incoming_dir, "MASHREQ", logger)

    if not _open_card_details(page, logger, bank_cfg):
        logger.info("MASHREQ: could not open card details")
        return attempt_download_capture(page, incoming_dir, "MASHREQ", logger)

    if not _open_estatements(page, logger):
        logger.info("MASHREQ: could not open E-Statements page")
        bank_cfg["download_diagnostics"] = {
            "requested_months": _normalize_requested_months(bank_cfg.get("requested_months")),
            "downloaded": [],
            "skipped_unavailable": [],
            "failed": [{"month": "latest", "reason": "estatements_navigation_failed"}],
        }
        return 0

    if not _wait_for_estatement_rows(page, logger):
        bank_cfg["download_diagnostics"] = {
            "requested_months": _normalize_requested_months(bank_cfg.get("requested_months")),
            "downloaded": [],
            "skipped_unavailable": [],
            "failed": [{"month": "latest", "reason": "statement_rows_not_detected"}],
        }
        return 0

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

    available = _scan_statement_month_tokens(page)
    if available:
        latest = sorted(available)[-1]
        path = _click_month_download_and_capture(
            page,
            month_token=latest,
            incoming_dir=incoming_dir,
            logger=logger,
        )
        if path is not None:
            bank_cfg["download_diagnostics"] = {
                "requested_months": ["latest"],
                "downloaded": [{"month": latest, "path": str(path)}],
                "skipped_unavailable": [],
                "failed": [],
            }
            return 1

    bank_cfg["download_diagnostics"] = {
        "requested_months": ["latest"],
        "downloaded": [],
        "skipped_unavailable": [],
        "failed": [{"month": "latest", "reason": "download_control_not_found_or_failed"}],
    }
    return 0

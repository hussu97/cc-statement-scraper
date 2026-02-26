from __future__ import annotations

import logging
import random
import re
import sqlite3
import time
from pathlib import Path
from typing import Any

from ccs_platform.adapters.banks.browser.shared import (
    attempt_download_capture,
    attempt_navigation_to_statements,
    click_keyword,
    require_env,
    save_download,
    text_snapshot,
)

OTP_CODE_PATTERN = re.compile(r"\b(\d{4,8})\b")
MASKED_CARD_PATTERN = re.compile(
    r"((?:x{2,}\s*)?\d{0,4}\s*(?:\*{2,}\s*){1,4}\d{2,4}|x{2,}\d{2,4}|\*{2,}\s*\d{2,4})",
    re.IGNORECASE,
)
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


def _extract_otp_code(payload: str) -> str | None:
    if not payload:
        return None

    checks = [
        re.compile(r"\botp\b\D{0,20}(\d{4,8})\b", re.IGNORECASE),
        re.compile(r"\b(?:one[-\s]?time|verification|security|auth(?:entication)?)\s*(?:code|password)?\D{0,20}(\d{4,8})\b", re.IGNORECASE),
        re.compile(r"\bcode\b\D{0,20}(\d{4,8})\b", re.IGNORECASE),
    ]
    for pattern in checks:
        match = pattern.search(payload)
        if match:
            return match.group(1)

    # Conservative fallback when context words are absent.
    for match in OTP_CODE_PATTERN.finditer(payload):
        code = match.group(1)
        if len(code) == 6:
            return code

    return None


def _decode_attributed_body(raw: Any) -> str:
    if not isinstance(raw, (bytes, bytearray)):
        return ""

    for encoding in ("utf-8", "latin1"):
        try:
            decoded = bytes(raw).decode(encoding, errors="ignore")
            if decoded:
                return decoded
        except Exception:  # noqa: BLE001
            continue
    return ""


def login(page: Any, logger: logging.Logger) -> None:
    cid = require_env("ADCB_CID")
    password = require_env("ADCB_LOGIN_PASSWORD")

    cid_radio = page.locator("input[aria-label='ADCB CID']")
    if cid_radio.count() > 0:
        cid_radio.first.check()

    page.fill("#frmLogin_txtUserId", cid)
    _fill_password_via_virtual_keyboard(page, password, logger)
    page.click("#frmLogin_btnLogin")
    logger.info("ADCB: login submitted")


def login_selector_visible(page: Any) -> bool:
    return page.locator("#frmLogin_txtUserId").first.is_visible()


def is_login_screen(text: str) -> bool:
    low = text.lower()
    return "login with" in low and "virtual keyboard" in low


def is_otp_screen(text: str) -> bool:
    low = text.lower()
    otp_markers = [
        "one-time password",
        "one time password",
        "otp",
        "verification code",
        "security code",
    ]
    return any(marker in low for marker in otp_markers)


def is_concurrent_session_gate(text: str) -> bool:
    low = text.lower()
    return "attempt to login has failed" in low and "currently logged into adcb personal internet banking" in low


def is_authenticated_session(page: Any, low_text: str) -> bool:
    url = page.url.lower()
    if "#_frmlogin" in url and is_login_screen(low_text):
        return False
    if is_concurrent_session_gate(low_text):
        return False
    if login_selector_visible(page):
        return False
    if is_otp_screen(low_text):
        return False
    return not is_login_screen(low_text)


def _open_virtual_keyboard(page: Any, logger: logging.Logger) -> None:
    selectors = [
        "#frmLogin_lnkVrtKb",
        "#frmLogin_btnVrtKb",
        "button:has-text('VIRTUAL KEYBOARD')",
        "text=VIRTUAL KEYBOARD",
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
                page.wait_for_timeout(400)
                logger.info("ADCB: opened virtual keyboard")
                return
            except Exception:  # noqa: BLE001
                continue


def _toggle_caps(page: Any, logger: logging.Logger) -> bool:
    selectors = ["#frmLogin_btnCapsLck", "button:has-text('Caps Lock')", "text=Caps Lock"]
    for selector in selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 2)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible() or not item.is_enabled():
                    continue
                item.click(timeout=2000)
                page.wait_for_timeout(250)
                logger.info("ADCB: toggled Caps Lock")
                return True
            except Exception:  # noqa: BLE001
                continue
    return False


def _collect_virtual_key_map(page: Any) -> tuple[dict[str, str], bool]:
    keys = page.locator("[id^='frmLogin_btnVrtItm']:visible")
    mapping: dict[str, str] = {}

    try:
        key_count = min(keys.count(), 120)
    except Exception:  # noqa: BLE001
        return mapping, False

    upper_count = 0
    lower_count = 0

    for idx in range(key_count):
        key = keys.nth(idx)
        try:
            if not key.is_enabled():
                continue
            key_id = (key.get_attribute("id") or "").strip()
            if not key_id:
                continue
            value = (key.get_attribute("value") or "").strip()
            if not value:
                value = (key.input_value() or "").strip()
            if not value:
                value = (key.inner_text() or "").strip()
            if not value:
                continue
            if value not in mapping:
                mapping[value] = key_id

            if value.isalpha():
                if value.upper() == value:
                    upper_count += 1
                elif value.lower() == value:
                    lower_count += 1
        except Exception:  # noqa: BLE001
            continue

    caps_on = upper_count > lower_count
    return mapping, caps_on


def _click_virtual_char(page: Any, char: str, logger: logging.Logger) -> bool:
    toggled_for_symbol = False

    for _ in range(8):
        mapping, caps_on = _collect_virtual_key_map(page)

        if char in mapping:
            key_id = mapping[char]
            try:
                page.locator(f"#{key_id}").first.click(timeout=2200)
                page.wait_for_timeout(120)
                return True
            except Exception:  # noqa: BLE001
                page.wait_for_timeout(120)
                continue

        if char.isalpha():
            desired_upper = char.isupper()
            if caps_on != desired_upper:
                _toggle_caps(page, logger)
                continue
        elif not toggled_for_symbol:
            # Some punctuation can move between keyboard states.
            toggled_for_symbol = _toggle_caps(page, logger) or toggled_for_symbol
            continue

        page.wait_for_timeout(120)

    return False


def _fill_password_via_virtual_keyboard(page: Any, password: str, logger: logging.Logger) -> None:
    page.fill("#frmLogin_txtPwd", "")
    page.click("#frmLogin_txtPwd")
    _open_virtual_keyboard(page, logger)

    for char in password:
        if not _click_virtual_char(page, char, logger):
            raise RuntimeError(f"ADCB virtual keyboard could not type character: {char!r}")

    logger.info("ADCB: password entered via virtual keyboard")


def _latest_sms_otp_from_messages(
    logger: logging.Logger,
    not_before_unix: float | None = None,
) -> str | None:
    db_path = Path.home() / "Library" / "Messages" / "chat.db"
    if not db_path.exists():
        logger.info("ADCB: Messages DB not found at %s", db_path)
        return None

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT
              message.date,
              COALESCE(handle.id, ''),
              COALESCE(message.text, ''),
              message.attributedBody
            FROM message
            LEFT JOIN handle ON message.handle_id = handle.ROWID
            WHERE message.is_from_me = 0
            ORDER BY message.date DESC
            LIMIT 300
            """
        )
        rows = cursor.fetchall()
        conn.close()
    except Exception as exc:  # noqa: BLE001
        logger.info("ADCB: unable to read Messages DB for OTP: %s", exc)
        return None

    now_unix = time.time()
    for date_raw, sender, text, attributed_body in rows:
        text_value = text or ""
        attributed_text = _decode_attributed_body(attributed_body)
        payload = f"{text_value}\n{attributed_text}".strip()
        if not payload:
            continue

        combined_low = f"{sender} {payload}".lower()
        if "adcb" not in combined_low and not any(
            token in combined_low for token in ["otp", "one-time", "one time", "verification code"]
        ):
            continue

        unix_ts = None
        if isinstance(date_raw, (int, float)):
            # Apple's message.date epoch starts at 2001-01-01 and is stored in nanoseconds.
            unix_ts = float(date_raw) / 1_000_000_000 + 978307200

        if unix_ts is not None and now_unix - unix_ts > 20 * 60:
            continue
        if unix_ts is not None and not_before_unix is not None and unix_ts + 5 < not_before_unix:
            continue

        code = _extract_otp_code(payload)
        if code:
            logger.info("ADCB: OTP candidate found from Messages sender=%s", sender)
            return code

    return None


def _collect_otp_inputs(page: Any) -> list[Any]:
    inputs = page.locator("input")
    candidates: list[Any] = []
    try:
        count = min(inputs.count(), 60)
    except Exception:  # noqa: BLE001
        count = 0

    for idx in range(count):
        item = inputs.nth(idx)
        try:
            if not item.is_visible() or not item.is_enabled():
                continue
            input_type = (item.get_attribute("type") or "text").strip().lower()
            if input_type in {"hidden", "checkbox", "radio", "button", "submit"}:
                continue
            candidates.append(item)
        except Exception:  # noqa: BLE001
            continue

    return candidates


def _human_pause(page: Any, minimum_ms: int, maximum_ms: int) -> None:
    if maximum_ms < minimum_ms:
        maximum_ms = minimum_ms
    page.wait_for_timeout(random.randint(minimum_ms, maximum_ms))


def _human_type(page: Any, input_locator: Any, value: str) -> bool:
    try:
        input_locator.click(timeout=2000)
        _human_pause(page, 120, 260)
        input_locator.fill("")
        _human_pause(page, 90, 210)
        for char in value:
            input_locator.type(char, delay=random.randint(70, 180))
            _human_pause(page, 45, 140)
        return True
    except Exception:  # noqa: BLE001
        return False


def _fill_otp_inputs(page: Any, otp: str, logger: logging.Logger) -> bool:
    inputs = _collect_otp_inputs(page)
    if not inputs:
        return False

    keyword_inputs: list[Any] = []
    single_digit_inputs: list[Any] = []
    general_inputs: list[Any] = []

    for item in inputs:
        try:
            attrs = " ".join(
                [
                    item.get_attribute("id") or "",
                    item.get_attribute("name") or "",
                    item.get_attribute("placeholder") or "",
                    item.get_attribute("aria-label") or "",
                ]
            ).lower()
            maxlength_raw = (item.get_attribute("maxlength") or "").strip()
            maxlength = int(maxlength_raw) if maxlength_raw.isdigit() else None

            if any(token in attrs for token in ["otp", "one-time", "verification", "security code", "token", "pin"]):
                keyword_inputs.append(item)
            else:
                general_inputs.append(item)

            if maxlength == 1:
                single_digit_inputs.append(item)
        except Exception:  # noqa: BLE001
            continue

    target_inputs = keyword_inputs or inputs

    # Multi-input OTP widgets (one char per box).
    if len(single_digit_inputs) >= min(4, len(otp)):
        for idx, char in enumerate(otp):
            if idx >= len(single_digit_inputs):
                break
            box = single_digit_inputs[idx]
            try:
                box.click(timeout=2000)
                _human_pause(page, 70, 170)
                box.type(char, delay=random.randint(65, 150))
                _human_pause(page, 50, 130)
            except Exception:  # noqa: BLE001
                box.fill(char)
                _human_pause(page, 70, 150)
        logger.info("ADCB: OTP typed into multi-input fields")
        return True

    # Single OTP input field.
    for item in target_inputs:
        if _human_type(page, item, otp):
            logger.info("ADCB: OTP typed into single input")
            return True

    # Last fallback for unusual fields.
    for item in general_inputs:
        if _human_type(page, item, otp):
            logger.info("ADCB: OTP typed into fallback input")
            return True

    return False


def _submit_otp(page: Any, logger: logging.Logger) -> bool:
    selectors = [
        "button:has-text('Submit')",
        "button:has-text('Verify')",
        "button:has-text('Continue')",
        "input[type='submit']",
        "[role='button']:has-text('Submit')",
        "[role='button']:has-text('Verify')",
        "#frmLogin_btnSubmit",
    ]

    for selector in selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 5)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible() or not item.is_enabled():
                    continue
                item.click(timeout=2500)
                page.wait_for_timeout(450)
                logger.info("ADCB: submitted OTP via %s", selector)
                return True
            except Exception:  # noqa: BLE001
                continue

    return False


def try_auto_otp(
    page: Any,
    logger: logging.Logger,
    low_text: str | None = None,
    *,
    not_before_unix: float | None = None,
    attempted_codes: set[str] | None = None,
) -> bool:
    page_text = (low_text or "").lower()
    if not page_text:
        try:
            page_text = (page.locator("body").inner_text(timeout=2500) or "").lower()
        except Exception:  # noqa: BLE001
            page_text = ""

    if not is_otp_screen(page_text):
        return False

    otp = _latest_sms_otp_from_messages(logger, not_before_unix=not_before_unix)
    if not otp:
        logger.info("ADCB: OTP screen detected but no recent SMS OTP found yet")
        return False

    if attempted_codes is not None and otp in attempted_codes:
        logger.info("ADCB: latest OTP %s already attempted; waiting for a new OTP", otp)
        return False

    if not _fill_otp_inputs(page, otp, logger):
        logger.info("ADCB: OTP value found but OTP input fields were not detected")
        return False

    # Small human-like think time before submitting OTP.
    _human_pause(page, 450, 1300)

    submitted = _submit_otp(page, logger)
    if not submitted:
        try:
            page.keyboard.press("Enter")
            page.wait_for_timeout(350)
            logger.info("ADCB: submitted OTP via Enter key")
            submitted = True
        except Exception:  # noqa: BLE001
            submitted = False

    if attempted_codes is not None and submitted:
        attempted_codes.add(otp)

    return True


def handle_concurrent_session_gate(page: Any, logger: logging.Logger, low_text: str | None = None) -> bool:
    low = (low_text or "").lower()
    if not low:
        try:
            low = (page.locator("body").inner_text(timeout=2500) or "").lower()
        except Exception:  # noqa: BLE001
            low = ""

    if not is_concurrent_session_gate(low):
        return False

    selectors = [
        "button:has-text('Login')",
        "[role='button']:has-text('Login')",
        "input[type='button'][value='Login']",
        "input[type='submit'][value='Login']",
    ]
    for selector in selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 4)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible() or not item.is_enabled():
                    continue
                item.click(timeout=2500)
                page.wait_for_timeout(1200)
                logger.info("ADCB: cleared concurrent-session gate via %s", selector)
                return True
            except Exception:  # noqa: BLE001
                continue

    logger.info("ADCB: concurrent-session gate detected but Login button click failed")
    return False


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


def _snapshot_pdf_mtimes(directory: Path) -> dict[Path, int]:
    if not directory.exists():
        return {}
    state: dict[Path, int] = {}
    for path in directory.iterdir():
        if not path.is_file() or path.suffix.lower() != ".pdf":
            continue
        try:
            state[path.resolve()] = path.stat().st_mtime_ns
        except FileNotFoundError:
            continue
    return state


def _latest_new_pdf(before: dict[Path, int], directory: Path) -> Path | None:
    after = _snapshot_pdf_mtimes(directory)
    candidates: list[Path] = []
    for path, mtime in after.items():
        if path not in before or mtime > before[path]:
            candidates.append(path)
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime_ns)


def _statement_download_section_visible(page: Any) -> bool:
    try:
        if page.locator("select").count() >= 2 and page.locator("button:has-text('Download')").count() > 0:
            return True
    except Exception:  # noqa: BLE001
        pass

    low = text_snapshot(page).lower()
    return (
        "to download previous statements choose the month and year" in low
        or ("credit card statement" in low and "download" in low and "terms and conditions" in low)
    )


def _ensure_statement_download_section(page: Any, logger: logging.Logger) -> bool:
    if _statement_download_section_visible(page):
        return True

    for _ in range(7):
        attempt_navigation_to_statements(page, logger)
        click_keyword(page, "Statement", logger)
        click_keyword(page, "Statements", logger)
        page.wait_for_timeout(800)
        if _statement_download_section_visible(page):
            return True
        page.mouse.wheel(0, 380)
        page.wait_for_timeout(450)

    return _statement_download_section_visible(page)


def _select_statement_period(page: Any, logger: logging.Logger, *, target_year: int, target_month: int) -> bool:
    result = page.evaluate(
        """
        ({ targetYear, targetMonth, monthIndex }) => {
          const norm = (value) => (value || '').toString().replace(/\\s+/g, ' ').trim().toLowerCase();
          const isVisible = (el) => {
            if (!el) return false;
            const style = getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const monthFromText = (value) => {
            const low = norm(value);
            const num = low.match(/\\b(0?[1-9]|1[0-2])\\b/);
            if (num) return parseInt(num[1], 10);
            for (const [key, idx] of Object.entries(monthIndex)) {
              if (low.includes(key)) return idx;
            }
            return null;
          };

          const selects = Array.from(document.querySelectorAll('select')).filter(isVisible);
          let yearSelect = null;
          let yearValue = '';
          let monthSelect = null;
          let monthValue = '';

          for (const select of selects) {
            const options = Array.from(select.options || []).filter((opt) => !opt.disabled);
            if (!options.length) continue;

            if (!yearSelect) {
              const matchYear = options.find((opt) => {
                const txt = `${opt.textContent || ''} ${opt.value || ''}`;
                return txt.includes(String(targetYear));
              });
              if (matchYear && matchYear.value) {
                yearSelect = select;
                yearValue = matchYear.value;
              }
            }

            if (!monthSelect) {
              const matchMonth = options.find((opt) => {
                const txt = `${opt.textContent || ''} ${opt.value || ''}`;
                const m = monthFromText(txt);
                return m === targetMonth;
              });
              if (matchMonth && matchMonth.value) {
                monthSelect = select;
                monthValue = matchMonth.value;
              }
            }
          }

          if (!yearSelect || !monthSelect || !yearValue || !monthValue) {
            return { selected: false, reason: 'period_select_not_found' };
          }

          yearSelect.value = yearValue;
          yearSelect.dispatchEvent(new Event('input', { bubbles: true }));
          yearSelect.dispatchEvent(new Event('change', { bubbles: true }));

          monthSelect.value = monthValue;
          monthSelect.dispatchEvent(new Event('input', { bubbles: true }));
          monthSelect.dispatchEvent(new Event('change', { bubbles: true }));

          return { selected: true };
        }
        """,
        {
            "targetYear": target_year,
            "targetMonth": target_month,
            "monthIndex": MONTH_INDEX,
        },
    )
    selected = bool(result and result.get("selected"))
    if selected:
        logger.info("ADCB: selected statement period year=%s month=%s", target_year, target_month)
    else:
        logger.info(
            "ADCB: statement period not available year=%s month=%s reason=%s",
            target_year,
            target_month,
            (result or {}).get("reason", "unknown"),
        )
    return selected


def _ensure_terms_checkbox_checked(page: Any, logger: logging.Logger) -> None:
    checked = page.evaluate(
        """
        () => {
          const norm = (value) => (value || '').toString().replace(/\\s+/g, ' ').trim().toLowerCase();
          const isVisible = (el) => {
            if (!el) return false;
            const style = getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };

          const checkboxes = Array.from(document.querySelectorAll('input[type="checkbox"]')).filter(isVisible);
          for (const box of checkboxes) {
            if (box.checked) return true;
            const section = box.closest('div, section, form, table, tr') || box.parentElement;
            const txt = norm(section ? section.innerText || section.textContent : '');
            if (txt.includes('terms and conditions') || txt.includes('i/we confirm')) {
              box.click();
              return true;
            }
          }
          return false;
        }
        """
    )
    if checked:
        logger.info("ADCB: ensured statement terms checkbox is checked")


def _download_statement_for_selected_period(page: Any, incoming_dir: Path, logger: logging.Logger) -> Path | None:
    selectors = [
        "button:has-text('Download')",
        "input[type='button'][value*='Download' i]",
        "input[type='submit'][value*='Download' i]",
        "[role='button']:has-text('Download')",
        "a:has-text('Download')",
    ]

    for selector in selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 8)
        except Exception:  # noqa: BLE001
            count = 0

        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible() or not item.is_enabled():
                    continue
                with page.expect_download(timeout=14000) as download_info:
                    item.click(timeout=2500)
                path = save_download(download_info.value, incoming_dir, "ADCB", logger)
                logger.info("ADCB: downloaded statement via %s", selector)
                return path
            except Exception:  # noqa: BLE001
                continue

    before = _snapshot_pdf_mtimes(incoming_dir)
    downloaded = attempt_download_capture(page, incoming_dir, "ADCB", logger)
    if downloaded > 0:
        return _latest_new_pdf(before, incoming_dir)
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

    if not _ensure_statement_download_section(page, logger):
        for month_token in requested_months:
            diagnostics["failed"].append(
                {
                    "month": month_token,
                    "reason": "statement_download_section_not_reachable",
                }
            )
        return 0, diagnostics

    for month_token in requested_months:
        target_year, target_month = _parse_requested_month(month_token)
        if target_year is None or target_month is None:
            diagnostics["failed"].append({"month": month_token, "reason": "invalid_month_token"})
            continue

        if not _select_statement_period(
            page,
            logger,
            target_year=target_year,
            target_month=target_month,
        ):
            diagnostics["skipped_unavailable"].append(
                {"month": month_token, "reason": "statement_period_not_available"}
            )
            continue

        _ensure_terms_checkbox_checked(page, logger)
        path = _download_statement_for_selected_period(page, incoming_dir, logger)
        if path is None:
            diagnostics["failed"].append({"month": month_token, "reason": "download_control_not_found_or_failed"})
            continue

        downloaded += 1
        diagnostics["downloaded"].append({"month": month_token, "path": str(path)})
        page.wait_for_timeout(700)

    return downloaded, diagnostics


def _is_card_details_screen(page: Any) -> bool:
    low = text_snapshot(page).lower()
    url = page.url.lower()
    if "#_frmlogin" in url or is_login_screen(low):
        return False
    if "#_frmlanding" in url and "account summary" in low:
        return False

    has_masked_card = bool(MASKED_CARD_PATTERN.search(low))
    if "card" in url and has_masked_card and ("statement" in low or "transactions" in low):
        return True
    if has_masked_card and "credit card" in low and "card number" in low:
        return True
    if has_masked_card and "statement" in low and "card number" in low:
        return True
    if has_masked_card and any(
        marker in low
        for marker in [
            "card limit",
            "minimum due",
            "available balance",
            "download statement",
            "download statements",
            "unbilled transactions",
        ]
    ):
        return True
    return False


def _click_card_by_limit(page: Any, logger: logging.Logger, limit_aed: int) -> bool:
    try:
        result = page.evaluate(
            """
            ({ targetAmount }) => {
              const visible = (el) => {
                const cs = getComputedStyle(el);
                const r = el.getBoundingClientRect();
                return cs.visibility !== 'hidden' && cs.display !== 'none' && r.width > 0 && r.height > 0;
              };
              const normalize = (s) => (s || '').replace(/\\s+/g, ' ').trim();
              const extractNums = (s) => {
                const raw = s.match(/\\d[\\d, ]*(?:\\.\\d+)?/g) || [];
                return raw
                  .map((n) => Number.parseFloat(n.replace(/[ ,]/g, '')))
                  .filter((n) => Number.isFinite(n));
              };
              const hasTargetAmount = (s) => {
                const nums = extractNums(s);
                return nums.some((n) => Math.abs(n - targetAmount) < 0.01);
              };
              const hasAed = (s) => /\\baed\\b/i.test(s) || /د\\.\\s*إ/i.test(s);
              const maskRe = /((?:x{2,}\\s*)?\\d{0,4}\\s*(?:\\*{2,}\\s*){1,4}\\d{2,4}|x{2,}\\d{2,4}|\\*{2,}\\s*\\d{2,4})/i;
              const looksCardLike = (s) =>
                /credit\\s*card|\\bcard\\b|xxx\\d{2,4}|\\*{2,}\\s*\\d{2,4}|card\\s*limit/i.test(s);

              const nodes = Array.from(
                document.querySelectorAll(
                  'a,button,[role=\"button\"],tr,td,div,span,li,section,article'
                )
              );

              for (const node of nodes) {
                if (!visible(node)) continue;
                const text = normalize(node.innerText || node.textContent || '');
                if (!text) continue;
                if (text.length > 260) continue;
                if (!hasAed(text) || !hasTargetAmount(text) || !looksCardLike(text)) continue;

                let mask = '';
                const match = text.match(maskRe);
                if (match) mask = normalize(match[1]);
                if (!mask && !/card\\s*limit/i.test(text)) continue;

                let cur = node;
                while (cur && cur !== document.body) {
                  if (!visible(cur)) {
                    cur = cur.parentElement;
                    continue;
                  }
                  const tag = (cur.tagName || '').toLowerCase();
                  const role = (cur.getAttribute && cur.getAttribute('role')) || '';
                  const hasHandler = !!(
                    (cur.getAttribute && cur.getAttribute('onclick')) ||
                    (cur.getAttribute && cur.getAttribute('ng-click')) ||
                    (cur.getAttribute && cur.getAttribute('data-ng-click'))
                  );
                  if (tag === 'a' || tag === 'button' || role === 'button' || hasHandler) {
                    cur.click();
                    return {
                      clicked: true,
                      mask,
                      matchedText: text,
                    };
                  }
                  cur = cur.parentElement;
                }

                // If no clickable ancestor is found, try direct click on the node.
                node.click();
                return {
                  clicked: true,
                  mask,
                  matchedText: text,
                };
              }

              return { clicked: false, mask: '', matchedText: '' };
            }
            """,
            {"targetAmount": float(limit_aed)},
        )
    except Exception:  # noqa: BLE001
        return False

    if not result or not result.get("clicked"):
        return False

    mask = (result.get("mask") or "").strip()
    matched_text = (result.get("matchedText") or "").strip()
    if mask:
        logger.info("ADCB: selected card by AED %s limit with mask=%s", limit_aed, mask)
    else:
        logger.info("ADCB: selected card by AED %s limit (mask not extracted)", limit_aed)
    if matched_text:
        logger.info("ADCB: matched card block text=%s", matched_text[:220])

    page.wait_for_timeout(1700)
    return True


def _wait_for_landing_ready(page: Any) -> None:
    for _ in range(22):
        low = text_snapshot(page).lower()
        if "welcome" in low and "last login" in low and "account summary" in low and "credit cards" in low:
            return
        page.wait_for_timeout(650)


def _click_sidebar_credit_cards(page: Any, logger: logging.Logger) -> bool:
    selectors = [
        "text=Credit Cards",
        "a:has-text('Credit Cards')",
        "li:has-text('Credit Cards')",
        "div:has-text('Credit Cards')",
    ]
    for selector in selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 10)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                try:
                    item.click(timeout=2500)
                except Exception:  # noqa: BLE001
                    item.click(timeout=2500, force=True)
                page.wait_for_timeout(900)
                logger.info("ADCB: clicked sidebar Credit Cards via %s", selector)
                return True
            except Exception:  # noqa: BLE001
                continue
    return False


def _click_card_with_last4(page: Any, logger: logging.Logger, bank_cfg: dict) -> bool:
    last4_values = [
        str(card.get("last4", "")).strip()
        for card in bank_cfg.get("cards", [])
        if str(card.get("last4", "")).strip()
    ]
    if not last4_values:
        return False

    for last4 in last4_values:
        selectors = [
            f"text={last4}",
            f"a:has-text('{last4}')",
            f"button:has-text('{last4}')",
            f"[role='button']:has-text('{last4}')",
            f"[aria-label*='{last4}' i]",
            f"[title*='{last4}' i]",
        ]
        for selector in selectors:
            locator = page.locator(selector)
            try:
                count = min(locator.count(), 8)
            except Exception:  # noqa: BLE001
                count = 0
            for idx in range(count):
                item = locator.nth(idx)
                try:
                    if not item.is_visible():
                        continue
                    try:
                        item.click(timeout=2500)
                    except Exception:  # noqa: BLE001
                        item.click(timeout=2500, force=True)
                    page.wait_for_timeout(1700)
                    logger.info("ADCB: clicked card candidate with last4=%s via %s", last4, selector)
                    if _is_card_details_screen(page):
                        return True
                except Exception:  # noqa: BLE001
                    continue

    return False


def _click_card_tile_fallback(page: Any, logger: logging.Logger) -> bool:
    try:
        clicked = page.evaluate(
            """
            () => {
              const visible = (el) => {
                const cs = getComputedStyle(el);
                const r = el.getBoundingClientRect();
                return cs.visibility !== 'hidden' && cs.display !== 'none' && r.width > 0 && r.height > 0;
              };
              const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
              const cardPattern = /(credit\\s*card|card\\s*number|\\d{2,4}\\s*\\*{2,}\\s*\\d{2,4}|\\*{4})/i;

              const nodes = Array.from(document.querySelectorAll('a,button,[role="button"],div,span,li,td'));
              for (const node of nodes) {
                if (!visible(node)) continue;
                const text = norm(node.innerText || node.textContent || '');
                if (!text || !cardPattern.test(text)) continue;

                let cur = node;
                while (cur && cur !== document.body) {
                  if (!visible(cur)) {
                    cur = cur.parentElement;
                    continue;
                  }
                  const tag = (cur.tagName || '').toLowerCase();
                  const role = (cur.getAttribute && cur.getAttribute('role')) || '';
                  const hasHandler = !!(
                    (cur.getAttribute && cur.getAttribute('onclick')) ||
                    (cur.getAttribute && cur.getAttribute('ng-click')) ||
                    (cur.getAttribute && cur.getAttribute('data-ng-click'))
                  );
                  if (tag === 'a' || tag === 'button' || role === 'button' || hasHandler) {
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
        if clicked:
            page.wait_for_timeout(1700)
            logger.info("ADCB: clicked card candidate via fallback scan")
            return True
    except Exception:  # noqa: BLE001
        pass

    return False


def _open_card_details(page: Any, logger: logging.Logger, bank_cfg: dict) -> bool:
    if _is_card_details_screen(page):
        return True

    limit_aed_raw = bank_cfg.get("target_card_limit_aed", 27000)
    try:
        target_limit_aed = int(limit_aed_raw)
    except Exception:  # noqa: BLE001
        target_limit_aed = 27000

    _wait_for_landing_ready(page)

    for _ in range(7):
        _click_sidebar_credit_cards(page, logger)
        click_keyword(page, "Credit Cards", logger)
        click_keyword(page, "Cards", logger)
        if _click_card_by_limit(page, logger, target_limit_aed) and _is_card_details_screen(page):
            return True
        if _click_card_with_last4(page, logger, bank_cfg):
            return True
        if _click_card_tile_fallback(page, logger) and _is_card_details_screen(page):
            return True
        page.mouse.wheel(0, 420)
        page.wait_for_timeout(500)

    return _is_card_details_screen(page)


def download_latest_statement(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    bank_cfg: dict,
) -> int:
    details_opened = _open_card_details(page, logger, bank_cfg)
    logger.info("ADCB: card details opened=%s current_url=%s", details_opened, page.url)

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

    for _ in range(8):
        attempt_navigation_to_statements(page, logger)
        page.wait_for_timeout(1000)

        downloaded = attempt_download_capture(page, incoming_dir, "ADCB", logger)
        if downloaded > 0:
            bank_cfg["download_diagnostics"] = {
                "requested_months": ["latest"],
                "downloaded": [{"month": "latest"}],
                "skipped_unavailable": [],
                "failed": [],
            }
            return downloaded

        click_keyword(page, "View", logger)
        click_keyword(page, "Download", logger)
        click_keyword(page, "PDF", logger)
        page.wait_for_timeout(900)

    bank_cfg["download_diagnostics"] = {
        "requested_months": ["latest"],
        "downloaded": [],
        "skipped_unavailable": [],
        "failed": [{"month": "latest", "reason": "download_control_not_found_or_failed"}],
    }
    return 0

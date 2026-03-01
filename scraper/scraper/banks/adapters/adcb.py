from __future__ import annotations

import logging
import random
import re
import sqlite3
import time
from pathlib import Path
from typing import Any

from scraper.banks.shared import (
    attempt_download_capture,
    attempt_navigation_to_statements,
    click_keyword,
    require_env,
    save_download,
    text_snapshot,
)
from scraper.banks.month_utils import MONTH_INDEX

OTP_CODE_PATTERN = re.compile(r"\b(\d{4,8})\b")
MASKED_CARD_PATTERN = re.compile(
    r"((?:x{2,}\s*)?\d{0,4}\s*(?:\*{2,}\s*){1,4}\d{2,4}|x{2,}\d{2,4}|\*{2,}\s*\d{2,4})",
    re.IGNORECASE,
)


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


def _score_option_text(text: str, mode: str) -> int | None:
    low = text.lower().strip()
    if not low:
        return None

    if mode == "year":
        year_match = re.search(r"\b(19|20)\d{2}\b", low)
        return int(year_match.group(0)) if year_match else None

    if mode == "month":
        return _parse_month_value(low)

    year_match = re.search(r"\b(19|20)\d{2}\b", low)
    month_val = _parse_month_value(low)
    if year_match and month_val:
        return int(year_match.group(0)) * 100 + month_val
    return None


def _extract_select_options(select_element: Any) -> list[dict[str, Any]]:
    try:
        return select_element.evaluate(
            """
            (el) => Array.from(el.options).map((opt) => ({
              text: (opt.textContent || '').trim(),
              value: opt.value || '',
              disabled: !!opt.disabled,
              selected: !!opt.selected
            }))
            """
        )
    except Exception:  # noqa: BLE001
        return []


def _classify_native_select_mode(select_element: Any) -> str | None:
    options = _extract_select_options(select_element)
    if not options:
        return None

    year_only = 0
    month_only = 0
    combined = 0

    for opt in options:
        text = (opt.get("text") or opt.get("value") or "").strip()
        low = text.lower()
        if opt.get("disabled"):
            continue
        if not text:
            continue
        if any(token in low for token in ["select", "choose", "please"]):
            continue

        has_year = re.search(r"\b(19|20)\d{2}\b", low) is not None
        has_month = _parse_month_value(low) is not None

        if has_year and has_month:
            combined += 1
        elif has_year:
            year_only += 1
        elif has_month:
            month_only += 1

    if combined > 0 and combined >= max(year_only, month_only):
        return "combined"
    if year_only > 0 and month_only == 0:
        return "year"
    if month_only > 0 and year_only == 0:
        return "month"
    return None


def _choose_option(
    select_element: Any,
    mode: str,
    logger: logging.Logger,
    *,
    target_score: int | None = None,
    strict_target: bool = False,
) -> bool:
    options = _extract_select_options(select_element)
    if not options:
        return False

    candidates: list[tuple[int, dict[str, Any]]] = []
    for opt in options:
        text = (opt.get("text") or "").strip()
        value = (opt.get("value") or "").strip()
        low = text.lower()
        if opt.get("disabled"):
            continue
        if not text and not value:
            continue
        if any(token in low for token in ["select", "choose", "please"]):
            continue

        score = _score_option_text(text, mode)
        if score is not None:
            candidates.append((score, opt))

    if not candidates:
        return False

    chosen = None
    if target_score is not None:
        for score, opt in candidates:
            if score == target_score:
                chosen = opt
                break

    if chosen is None and strict_target and target_score is not None:
        logger.info(
            "ADCB: target %s option score=%s not found in native select",
            mode,
            target_score,
        )
        return False

    if chosen is None:
        candidates.sort(key=lambda x: x[0], reverse=True)
        chosen = candidates[0][1]

    try:
        if chosen.get("value"):
            select_element.select_option(chosen["value"])
        else:
            select_element.select_option(label=chosen.get("text", ""))
        logger.info(
            "ADCB: selected %s option %s (target_score=%s)",
            mode,
            chosen.get("text", ""),
            target_score,
        )
        return True
    except Exception:  # noqa: BLE001
        return False


def _selected_option_score(select_element: Any, mode: str) -> int | None:
    options = _extract_select_options(select_element)
    selected = next((opt for opt in options if opt.get("selected")), None)
    if selected is None:
        return None
    return _score_option_text(str(selected.get("text") or ""), mode)


def _dismiss_optional_ad_popup(page: Any, logger: logging.Logger) -> bool:
    dismissed = False
    for _ in range(4):
        dismissed_this_round = False

        for selector in [
            "[role='dialog'] button:has-text('Close')",
            "[role='dialog'] button:has-text('Dismiss')",
            "[role='dialog'] button:has-text('Skip')",
            "[role='dialog'] button:has-text('Not now')",
            "[role='dialog'] button:has-text('Later')",
            "[role='dialog'] [aria-label='Close']",
            ".modal button:has-text('Close')",
            ".popup button:has-text('Close')",
            ".modal [aria-label='Close']",
            ".popup [aria-label='Close']",
            "button:has-text('Close')",
            "[aria-label='Close']",
        ]:
            locator = page.locator(selector)
            try:
                count = min(locator.count(), 5)
            except Exception:  # noqa: BLE001
                count = 0

            for idx in range(count):
                item = locator.nth(idx)
                try:
                    if not item.is_visible():
                        continue
                    item.click(timeout=1800)
                    page.wait_for_timeout(500)
                    logger.info("ADCB: dismissed optional popup via %s", selector)
                    dismissed = True
                    dismissed_this_round = True
                    break
                except Exception:  # noqa: BLE001
                    continue
            if dismissed_this_round:
                break

        if not dismissed_this_round:
            break

    return dismissed


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


def login(page: Any, logger: logging.Logger, credentials: dict[str, str] | None = None) -> None:
    cid = require_env("ADCB_CID", credentials)
    password = require_env("ADCB_LOGIN_PASSWORD", credentials)

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


def _find_statement_download_container(page: Any) -> Any | None:
    selectors = "section,div,form,article,table,tbody,tr,td"
    anchor_text = "to download previous statements choose the month and year"
    containers = page.locator(selectors)
    try:
        count = min(containers.count(), 320)
    except Exception:  # noqa: BLE001
        count = 0

    for idx in range(count):
        item = containers.nth(idx)
        try:
            if not item.is_visible():
                continue
            text = (item.inner_text(timeout=800) or "").lower()
            if anchor_text not in text:
                continue
            # Keep only containers that own at least one select and a download action.
            if item.locator("select").count() < 1:
                continue
            if item.locator("button:has-text('Download')").count() == 0 and item.locator(
                "input[type='button'][value*='Download' i], input[type='submit'][value*='Download' i], a:has-text('Download')"
            ).count() == 0:
                continue
            return item
        except Exception:  # noqa: BLE001
            continue

    return None


def _ensure_statement_download_section(page: Any, logger: logging.Logger) -> bool:
    if _statement_download_section_visible(page):
        return True

    for _ in range(7):
        _dismiss_optional_ad_popup(page, logger)
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
    scope = _find_statement_download_container(page)
    if scope is None:
        logger.info("ADCB: statement block anchor not found; falling back to page-wide selects")
        selects = page.locator("select")
    else:
        selects = scope.locator("select")

    try:
        count = min(selects.count(), 10)
    except Exception:  # noqa: BLE001
        count = 0

    visible = []
    for idx in range(count):
        select = selects.nth(idx)
        try:
            if select.is_visible():
                visible.append(select)
        except Exception:  # noqa: BLE001
            continue

    if not visible:
        logger.info("ADCB: statement period controls not visible")
        return False

    classified: list[tuple[Any, str]] = []
    for select in visible:
        mode = _classify_native_select_mode(select)
        if mode:
            classified.append((select, mode))

    year_selects = [select for select, mode in classified if mode == "year"]
    month_selects = [select for select, mode in classified if mode == "month"]
    combined_selects = [select for select, mode in classified if mode == "combined"]

    target_combined = target_year * 100 + target_month

    if year_selects and month_selects:
        selected_year = False
        for select in year_selects:
            selected_year = _choose_option(
                select,
                "year",
                logger,
                target_score=target_year,
                strict_target=True,
            ) or selected_year

        if selected_year:
            page.wait_for_timeout(1100)

        selected_month = False
        # Re-read visible selects because month options may refresh after year change.
        if scope is not None:
            selects = scope.locator("select")
        else:
            selects = page.locator("select")
        try:
            refreshed_count = min(selects.count(), 10)
        except Exception:  # noqa: BLE001
            refreshed_count = 0
        refreshed_months = []
        for idx in range(refreshed_count):
            select = selects.nth(idx)
            try:
                if not select.is_visible():
                    continue
            except Exception:  # noqa: BLE001
                continue
            if _classify_native_select_mode(select) == "month":
                refreshed_months.append(select)
        if refreshed_months:
            month_selects = refreshed_months

        for select in month_selects:
            selected_month = _choose_option(
                select,
                "month",
                logger,
                target_score=target_month,
                strict_target=True,
            ) or selected_month

        if selected_year and selected_month:
            page.wait_for_timeout(500)
            year_ok = any(_selected_option_score(select, "year") == target_year for select in year_selects)
            month_ok = any(_selected_option_score(select, "month") == target_month for select in month_selects)
            if year_ok and month_ok:
                logger.info("ADCB: selected statement period year=%s month=%s", target_year, target_month)
                return True

    for select in combined_selects:
        if _choose_option(
            select,
            "combined",
            logger,
            target_score=target_combined,
            strict_target=True,
        ):
            page.wait_for_timeout(550)
            if _selected_option_score(select, "combined") == target_combined:
                logger.info("ADCB: selected statement period year=%s month=%s", target_year, target_month)
                return True

    logger.info(
        "ADCB: statement period not available year=%s month=%s reason=period_select_not_found_or_verify_failed",
        target_year,
        target_month,
    )
    return False


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
    scope = _find_statement_download_container(page)
    if scope is not None:
        selectors = [
            "button:has-text('Download')",
            "input[type='button'][value*='Download' i]",
            "input[type='submit'][value*='Download' i]",
            "[role='button']:has-text('Download')",
            "a:has-text('Download')",
        ]
        for selector in selectors:
            locator = scope.locator(selector)
            try:
                count = min(locator.count(), 6)
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
                    logger.info("ADCB: downloaded statement via anchored statement block")
                    return path
                except Exception:  # noqa: BLE001
                    continue

    try:
        with page.expect_download(timeout=14000) as download_info:
            clicked = page.evaluate(
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

                  const downloadLike = (txt) => {
                    const low = norm(txt);
                    return low.includes('download') && (low.includes('statement') || low === 'download');
                  };

                  const containers = Array.from(document.querySelectorAll('section,div,form,article,table,tbody,tr,td'));
                  for (const container of containers) {
                    if (!isVisible(container)) continue;
                    const text = norm(container.innerText || container.textContent || '');
                    if (!text) continue;

                    const visibleSelects = Array.from(container.querySelectorAll('select')).filter(isVisible);
                    if (visibleSelects.length < 1) continue;
                    if (!(text.includes('statement') && (text.includes('month') || text.includes('year')))) continue;

                    const controls = Array.from(
                      container.querySelectorAll(
                        'button, a, [role=\"button\"], input[type=\"button\"], input[type=\"submit\"]'
                      )
                    ).filter(isVisible);

                    for (const control of controls) {
                      const label = norm(
                        (control.innerText || control.textContent || control.value || control.title || control.getAttribute?.('aria-label') || '')
                      );
                      if (!downloadLike(label)) continue;
                      control.click();
                      return true;
                    }
                  }
                  return false;
                }
                """
            )
            if not clicked:
                raise RuntimeError("Scoped statement download control not found")
        path = save_download(download_info.value, incoming_dir, "ADCB", logger)
        logger.info("ADCB: downloaded statement via scoped statement-period section")
        return path
    except Exception:  # noqa: BLE001
        pass

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
        _dismiss_optional_ad_popup(page, logger)

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


def _wait_for_card_details_screen(page: Any, *, timeout_ms: int = 4200) -> bool:
    end = time.monotonic() + (max(timeout_ms, 200) / 1000.0)
    while time.monotonic() < end:
        if _is_card_details_screen(page):
            return True
        try:
            page.wait_for_timeout(350)
        except Exception:  # noqa: BLE001
            break
    return _is_card_details_screen(page)


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

    return _wait_for_card_details_screen(page, timeout_ms=5000)


def _wait_for_landing_ready(page: Any, logger: logging.Logger) -> None:
    for _ in range(22):
        _dismiss_optional_ad_popup(page, logger)
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
                    logger.info("ADCB: clicked card candidate with last4=%s via %s", last4, selector)
                    if _wait_for_card_details_screen(page, timeout_ms=5200):
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
            logger.info("ADCB: clicked card candidate via fallback scan")
            return _wait_for_card_details_screen(page, timeout_ms=5200)
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

    _wait_for_landing_ready(page, logger)

    for _ in range(7):
        _dismiss_optional_ad_popup(page, logger)
        _click_sidebar_credit_cards(page, logger)
        click_keyword(page, "Credit Cards", logger)
        click_keyword(page, "Cards", logger)
        if _click_card_by_limit(page, logger, target_limit_aed):
            return True
        if _click_card_with_last4(page, logger, bank_cfg):
            return True
        if _click_card_tile_fallback(page, logger):
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
    _dismiss_optional_ad_popup(page, logger)
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

    # Latest/monthless scrape: first try the structured statement-period section,
    # which is more reliable than generic button scanning on ADCB.
    if _ensure_statement_download_section(page, logger):
        _ensure_terms_checkbox_checked(page, logger)
        latest_path = _download_statement_for_selected_period(page, incoming_dir, logger)
        if latest_path is not None:
            bank_cfg["download_diagnostics"] = {
                "requested_months": ["latest"],
                "downloaded": [{"month": "latest", "path": str(latest_path)}],
                "skipped_unavailable": [],
                "failed": [],
            }
            return 1
        logger.info("ADCB: structured latest statement download path failed; using fallback navigation")

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


from scraper.banks.base import AuthPollAction, AuthPollState, BankAdapter


def _on_auth_poll_tick(page: Any, low_text: str, logger: logging.Logger, state: AuthPollState) -> AuthPollAction:
    extra = state.extra

    # OTP screen tracking
    if is_otp_screen(low_text):
        if extra.get("otp_challenge_started_unix") is None:
            extra["otp_challenge_started_unix"] = time.time()
            extra.setdefault("attempted_otp_codes", set()).clear()
        extra["had_challenge"] = True
    else:
        extra["otp_challenge_started_unix"] = None
        extra.setdefault("attempted_otp_codes", set()).clear()

    # Concurrent session gate
    if handle_concurrent_session_gate(page, logger, low_text):
        extra["had_challenge"] = True
        return AuthPollAction.WAIT

    # Auto OTP
    if try_auto_otp(
        page,
        logger,
        low_text,
        not_before_unix=extra.get("otp_challenge_started_unix"),
        attempted_codes=extra.setdefault("attempted_otp_codes", set()),
    ):
        return AuthPollAction.WAIT

    # Re-login after challenge
    if (
        is_login_screen(low_text)
        and extra.get("had_challenge")
        and state.relogin_attempts < 2
        and time.time() - state.last_login_attempt_unix >= 8
    ):
        logger.info("ADCB: returned to login after challenge; retrying login")
        return AuthPollAction.RETRY_LOGIN

    return AuthPollAction.CONTINUE


ADAPTER = BankAdapter(
    code="ADCB",
    login=login,
    login_selector_visible=login_selector_visible,
    download_latest_statement=download_latest_statement,
    is_authenticated_session=is_authenticated_session,
    is_login_screen=is_login_screen,
    on_auth_poll_tick=_on_auth_poll_tick,
    skip_mfa_user_prompt=True,
    skip_keyword_fallback=True,
)

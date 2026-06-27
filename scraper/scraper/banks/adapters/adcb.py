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
    """Dismiss any optional ad/promo popup in any frame on the page."""
    # First: force-click ADCB's "Refer & earn" popup "Do Later" link.
    # GWT renders this with opacity/transform transitions, so Playwright's normal
    # visibility check (is_visible) returns False even when the popup is shown.
    # Using force=True bypasses all actionability checks and fires the click.
    try:
        do_later = page.locator("a:has-text('Do Later')")
        if do_later.count() > 0:
            do_later.first.click(force=True, timeout=2000)
            page.wait_for_timeout(500)
            logger.info("ADCB: force-clicked 'Do Later' to dismiss Refer & earn popup")
            return True
    except Exception:  # noqa: BLE001
        pass
    # Also try the × close button with force click.
    try:
        close_btn = page.locator("button:has-text('×'), button:has-text('✕')")
        if close_btn.count() > 0:
            close_btn.first.click(force=True, timeout=1500)
            page.wait_for_timeout(400)
            logger.info("ADCB: force-clicked × to dismiss popup")
            return True
    except Exception:  # noqa: BLE001
        pass

    selectors = [
        # "Refer & earn" popup — "Do Later" link (anchor, not button)
        "a:has-text('Do Later')",
        "a:has-text('do later')",
        # Bootstrap-style close button (data-dismiss="modal")
        "[data-dismiss='modal']",
        "button.close",
        ".modal-header button.close",
        # Generic dialog close patterns
        "[role='dialog'] button:has-text('Close')",
        "[role='dialog'] button:has-text('Dismiss')",
        "[role='dialog'] button:has-text('Skip')",
        "[role='dialog'] button:has-text('Not now')",
        "[role='dialog'] button:has-text('Later')",
        "[role='dialog'] a:has-text('Later')",
        "[role='dialog'] [aria-label='Close']",
        ".modal button:has-text('Close')",
        ".popup button:has-text('Close')",
        ".modal [aria-label='Close']",
        ".popup [aria-label='Close']",
        "button:has-text('Close')",
        "[aria-label='Close']",
    ]
    dismissed = False
    # Search both main frame and any child frames (ADCB may render popups in iframes).
    try:
        frames = list(page.frames)
    except Exception:  # noqa: BLE001
        frames = []
    if page not in frames:
        frames = [page] + frames

    for _ in range(4):
        dismissed_this_round = False
        for frame in frames:
            for selector in selectors:
                try:
                    locator = frame.locator(selector)
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
                        logger.info("ADCB: dismissed optional popup via %s (frame=%s)", selector, getattr(frame, "name", "main"))
                        dismissed = True
                        dismissed_this_round = True
                        break
                    except Exception:  # noqa: BLE001
                        continue
                if dismissed_this_round:
                    break
            if dismissed_this_round:
                break
        if not dismissed_this_round:
            break

    # JavaScript fallback: click "Do Later" or × by innerText regardless of CSS
    # visibility.  ADCB's "Refer & earn" popup renders via GWT with opacity/transform
    # transitions, so Playwright's is_visible() may return False for the anchor.
    # Always run the JS fallback to catch cases that the selector loop missed.
        try:
            clicked_text = page.evaluate(
                """
                () => {
                  const targets = ['Do Later', 'do later', 'Not Now', 'not now', 'Skip', 'skip'];
                  for (const el of [...document.querySelectorAll('a, button, span, div')]) {
                    const t = (el.innerText || el.textContent || '').trim();
                    if (targets.some(tx => t.toLowerCase() === tx.toLowerCase())) {
                      el.click();
                      return t;
                    }
                  }
                  // × / ✕ close button (popup header X)
                  for (const el of [...document.querySelectorAll('button, span, a, div')]) {
                    const t = (el.innerText || el.textContent || '').trim();
                    if (t === '\xd7' || t === '\u2715' || t === 'x' || t === 'X') {
                      const r = el.getBoundingClientRect();
                      if (r.width > 0 && r.height > 0) { el.click(); return t; }
                    }
                  }
                  return null;
                }
                """
            )
            if clicked_text:
                page.wait_for_timeout(700)
                logger.info("ADCB: dismissed popup via JS fallback (clicked '%s')", clicked_text)
                dismissed = True
        except Exception:  # noqa: BLE001
            pass

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

    # Click ADCB's own Reset button first — this is the only reliable way to
    # clear ADCB's internal virtual-keyboard password buffer.  Programmatic
    # page.fill("", "") only clears the visible field value, not the encrypted
    # password buffer maintained by ADCB's JS.  On re-login attempts, without
    # this reset, the previous password is still in the buffer and the new
    # characters are appended, doubling the password.
    try:
        reset_btn = page.locator("#frmLogin_btnReset, input[value='Reset'], button:has-text('Reset')")
        if reset_btn.count() > 0 and reset_btn.first.is_visible():
            reset_btn.first.click(timeout=2000)
            page.wait_for_timeout(400)
            logger.info("ADCB: reset login form")
    except Exception:  # noqa: BLE001
        pass

    cid_radio = page.locator("input[aria-label='ADCB CID']")
    if cid_radio.count() > 0:
        cid_radio.first.check()

    page.fill("#frmLogin_txtUserId", cid)
    _fill_password_via_virtual_keyboard(page, password, logger)

    # Wait for the login button to be enabled.  If it stays disabled after
    # waiting (e.g. ADCB in a bad state), clear cookies/storage and reload the
    # page so we start from a clean slate on the next attempt.
    portal = "https://online.adcb.com/apps/ADCBIB/#_frmLogin"
    try:
        btn = page.locator("#frmLogin_btnLogin")
        for _ in range(20):
            if btn.count() > 0 and btn.first.is_enabled():
                break
            page.wait_for_timeout(300)
        else:
            # Button never became enabled — hard reset.
            logger.warning("ADCB: login button stayed disabled; clearing session and reloading")
            try:
                page.context.clear_cookies()
                page.evaluate(
                    "() => { try { localStorage.clear(); } catch(_) {} "
                    "try { sessionStorage.clear(); } catch(_) {} }"
                )
            except Exception:  # noqa: BLE001
                pass
            page.goto(portal, wait_until="domcontentloaded", timeout=30000)
            logger.info("ADCB: waiting 2000ms — portal navigation after storage clear; allowing login page to render")
            page.wait_for_timeout(2000)
            return  # Caller will detect login screen and retry.
    except Exception:  # noqa: BLE001
        pass

    page.click("#frmLogin_btnLogin")
    logger.info("ADCB: login submitted")


def login_selector_visible(page: Any) -> bool:
    try:
        return page.locator("#frmLogin_txtUserId").first.is_visible()
    except Exception:  # noqa: BLE001
        # TargetClosedError: page navigated/closed during concurrent-session gate
        # handling.  Treat as not visible so the caller doesn't crash.
        return False


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
    try:
        url = page.url.lower()
    except Exception:  # noqa: BLE001
        # TargetClosedError: page closed mid-navigation after concurrent-session
        # gate dismissal.  Return False so the auth poll retries.
        return False
    low = low_text.lower()
    # Logout / session-timeout pages are NOT authenticated.
    if "#_frmlogout" in url:
        return False
    if "timed out" in low and "inactivity" in low:
        return False
    if "#_frmlogin" in url and is_login_screen(low):
        return False
    if is_concurrent_session_gate(low):
        return False
    if login_selector_visible(page):
        return False
    if is_otp_screen(low):
        return False
    return not is_login_screen(low)


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

    # Strategy: prefer "Continue browsing" over "Login".
    #
    # "Continue browsing" resumes the EXISTING authenticated session — no new
    # OTP required.  "Login" terminates the existing session and starts a fresh
    # login, requiring a new OTP and triggering ADCB rate-limiting when multiple
    # runs happen in quick succession.
    #
    # Try "Continue browsing" first; if it navigates us to the authenticated
    # dashboard, perfect.  If the button isn't there, fall back to "Login".
    continue_selectors = [
        "button:has-text('Continue browsing')",
        "button:has-text('Continue Browsing')",
        "button:has-text('Continue')",
        "[role='button']:has-text('Continue browsing')",
        "[role='button']:has-text('Continue')",
        "input[type='button'][value='Continue browsing']",
        "input[type='button'][value='Continue']",
        "input[type='button'][value*='Continue' i]",
        "input[type='submit'][value*='Continue' i]",
        "a:has-text('Continue browsing')",
        "a:has-text('Continue')",
    ]
    for selector in continue_selectors:
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
                logger.info("ADCB: waiting 2000ms — 'Continue browsing' clicked; allowing session to resume")
                page.wait_for_timeout(2000)
                logger.info("ADCB: clicked 'Continue browsing' on gate (using existing session)")
                return True
            except Exception:  # noqa: BLE001
                continue

    # Fallback: "Login" terminates the existing session and forces re-login.
    login_selectors = [
        "button:has-text('Login')",
        "[role='button']:has-text('Login')",
        "input[type='button'][value='Login']",
        "input[type='submit'][value='Login']",
    ]
    for selector in login_selectors:
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
                # Give ADCB's backend a moment to register the session termination.
                logger.info("ADCB: waiting 3000ms — Login clicked to terminate concurrent session; allowing backend to register")
                page.wait_for_timeout(3000)
                logger.info("ADCB: cleared concurrent-session gate via %s", selector)
                return True
            except Exception:  # noqa: BLE001
                continue

    logger.info("ADCB: concurrent-session gate detected but no button click succeeded")
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
                    logger.info("ADCB: waiting for download event via anchored statement block (up to 14000ms)")
                    with page.expect_download(timeout=14000) as download_info:
                        item.click(timeout=2500)
                    path = save_download(download_info.value, incoming_dir, "ADCB", logger)
                    logger.info("ADCB: downloaded statement via anchored statement block")
                    return path
                except Exception:  # noqa: BLE001
                    continue

    try:
        logger.info("ADCB: waiting for download event via JS page-level scan (up to 14000ms)")
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
                logger.info("ADCB: waiting for download event via %s (up to 14000ms)", selector)
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
    """Return True only when the per-card statement DOWNLOAD section is visible.

    ADCB's SPA keeps the URL at #_frmLanding for all views.  We cannot use URL
    or general page text to distinguish screens.  Instead, we require positive
    evidence of the statement-download form (month/year selects, download button,
    or the "to download previous statements" heading).

    The CC Statement LIST page (showing all cards before one is selected) must NOT
    match — it shares masked card numbers, "credit card statement", and "card number"
    column header with the per-card details screen.
    """
    low = text_snapshot(page).lower()
    url = page.url.lower()
    if "#_frmlogin" in url or is_login_screen(low):
        return False

    has_masked_card = bool(MASKED_CARD_PATTERN.search(low))

    # Strongest positive: the "to download previous statements" prompt.
    if "to download previous statements" in low and has_masked_card:
        return True

    # Download form: month/year selects are visible.
    if has_masked_card and ("select month" in low or "select year" in low):
        return True

    # "To download" combined with a period-selection hint.
    if has_masked_card and "to download" in low and (
        "month" in low or "year" in low or "period" in low
    ):
        return True

    # "Generate e-statement" or "e-statement" button/heading.
    if has_masked_card and any(m in low for m in ["generate e-statement", "e-statement"]):
        return True

    # "Unbilled transactions" section only appears on card details (not CC list).
    if has_masked_card and "unbilled transactions" in low:
        return True

    # "Select card" + "download" — appears on single-card download forms.
    if has_masked_card and "select card" in low and "download" in low:
        return True

    # Playwright-visible check: at least 2 <select> elements + a Download button.
    try:
        if (
            page.locator("select").count() >= 2
            and page.locator("button:has-text('Download'), input[value*='Download' i]").count() > 0
            and has_masked_card
        ):
            return True
    except Exception:  # noqa: BLE001
        pass

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


def _is_popup_blocking(page: Any) -> bool:
    """Return True if a known modal/popup overlay is currently visible in any frame."""
    selectors = [
        "a:has-text('Do Later')",
        "[data-dismiss='modal']:visible",
        "button.close:visible",
        "[role='dialog']:visible",
    ]
    try:
        frames = list(page.frames)
    except Exception:  # noqa: BLE001
        frames = []
    if page not in frames:
        frames = [page] + frames
    for frame in frames:
        for selector in selectors:
            try:
                if frame.locator(selector).first.is_visible():
                    return True
            except Exception:  # noqa: BLE001
                pass
    # JS fallback: detect "Do Later" by innerText (GWT popups may not be
    # Playwright-visible due to opacity/transform transitions).
    # Use only "do later" — it is unique to the popup modal, not the main content.
    try:
        found = page.evaluate(
            "() => (document.body.innerText || '').toLowerCase().includes('do later')"
        )
        if found:
            return True
    except Exception:  # noqa: BLE001
        pass
    return False


def _wait_for_landing_ready(page: Any, logger: logging.Logger) -> None:
    for _ in range(40):
        _dismiss_optional_ad_popup(page, logger)
        low = text_snapshot(page).lower()
        landing_ready = (
            "welcome" in low
            and "last login" in low
            and "account summary" in low
            and "credit cards" in low
        )
        # Require the Account Summary MAIN CONTENT area to be rendered, not just
        # the sidebar (which loads instantly).  The masked card number or the CC
        # list hint confirms the content area has loaded.  Without this, sidebar
        # nav clicks get ignored by ADCB's SPA while the page is still loading.
        # NOTE: "touchpoints" was removed — it is always present in the sidebar
        # nav item and caused an immediate (premature) content_loaded = True.
        content_loaded = bool(MASKED_CARD_PATTERN.search(low)) or "click on credit card number" in low
        if landing_ready and content_loaded and not _is_popup_blocking(page):
            logger.info("ADCB: landing page ready (content loaded)")
            # The "Refer & earn" popup appears 1-3 s AFTER content loads, async.
            # ALWAYS wait 3 s minimum so the popup has time to appear — then
            # actively dismiss it.  Without this fixed pause, the popup arrives
            # mid-sidebar-click and its overlay intercepts all mouse events.
            logger.info("ADCB: waiting 3000ms — allowing 'Refer & Earn' popup time to appear before dismissal")
            page.wait_for_timeout(3000)
            for _pw in range(6):  # up to 3 more s (6 × 500 ms) of dismissal
                _dismiss_optional_ad_popup(page, logger)
                if not _is_popup_blocking(page):
                    logger.info("ADCB: popup cleared, proceeding to sidebar nav")
                    break
                page.wait_for_timeout(500)
            return
        page.wait_for_timeout(650)


def _click_sidebar_credit_cards(page: Any, logger: logging.Logger) -> bool:
    # Dismiss any popup that might be blocking the sidebar before attempting clicks.
    _dismiss_optional_ad_popup(page, logger)
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
              const cardPattern = /(credit\\s*card|card\\s*number|\\d{2,4}\\s*[\\*xX]{2,}\\s*\\d{2,4}|[\\*xX]{4})/i;

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


def _click_card_link_in_landing_table(page: Any, logger: logging.Logger, bank_cfg: dict) -> bool:
    """Click the credit card link directly from the Credit Cards table on the landing/dashboard page.

    Prefers a card whose last-4 digits match bank_cfg['cards'][*]['last4']; falls back to the
    first masked-card link found inside the Credit Cards section.

    Uses Playwright locators (which auto-scroll into view) as the primary strategy so that
    card links that are below the initial viewport fold are still reliably clicked.
    """
    last4_values = [
        str(card.get("last4", "")).strip()
        for card in bank_cfg.get("cards", [])
        if str(card.get("last4", "")).strip()
    ]

    # --- DOM diagnostic: log what elements contain the last4 values ---
    for last4 in last4_values:
        try:
            matches = page.evaluate(
                """
                (last4) => {
                  const results = [];
                  for (const el of Array.from(document.querySelectorAll('*'))) {
                    const t = (el.innerText || el.textContent || '').trim();
                    if (t.includes(last4) && t.length < 120) {
                      const r = el.getBoundingClientRect();
                      results.push({
                        tag: el.tagName,
                        text: t.substring(0, 80),
                        id: el.id || '',
                        cls: (typeof el.className === 'string' ? el.className : '').substring(0, 40),
                        href: el.href || '',
                        w: Math.round(r.width),
                        h: Math.round(r.height),
                      });
                      if (results.length >= 10) break;
                    }
                  }
                  return results;
                }
                """,
                last4,
            )
            logger.info("ADCB: DOM elements containing '%s': %s", last4, matches)
        except Exception:  # noqa: BLE001
            pass

    # --- Primary: Playwright locator approach (anchors, handles auto-scroll) ---
    # locator.click() automatically scrolls the element into view.
    for last4 in last4_values:
        for selector in [
            f"a:has-text('{last4}')",
            f"a[href*='{last4}']",
        ]:
            locator = page.locator(selector)
            try:
                count = min(locator.count(), 5)
            except Exception:  # noqa: BLE001
                count = 0
            if count:
                logger.info("ADCB: '%s' found count=%s", selector, count)
            for idx in range(count):
                item = locator.nth(idx)
                try:
                    item.click(timeout=3500)
                    logger.info("ADCB: clicked credit card link in landing table (last4=%s via %s)", last4, selector)
                    if _wait_for_card_details_screen(page, timeout_ms=6000):
                        return True
                except Exception:  # noqa: BLE001
                    continue

    # --- Secondary: direct pixel-level mouse click on the card row ---
    # ADCB's GWT SPA may require genuine mouse events at pixel coordinates.
    # Strategy: find the li.seg2Normal row containing last4, then prefer the
    # sKHbxTrans transparent overlay WITHIN that row as the actual click target
    # (GWT event delegation typically attaches handlers to the overlay div).
    for last4 in last4_values:
        try:
            rect = page.evaluate(
                """
                (last4) => {
                  // Helper: check if an element is inside the Account Summary CC widget.
                  // That widget's containers have IDs starting with "segCreditCardsbox_".
                  // Clicking those rows does NOTHING (display-only widget).
                  const isAcctSummary = (el) => {
                    let cur = el;
                    while (cur && cur !== document.body) {
                      if (cur.id && cur.id.startsWith('segCreditCardsbox_')) return true;
                      cur = cur.parentElement;
                    }
                    return false;
                  };

                  // Find the card row li.seg2Normal that contains this last4.
                  for (const li of document.querySelectorAll('li.seg2Normal, tr.seg2Normal')) {
                    const liText = (li.innerText || li.textContent || '').trim();
                    if (!liText.includes(last4)) continue;
                    const liRect = li.getBoundingClientRect();
                    if (liRect.width === 0 || liRect.height === 0) continue;

                    // Flag Account Summary rows — they are not navigable.
                    const inAcctSummary = isAcctSummary(li);

                    // Prefer the transparent GWT overlay div within this row.
                    const overlay = li.querySelector(
                      'div[class*="Trans"], div[class*="sKHb"], div[class*="trans"]'
                    );
                    if (overlay) {
                      const r = overlay.getBoundingClientRect();
                      if (r.width > 0 && r.height > 0)
                        return { left: r.left, top: r.top, width: r.width, height: r.height,
                                 tag: 'DIV', cls: overlay.className || '', source: 'overlay',
                                 acct_summary: inAcctSummary };
                    }

                    // Fall back to a child div/span that directly contains last4.
                    for (const child of li.querySelectorAll('div, span')) {
                      const ct = (child.innerText || child.textContent || '').trim();
                      if (!ct.includes(last4)) continue;
                      const r = child.getBoundingClientRect();
                      if (r.width > 0 && r.height > 0)
                        return { left: r.left, top: r.top, width: r.width, height: r.height,
                                 tag: child.tagName, cls: child.className || '', source: 'child',
                                 acct_summary: inAcctSummary };
                    }

                    // Last resort: click the row itself.
                    return { left: liRect.left, top: liRect.top, width: liRect.width, height: liRect.height,
                             tag: li.tagName, cls: li.className || '', source: 'row',
                             acct_summary: inAcctSummary };
                  }

                  // Fallback: any element with last4 text (mark acct_summary if applicable).
                  for (const el of document.querySelectorAll('li.seg2Normal, div.sKHbxTrans')) {
                    const t = (el.innerText || el.textContent || '').trim();
                    if (t.includes(last4)) {
                      const r = el.getBoundingClientRect();
                      if (r.width > 0 && r.height > 0)
                        return { left: r.left, top: r.top, width: r.width, height: r.height,
                                 tag: el.tagName, cls: el.className || '', source: 'fallback',
                                 acct_summary: isAcctSummary(el) };
                    }
                  }
                  return null;
                }
                """,
                last4,
            )
        except Exception:  # noqa: BLE001
            rect = None

        # Skip if this element belongs to the Account Summary read-only CC widget.
        # That widget's container IDs start with "segCreditCardsbox_" and clicking
        # its rows does nothing (the widget is display-only on Account Summary).
        if rect and rect.get("acct_summary"):
            logger.info(
                "ADCB: skipping Account Summary CC widget element (%s.%s) — not navigable",
                rect.get("tag", "?"), rect.get("cls", "")[:30],
            )
            rect = None

        if rect:
            cx = rect["left"] + rect["width"] / 2
            cy = rect["top"] + rect["height"] / 2
            logger.info(
                "ADCB: mouse-clicking card row (%s.%s source=%s) at (%.0f, %.0f)",
                rect.get("tag", "?"), rect.get("cls", "")[:30], rect.get("source", "?"), cx, cy,
            )
            try:
                page.mouse.click(cx, cy)
                if _wait_for_card_details_screen(page, timeout_ms=10000):
                    logger.info("ADCB: card details opened via pixel click at (%.0f, %.0f)", cx, cy)
                    return True
                # Log page text to diagnose what's there after click.
                try:
                    post_snap = text_snapshot(page).lower()[:600]
                    logger.info("ADCB: page text after card pixel click: %s", post_snap)
                except Exception:  # noqa: BLE001
                    pass
            except Exception:  # noqa: BLE001
                pass
            # Try double-click in case the SPA requires it.
            try:
                page.mouse.dblclick(cx, cy)
                if _wait_for_card_details_screen(page, timeout_ms=6000):
                    logger.info("ADCB: card details opened via pixel double-click")
                    return True
            except Exception:  # noqa: BLE001
                pass

    # --- Tertiary: broader element search (li / td / span / div cells) ---
    # ADCB renders credit card rows as <li class="seg2Normal"> items with nested
    # div cells.  The clickable element is the row li or the inner card-info cell.
    for last4 in last4_values:
        for selector in [
            f"li:has-text('{last4}')",
            f"td:has-text('{last4}')",
            f"span:has-text('{last4}')",
            f"div.kcell:has-text('{last4}')",
            f"div.sKHbxTrans:has-text('{last4}')",
        ]:
            locator = page.locator(selector)
            try:
                count = min(locator.count(), 5)
            except Exception:  # noqa: BLE001
                count = 0
            if count:
                logger.info("ADCB: '%s' found count=%s — trying force click", selector, count)
            for idx in range(count):
                item = locator.nth(idx)
                try:
                    item.scroll_into_view_if_needed(timeout=2000)
                    try:
                        item.click(timeout=3500)
                    except Exception:  # noqa: BLE001
                        item.click(timeout=3500, force=True)
                    logger.info("ADCB: clicked %s with last4=%s", selector, last4)
                    if _wait_for_card_details_screen(page, timeout_ms=6000):
                        return True
                except Exception:  # noqa: BLE001
                    continue

    # --- Tertiary: any link by card-number role ---
    card_pattern = re.compile(r"\d{4}[xX*\s]{4,}\d{2,4}", re.IGNORECASE)
    locator = page.get_by_role("link", name=card_pattern)
    try:
        count = min(locator.count(), 8)
    except Exception:  # noqa: BLE001
        count = 0
    if count:
        logger.info("ADCB: card link role-pattern found count=%s", count)
    for idx in range(count):
        item = locator.nth(idx)
        try:
            item.click(timeout=3500)
            logger.info("ADCB: clicked credit card link via role-pattern (idx=%s)", idx)
            if _wait_for_card_details_screen(page, timeout_ms=6000):
                return True
        except Exception:  # noqa: BLE001
            continue

    # --- Quaternary: JS-based approach using dispatchEvent (handles onclick-less TDs) ---
    try:
        result = page.evaluate(
            """
            ({ preferredLast4List }) => {
              const maskRe = /(\\d{4}[xX*\\s]{4,}\\d{2,4}|[xX*]{2,}\\s*\\d{2,4})/i;
              const allEls = Array.from(
                document.querySelectorAll('a,td,span,div,li,tr,[role="link"],[role="button"]')
              );
              const cardEls = allEls.filter(el => {
                const t = (el.innerText || el.textContent || '').trim();
                return (maskRe.test(t) || /\\d{4}[Xx*]{4,}\\d{2,4}/i.test(t)) && t.length < 120;
              });

              if (cardEls.length === 0) return { clicked: false, last4: '' };

              // Try preferred last4 first
              for (const last4 of preferredLast4List) {
                const match = cardEls.find(el => {
                  const t = (el.innerText || el.textContent || '').trim();
                  return t.endsWith(last4) || t.includes(last4);
                });
                if (match) {
                  // Walk up to find nearest clickable ancestor; otherwise dispatch on the node.
                  let cur = match;
                  while (cur && cur !== document.body) {
                    const tag = (cur.tagName || '').toLowerCase();
                    const role = (cur.getAttribute && cur.getAttribute('role')) || '';
                    const hasHandler = !!(
                      cur.getAttribute('onclick') ||
                      cur.getAttribute('ng-click') ||
                      cur.getAttribute('data-ng-click')
                    );
                    if (tag === 'a' || tag === 'button' || role === 'button' || role === 'link' || hasHandler) {
                      cur.click();
                      return { clicked: true, last4, element: tag };
                    }
                    cur = cur.parentElement;
                  }
                  // No clickable ancestor found — dispatch click on the node itself.
                  match.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
                  return { clicked: true, last4, element: (match.tagName || '').toLowerCase() };
                }
              }

              // Fallback: first card element found
              const first = cardEls[0];
              first.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
              const t = (first.innerText || first.textContent || '').trim();
              return { clicked: true, last4: t.slice(-4), element: (first.tagName || '').toLowerCase() };
            }
            """,
            {"preferredLast4List": last4_values},
        )
    except Exception:  # noqa: BLE001
        return False

    if not result or not result.get("clicked"):
        return False

    last4 = result.get("last4", "")
    element = result.get("element", "?")
    logger.info("ADCB: clicked credit card element (tag=%s, last4=%s) via JS dispatchEvent", element, last4)
    return _wait_for_card_details_screen(page, timeout_ms=6000)


def _wait_for_credit_cards_list_page(page: Any, logger: logging.Logger) -> bool:
    """Wait until the dedicated Credit Cards list page has loaded.

    This page is reached by clicking the sidebar "Credit Cards" → sub-item.
    It shows a list of masked card numbers (li.seg2Normal rows).  Returns True
    if the page is ready, False on timeout.
    """
    for tick in range(25):
        _dismiss_optional_ad_popup(page, logger)
        url = page.url.lower()
        low = text_snapshot(page).lower()
        has_masked = bool(MASKED_CARD_PATTERN.search(low))

        if _is_popup_blocking(page):
            page.wait_for_timeout(600)
            continue

        # Strong indicator: "click on credit card number" hint text.
        # NOTE: this text ALSO appears in the Account Summary CC widget (read-only).
        # Only accept it if segCreditCardsbox_* (Account Summary container) is absent.
        if "click on credit card number" in low:
            try:
                in_acct_summary = page.evaluate(
                    "() => !!document.querySelector('[id^=\"segCreditCardsbox_\"]')"
                )
            except Exception:  # noqa: BLE001
                in_acct_summary = False
            if not in_acct_summary:
                logger.info("ADCB: CC list page ready (hint text, not AcctSummary, tick=%d), url=%s", tick, page.url)
                return True
            logger.info("ADCB: 'click on credit card number' found but still on AcctSummary (tick=%d)", tick)

        # ADCB SPA keeps URL at #_frmLanding always.  Use content as indicator.
        # The CC Statement page shows masked cards + "credit card statement" heading
        # WITHOUT the "account summary" full text (account summary is in the sidebar
        # nav only, but the Account Summary *page* heading text would also contain it).
        # The critical distinction: on the CC Statement page the main content area
        # should show the word "statement" prominently combined with card rows.
        # NOTE: do NOT rely on li.seg2Normal alone — Account Summary widget has these too.
        if has_masked and "credit card statement" in low:
            logger.info("ADCB: CC list page ready (CC statement heading + masked card, tick=%d), url=%s", tick, page.url)
            return True

        # URL changed away from landing — masked card present → probably CC page.
        if "#_frmlanding" not in url and has_masked:
            logger.info("ADCB: CC list page ready (url changed, tick=%d), url=%s", tick, page.url)
            return True

        page.wait_for_timeout(600)

    logger.info("ADCB: CC list page wait timed out, url=%s", page.url)
    return False


def _get_sidebar_item_texts(page: Any) -> set:
    """Return the set of short text strings visible in the left sidebar (x < 250)."""
    try:
        items = page.evaluate(
            """
            () => {
              return [...document.querySelectorAll('a, li, div, span')]
                .filter(el => {
                  const r = el.getBoundingClientRect();
                  return r.left < 250 && r.width > 0 && r.height > 0;
                })
                .map(el => (el.innerText || el.textContent || '').trim()
                  .replace(/^[+\\-\\s]+/, '').trim().toLowerCase())
                .filter(t => t.length > 1 && t.length < 40);
            }
            """
        )
        return set(items)
    except Exception:  # noqa: BLE001
        return set()


def _navigate_via_sidebar_to_credit_cards(page: Any, logger: logging.Logger) -> bool:
    """Click the sidebar '+ Credit Cards' item, wait for sub-items, then click the best one."""

    # Step 1: Ensure popup is gone before touching the sidebar.
    # ADCB's SPA ignores sidebar nav clicks while a modal overlay is open.
    for _ in range(15):  # up to 7.5 s
        _dismiss_optional_ad_popup(page, logger)
        if not _is_popup_blocking(page):
            break
        page.wait_for_timeout(500)
    else:
        logger.info("ADCB: popup still blocking after 7.5 s — proceeding anyway")

    # Step 2: Snapshot sidebar items BEFORE clicking Credit Cards.
    before_items = _get_sidebar_item_texts(page)
    logger.info(
        "ADCB: sidebar before CC click (%d unique texts): %s",
        len(before_items), sorted(before_items),
    )

    # Step 3: Click "Credit Cards" (+ prefix) in sidebar.
    # Use real mouse coordinates so ADCB's SPA receives proper mouse events.
    try:
        rect = page.evaluate(
            """
            () => {
              const els = [...document.querySelectorAll('a, li, div, span')];
              const match = els.find(el => {
                const t = (el.innerText || el.textContent || '').trim()
                  .replace(/^[+\\-\\s]+/, '').trim();
                if (t.toLowerCase() !== 'credit cards') return false;
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0 && r.left < 250;
              });
              if (!match) return null;
              const r = match.getBoundingClientRect();
              return { left: r.left, top: r.top, width: r.width, height: r.height };
            }
            """
        )
    except Exception:  # noqa: BLE001
        rect = None

    if not rect:
        logger.info("ADCB: sidebar Credit Cards element not found")
        return False

    # Scroll the element into view before clicking (in case sidebar is long).
    # Also log the element's tag/class for diagnostics.
    try:
        scroll_info = page.evaluate(
            """
            () => {
              const match = [...document.querySelectorAll('a, li, div, span')].find(el => {
                const t = (el.innerText || el.textContent || '').trim()
                  .replace(/^[+\\-\\s]+/, '').trim();
                if (t.toLowerCase() !== 'credit cards') return false;
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0 && r.left < 250;
              });
              if (!match) return null;
              match.scrollIntoView({ block: 'center', behavior: 'instant' });
              return { tag: match.tagName, cls: (match.className || '').substring(0, 40),
                       txt: (match.innerText || match.textContent || '').trim().substring(0, 30) };
            }
            """
        )
        if scroll_info:
            logger.info("ADCB: Credit Cards sidebar element: %s", scroll_info)
        page.wait_for_timeout(300)
        # Re-fetch rect after scroll (position may have shifted).
        rect = page.evaluate(
            """
            () => {
              const els = [...document.querySelectorAll('a, li, div, span')];
              const match = els.find(el => {
                const t = (el.innerText || el.textContent || '').trim()
                  .replace(/^[+\\-\\s]+/, '').trim();
                if (t.toLowerCase() !== 'credit cards') return false;
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0 && r.left < 250;
              });
              if (!match) return null;
              const r = match.getBoundingClientRect();
              return { left: r.left, top: r.top, width: r.width, height: r.height };
            }
            """
        )
    except Exception:  # noqa: BLE001
        pass

    if not rect:
        logger.info("ADCB: sidebar Credit Cards element not found after scroll")
        return False

    # Click at the centre of the element using real mouse events.
    # Move to the element first (GWT uses mouseenter/mouseover for menu activation).
    cx = rect["left"] + rect["width"] / 2
    cy = rect["top"] + rect["height"] / 2
    try:
        page.mouse.move(cx, cy)
        page.wait_for_timeout(300)
        page.mouse.click(cx, cy)
        logger.info("ADCB: mouse-clicked Credit Cards in sidebar at (%.0f, %.0f)", cx, cy)
    except Exception:  # noqa: BLE001
        # Fall back to JS synthetic click.
        try:
            page.evaluate(
                """
                (pos) => {
                  const els = [...document.querySelectorAll('a, li, div, span')];
                  const match = els.find(el => {
                    const t = (el.innerText || el.textContent || '').trim()
                      .replace(/^[+\\-\\s]+/, '').trim();
                    if (t.toLowerCase() !== 'credit cards') return false;
                    const r = el.getBoundingClientRect();
                    return r.width > 0 && r.height > 0 && r.left < 250;
                  });
                  if (match) match.click();
                }
                """,
                {"cx": cx, "cy": cy},
            )
            logger.info("ADCB: JS-clicked Credit Cards fallback at (%.0f, %.0f)", cx, cy)
        except Exception:  # noqa: BLE001
            logger.info("ADCB: sidebar Credit Cards click failed entirely")
            return False

    # Step 3b: Immediately check whether the main content changed to CC Statement page.
    # ADCB's sidebar "Credit Cards" link may navigate directly (no accordion sub-items).
    # The Account Summary page has CC widgets with ID prefix "segCreditCardsbox_*".
    # The CC Statement page has DIFFERENT container IDs for the card rows.
    logger.info("ADCB: waiting 1500ms — sidebar Credit Cards clicked; giving content a moment to render")
    page.wait_for_timeout(1500)  # give content a moment to render
    try:
        on_cc_stmt_page = page.evaluate(
            """
            () => {
              // If Account Summary CC widget exists, we're on Account Summary (NOT CC Statement).
              const acctSummaryWidget = document.querySelector('[id^="segCreditCardsbox_"]');
              if (acctSummaryWidget) return false;
              // If li.seg2Normal exists (CC Statement card rows) without segCreditCardsbox, we're there.
              const ccRow = document.querySelector('li.seg2Normal');
              return !!ccRow;
            }
            """
        )
        if on_cc_stmt_page:
            logger.info("ADCB: CC Statement page already loaded after sidebar click (direct nav, no sub-items)")
            return True
    except Exception:  # noqa: BLE001
        pass

    # Step 4: Poll up to 10 s for NEW sidebar items that appeared after the click.
    # Sub-items are identified by text that:
    #   - Was NOT present before the click
    #   - Contains 'credit card' but is not exactly 'credit cards' or 'islamic credit cards'
    #   - Is short (< 40 chars)
    _KNOWN_TOP_LEVEL = {
        "credit cards", "islamic credit cards", "accounts", "loans",
        "islamic finance", "touchpoints", "fixed deposit",
        "term investment deposits", "investments", "bill payments",
        "money transfer", "uae direct debit", "insurance", "refer a friend",
        "other services", "service request", "account summary", "offers & updates",
    }
    _SUB_ITEM_PRIORITY = [
        "credit card statement",
        "card statement",
        "credit card detail",
        "credit card summary",
        "card detail",
        "card summary",
    ]

    best_sub_item_text: str | None = None
    for tick in range(20):  # 20 × 500ms = 10 s
        page.wait_for_timeout(500)
        after_items = _get_sidebar_item_texts(page)
        new_items = after_items - before_items - _KNOWN_TOP_LEVEL
        if new_items:
            logger.info("ADCB: new sidebar items after CC expand (tick=%d): %s", tick, sorted(new_items))
            # Pick the highest-priority sub-item.
            for keyword in _SUB_ITEM_PRIORITY:
                match = next((t for t in new_items if keyword in t), None)
                if match:
                    best_sub_item_text = match
                    break
            if best_sub_item_text:
                break

    if not best_sub_item_text:
        after_items_local = after_items if 'after_items' in dir() else set()
        logger.info(
            "ADCB: no CC sub-items after first 10 s; new items: %s — retrying click",
            sorted(after_items_local - before_items),
        )
        # Retry: click Credit Cards again (SPA may have ignored the first click
        # if the page was still settling).
        try:
            retry_rect = page.evaluate(
                """
                () => {
                  const match = [...document.querySelectorAll('a, li, div, span')].find(el => {
                    const t = (el.innerText || el.textContent || '').trim()
                      .replace(/^[+\\-\\s]+/, '').trim();
                    if (t.toLowerCase() !== 'credit cards') return false;
                    const r = el.getBoundingClientRect();
                    return r.width > 0 && r.height > 0 && r.left < 250;
                  });
                  if (!match) return null;
                  const r = match.getBoundingClientRect();
                  return { left: r.left, top: r.top, width: r.width, height: r.height };
                }
                """
            )
            if retry_rect:
                rcx = retry_rect["left"] + retry_rect["width"] / 2
                rcy = retry_rect["top"] + retry_rect["height"] / 2
                page.mouse.move(rcx, rcy)
                page.wait_for_timeout(400)
                page.mouse.click(rcx, rcy)
                logger.info("ADCB: retry-clicked Credit Cards in sidebar at (%.0f, %.0f)", rcx, rcy)
        except Exception:  # noqa: BLE001
            pass

        # Poll another 10 s for sub-items after the retry click.
        retry_before = after_items_local
        for tick in range(20):
            page.wait_for_timeout(500)
            after_items = _get_sidebar_item_texts(page)
            new_items = after_items - retry_before - _KNOWN_TOP_LEVEL
            if new_items:
                logger.info("ADCB: new sidebar items after CC retry (tick=%d): %s", tick, sorted(new_items))
                for keyword in _SUB_ITEM_PRIORITY:
                    match = next((t for t in new_items if keyword in t), None)
                    if match:
                        best_sub_item_text = match
                        break
                if best_sub_item_text:
                    break

    if not best_sub_item_text:
        logger.info("ADCB: no CC sub-items appeared even after retry; giving up")
        return False

    # Step 5: Click the identified sub-item using REAL mouse events.
    # JS el.click() does not reliably trigger ADCB's GWT SPA handlers — use
    # page.mouse.click() at the element's pixel coordinates instead.
    try:
        sub_rect = page.evaluate(
            """
            (targetText) => {
              const els = [...document.querySelectorAll('a, div, span, li')];
              for (const el of els) {
                const t = (el.innerText || el.textContent || '').trim().toLowerCase()
                  .replace(/^[+\\-\\s]+/, '').trim();
                if (t !== targetText) continue;
                const r = el.getBoundingClientRect();
                if (r.left < 250 && r.width > 0 && r.height > 0)
                  return { left: r.left, top: r.top, width: r.width, height: r.height };
              }
              return null;
            }
            """,
            best_sub_item_text,
        )
    except Exception:  # noqa: BLE001
        sub_rect = None

    if sub_rect:
        sub_cx = sub_rect["left"] + sub_rect["width"] / 2
        sub_cy = sub_rect["top"] + sub_rect["height"] / 2
        try:
            page.mouse.click(sub_cx, sub_cy)
            logger.info(
                "ADCB: mouse-clicked CC sub-item: '%s' at (%.0f, %.0f), url=%s",
                best_sub_item_text, sub_cx, sub_cy, page.url,
            )
            logger.info("ADCB: waiting 2000ms — CC sub-item mouse-clicked; waiting for page to update")
            page.wait_for_timeout(2000)
            logger.info("ADCB: after sub-item click, url=%s", page.url)
            return True
        except Exception:  # noqa: BLE001
            pass

    # Fallback: JS synthetic click (may not fire GWT handlers but worth trying).
    try:
        sub_clicked = page.evaluate(
            """
            (targetText) => {
              for (const el of document.querySelectorAll('a, div, span, li')) {
                const t = (el.innerText || el.textContent || '').trim().toLowerCase()
                  .replace(/^[+\\-\\s]+/, '').trim();
                if (t !== targetText) continue;
                const r = el.getBoundingClientRect();
                if (r.left < 250 && r.width > 0 && r.height > 0) {
                  el.click();
                  return t;
                }
              }
              return null;
            }
            """,
            best_sub_item_text,
        )
        if sub_clicked:
            logger.info("ADCB: waiting 2000ms — CC sub-item JS-clicked; waiting for page to update")
            page.wait_for_timeout(2000)
            logger.info("ADCB: JS-clicked CC sub-item: '%s' (fallback), url=%s", sub_clicked, page.url)
            return True
    except Exception:  # noqa: BLE001
        pass

    logger.info("ADCB: could not click CC sub-item '%s'", best_sub_item_text)
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

    # --- Stage 1: Navigate to the dedicated Credit Cards list page via sidebar.
    # The Account Summary landing page shows a read-only CC summary widget;
    # clicking card rows there does NOT navigate to statement details.
    # The correct path is: sidebar "Credit Cards" → CC list (Image 1) → click card.
    _navigate_via_sidebar_to_credit_cards(page, logger)
    cc_page_ready = _wait_for_credit_cards_list_page(page, logger)
    logger.info("ADCB: CC list page ready=%s, url=%s", cc_page_ready, page.url)

    # Give the CC list content a moment to finish rendering before we click.
    if cc_page_ready:
        logger.info("ADCB: waiting 1500ms — CC list page ready; allowing content to finish rendering")
        page.wait_for_timeout(1500)

    # Diagnostic: log whether we're on Account Summary or CC Statement page.
    try:
        page_info = page.evaluate(
            """
            () => {
              const inAcctSummary = !!document.querySelector('[id^="segCreditCardsbox_"]');
              const ccRows = document.querySelectorAll('li.seg2Normal').length;
              const clickHint = document.body.innerText.includes('click on credit card number') ||
                                document.body.innerText.toLowerCase().includes('click on credit card number');
              return { inAcctSummary, ccRows, clickHint };
            }
            """
        )
        logger.info("ADCB: page diagnosis before card click loop: %s", page_info)
        in_acct_summary = page_info.get("inAcctSummary", True)
    except Exception:  # noqa: BLE001
        in_acct_summary = True

    # If still on Account Summary, sidebar navigation didn't work.
    # Retry sidebar navigation up to 2 more times before giving up.
    if in_acct_summary:
        logger.info("ADCB: still on Account Summary after initial sidebar nav — retrying navigation")
        for nav_retry in range(2):
            logger.info("ADCB: waiting 2000ms — still on Account Summary; pausing before sidebar nav retry %d/2", nav_retry + 1)
            page.wait_for_timeout(2000)
            _navigate_via_sidebar_to_credit_cards(page, logger)
            cc_page_ready = _wait_for_credit_cards_list_page(page, logger)
            try:
                in_acct_summary = page.evaluate(
                    "() => !!document.querySelector('[id^=\"segCreditCardsbox_\"]')"
                )
            except Exception:  # noqa: BLE001
                in_acct_summary = True
            logger.info(
                "ADCB: nav retry #%d: cc_page_ready=%s, inAcctSummary=%s",
                nav_retry + 1, cc_page_ready, in_acct_summary,
            )
            if not in_acct_summary:
                break
        if in_acct_summary:
            logger.info("ADCB: still on Account Summary after all sidebar retries — card click will likely fail")

    # --- Stage 2: Click the specific card from whatever page we're on.
    for attempt in range(7):
        _dismiss_optional_ad_popup(page, logger)

        if _is_card_details_screen(page):
            return True

        # Primary: click by last4 from the current CC list page
        if _click_card_link_in_landing_table(page, logger, bank_cfg):
            return True
        # Secondary: match by credit limit amount
        if _click_card_by_limit(page, logger, target_limit_aed):
            return True
        # Tertiary: generic card-pattern fallback scan
        if _click_card_tile_fallback(page, logger):
            return True

        # Re-navigate via sidebar every other attempt
        if attempt % 2 == 1:
            _navigate_via_sidebar_to_credit_cards(page, logger)
            _wait_for_credit_cards_list_page(page, logger)

        try:
            page.mouse.wheel(0, 200)
        except Exception:  # noqa: BLE001
            pass
        page.wait_for_timeout(500)

    return _is_card_details_screen(page)


def _logout_adcb(page: Any, logger: logging.Logger) -> None:
    """Attempt to log out of ADCB so the server-side session is terminated.

    This prevents the concurrent-session gate from appearing on the next run.
    """
    try:
        logout_selectors = [
            "a:has-text('Logout')",
            "a:has-text('Log Out')",
            "a:has-text('Log out')",
            "button:has-text('Logout')",
            "button:has-text('Log Out')",
            "[role='button']:has-text('Logout')",
            "[role='button']:has-text('Log Out')",
        ]
        for selector in logout_selectors:
            try:
                el = page.locator(selector).first
                if el.is_visible(timeout=800):
                    el.click(timeout=2000)
                    logger.info("ADCB: waiting 1500ms — logout button clicked; allowing session termination")
                    page.wait_for_timeout(1500)
                    logger.info("ADCB: clicked logout button (%s)", selector)
                    return
            except Exception:  # noqa: BLE001
                continue
        # Fallback: navigate directly to the ADCB logout hash URL.
        page.goto(
            "https://online.adcb.com/apps/ADCBIB/#_frmLogout",
            wait_until="domcontentloaded",
            timeout=10000,
        )
        logger.info("ADCB: waiting 1000ms — logout URL navigation; allowing server session to terminate")
        page.wait_for_timeout(1000)
        logger.info("ADCB: navigated to logout URL to terminate server session")
    except Exception:  # noqa: BLE001
        logger.info("ADCB: logout attempt failed (non-fatal)")


def download_latest_statement(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    bank_cfg: dict,
) -> int:
    try:
        return _download_latest_statement_impl(page, incoming_dir, logger, bank_cfg)
    finally:
        # Always log out after the download attempt so the server-side session is
        # terminated.  Without this, the next run hits the concurrent-session gate
        # which triggers OTP rate-limiting and cascading re-login failures.
        _logout_adcb(page, logger)


def _download_latest_statement_impl(
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

    # Concurrent session gate — dismiss it and record the time so we can
    # immediately re-login without the 45-second OTP delay.
    if handle_concurrent_session_gate(page, logger, low_text):
        extra["gate_dismissed_unix"] = time.time()
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

    # Timeout / logout screen — treat as unauthenticated, stop retrying.
    low = low_text.lower()
    if ("timed out" in low and "inactivity" in low) or "#_frmlogout" in page.url.lower():
        logger.info("ADCB: session timed out / logged out — cannot recover")
        return AuthPollAction.CONTINUE

    # Immediate re-login after gate dismissal.
    # The gate click terminates the old server-side session.  KEEP browser cookies
    # so ADCB can recognise the device and send OTPs without rate-limiting.
    # Only clear sessionStorage/localStorage (in-page state), NOT cookies.
    gate_dismissed = extra.get("gate_dismissed_unix")
    gate_relogin_count = extra.get("gate_relogin_count", 0)
    if (
        is_login_screen(low_text)
        and gate_dismissed is not None
        and time.time() - gate_dismissed >= 5  # give ADCB 5 s to terminate the old session
        and gate_relogin_count < 5  # allow up to 5 gate-triggered re-logins
    ):
        extra.pop("gate_dismissed_unix", None)
        extra["gate_relogin_count"] = gate_relogin_count + 1
        # Clear in-page state (sessionStorage, localStorage) but KEEP cookies.
        # Clearing cookies removes device-recognition tokens which causes ADCB to
        # rate-limit OTP delivery on the subsequent login.
        try:
            page.evaluate(
                "() => { try { sessionStorage.clear(); } catch(_) {} "
                "try { localStorage.clear(); } catch(_) {} }"
            )
            logger.info("ADCB: cleared page storage before gate re-login (cookies kept)")
        except Exception:  # noqa: BLE001
            pass
        portal = state.portal_url or "https://online.adcb.com/apps/ADCBIB/#_frmLogin"
        try:
            page.goto(portal, wait_until="domcontentloaded", timeout=30000)
            logger.info("ADCB: waiting 1500ms — portal navigation after gate dismissal; allowing login page to render")
            page.wait_for_timeout(1500)
        except Exception:  # noqa: BLE001
            pass
        logger.info(
            "ADCB: re-logging in after gate dismissal "
            "(gate attempt %d/5, waited 5 s, cookies kept)",
            gate_relogin_count + 1,
        )
        return AuthPollAction.RETRY_LOGIN

    # Standard re-login after OTP challenge with no subsequent gate dismissal.
    # Use a longer gap when we previously dismissed a concurrent-session gate,
    # because ADCB rate-limits OTP delivery after the gate flow.  Normal timeout
    # is 45 s; after a gate dismissal give 120 s so the delayed OTP can arrive.
    # Skip if gate_dismissed_unix is set — that path is handled above.
    _relogin_threshold = 200 if extra.get("gate_relogin_count", 0) > 0 else 45
    if (
        is_login_screen(low_text)
        and extra.get("had_challenge")
        and extra.get("gate_dismissed_unix") is None
        and state.relogin_attempts < 3
        and time.time() - state.last_login_attempt_unix >= _relogin_threshold
    ):
        # Clear session cookies/storage BEFORE re-login so the SPA renders a
        # fresh login form (stale cookies from a previous OTP flow can cause
        # silent form-submission failures).
        try:
            page.context.clear_cookies()
            page.evaluate(
                "() => { try { localStorage.clear(); } catch(_) {} "
                "try { sessionStorage.clear(); } catch(_) {} }"
            )
            logger.info("ADCB: cleared stale session before re-login")
        except Exception:  # noqa: BLE001
            pass
        portal = state.portal_url or "https://online.adcb.com/apps/ADCBIB/#_frmLogin"
        try:
            page.goto(portal, wait_until="domcontentloaded", timeout=30000)
            logger.info("ADCB: waiting 2500ms — portal navigation after OTP challenge; allowing login page to render")
            page.wait_for_timeout(2500)
        except Exception:  # noqa: BLE001
            pass
        logger.info("ADCB: returned to login after challenge; retrying login")
        return AuthPollAction.RETRY_LOGIN

    return AuthPollAction.CONTINUE


def _browser_launch_overrides() -> dict:
    """Return ADCB-specific browser launch overrides.

    Fills in the fingerprint gaps that bot-detectors commonly probe after
    ``--disable-blink-features=AutomationControlled`` removes ``webdriver``:
    - A fuller ``window.chrome`` object (``app``, ``csi``, ``loadTimes``)
    - Realistic ``hardwareConcurrency`` and ``deviceMemory``
    """
    init_script = """
    (() => {
      // --- window.chrome (fuller object) ------------------------------------
      try {
        const chrome = window.chrome || {};
        if (!chrome.app) {
          chrome.app = {
            isInstalled: false,
            InstallState: {
              DISABLED: 'disabled',
              INSTALLED: 'installed',
              NOT_INSTALLED: 'not_installed',
            },
            RunningState: {
              CANNOT_RUN: 'cannot_run',
              READY_TO_RUN: 'ready_to_run',
              RUNNING: 'running',
            },
            getDetails: function() { return null; },
            getIsInstalled: function() { return false; },
            installState: function() { return 'not_installed'; },
            runningState: function() { return 'cannot_run'; },
          };
        }
        if (!chrome.csi) {
          chrome.csi = function() {
            return {
              startE:  Date.now(),
              onloadT: Date.now() + 300,
              pageT:   2000,
              tran:    15,
            };
          };
        }
        if (!chrome.loadTimes) {
          chrome.loadTimes = function() {
            return {
              requestTime:             performance.timeOrigin / 1000,
              startLoadTime:           performance.timeOrigin / 1000,
              commitLoadTime:          (performance.timeOrigin + 50) / 1000,
              finishDocumentLoadTime:  (performance.timeOrigin + 200) / 1000,
              finishLoadTime:          (performance.timeOrigin + 300) / 1000,
              firstPaintTime:          (performance.timeOrigin + 150) / 1000,
              firstPaintAfterLoadTime: 0,
              navigationType:          'Other',
              wasFetchedViaSpdy:       false,
              wasNpnNegotiated:        false,
              npnNegotiatedProtocol:   'unknown',
              wasAlternateProtocolAvailable: false,
              connectionInfo:          'unknown',
            };
          };
        }
        window.chrome = chrome;
      } catch (_) {}

      // --- hardware concurrency / device memory ----------------------------
      try {
        Object.defineProperty(navigator, 'hardwareConcurrency', {
          get: function() { return 8; },
        });
      } catch (_) {}
      try {
        Object.defineProperty(navigator, 'deviceMemory', {
          get: function() { return 8; },
        });
      } catch (_) {}
    })();
    """
    return {"init_scripts": [init_script]}


ADAPTER = BankAdapter(
    code="ADCB",
    login=login,
    login_selector_visible=login_selector_visible,
    download_latest_statement=download_latest_statement,
    is_authenticated_session=is_authenticated_session,
    is_login_screen=is_login_screen,
    on_auth_poll_tick=_on_auth_poll_tick,
    browser_launch_overrides=_browser_launch_overrides,
    skip_mfa_user_prompt=True,
    skip_keyword_fallback=True,
)

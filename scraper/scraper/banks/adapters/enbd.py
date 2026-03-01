from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any

from scraper.banks.shared import attempt_download_capture, require_env, save_download, text_snapshot
from scraper.banks.month_utils import MONTH_INDEX


def login(page: Any, logger: logging.Logger, credentials: dict[str, str] | None = None) -> None:
    username = require_env("ENBD_USERNAME", credentials)
    password = require_env("ENBD_PASSWORD", credentials)

    page.fill("input#userName", username)
    page.fill("input#password", password)
    page.click("button[aria-label='Login']")
    logger.info("ENBD: login submitted")


def login_selector_visible(page: Any) -> bool:
    return page.locator("input#userName").first.is_visible()


def _dismiss_overlays(page: Any, logger: logging.Logger) -> None:
    for _ in range(5):
        dismissed_any = False

        backdrop = page.locator(".cdk-overlay-backdrop.cdk-overlay-backdrop-showing")
        try:
            count = min(backdrop.count(), 3)
        except Exception:  # noqa: BLE001
            count = 0

        for idx in range(count):
            item = backdrop.nth(idx)
            try:
                if not item.is_visible():
                    continue
                try:
                    item.click(timeout=1200)
                except Exception:  # noqa: BLE001
                    page.keyboard.press("Escape")
                page.wait_for_timeout(500)
                dismissed_any = True
                logger.info("ENBD: dismissed overlay backdrop")
                break
            except Exception:  # noqa: BLE001
                continue

        for selector in [
            "button[aria-label='Close']",
            "button:has-text('Close')",
            "button:has-text('Dismiss')",
            "button:has-text('Skip')",
            "button:has-text('Not now')",
            "[role='button'][aria-label='Close']",
            ".cdk-overlay-container button",
        ]:
            locator = page.locator(selector)
            try:
                count = min(locator.count(), 4)
            except Exception:  # noqa: BLE001
                count = 0

            for idx in range(count):
                item = locator.nth(idx)
                try:
                    if not item.is_visible():
                        continue
                    item.click(timeout=1200)
                    page.wait_for_timeout(450)
                    dismissed_any = True
                    logger.info("ENBD: clicked overlay close control via %s", selector)
                    break
                except Exception:  # noqa: BLE001
                    continue
            if dismissed_any:
                break

        if not dismissed_any:
            return


def _wait_for_dashboard_ready(page: Any, logger: logging.Logger) -> None:
    for _ in range(20):
        _dismiss_overlays(page, logger)
        low = text_snapshot(page).lower()
        if "quick actions" in low and "recent transactions" in low:
            return
        page.wait_for_timeout(700)


def _is_cards_detail(page: Any) -> bool:
    if "/cards-detail" in page.url.lower():
        return True
    low = text_snapshot(page).lower()
    return "statements" in low and "transactions" in low and "cards" in low


def _click_cards_tile(page: Any, logger: logging.Logger) -> bool:
    selectors = [
        ".dashboard-card-container",
        ".dashboard-content-wrapper",
        ".card-header-section",
        "div.card-heading[aria-label='Cards']",
        "div[aria-label='Cards']",
        "text=CARDS",
    ]

    for _ in range(6):
        _dismiss_overlays(page, logger)

        # If we navigated away from the dashboard (e.g. accidentally clicked Accounts
        # or Loan tile), go back before retrying.
        if not _is_cards_detail(page):
            has_tiles = False
            try:
                has_tiles = page.locator(".dashboard-card-container").count() > 0
            except Exception:  # noqa: BLE001
                pass
            if not has_tiles:
                try:
                    page.go_back(timeout=4000)
                    page.wait_for_timeout(1500)
                    _dismiss_overlays(page, logger)
                    logger.info("ENBD: navigated back after landing on wrong tile page")
                except Exception:  # noqa: BLE001
                    pass

        # Try JS evaluator first: specifically target a tile whose heading says "Cards"
        # (avoids clicking Accounts or Loan tiles when multiple tiles exist on the dashboard).
        try:
            clicked = page.evaluate(
                """
                () => {
                  const isVisible = (el) => {
                    const cs = getComputedStyle(el);
                    const r = el.getBoundingClientRect();
                    return cs.visibility !== 'hidden' && cs.display !== 'none' && r.width > 0 && r.height > 0;
                  };
                  const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                  const tiles = Array.from(document.querySelectorAll(
                    '.dashboard-card-container, [class*="card-container"]'
                  ));
                  for (const tile of tiles) {
                    if (!isVisible(tile)) continue;
                    // Check aria-label on the tile itself
                    const tileLabel = norm(tile.getAttribute('aria-label') || '');
                    if (tileLabel === 'cards') { tile.click(); return true; }
                    // Check heading/label children
                    const headings = Array.from(tile.querySelectorAll(
                      'h1, h2, h3, h4, [class*="heading"], [class*="title"], [class*="label"]'
                    ));
                    for (const h of headings) {
                      if (!isVisible(h)) continue;
                      const txt = norm(h.innerText || h.textContent || '');
                      if (txt === 'cards') { tile.click(); return true; }
                    }
                  }
                  return false;
                }
                """
            )
            if clicked:
                page.wait_for_timeout(2200)
                logger.info("ENBD: clicked Cards tile via JS heading evaluator")
                if _is_cards_detail(page):
                    return True
        except Exception:  # noqa: BLE001
            pass

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
                    try:
                        item.click(timeout=2500)
                    except Exception:  # noqa: BLE001
                        item.click(timeout=2500, force=True)
                    page.wait_for_timeout(2200)
                    logger.info("ENBD: clicked cards entry via %s", selector)
                    if _is_cards_detail(page):
                        return True
                except Exception:  # noqa: BLE001
                    continue

        page.mouse.wheel(0, 350)
        page.wait_for_timeout(600)

    return _is_cards_detail(page)


def _open_statements_view(page: Any, logger: logging.Logger) -> bool:
    for _ in range(10):
        _dismiss_overlays(page, logger)

        # Strictly click "View All" in the Statements section only.
        try:
            clicked = page.evaluate(
                """
                () => {
                  const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                  const isVisible = (el) => {
                    const cs = getComputedStyle(el);
                    const r = el.getBoundingClientRect();
                    return cs.visibility !== 'hidden' && cs.display !== 'none' && r.width > 0 && r.height > 0;
                  };
                  const sections = Array.from(document.querySelectorAll('section,div,mat-card,app-card,article'));
                  for (const section of sections) {
                    if (!isVisible(section)) continue;
                    const st = norm(section.innerText || section.textContent || '');
                    if (!st.includes('statement')) continue;
                    if (st.includes('recent transactions')) continue;

                    const nodes = Array.from(section.querySelectorAll('button, a, [role="button"], div, span'));
                    for (const node of nodes) {
                      if (!isVisible(node)) continue;
                      const t = norm(node.innerText || node.textContent || node.value || '');
                      if (!(t === 'view all' || t.startsWith('view all '))) continue;

                      let cur = node;
                      while (cur && cur !== document.body) {
                        const tag = (cur.tagName || '').toLowerCase();
                        const role = (cur.getAttribute && cur.getAttribute('role')) || '';
                        if ((tag === 'button' || tag === 'a' || role === 'button') && isVisible(cur)) {
                          cur.click();
                          return true;
                        }
                        cur = cur.parentElement;
                      }

                      node.click();
                      return true;
                    }
                  }
                  return false;
                }
                """
            )
            if clicked:
                page.wait_for_timeout(1800)
                if _is_statements_download_page(page):
                    logger.info("ENBD: clicked Statements -> View All")
                    return True
                logger.info("ENBD: clicked Statements -> View All but download controls not ready yet")
        except Exception:  # noqa: BLE001
            pass

        page.mouse.wheel(0, 650)
        page.wait_for_timeout(700)

    return _is_statements_download_page(page)


def _extract_select_options(select_element: Any) -> list[dict[str, Any]]:
    try:
        return select_element.evaluate(
            """
            (el) => Array.from(el.options).map((opt) => ({
              text: (opt.textContent || '').trim(),
              value: opt.value || '',
              disabled: !!opt.disabled
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
    if year_match:
        return int(year_match.group(0)) * 100 + (month_val or 0)
    return month_val


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
            "ENBD: target %s option score=%s not found in native select",
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
            "ENBD: selected %s option %s (target_score=%s)",
            mode,
            chosen.get("text", ""),
            target_score,
        )
        return True
    except Exception:  # noqa: BLE001
        return False


def _native_select_contains_target(select_element: Any, mode: str, target_score: int | None) -> bool:
    if target_score is None:
        return True
    options = _extract_select_options(select_element)
    for opt in options:
        text = (opt.get("text") or opt.get("value") or "").strip()
        low = text.lower()
        if opt.get("disabled"):
            continue
        if not text:
            continue
        if any(token in low for token in ["select", "choose", "please"]):
            continue
        score = _score_option_text(text, mode)
        if score == target_score:
            return True
    return False


def _native_select_group_contains_target(selects: list[Any], mode: str, target_score: int | None) -> bool:
    if target_score is None:
        return True
    if not selects:
        return False
    for select in selects:
        if _native_select_contains_target(select, mode, target_score):
            return True
    return False


def _visible_native_selects_by_mode(page: Any) -> tuple[list[Any], list[Any], list[Any]]:
    selects = page.locator("select")
    try:
        count = min(selects.count(), 8)
    except Exception:  # noqa: BLE001
        count = 0

    classified: list[tuple[Any, str]] = []
    for idx in range(count):
        select = selects.nth(idx)
        try:
            if not select.is_visible():
                continue
        except Exception:  # noqa: BLE001
            continue
        mode = _classify_native_select_mode(select)
        if not mode:
            continue
        classified.append((select, mode))

    year_selects = [select for select, mode in classified if mode == "year"]
    month_selects = [select for select, mode in classified if mode == "month"]
    combined_selects = [select for select, mode in classified if mode == "combined"]
    return year_selects, month_selects, combined_selects


def _target_period_not_present_in_native_controls(page: Any, target_year: int, target_month: int) -> bool:
    year_selects, month_selects, combined_selects = _visible_native_selects_by_mode(page)
    target_combined = target_year * 100 + target_month

    # Explicit year+month controls: missing year means requested period cannot be selected.
    if year_selects and month_selects:
        if not _native_select_group_contains_target(year_selects, "year", target_year):
            return True
        return False

    # Combined month-year controls: missing exact period means unavailable.
    if combined_selects:
        if not _native_select_group_contains_target(combined_selects, "combined", target_combined):
            return True

    return False


def _select_from_material_dropdown(
    page: Any,
    label: str,
    mode: str,
    logger: logging.Logger,
    *,
    target_score: int | None = None,
    strict_target: bool = False,
) -> bool:
    container = page.locator(f".form-element-container:has(label:has-text('{label}'))")
    if container.count() == 0:
        return False

    trigger_selectors = [
        ".mat-select-trigger",
        ".mat-form-field-flex",
        ".mat-form-field-infix",
    ]

    opened = False
    for selector in trigger_selectors:
        locator = container.locator(selector)
        try:
            count = min(locator.count(), 4)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                item.click(timeout=2500)
                page.wait_for_timeout(600)
                opened = True
                break
            except Exception:  # noqa: BLE001
                continue
        if opened:
            break

    if not opened:
        return False

    options_locator = page.locator(".cdk-overlay-container [role='option'], .cdk-overlay-container mat-option")
    try:
        option_count = min(options_locator.count(), 80)
    except Exception:  # noqa: BLE001
        option_count = 0

    candidates: list[tuple[int, int, str]] = []
    for idx in range(option_count):
        item = options_locator.nth(idx)
        try:
            if not item.is_visible():
                continue
            text = (item.inner_text() or "").strip()
            if not text:
                continue
            score = _score_option_text(text, mode)
            if score is None:
                continue
            candidates.append((score, idx, text))
        except Exception:  # noqa: BLE001
            continue

    if not candidates:
        page.keyboard.press("Escape")
        return False

    chosen_idx = None
    option_text = ""
    if target_score is not None:
        for score, idx, text in candidates:
            if score == target_score:
                chosen_idx = idx
                option_text = text
                break

    if chosen_idx is None and strict_target and target_score is not None:
        page.keyboard.press("Escape")
        logger.info(
            "ENBD: target %s option score=%s not found in material dropdown",
            mode,
            target_score,
        )
        return False

    if chosen_idx is None:
        candidates.sort(key=lambda x: x[0], reverse=True)
        _, chosen_idx, option_text = candidates[0]

    try:
        options_locator.nth(chosen_idx).click(timeout=2500)
        page.wait_for_timeout(500)
        logger.info(
            "ENBD: selected %s option %s (target_score=%s)",
            mode,
            option_text,
            target_score,
        )
        return True
    except Exception:  # noqa: BLE001
        page.keyboard.press("Escape")
        return False


def _has_material_dropdown_label(page: Any, label: str) -> bool:
    try:
        return page.locator(f".form-element-container:has(label:has-text('{label}'))").count() > 0
    except Exception:  # noqa: BLE001
        return False


def _collect_material_dropdown_scores(page: Any, label: str, mode: str) -> set[int] | None:
    container = page.locator(f".form-element-container:has(label:has-text('{label}'))")
    if container.count() == 0:
        return None

    trigger_selectors = [
        ".mat-select-trigger",
        ".mat-form-field-flex",
        ".mat-form-field-infix",
    ]

    opened = False
    for selector in trigger_selectors:
        locator = container.locator(selector)
        try:
            count = min(locator.count(), 4)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                item.click(timeout=2500)
                page.wait_for_timeout(450)
                opened = True
                break
            except Exception:  # noqa: BLE001
                continue
        if opened:
            break

    if not opened:
        return None

    options = page.locator(".cdk-overlay-container [role='option'], .cdk-overlay-container mat-option")
    try:
        option_count = min(options.count(), 120)
    except Exception:  # noqa: BLE001
        option_count = 0

    scores: set[int] = set()
    for idx in range(option_count):
        option = options.nth(idx)
        try:
            if not option.is_visible():
                continue
            text = (option.inner_text() or "").strip()
            if not text:
                continue
            score = _score_option_text(text, mode)
            if score is not None:
                scores.add(score)
        except Exception:  # noqa: BLE001
            continue

    try:
        page.keyboard.press("Escape")
    except Exception:  # noqa: BLE001
        pass
    page.wait_for_timeout(180)
    return scores


def _material_dropdown_contains_target(page: Any, label: str, mode: str, target_score: int | None) -> bool | None:
    if target_score is None:
        return True
    scores = _collect_material_dropdown_scores(page, label, mode)
    if scores is None:
        return None
    return target_score in scores


def _target_period_not_present_in_material_controls(
    page: Any,
    logger: logging.Logger,
    target_year: int,
    target_month: int,
) -> bool:
    has_year_label = _has_material_dropdown_label(page, "Year")
    has_month_label = _has_material_dropdown_label(page, "Month")
    if not has_year_label and not has_month_label:
        return False

    if has_year_label:
        year_present = _material_dropdown_contains_target(page, "Year", "year", target_year)
        if year_present is False:
            logger.info("ENBD: requested year %s not present in material year dropdown options", target_year)
            return True
        if year_present is True:
            # Pick year once so ENBD can refresh month options for that specific year.
            if _select_from_material_dropdown(
                page,
                "Year",
                "year",
                logger,
                target_score=target_year,
                strict_target=True,
            ):
                page.wait_for_timeout(420)

    if has_month_label:
        month_present = _material_dropdown_contains_target(page, "Month", "month", target_month)
        if month_present is False:
            logger.info(
                "ENBD: requested month %s not present in material month dropdown options for year %s",
                target_month,
                target_year,
            )
            return True

    return False


def _select_from_any_material_dropdown(
    page: Any,
    mode: str,
    logger: logging.Logger,
    *,
    target_score: int | None = None,
    strict_target: bool = False,
) -> bool:
    trigger_selectors = [
        ".form-element-container .mat-select-trigger",
        ".mat-form-field .mat-select-trigger",
        ".mat-select-trigger",
        "mat-select",
        "[role='combobox']",
    ]
    option_locator = ".cdk-overlay-container [role='option'], .cdk-overlay-container mat-option"

    for selector in trigger_selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 8)
        except Exception:  # noqa: BLE001
            count = 0

        for idx in range(count):
            trigger = locator.nth(idx)
            try:
                if not trigger.is_visible():
                    continue
                trigger.click(timeout=2500)
                page.wait_for_timeout(550)
            except Exception:  # noqa: BLE001
                continue

            options = page.locator(option_locator)
            try:
                option_count = min(options.count(), 120)
            except Exception:  # noqa: BLE001
                option_count = 0

            candidates: list[tuple[int, int, str]] = []
            for opt_idx in range(option_count):
                item = options.nth(opt_idx)
                try:
                    if not item.is_visible():
                        continue
                    text = (item.inner_text() or "").strip()
                    if not text:
                        continue
                    score = _score_option_text(text, mode)
                    if score is None:
                        continue
                    candidates.append((score, opt_idx, text))
                except Exception:  # noqa: BLE001
                    continue

            if not candidates:
                page.keyboard.press("Escape")
                page.wait_for_timeout(200)
                continue

            chosen_idx = None
            chosen_text = ""

            if target_score is not None:
                for score, opt_idx, text in candidates:
                    if score == target_score:
                        chosen_idx = opt_idx
                        chosen_text = text
                        break

            if chosen_idx is None and strict_target and target_score is not None:
                page.keyboard.press("Escape")
                page.wait_for_timeout(220)
                continue

            if chosen_idx is None:
                candidates.sort(key=lambda x: x[0], reverse=True)
                _, chosen_idx, chosen_text = candidates[0]

            try:
                options.nth(chosen_idx).click(timeout=2500)
                page.wait_for_timeout(500)
                logger.info(
                    "ENBD: selected %s option %s via generic material dropdown (selector=%s)",
                    mode,
                    chosen_text,
                    selector,
                )
                return True
            except Exception:  # noqa: BLE001
                page.keyboard.press("Escape")
                page.wait_for_timeout(220)
                continue

    return False


def _log_period_selection_snapshot(page: Any, logger: logging.Logger) -> None:
    try:
        native_snapshot = page.evaluate(
            """
            () => {
              const out = [];
              const selects = Array.from(document.querySelectorAll('select'));
              for (const sel of selects) {
                const cs = getComputedStyle(sel);
                const rect = sel.getBoundingClientRect();
                const visible = cs.visibility !== 'hidden' && cs.display !== 'none' && rect.width > 0 && rect.height > 0;
                if (!visible) continue;
                const options = Array.from(sel.options || []).slice(0, 12).map((opt) => (opt.textContent || '').trim());
                out.push({ id: sel.id || '', name: sel.name || '', options });
                if (out.length >= 6) break;
              }
              return out;
            }
            """
        )
    except Exception:  # noqa: BLE001
        native_snapshot = []

    try:
        material_snapshot = page.evaluate(
            """
            () => {
              const out = [];
              const triggers = Array.from(
                document.querySelectorAll('.mat-select-trigger, [role="combobox"], mat-select')
              );
              const seen = new Set();
              for (const el of triggers) {
                const cs = getComputedStyle(el);
                const rect = el.getBoundingClientRect();
                const visible = cs.visibility !== 'hidden' && cs.display !== 'none' && rect.width > 0 && rect.height > 0;
                if (!visible) continue;
                const txt = ((el.innerText || el.textContent || '') + '').replace(/\\s+/g, ' ').trim();
                if (!txt || seen.has(txt)) continue;
                seen.add(txt);
                out.push(txt.slice(0, 120));
                if (out.length >= 10) break;
              }
              return out;
            }
            """
        )
    except Exception:  # noqa: BLE001
        material_snapshot = []

    logger.info(
        "ENBD: statement-period selection snapshot native_selects=%s material_triggers=%s",
        native_snapshot,
        material_snapshot,
    )


def _select_from_aria_listbox(
    page: Any,
    mode: str,
    logger: logging.Logger,
    *,
    target_score: int | None = None,
    strict_target: bool = False,
) -> bool:
    """Select a year or month from ENBD's ARIA-listbox-based E-statement controls.

    ENBD's /actions/e-statement page uses ``[role='listbox']`` elements
    (``aria-label='Select year'`` / ``aria-label='Select month'``) whose options
    expand inline rather than in a CDK overlay container.
    """
    label_map = {"year": "Select year", "month": "Select month"}
    aria_label = label_map.get(mode)
    if not aria_label:
        return False

    listbox = page.locator(f"[role='listbox'][aria-label='{aria_label}']")
    try:
        if listbox.count() == 0 or not listbox.first.is_visible():
            return False
    except Exception:  # noqa: BLE001
        return False

    # Options live inline inside the listbox; click the listbox to expand if needed.
    options_locator = listbox.first.locator("[role='option']")
    try:
        option_count = options_locator.count()
    except Exception:  # noqa: BLE001
        option_count = 0

    if option_count == 0:
        try:
            listbox.first.click(timeout=2000)
            page.wait_for_timeout(400)
            option_count = options_locator.count()
        except Exception:  # noqa: BLE001
            return False

    candidates: list[tuple[int, int, str]] = []
    for idx in range(min(option_count, 60)):
        item = options_locator.nth(idx)
        try:
            if not item.is_visible():
                continue
            text = (item.inner_text() or "").strip()
            if not text:
                continue
            score = _score_option_text(text, mode)
            if score is None:
                continue
            candidates.append((score, idx, text))
        except Exception:  # noqa: BLE001
            continue

    if not candidates:
        return False

    chosen_idx = None
    chosen_text = ""

    if target_score is not None:
        for score, idx, text in candidates:
            if score == target_score:
                chosen_idx = idx
                chosen_text = text
                break

    if chosen_idx is None and strict_target and target_score is not None:
        logger.info(
            "ENBD: target %s option score=%s not found in ARIA listbox",
            mode,
            target_score,
        )
        return False

    if chosen_idx is None:
        candidates.sort(key=lambda x: x[0], reverse=True)
        _, chosen_idx, chosen_text = candidates[0]

    try:
        options_locator.nth(chosen_idx).click(timeout=2500)
        page.wait_for_timeout(500)
        logger.info(
            "ENBD: selected %s option %s via ARIA listbox (target_score=%s)",
            mode,
            chosen_text,
            target_score,
        )
        return True
    except Exception:  # noqa: BLE001
        return False


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


def _select_statement_period(
    page: Any,
    logger: logging.Logger,
    requested_month: str | None,
    *,
    target_year: int | None = None,
    target_month: int | None = None,
) -> bool:
    if target_year is None or target_month is None:
        parsed_year, parsed_month = _parse_requested_month(requested_month)
        target_year = target_year if target_year is not None else parsed_year
        target_month = target_month if target_month is not None else parsed_month
    target_combined = None
    if target_year is not None and target_month is not None:
        target_combined = target_year * 100 + target_month
    strict_target = target_combined is not None

    selects = page.locator("select")
    try:
        count = min(selects.count(), 8)
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

    if visible:
        classified: list[tuple[Any, str]] = []
        for select in visible:
            mode = _classify_native_select_mode(select)
            if mode:
                classified.append((select, mode))

        year_selects = [select for select, mode in classified if mode == "year"]
        month_selects = [select for select, mode in classified if mode == "month"]
        combined_selects = [select for select, mode in classified if mode == "combined"]

        # Try explicit year+month controls first.
        if year_selects and month_selects:
            if strict_target and not _native_select_group_contains_target(year_selects, "year", target_year):
                _log_period_selection_snapshot(page, logger)
                logger.info(
                    "ENBD: requested year %s not present in year dropdown options",
                    target_year,
                )
                return False

            selected_year = False
            for select in year_selects:
                selected_year = _choose_option(
                    select,
                    "year",
                    logger,
                    target_score=target_year,
                    strict_target=strict_target,
                ) or selected_year

            if selected_year:
                # ENBD can refresh month options asynchronously after year changes.
                page.wait_for_timeout(1300)

                refreshed_months: list[Any] = []
                selects = page.locator("select")
                try:
                    refreshed_count = min(selects.count(), 8)
                except Exception:  # noqa: BLE001
                    refreshed_count = 0
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

            if strict_target and not _native_select_group_contains_target(month_selects, "month", target_month):
                _log_period_selection_snapshot(page, logger)
                logger.info(
                    "ENBD: requested month %s not present in month dropdown options for year %s",
                    target_month,
                    target_year,
                )
                return False

            selected_month = False
            for select in month_selects:
                selected_month = _choose_option(
                    select,
                    "month",
                    logger,
                    target_score=target_month,
                    strict_target=strict_target,
                ) or selected_month

            if selected_year and selected_month:
                page.wait_for_timeout(650)
                return True

        # Combined month-year control fallback.
        if strict_target and combined_selects and not _native_select_group_contains_target(
            combined_selects,
            "combined",
            target_combined,
        ):
            _log_period_selection_snapshot(page, logger)
            logger.info(
                "ENBD: requested period %s-%02d not present in combined dropdown options",
                target_year,
                target_month,
            )
            return False

        for select in combined_selects:
            if _choose_option(
                select,
                "combined",
                logger,
                target_score=target_combined,
                strict_target=strict_target,
            ):
                page.wait_for_timeout(650)
                return True

    # Angular Material dropdown fallback (ENBD E-statement page).
    selected_year = _select_from_material_dropdown(
        page,
        "Year",
        "year",
        logger,
        target_score=target_year,
        strict_target=strict_target,
    )
    if not selected_year:
        if _has_material_dropdown_label(page, "Year"):
            # Labelled dropdown exists but target was not selected.
            if strict_target:
                return False
        else:
            selected_year = _select_from_any_material_dropdown(
                page,
                "year",
                logger,
                target_score=target_year,
                strict_target=strict_target,
            )
    selected_month = _select_from_material_dropdown(
        page,
        "Month",
        "month",
        logger,
        target_score=target_month,
        strict_target=strict_target,
    )
    if not selected_month:
        if _has_material_dropdown_label(page, "Month"):
            if strict_target:
                return False
        else:
            selected_month = _select_from_any_material_dropdown(
                page,
                "month",
                logger,
                target_score=target_month,
                strict_target=strict_target,
            )
    if selected_year and selected_month:
        page.wait_for_timeout(600)
        return True

    # ARIA listbox fallback (ENBD /actions/e-statement page uses [role='listbox'] controls
    # rather than native <select> or Material Angular dropdowns).
    aria_year = _select_from_aria_listbox(
        page,
        "year",
        logger,
        target_score=target_year,
        strict_target=strict_target,
    )
    if aria_year:
        # ENBD enables the month listbox asynchronously after a year is chosen.
        page.wait_for_timeout(700)
    aria_month = _select_from_aria_listbox(
        page,
        "month",
        logger,
        target_score=target_month,
        strict_target=strict_target,
    )
    if aria_year and aria_month:
        page.wait_for_timeout(600)
        return True

    if strict_target:
        _log_period_selection_snapshot(page, logger)
        logger.info(
            "ENBD: exact statement period not available for target year=%s month=%s",
            target_year,
            target_month,
        )
        return False

    return True


def _select_statement_period_with_retry(
    page: Any,
    logger: logging.Logger,
    requested_month: str | None,
    *,
    target_year: int | None = None,
    target_month: int | None = None,
    attempts: int = 3,
) -> bool:
    if target_year is not None and target_month is not None:
        if _target_period_not_present_in_native_controls(page, target_year, target_month):
            _log_period_selection_snapshot(page, logger)
            logger.info(
                "ENBD: requested period %s-%02d is unavailable in native dropdown controls",
                target_year,
                target_month,
            )
            return False
        if _target_period_not_present_in_material_controls(page, logger, target_year, target_month):
            _log_period_selection_snapshot(page, logger)
            logger.info(
                "ENBD: requested period %s-%02d is unavailable in material dropdown controls",
                target_year,
                target_month,
            )
            return False

    for attempt in range(max(1, attempts)):
        selected = _select_statement_period(
            page,
            logger,
            requested_month=requested_month,
            target_year=target_year,
            target_month=target_month,
        )
        if selected:
            return True

        if target_year is not None and target_month is not None:
            if _target_period_not_present_in_native_controls(page, target_year, target_month):
                return False
            if _target_period_not_present_in_material_controls(page, logger, target_year, target_month):
                return False

        if attempt < attempts - 1:
            _dismiss_overlays(page, logger)
            page.wait_for_timeout(900 + (attempt * 300))
    return False


def _click_download(page: Any, incoming_dir: Path, logger: logging.Logger) -> Path | None:
    selectors = [
        "button:has-text('Download')",
        "a:has-text('Download')",
        "button:has-text('Download PDF')",
        "a:has-text('Download PDF')",
        "[role='button']:has-text('Download')",
        "[aria-label*='download' i]",
        "[title*='download' i]",
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
                with page.expect_download(timeout=9000) as download_info:
                    item.click(timeout=3000)
                return save_download(download_info.value, incoming_dir, "ENBD", logger)
            except Exception:  # noqa: BLE001
                continue

    return None


def _is_statements_download_page(page: Any) -> bool:
    def _has_visible(selector: str, limit: int = 8) -> bool:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), limit)
        except Exception:  # noqa: BLE001
            return False
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if item.is_visible():
                    return True
            except Exception:  # noqa: BLE001
                continue
        return False

    has_period_controls = any(
        [
            _has_visible("select"),
            _has_visible(".mat-select-trigger"),
            _has_visible("[role='combobox']"),
            # ENBD /actions/e-statement page uses ARIA listbox controls
            _has_visible("[role='listbox']"),
        ]
    )
    has_download_controls = any(
        [
            _has_visible("button:has-text('Download')"),
            _has_visible("a:has-text('Download')"),
            _has_visible("button:has-text('Download PDF')"),
            _has_visible("a:has-text('Download PDF')"),
            _has_visible("[role='button']:has-text('Download')"),
        ]
    )

    return has_period_controls and has_download_controls


def _dismiss_post_download_ui(page: Any, logger: logging.Logger) -> None:
    done_selectors = [
        "button:has-text('DONE')",
        "button:has-text('Done')",
        "[role='button']:has-text('DONE')",
        "[role='button']:has-text('Done')",
    ]
    for selector in done_selectors:
        locator = page.locator(selector)
        try:
            count = min(locator.count(), 4)
        except Exception:  # noqa: BLE001
            count = 0
        for idx in range(count):
            item = locator.nth(idx)
            try:
                if not item.is_visible():
                    continue
                item.click(timeout=2500)
                page.wait_for_timeout(1000)
                logger.info("ENBD: clicked post-download DONE action")
                break
            except Exception:  # noqa: BLE001
                continue

    try:
        clicked_done = page.evaluate(
            """
            () => {
              const isVisible = (el) => {
                const cs = getComputedStyle(el);
                const r = el.getBoundingClientRect();
                return cs.visibility !== 'hidden' && cs.display !== 'none' && r.width > 0 && r.height > 0;
              };
              const nodes = Array.from(document.querySelectorAll('button, a, [role=\"button\"], div, span'));
              for (const node of nodes) {
                const txt = ((node.innerText || node.textContent || '') + '').replace(/\\s+/g, ' ').trim().toLowerCase();
                if (txt !== 'done') continue;
                if (!isVisible(node)) continue;
                node.click();
                return true;
              }
              return false;
            }
            """
        )
        if clicked_done:
            page.wait_for_timeout(900)
            logger.info("ENBD: clicked DONE action via JS fallback")
    except Exception:  # noqa: BLE001
        pass

    # ENBD occasionally leaves modal/toast overlays after a successful download.
    _dismiss_overlays(page, logger)
    try:
        page.mouse.click(24, 24)
        page.wait_for_timeout(250)
    except Exception:  # noqa: BLE001
        pass
    _dismiss_overlays(page, logger)
    page.wait_for_timeout(700)


def _ensure_statements_download_page(page: Any, logger: logging.Logger) -> bool:
    if _is_statements_download_page(page):
        return True

    # Handle post-download success screen if still visible.
    try:
        done = page.locator("button:has-text('DONE'), [role='button']:has-text('DONE')")
        if done.count() > 0 and done.first.is_visible():
            done.first.click(timeout=2500)
            page.wait_for_timeout(1000)
            logger.info("ENBD: dismissed success screen via DONE before reopening statements")
            if _is_statements_download_page(page):
                return True
    except Exception:  # noqa: BLE001
        pass

    for _ in range(2):
        if _open_statements_view(page, logger):
            page.wait_for_timeout(1000)
            if _is_statements_download_page(page):
                return True

    logger.info("ENBD: statements download controls not detected; could not re-open statements view")
    return False


def _normalize_requested_months(value: Any) -> list[str]:
    if isinstance(value, str):
        token = value.strip()
        return [token] if token else []
    if isinstance(value, list):
        tokens = []
        seen = set()
        for item in value:
            token = str(item or "").strip()
            if not token or token in seen:
                continue
            seen.add(token)
            tokens.append(token)
        return tokens
    return []


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
    for month_token in requested_months:
        if not _ensure_statements_download_page(page, logger):
            diagnostics["failed"].append(
                {
                    "month": month_token,
                    "reason": "statements_page_not_reachable",
                }
            )
            continue

        target_year, target_month = _parse_requested_month(month_token)
        if target_year is None or target_month is None:
            diagnostics["failed"].append(
                {
                    "month": month_token,
                    "reason": "invalid_month_token",
                }
            )
            continue

        selected = _select_statement_period_with_retry(
            page,
            logger,
            requested_month=month_token,
            target_year=target_year,
            target_month=target_month,
        )
        if not selected:
            diagnostics["skipped_unavailable"].append(
                {
                    "month": month_token,
                    "reason": "statement_period_not_available",
                }
            )
            continue

        path = _click_download(page, incoming_dir, logger)
        if path is None:
            diagnostics["failed"].append(
                {
                    "month": month_token,
                    "reason": "download_control_not_found_or_failed",
                }
            )
            continue

        downloaded += 1
        diagnostics["downloaded"].append(
            {
                "month": month_token,
                "path": str(path),
            }
        )
        _dismiss_post_download_ui(page, logger)

    return downloaded, diagnostics


def download_latest_statement(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    bank_cfg: dict,  # noqa: ARG001
) -> int:
    _wait_for_dashboard_ready(page, logger)

    if not _click_cards_tile(page, logger):
        logger.info("ENBD: failed to open cards detail page")
        return attempt_download_capture(page, incoming_dir, "ENBD", logger)

    # On cards page, scroll to statements and open View.
    if not _open_statements_view(page, logger):
        logger.info("ENBD: Statements->View not found")
        return attempt_download_capture(page, incoming_dir, "ENBD", logger)

    requested_months = _normalize_requested_months(bank_cfg.get("requested_months"))
    requested_month = str(bank_cfg.get("requested_month") or "").strip()
    if not requested_months and requested_month:
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

    # Legacy/latest fallback path when no explicit requested month list is provided.
    selected = _select_statement_period(page, logger, requested_month=None)
    if not selected:
        bank_cfg["download_diagnostics"] = {
            "requested_months": [],
            "downloaded": [],
            "skipped_unavailable": [{"month": "latest", "reason": "statement_period_not_available"}],
            "failed": [],
        }
        return 0

    path = _click_download(page, incoming_dir, logger)
    if path is not None:
        bank_cfg["download_diagnostics"] = {
            "requested_months": ["latest"],
            "downloaded": [{"month": "latest", "path": str(path)}],
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
    return attempt_download_capture(page, incoming_dir, "ENBD", logger)


from scraper.banks.base import BankAdapter

ADAPTER = BankAdapter(
    code="ENBD",
    login=login,
    login_selector_visible=login_selector_visible,
    download_latest_statement=download_latest_statement,
)

from __future__ import annotations

import logging
import os
import re
from pathlib import Path
from typing import Any

from scraper.banks.shared import (
    BrowserDownloadError,
    attempt_download_capture,
    require_env,
    save_download,
    text_snapshot,
)
from scraper.banks.month_utils import MONTH_INDEX

MONTH_NAMES = {
    1: "January",
    2: "February",
    3: "March",
    4: "April",
    5: "May",
    6: "June",
    7: "July",
    8: "August",
    9: "September",
    10: "October",
    11: "November",
    12: "December",
}


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


# ── cards ────────────────────────────────────────────────────────────────────
# A replaced card stays listed in the portal next to its successor, and the old flow
# clicked the best "credit card" match: the first card, i.e. the retired one. The portal
# shows card numbers masked ("5290 xxxx xxxx 6774"); we read the last four from that text,
# export each wanted card in turn, and the parser reads the card from the PDF itself.

_MASKED_CARD_RE = re.compile(
    r"(?<!\d)(?:\d{4}[\s-]*)?(?:\d{2}[xX*•]{2}|[xX*•]{4})[\s-]*[xX*•]{4}[\s-]*(\d{4})(?!\d)"
)


def card_last4s_in_text(text: str) -> list[str]:
    """The last four digits of every masked card number in ``text``, in order, de-duplicated."""
    seen: list[str] = []
    for match in _MASKED_CARD_RE.finditer(text or ""):
        if match.group(1) not in seen:
            seen.append(match.group(1))
    return seen


def parse_card_last4s(value: Any) -> list[str]:
    """``SIB_CARD_LAST4S`` / ``card_last4s`` config: "4821,6774", ["4821"], 4821 → ["4821", ...]."""
    if value is None:
        return []
    items = value if isinstance(value, list) else re.split(r"[\s,;]+", str(value))
    out: list[str] = []
    for item in items:
        token = str(item or "").strip()
        if re.fullmatch(r"\d{4}", token) and token not in out:
            out.append(token)
    return out


def wanted_card_last4s(discovered: list[str], configured: list[str]) -> list[str]:
    """Which cards to export. Configured cards (in their order) when set, else every card the
    portal lists. An empty result means the page offers no card choice: the single-card flow."""
    if configured:
        return list(configured)
    return list(discovered)


def _configured_card_last4s(bank_cfg: dict) -> list[str]:
    return parse_card_last4s(bank_cfg.get("card_last4s") or os.environ.get("SIB_CARD_LAST4S"))


def _page_text_with_shadow(page: Any) -> str:
    """Body text plus the text of every open shadow root (the portal is built from web components)."""
    try:
        return str(
            page.evaluate(
                """
                () => {
                  const parts = [document.body ? document.body.innerText : ''];
                  const walk = (root) => {
                    for (const el of root.querySelectorAll('*')) {
                      if (el.shadowRoot) {
                        parts.push(el.shadowRoot.textContent || '');
                        walk(el.shadowRoot);
                      }
                    }
                  };
                  walk(document);
                  return parts.join('\\n');
                }
                """
            )
            or ""
        )
    except Exception:  # noqa: BLE001
        return text_snapshot(page)


def _discover_card_last4s(page: Any, logger: logging.Logger) -> list[str]:
    """The credit cards listed in the Credit Card section (not the dashboard, which may also
    show debit cards). None found keeps the single-card flow."""
    found: list[str] = []
    if _click_shadow_best_match(page, ["credit card"], logger, action_name="Credit Card"):
        logger.info("SIB: waiting 800ms — Credit Card section clicked; reading the listed cards")
        page.wait_for_timeout(800)
        found = card_last4s_in_text(_page_text_with_shadow(page))
    logger.info("SIB: credit cards listed in the portal: %s", ", ".join(found) if found else "none shown")
    return found


def _select_card(page: Any, last4: str, logger: logging.Logger) -> bool:
    """Pick the card ending ``last4``: a native <select> option, else the most specific visible
    element (shortest text) showing that masked number. Walks open shadow roots."""
    result = page.evaluate(
        """
        (last4) => {
          const masked = new RegExp('(?:\\\\d{2}[xX*•]{2}|[xX*•]{4})[\\\\s-]*[xX*•]{4}[\\\\s-]*' + last4 + '(?!\\\\d)');
          const norm = (value) => (value || '').toString().replace(/\\s+/g, ' ').trim();
          const isVisible = (el) => {
            if (!el || !el.getBoundingClientRect) return false;
            const style = getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const all = [];
          const walk = (root) => {
            for (const el of root.querySelectorAll('*')) {
              all.push(el);
              if (el.shadowRoot) walk(el.shadowRoot);
            }
          };
          walk(document);
          for (const select of all.filter((el) => (el.tagName || '').toLowerCase() === 'select' && isVisible(el))) {
            const option = Array.from(select.options || []).find((opt) => masked.test(norm(opt.textContent)));
            if (option) {
              select.value = option.value;
              select.dispatchEvent(new Event('input', { bubbles: true }));
              select.dispatchEvent(new Event('change', { bubbles: true }));
              return 'select';
            }
          }
          let best = null;
          for (const el of all) {
            if (!isVisible(el)) continue;
            const text = norm(el.innerText || el.textContent);
            if (!text || text.length > 400 || !masked.test(text)) continue;
            if (!best || text.length < best.len) best = { el, len: text.length };
          }
          if (!best) return '';
          best.el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true }));
          return 'click';
        }
        """,
        last4,
    )
    if result:
        logger.info("SIB: selected card ending %s via %s", last4, result)
    return bool(result)


def _click_first_visible(
    page: Any,
    selectors: list[str],
    logger: logging.Logger,
    *,
    action_name: str,
    timeout_ms: int = 2500,
) -> bool:
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
                item.click(timeout=timeout_ms)
                logger.info("SIB: clicked %s via %s", action_name, selector)
                return True
            except Exception:  # noqa: BLE001
                continue
    return False


def _fill_first_visible_input(
    page: Any,
    selectors: list[str],
    value: str,
    logger: logging.Logger,
    *,
    field_name: str,
) -> bool:
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
                item.fill(value, timeout=3000)
                logger.info("SIB: filled %s via %s", field_name, selector)
                return True
            except Exception:  # noqa: BLE001
                continue
    return False


def _has_visible_password_input(page: Any) -> bool:
    selectors = [
        "input#originalP:visible",
        "input[type='password']:visible",
        "input[aria-label*='password' i]:visible",
        "input[placeholder*='password' i]:visible",
    ]
    for selector in selectors:
        locator = page.locator(selector)
        try:
            if locator.count() > 0 and locator.first.is_visible():
                return True
        except Exception:  # noqa: BLE001
            continue
    return False


def _click_shadow_best_match(page: Any, terms: list[str], logger: logging.Logger, *, action_name: str) -> bool:
    lowered_terms = [term.strip().lower() for term in terms if term and term.strip()]
    if not lowered_terms:
        return False

    clicked = page.evaluate(
        """
        (terms) => {
          const norm = (value) => (value || '').toString().replace(/\\s+/g, ' ').trim().toLowerCase();
          const isVisible = (el) => {
            if (!el) return false;
            const style = getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const all = [];
          const walk = (root) => {
            for (const el of root.querySelectorAll('*')) {
              all.push(el);
              if (el.shadowRoot) walk(el.shadowRoot);
            }
          };
          walk(document);

          let best = null;
          for (const el of all) {
            if (!isVisible(el)) continue;
            const tag = (el.tagName || '').toLowerCase();
            const role = norm(el.getAttribute && el.getAttribute('role'));
            if (
              tag !== 'button' &&
              tag !== 'a' &&
              tag !== 'sib-button' &&
              role !== 'button' &&
              role !== 'tab' &&
              tag !== 'div' &&
              tag !== 'span' &&
              tag !== 'li'
            ) {
              continue;
            }

            const content = norm(
              [
                el.innerText || '',
                el.textContent || '',
                el.getAttribute && el.getAttribute('aria-label'),
                el.getAttribute && el.getAttribute('title'),
                el.getAttribute && el.getAttribute('name'),
                el.id || '',
                el.className || '',
              ].join(' ')
            );
            if (!content) continue;

            let score = 0;
            for (const term of terms) {
              if (content.includes(term)) score += 1;
            }
            if (!score) continue;
            if (!best || score > best.score) {
              best = { el, score };
            }
          }

          if (!best) return false;
          try {
            best.el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true }));
            return true;
          } catch (e) {
            try {
              best.el.click();
              return true;
            } catch (e2) {
              return false;
            }
          }
        }
        """,
        lowered_terms,
    )
    if clicked:
        logger.info("SIB: clicked %s via shadow-tree fallback terms=%s", action_name, lowered_terms)
    return bool(clicked)


def _resolve_pam_template_base64(page: Any, credentials: dict[str, str] | None = None) -> str:
    configured = ((credentials or os.environ).get("SIB_SECURE_IMAGE_TEMPLATE_BASE64") or "").strip()
    if configured:
        return configured

    resolved = page.evaluate(
        """
        () => {
          const all = [];
          const walk = (root) => {
            for (const el of root.querySelectorAll('*')) {
              all.push(el);
              if (el.shadowRoot) walk(el.shadowRoot);
            }
          };
          walk(document);
          for (const el of all) {
            const mode = el && el.loginModeData;
            if (!mode || typeof mode !== 'object') continue;
            const data = mode.data;
            if (typeof data === 'string' && data.length > 100) {
              return data;
            }
          }
          return '';
        }
        """
    )
    return str(resolved or "").strip()


def _maybe_select_secure_image(page: Any, logger: logging.Logger, credentials: dict[str, str] | None = None) -> None:
    template = _resolve_pam_template_base64(page, credentials)
    selection = page.evaluate(
        """
        async (payload) => {
          const norm = (value) => (value || '').toString().replace(/\\s+/g, ' ').trim().toLowerCase();
          const isVisible = (el) => {
            if (!el) return false;
            const style = getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const all = [];
          const walk = (root) => {
            for (const el of root.querySelectorAll('*')) {
              all.push(el);
              if (el.shadowRoot) walk(el.shadowRoot);
            }
          };
          walk(document);

          const candidates = all.filter((el) => {
            return (
              (el.tagName || '').toLowerCase() === 'img' &&
              el.classList &&
              el.classList.contains('selectimg') &&
              isVisible(el)
            );
          });
          if (!candidates.length) {
            return { selected: false, reason: 'no_candidates', candidate_count: 0 };
          }

          const secureTerms = ['burj', 'khalifa'];
          const metadataScore = (img) => {
            const txt = norm(
              [
                img.alt || '',
                img.title || '',
                img.getAttribute('aria-label') || '',
                img.getAttribute('name') || '',
                img.className || '',
                img.parentElement ? img.parentElement.innerText : '',
              ].join(' ')
            );
            let score = 0;
            for (const term of secureTerms) {
              if (txt.includes(term)) score += 1;
            }
            return score;
          };

          let templateSrc = (payload.template || '').trim();
          if (templateSrc && !templateSrc.startsWith('data:image')) {
            templateSrc = `data:image/png;base64,${templateSrc}`;
          }

          if (!templateSrc) {
            for (const el of all) {
              const mode = el && el.loginModeData;
              if (!mode || typeof mode !== 'object') continue;
              const data = mode.data;
              if (typeof data === 'string' && data.length > 100) {
                templateSrc = data.startsWith('data:image') ? data : `data:image/png;base64,${data}`;
                break;
              }
            }
          }

          const toAbsSrc = (src) => {
            if (!src) return '';
            if (src.startsWith('data:image')) return src;
            try {
              return new URL(src, window.location.origin).toString();
            } catch (e) {
              return src;
            }
          };

          const cache = new Map();
          const toVector = async (src) => {
            const key = toAbsSrc(src);
            if (!key) throw new Error('empty-src');
            if (cache.has(key)) return cache.get(key);

            const img = new Image();
            img.crossOrigin = 'anonymous';
            img.src = key;
            if (img.decode) {
              await img.decode();
            } else {
              await new Promise((resolve, reject) => {
                img.onload = resolve;
                img.onerror = reject;
              });
            }

            const canvas = document.createElement('canvas');
            canvas.width = 16;
            canvas.height = 16;
            const ctx = canvas.getContext('2d');
            if (!ctx) throw new Error('canvas-context-missing');
            ctx.drawImage(img, 0, 0, 16, 16);
            const data = ctx.getImageData(0, 0, 16, 16).data;
            const vec = [];
            for (let idx = 0; idx < data.length; idx += 4) {
              vec.push((data[idx] + data[idx + 1] + data[idx + 2]) / 3);
            }
            cache.set(key, vec);
            return vec;
          };

          const similarity = (a, b) => {
            if (!a || !b || a.length !== b.length || !a.length) return 0;
            let diff = 0;
            for (let idx = 0; idx < a.length; idx += 1) {
              diff += Math.abs(a[idx] - b[idx]);
            }
            return 1 - diff / (a.length * 255);
          };

          let templateVector = null;
          if (templateSrc) {
            try {
              templateVector = await toVector(templateSrc);
            } catch (e) {
              templateVector = null;
            }
          }

          let best = null;
          const scores = [];
          for (let idx = 0; idx < candidates.length; idx += 1) {
            const img = candidates[idx];
            const src = img.getAttribute('src') || img.src || '';
            const meta = metadataScore(img);
            let imageSim = 0;
            if (templateVector && src) {
              try {
                const vec = await toVector(src);
                imageSim = similarity(templateVector, vec);
              } catch (e) {
                imageSim = 0;
              }
            }

            const total = meta * 10 + imageSim;
            scores.push({ index: idx, meta, similarity: imageSim, total });

            if (!best || total > best.total || (total === best.total && idx < best.index)) {
              best = { index: idx, total, meta, similarity: imageSim };
            }
          }

          if (!best) {
            return {
              selected: false,
              reason: 'scoring_failed',
              candidate_count: candidates.length,
              used_template: !!templateVector,
            };
          }

          const target = candidates[best.index];
          let clickTarget = target;
          for (let hop = 0; hop < 3 && clickTarget; hop += 1) {
            const tag = (clickTarget.tagName || '').toLowerCase();
            const role = clickTarget.getAttribute && clickTarget.getAttribute('role');
            if (tag === 'button' || tag === 'a' || role === 'button' || tag === 'img') break;
            clickTarget = clickTarget.parentElement;
          }

          try {
            clickTarget.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true }));
          } catch (e) {
            try {
              target.click();
            } catch (e2) {
              return {
                selected: false,
                reason: 'click_failed',
                candidate_count: candidates.length,
                used_template: !!templateVector,
                best_index: best.index,
                best_score: best.total,
                scores,
              };
            }
          }

          return {
            selected: true,
            reason: 'selected',
            candidate_count: candidates.length,
            used_template: !!templateVector,
            best_index: best.index,
            best_score: best.total,
            best_meta_score: best.meta,
            best_similarity: best.similarity,
            scores,
          };
        }
        """,
        {"template": template},
    )

    if not selection:
        return
    if not selection.get("candidate_count"):
        return
    if selection.get("selected"):
        logger.info(
            "SIB: secure image selected (candidates=%s index=%s score=%.4f template=%s)",
            selection.get("candidate_count"),
            selection.get("best_index"),
            float(selection.get("best_score") or 0.0),
            bool(selection.get("used_template")),
        )
    else:
        logger.warning(
            "SIB: secure image selection fallback had no click (reason=%s candidates=%s)",
            selection.get("reason"),
            selection.get("candidate_count"),
        )


_BIOMETRIC_PROMPT = "text=/confirm your login using biometrics/i"


def _biometric_prompt_visible(page: Any) -> bool:
    """SIB's push login: "Confirm your login using biometrics (face or touch ID) on your registered mobile"."""
    try:
        return page.locator(_BIOMETRIC_PROMPT).count() > 0
    except Exception:  # noqa: BLE001
        return False


def biometric_wait_seconds(value: str | None = None) -> int:
    """How long to wait for the owner to approve the SIB app push (SIB_BIOMETRIC_WAIT_S, default 180 s)."""
    raw = (value if value is not None else os.environ.get("SIB_BIOMETRIC_WAIT_S", "")).strip()
    try:
        return max(15, min(int(raw), 900)) if raw else 180
    except ValueError:
        return 180


def _wait_for_biometric_approval(page: Any, logger: logging.Logger) -> None:
    """Wait while the SIB app push is pending; the owner approves it on their phone."""
    budget_s = biometric_wait_seconds()
    polls = max(1, budget_s // 3)
    logger.warning(
        "SIB: login needs approval in the SIB app on your registered phone (Face ID / Touch ID); "
        "waiting up to %ds",
        budget_s,
    )
    for poll in range(polls):
        logger.info("SIB: waiting 3000ms — biometric approval pending on the phone (poll %d/%d)", poll + 1, polls)
        page.wait_for_timeout(3000)
        if not _biometric_prompt_visible(page):
            logger.info("SIB: biometric approval received")
            return
    raise BrowserDownloadError(
        f"SIB: login was not approved in the SIB app within {budget_s}s (approve the push, or set SIB_BIOMETRIC_WAIT_S)"
    )


def login(page: Any, logger: logging.Logger, credentials: dict[str, str] | None = None) -> None:
    user_id = require_env("SIB_USER_ID", credentials)
    password = require_env("SIB_PASSWORD", credentials)

    logger.info("SIB: waiting 1200ms — login page loaded; allowing initial render")
    page.wait_for_timeout(1200)

    if not _has_visible_password_input(page):
        _fill_first_visible_input(
            page,
            selectors=[
                "input#useridtextbox",
                "input[aria-label*='user' i]",
                "input[placeholder*='user' i]",
                "input[id*='user' i]",
                "input[name*='user' i]",
                "input:visible",
            ],
            value=user_id,
            logger=logger,
            field_name="user ID",
        )
        page.wait_for_timeout(400)

        _SECURE_LOGIN_SELECTORS = [
            "sib-button#proceed",
            "#proceed",
            "button:has-text('Secure Login')",
            "[role='button']:has-text('Secure Login')",
            "text=Secure Login",
        ]
        for click_attempt in range(2):
            # Click once per attempt; do not re-click while the page is
            # transitioning to the password screen — it can reset the flow.
            if not _has_visible_password_input(page):
                clicked = _click_first_visible(
                    page,
                    selectors=_SECURE_LOGIN_SELECTORS,
                    logger=logger,
                    action_name="Secure Login",
                )
                if not clicked:
                    clicked = _click_shadow_best_match(
                        page, ["secure login"], logger, action_name="Secure Login"
                    )

            # Poll up to 10.5s (7 × 1500ms) for the password input to appear.
            for poll in range(7):
                logger.info(
                    "SIB: waiting 1500ms — Secure Login clicked; waiting for password input"
                    " (attempt %d/2, poll %d/7)",
                    click_attempt + 1,
                    poll + 1,
                )
                page.wait_for_timeout(1500)
                if _has_visible_password_input(page) or _biometric_prompt_visible(page):
                    break

            if _has_visible_password_input(page) or _biometric_prompt_visible(page):
                break

    if _biometric_prompt_visible(page):
        # Push login (since 2026-10): no password step; the SIB app approves it.
        _wait_for_biometric_approval(page, logger)
        logger.info("SIB: waiting 2000ms — biometric login approved; letting the portal load")
        page.wait_for_timeout(2000)
        if not _has_visible_password_input(page):
            logger.info("SIB: login submitted (biometric)")
            return

    if not _has_visible_password_input(page):
        raise BrowserDownloadError("SIB: password input not found after Secure Login")

    _maybe_select_secure_image(page, logger, credentials)

    filled_password = _fill_first_visible_input(
        page,
        selectors=[
            "input#originalP",
            "input[aria-label*='password' i]",
            "input[placeholder*='password' i]",
            "input[type='password']",
        ],
        value=password,
        logger=logger,
        field_name="password",
    )
    if not filled_password:
        raise BrowserDownloadError("SIB: password field not found")

    clicked_continue = _click_first_visible(
        page,
        selectors=[
            "button:has-text('Continue')",
            "[role='button']:has-text('Continue')",
            "sib-button:has-text('Continue')",
            "text=Continue",
        ],
        logger=logger,
        action_name="Continue",
    )
    if not clicked_continue:
        clicked_continue = _click_shadow_best_match(page, ["continue"], logger, action_name="Continue")
    if not clicked_continue:
        raise BrowserDownloadError("SIB: Continue button not found on login screen")

    logger.info("SIB: login submitted")


def login_selector_visible(page: Any) -> bool:
    try:
        user_input_visible = page.locator(
            "input#useridtextbox, input[aria-label*='user' i], input[placeholder*='user' i], input[id*='user' i]"
        ).count() > 0
    except Exception:  # noqa: BLE001
        user_input_visible = False

    try:
        secure_login_visible = page.locator(
            "sib-button#proceed, #proceed, button:has-text('Secure Login'), [role='button']:has-text('Secure Login')"
        ).count() > 0
    except Exception:  # noqa: BLE001
        secure_login_visible = False

    low = text_snapshot(page).lower()
    if "secure login" in low and ("enter user id" in low or "user id" in low):
        return True
    return bool(user_input_visible and secure_login_visible)


def _popup_has_download_controls(page: Any) -> bool:
    try:
        if page.locator("button:has-text('Download Statement')").count() > 0:
            return True
    except Exception:  # noqa: BLE001
        pass
    low = text_snapshot(page).lower()
    return "download statement" in low


def _open_estatement_popup(page: Any, logger: logging.Logger, card_last4: str | None = None) -> bool:
    if _popup_has_download_controls(page):
        if card_last4 and _select_card(page, card_last4, logger):
            logger.info("SIB: waiting 800ms — card ending %s chosen in the E-statement popup", card_last4)
            page.wait_for_timeout(800)
        return True

    for _ in range(10):
        # Best-effort path: open Credit Card section then E-statement.
        _click_shadow_best_match(page, ["credit card"], logger, action_name="Credit Card")
        logger.info("SIB: waiting 800ms — Credit Card section clicked; allowing E-statement to appear")
        page.wait_for_timeout(800)
        if card_last4 and _select_card(page, card_last4, logger):
            # The section lists every card (a replaced one too): open the wanted card first.
            logger.info("SIB: waiting 800ms — card ending %s chosen; allowing its E-statement to appear", card_last4)
            page.wait_for_timeout(800)
        clicked_estatement = _click_first_visible(
            page,
            selectors=[
                "a:has-text('E-statement')",
                "button:has-text('E-statement')",
                "[role='button']:has-text('E-statement')",
                "text=E-statement",
                "text=Estatement",
            ],
            logger=logger,
            action_name="E-statement",
        )
        if not clicked_estatement:
            clicked_estatement = _click_shadow_best_match(
                page,
                ["e-statement"],
                logger,
                action_name="E-statement",
            )
        if not clicked_estatement:
            clicked_estatement = _click_shadow_best_match(
                page,
                ["estatement"],
                logger,
                action_name="E-statement",
            )

        logger.info("SIB: waiting 1000ms — E-statement clicked; waiting for popup to load")
        page.wait_for_timeout(1000)
        if _popup_has_download_controls(page):
            logger.info("SIB: E-statement popup detected")
            if card_last4 and _select_card(page, card_last4, logger):
                logger.info("SIB: waiting 800ms — card ending %s chosen in the E-statement popup", card_last4)
                page.wait_for_timeout(800)
            return True

        page.mouse.wheel(0, 450)
        page.wait_for_timeout(450)

    return _popup_has_download_controls(page)


def _select_native_dropdown_value(
    page: Any,
    *,
    mode: str,
    target_year: int | None,
    target_month: int | None,
) -> bool:
    month_aliases = {name: value for name, value in MONTH_INDEX.items()}
    result = page.evaluate(
        """
        ({ mode, targetYear, targetMonth, monthAliases }) => {
          const norm = (value) => (value || '').toString().replace(/\\s+/g, ' ').trim().toLowerCase();
          const isVisible = (el) => {
            if (!el) return false;
            const style = getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };

          const all = [];
          const walk = (root) => {
            for (const el of root.querySelectorAll('*')) {
              all.push(el);
              if (el.shadowRoot) walk(el.shadowRoot);
            }
          };
          walk(document);

          const selects = all.filter((el) => (el.tagName || '').toLowerCase() === 'select' && isVisible(el));
          if (!selects.length) return false;

          const optionMonth = (text) => {
            const low = norm(text);
            const numMatch = low.match(/\\b(0?[1-9]|1[0-2])\\b/);
            if (numMatch) return parseInt(numMatch[1], 10);
            for (const [name, idx] of Object.entries(monthAliases)) {
              if (low.includes(name)) return idx;
            }
            return null;
          };

          for (const select of selects) {
            const options = Array.from(select.options || []);
            if (!options.length) continue;

            let match = null;
            if (mode === 'year' && targetYear) {
              match = options.find((opt) => {
                const txt = `${opt.textContent || ''} ${opt.value || ''}`;
                return txt.includes(String(targetYear));
              });
            } else if (mode === 'month' && targetMonth) {
              match = options.find((opt) => {
                const txt = `${opt.textContent || ''} ${opt.value || ''}`;
                const monthVal = optionMonth(txt);
                return monthVal === targetMonth;
              });
            }

            if (!match || !match.value) continue;
            select.value = match.value;
            select.dispatchEvent(new Event('input', { bubbles: true }));
            select.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
          }
          return false;
        }
        """,
        {
            "mode": mode,
            "targetYear": target_year,
            "targetMonth": target_month,
            "monthAliases": month_aliases,
        },
    )
    return bool(result)


def _select_custom_dropdown_value(
    page: Any,
    logger: logging.Logger,
    *,
    mode: str,
    target_year: int | None,
    target_month: int | None,
) -> bool:
    if mode == "year" and target_year is not None:
        open_terms = ["year"]
        value_terms = [str(target_year)]
    elif mode == "month" and target_month is not None:
        open_terms = ["month"]
        value_terms = [
            str(target_month),
            f"{target_month:02d}",
            MONTH_NAMES.get(target_month, ""),
            MONTH_NAMES.get(target_month, "")[:3],
        ]
    else:
        return False

    _click_shadow_best_match(page, open_terms, logger, action_name=f"open {mode} selector")
    page.wait_for_timeout(350)
    for value in value_terms:
        token = value.strip().lower()
        if not token:
            continue
        if _click_shadow_best_match(page, [token], logger, action_name=f"select {mode}={value}"):
            page.wait_for_timeout(350)
            return True
    return False


def _select_statement_period(
    page: Any,
    logger: logging.Logger,
    *,
    requested_month: str | None,
    target_year: int | None = None,
    target_month: int | None = None,
) -> bool:
    if target_year is None or target_month is None:
        parsed_year, parsed_month = _parse_requested_month(requested_month)
        target_year = target_year if target_year is not None else parsed_year
        target_month = target_month if target_month is not None else parsed_month

    if target_year is None or target_month is None:
        return True

    selected_year = _select_native_dropdown_value(
        page,
        mode="year",
        target_year=target_year,
        target_month=target_month,
    ) or _select_custom_dropdown_value(
        page,
        logger,
        mode="year",
        target_year=target_year,
        target_month=target_month,
    )
    selected_month = _select_native_dropdown_value(
        page,
        mode="month",
        target_year=target_year,
        target_month=target_month,
    ) or _select_custom_dropdown_value(
        page,
        logger,
        mode="month",
        target_year=target_year,
        target_month=target_month,
    )

    if selected_year and selected_month:
        logger.info("SIB: selected statement period year=%s month=%s", target_year, target_month)
        return True

    logger.info(
        "SIB: statement period not available for year=%s month=%s (selected_year=%s selected_month=%s)",
        target_year,
        target_month,
        selected_year,
        selected_month,
    )
    return False


def _download_statement(page: Any, incoming_dir: Path, logger: logging.Logger) -> Path | None:
    controls = [
        "button:has-text('Download Statement')",
        "[role='button']:has-text('Download Statement')",
        "a:has-text('Download Statement')",
        "text=Download Statement",
    ]

    for selector in controls:
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
                logger.info("SIB: waiting for download event via explicit control (up to 18000ms)")
                with page.expect_download(timeout=18000) as download_info:
                    item.click(timeout=3500)
                path = save_download(download_info.value, incoming_dir, "SIB", logger)
                logger.info("SIB: statement downloaded via explicit control")
                return path
            except Exception:  # noqa: BLE001
                continue

    before = _snapshot_pdf_mtimes(incoming_dir)
    try:
        logger.info("SIB: waiting for download event via shadow fallback control (up to 12000ms)")
        with page.expect_download(timeout=12000) as download_info:
            if not _click_shadow_best_match(
                page,
                ["download statement"],
                logger,
                action_name="Download Statement",
            ):
                raise RuntimeError("download_statement_click_not_found")
        path = save_download(download_info.value, incoming_dir, "SIB", logger)
        logger.info("SIB: statement downloaded via shadow fallback control")
        return path
    except Exception:  # noqa: BLE001
        pass

    fallback_downloads = attempt_download_capture(page, incoming_dir, "SIB", logger)
    if fallback_downloads > 0:
        return _latest_new_pdf(before, incoming_dir)
    return None


def _close_estatement_popup(page: Any, logger: logging.Logger) -> None:
    closed = _click_first_visible(
        page,
        selectors=[
            "button:has-text('Close')",
            "button:has-text('Cancel')",
            "[role='button']:has-text('Close')",
            "[role='button']:has-text('Cancel')",
        ],
        logger=logger,
        action_name="popup close",
        timeout_ms=1500,
    )
    if not closed:
        _click_shadow_best_match(page, ["close"], logger, action_name="popup close")
    try:
        page.keyboard.press("Escape")
    except Exception:  # noqa: BLE001
        pass
    page.wait_for_timeout(350)


def _download_requested_months(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    requested_months: list[str],
    card_last4: str | None = None,
) -> tuple[int, dict[str, Any]]:
    diagnostics: dict[str, Any] = {
        "requested_months": requested_months,
        "downloaded": [],
        "skipped_unavailable": [],
        "failed": [],
    }

    downloaded = 0
    for month_token in requested_months:
        target_year, target_month = _parse_requested_month(month_token)
        if target_year is None or target_month is None:
            diagnostics["failed"].append({"month": month_token, "reason": "invalid_month_token"})
            continue

        if not _open_estatement_popup(page, logger, card_last4):
            diagnostics["failed"].append({"month": month_token, "reason": "estatement_popup_not_opened"})
            continue

        if not _select_statement_period(
            page,
            logger,
            requested_month=month_token,
            target_year=target_year,
            target_month=target_month,
        ):
            diagnostics["skipped_unavailable"].append(
                {"month": month_token, "reason": "statement_period_not_available"}
            )
            _close_estatement_popup(page, logger)
            continue

        path = _download_statement(page, incoming_dir, logger)
        if path is None:
            diagnostics["failed"].append({"month": month_token, "reason": "download_control_not_found_or_failed"})
            _close_estatement_popup(page, logger)
            continue

        downloaded += 1
        diagnostics["downloaded"].append({"month": month_token, "path": str(path)})
        _close_estatement_popup(page, logger)

    return downloaded, diagnostics


def download_latest_statement(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    bank_cfg: dict,
) -> int:
    requested_months = _normalize_requested_months(bank_cfg.get("requested_months"))
    requested_month = str(bank_cfg.get("requested_month") or "").strip()
    if not requested_months and requested_month:
        requested_months = [requested_month]

    # Every card the portal lists (or the configured SIB_CARD_LAST4S / card_last4s), one
    # export each; no card choice on the page keeps the single-card flow.
    cards = wanted_card_last4s(_discover_card_last4s(page, logger), _configured_card_last4s(bank_cfg))
    if cards:
        logger.info("SIB: exporting cards ending %s", ", ".join(cards))

    total = 0
    merged: dict[str, Any] = {
        "requested_months": requested_months or ["latest"],
        "cards": cards,
        "downloaded": [],
        "skipped_unavailable": [],
        "failed": [],
    }
    for card_last4 in cards or [None]:
        count, diagnostics = _download_for_card(page, incoming_dir, logger, requested_months, card_last4)
        total += count
        for key in ("downloaded", "skipped_unavailable", "failed"):
            for entry in diagnostics.get(key, []):
                merged[key].append({**entry, **({"card_last4": card_last4} if card_last4 else {})})
    bank_cfg["download_diagnostics"] = merged
    return total


def _download_for_card(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    requested_months: list[str],
    card_last4: str | None,
) -> tuple[int, dict[str, Any]]:
    if requested_months:
        return _download_requested_months(page, incoming_dir, logger, requested_months, card_last4)

    if not _open_estatement_popup(page, logger, card_last4):
        return 0, {
            "requested_months": ["latest"],
            "downloaded": [],
            "skipped_unavailable": [{"month": "latest", "reason": "estatement_popup_not_opened"}],
            "failed": [],
        }

    path = _download_statement(page, incoming_dir, logger)
    _close_estatement_popup(page, logger)
    if path is not None:
        return 1, {
            "requested_months": ["latest"],
            "downloaded": [{"month": "latest", "path": str(path)}],
            "skipped_unavailable": [],
            "failed": [],
        }
    return 0, {
        "requested_months": ["latest"],
        "downloaded": [],
        "skipped_unavailable": [],
        "failed": [{"month": "latest", "reason": "download_control_not_found_or_failed"}],
    }


from scraper.banks.base import BankAdapter

ADAPTER = BankAdapter(
    code="SIB",
    login=login,
    login_selector_visible=login_selector_visible,
    download_latest_statement=download_latest_statement,
)

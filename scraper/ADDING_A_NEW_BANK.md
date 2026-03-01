# Adding a New Bank

This guide explains how to add support for a new bank to the scraper. The architecture is fully bank-agnostic — `downloader.py` auto-discovers adapters and requires **no changes** when you add a new bank.

## Steps

### 1. Create the adapter module

Create `scraper/scraper/banks/adapters/<bankcode>.py` (lowercase bank code), e.g. `scraper/scraper/banks/adapters/cbd.py`.

### 2. Implement the three required functions

```python
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

from scraper.banks.shared import require_env


def login(page: Any, logger: logging.Logger, credentials: dict[str, str] | None = None) -> None:
    username = require_env("CBD_USERNAME", credentials)
    password = require_env("CBD_PASSWORD", credentials)

    page.fill("input#username", username)
    page.fill("input#password", password)
    page.click("button[type='submit']")
    logger.info("CBD: login submitted")


def login_selector_visible(page: Any) -> bool:
    return page.locator("input#username").first.is_visible()


def download_latest_statement(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    bank_cfg: dict[str, Any],
) -> int:
    # Navigate to statements page and trigger download.
    # Return the number of files triggered (0 if none).
    ...
    return 0
```

### 3. (Optional) Implement auth-flow hook functions

If your bank has a non-standard authentication flow (OTP, anti-bot screens, concurrent session gates, etc.), implement one or more of the following hook functions.

#### `is_authenticated_session(page, low_text) -> bool`

Return `True` when the current page is definitely a post-login authenticated state.

```python
def is_authenticated_session(page: Any, low_text: str) -> bool:
    url = page.url.lower()
    return "/dashboard" in url or ("welcome" in low_text and "sign out" in low_text)
```

#### `is_login_screen(low_text) -> bool`

Return `True` when the current page is the bank's login form.

```python
def is_login_screen(low_text: str) -> bool:
    return "sign in to your account" in low_text and "username" in low_text
```

#### `is_login_failure(low_text) -> bool`

Override if the bank uses unusual failure copy. By default delegates to the generic `shared.is_login_failure`.

```python
def is_login_failure(low_text: str) -> bool:
    from scraper.banks.shared import is_login_failure as _shared
    return _shared(low_text) and "some_false_positive_phrase" not in low_text
```

#### `on_auth_poll_tick(page, low_text, logger, state) -> AuthPollAction`

Called once per polling iteration. Use `state.extra` for adapter-private mutable state across ticks.

```python
from scraper.banks.base import AuthPollAction, AuthPollState

def on_auth_poll_tick(page: Any, low_text: str, logger: logging.Logger, state: AuthPollState) -> AuthPollAction:
    # Example: dismiss an intermediate "Continue" gate
    btn = page.locator("button:has-text('Continue')")
    if btn.count() > 0:
        try:
            btn.first.click(timeout=2000)
            logger.info("CBD: dismissed Continue gate")
        except Exception:
            pass
    return AuthPollAction.CONTINUE
```

`AuthPollAction` values:

| Value | Meaning |
|-------|---------|
| `CONTINUE` | No special action; proceed with generic checks |
| `AUTHENTICATED` | Adapter confirms auth; return page immediately |
| `RETRY_LOGIN` | Re-invoke `login()` (no credentials), increment `state.relogin_attempts` |
| `WAIT` | Skip rest of this iteration; sleep before next tick |

`AuthPollState` fields:

| Field | Type | Description |
|-------|------|-------------|
| `elapsed_seconds` | `float` | Seconds since polling started |
| `prompted_for_mfa` | `bool` | Whether the MFA prompt has been shown |
| `relogin_attempts` | `int` | Number of times `RETRY_LOGIN` has been returned |
| `last_login_attempt_unix` | `float` | Unix timestamp of the last login attempt |
| `portal_url` | `str \| None` | The bank's portal URL |
| `extra` | `dict` | Free-form dict for adapter-private state |

#### `browser_launch_overrides() -> dict`

Return browser launch overrides. Supported keys:

- `channel_candidates`: list of channel strings or `None`, e.g. `["chrome", None]` — tries real Chrome first, falls back to bundled Chromium.
- `init_scripts`: list of JavaScript strings to inject into every page via `add_init_script`.

```python
def browser_launch_overrides() -> dict:
    return {
        "channel_candidates": ["chrome", None],
        "init_scripts": [
            "Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });",
        ],
    }
```

### 4. Define the `ADAPTER` constant

At the bottom of your module, define `ADAPTER`. This is the only thing the auto-discovery mechanism looks for.

```python
from scraper.banks.base import AuthPollAction, AuthPollState, BankAdapter

ADAPTER = BankAdapter(
    code="CBD",
    login=login,
    login_selector_visible=login_selector_visible,
    download_latest_statement=download_latest_statement,
    # Optional hooks:
    is_authenticated_session=is_authenticated_session,
    is_login_screen=is_login_screen,
    on_auth_poll_tick=on_auth_poll_tick,
    # Flags:
    skip_mfa_user_prompt=False,       # True = suppress interactive MFA prompt (bank auto-handles OTP)
    skip_keyword_fallback=False,      # True = skip generic POST_LOGIN_KEYWORDS check
    skip_login_selector_fallback=False,  # True = skip login-selector-visible + keyword fallback
    # Browser overrides:
    browser_launch_overrides=browser_launch_overrides,
)
```

### 5. Add the bank to `config/banks.yaml`

```yaml
banks:
  CBD:
    portal_url: "https://ibanking.cbd.ae/..."
    cards:
      - last4: "1234"
```

### 6. Set credentials as environment variables

```bash
export CBD_USERNAME="your_username"
export CBD_PASSWORD="your_password"
```

### 7. Verify discovery

```bash
cd scraper
source .venv/bin/activate
python -c "from scraper.banks.adapters import discover_adapters; print(discover_adapters())"
```

You should see `BankAdapter(code='CBD')` in the output.

### 8. Run tests

```bash
cd scraper && source .venv/bin/activate && python -m pytest -q
```

### 9. Dry-run

```bash
ccs-scraper scrape --profile <profile> --banks CBD --no-upload --headless
```

---

## What you do NOT need to change

- `downloader.py` — bank-agnostic; auto-discovers all adapters
- `scraper/scraper/banks/adapters/__init__.py` — scans for `ADAPTER` at import time
- `scraper/scraper/banks/base.py` — the interface; only change this to add new hook types

## Full example: a minimal adapter

```python
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

from scraper.banks.base import BankAdapter
from scraper.banks.shared import require_env


def login(page: Any, logger: logging.Logger, credentials: dict[str, str] | None = None) -> None:
    username = require_env("CBD_USERNAME", credentials)
    password = require_env("CBD_PASSWORD", credentials)
    page.fill("input#username", username)
    page.fill("input#password", password)
    page.click("button[type='submit']")
    logger.info("CBD: login submitted")


def login_selector_visible(page: Any) -> bool:
    return page.locator("input#username").first.is_visible()


def download_latest_statement(
    page: Any,
    incoming_dir: Path,
    logger: logging.Logger,
    bank_cfg: dict[str, Any],
) -> int:
    return 0  # implement statement download logic here


ADAPTER = BankAdapter(
    code="CBD",
    login=login,
    login_selector_visible=login_selector_visible,
    download_latest_statement=download_latest_statement,
)
```

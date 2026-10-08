"""SIB push login: wait for the owner's approval in the SIB app instead of a password."""

import logging

import pytest

from scraper.banks.adapters import sib
from scraper.banks.shared import BrowserDownloadError


class _Locator:
    def __init__(self, page: "_Page", selector: str) -> None:
        self.page, self.selector = page, selector

    def count(self) -> int:
        return 1 if self.selector == sib._BIOMETRIC_PROMPT and self.page.prompt_polls_left > 0 else 0


class _Page:
    def __init__(self, prompt_polls: int) -> None:
        self.prompt_polls_left = prompt_polls
        self.waits: list[int] = []

    def locator(self, selector: str) -> _Locator:
        return _Locator(self, selector)

    def wait_for_timeout(self, ms: int) -> None:
        self.waits.append(ms)
        self.prompt_polls_left -= 1


def test_wait_seconds_default_and_bounds():
    assert sib.biometric_wait_seconds("") == 180
    assert sib.biometric_wait_seconds("60") == 60
    assert sib.biometric_wait_seconds("5") == 15
    assert sib.biometric_wait_seconds("99999") == 900
    assert sib.biometric_wait_seconds("abc") == 180


def test_returns_once_the_prompt_goes_away(monkeypatch):
    monkeypatch.setenv("SIB_BIOMETRIC_WAIT_S", "30")
    page = _Page(prompt_polls=3)
    sib._wait_for_biometric_approval(page, logging.getLogger("t"))
    assert page.waits == [3000, 3000, 3000]


def test_times_out_with_a_clear_error(monkeypatch):
    monkeypatch.setenv("SIB_BIOMETRIC_WAIT_S", "15")
    page = _Page(prompt_polls=100)
    with pytest.raises(BrowserDownloadError, match="not approved in the SIB app"):
        sib._wait_for_biometric_approval(page, logging.getLogger("t"))

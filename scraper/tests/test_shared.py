from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from scraper.banks.shared import (
    BrowserDownloadError,
    count_new_or_updated_pdfs,
    is_login_failure,
    is_mfa_pending,
    require_env,
    snapshot_pdf_state,
)


# ---------------------------------------------------------------------------
# is_mfa_pending
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("text", [
    "Please authenticate on your registered device",
    "Authorise with the app to continue",
    "Enter your SmartPass code",
    "Enter the one-time password sent to your phone",
    "One Time Password sent via SMS",
])
def test_is_mfa_pending_matches(text: str) -> None:
    assert is_mfa_pending(text) is True


@pytest.mark.parametrize("text", [
    "Welcome to online banking",
    "Your account balance is AED 1,200.00",
    "Download your statement",
    "Invalid username/password",
    "",
])
def test_is_mfa_pending_no_match(text: str) -> None:
    assert is_mfa_pending(text) is False


def test_is_mfa_pending_case_insensitive() -> None:
    assert is_mfa_pending("AUTHENTICATE ON YOUR REGISTERED DEVICE") is True
    assert is_mfa_pending("one-time password") is True


# ---------------------------------------------------------------------------
# is_login_failure
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("text", [
    "Invalid username/password combination",
    "Incorrect password, please try again",
    "Login Failed. Please try again.",
    "Invalid credentials provided",
    "Unable to carry out your instructions at this time",
    "You are not authorized to login to this portal",
])
def test_is_login_failure_matches(text: str) -> None:
    assert is_login_failure(text) is True


@pytest.mark.parametrize("text", [
    "Welcome back!",
    "Your last login was on Monday",
    "Account summary",
    "Download statement",
    "",
])
def test_is_login_failure_no_match(text: str) -> None:
    assert is_login_failure(text) is False


def test_is_login_failure_case_insensitive() -> None:
    assert is_login_failure("LOGIN FAILED") is True
    assert is_login_failure("INVALID USERNAME/PASSWORD") is True


# ---------------------------------------------------------------------------
# require_env
# ---------------------------------------------------------------------------

def test_require_env_returns_value() -> None:
    assert require_env("KEY", {"KEY": "value"}) == "value"


def test_require_env_raises_on_missing_key() -> None:
    with pytest.raises(BrowserDownloadError, match="KEY"):
        require_env("KEY", {})


def test_require_env_raises_on_blank_value() -> None:
    with pytest.raises(BrowserDownloadError, match="BLANK"):
        require_env("BLANK", {"BLANK": ""})


def test_require_env_falls_back_to_os_environ(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TEST_VAR_XYZ", "from_os")
    assert require_env("TEST_VAR_XYZ") == "from_os"


def test_require_env_raises_when_not_in_os_environ(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("MISSING_VAR_XYZ", raising=False)
    with pytest.raises(BrowserDownloadError):
        require_env("MISSING_VAR_XYZ")


# ---------------------------------------------------------------------------
# snapshot_pdf_state
# ---------------------------------------------------------------------------

def test_snapshot_empty_directory(tmp_path: Path) -> None:
    assert snapshot_pdf_state([tmp_path]) == {}


def test_snapshot_missing_directory(tmp_path: Path) -> None:
    missing = tmp_path / "nonexistent"
    assert snapshot_pdf_state([missing]) == {}


def test_snapshot_captures_pdf_files(tmp_path: Path) -> None:
    (tmp_path / "statement_jan.pdf").write_bytes(b"%PDF-1.4")
    (tmp_path / "statement_feb.pdf").write_bytes(b"%PDF-1.4")
    state = snapshot_pdf_state([tmp_path])
    assert len(state) == 2
    assert all(k.endswith(".pdf") for k in state)


def test_snapshot_ignores_non_pdf_files(tmp_path: Path) -> None:
    (tmp_path / "notes.txt").write_text("hello")
    (tmp_path / "archive.zip").write_bytes(b"PK")
    (tmp_path / "image.png").write_bytes(b"\x89PNG")
    assert snapshot_pdf_state([tmp_path]) == {}


def test_snapshot_case_insensitive_pdf_extension(tmp_path: Path) -> None:
    # .PDF (uppercase) should still be captured
    upper = tmp_path / "STMT.PDF"
    upper.write_bytes(b"%PDF-1.4")
    state = snapshot_pdf_state([tmp_path])
    assert len(state) == 1


def test_snapshot_records_mtime(tmp_path: Path) -> None:
    pdf = tmp_path / "stmt.pdf"
    pdf.write_bytes(b"%PDF-1.4")
    state = snapshot_pdf_state([tmp_path])
    key = str(pdf.resolve())
    assert state[key] == pdf.stat().st_mtime_ns


def test_snapshot_multiple_directories(tmp_path: Path) -> None:
    dir_a = tmp_path / "a"
    dir_b = tmp_path / "b"
    dir_a.mkdir()
    dir_b.mkdir()
    (dir_a / "s1.pdf").write_bytes(b"%PDF")
    (dir_b / "s2.pdf").write_bytes(b"%PDF")
    state = snapshot_pdf_state([dir_a, dir_b])
    assert len(state) == 2


# ---------------------------------------------------------------------------
# count_new_or_updated_pdfs
# ---------------------------------------------------------------------------

def test_count_returns_zero_when_nothing_changed(tmp_path: Path) -> None:
    (tmp_path / "a.pdf").write_bytes(b"%PDF")
    before = snapshot_pdf_state([tmp_path])
    after = snapshot_pdf_state([tmp_path])
    assert count_new_or_updated_pdfs(before, after) == 0


def test_count_detects_new_file(tmp_path: Path) -> None:
    before = snapshot_pdf_state([tmp_path])
    (tmp_path / "new.pdf").write_bytes(b"%PDF")
    after = snapshot_pdf_state([tmp_path])
    assert count_new_or_updated_pdfs(before, after) == 1


def test_count_detects_multiple_new_files(tmp_path: Path) -> None:
    before = snapshot_pdf_state([tmp_path])
    (tmp_path / "a.pdf").write_bytes(b"%PDF")
    (tmp_path / "b.pdf").write_bytes(b"%PDF")
    after = snapshot_pdf_state([tmp_path])
    assert count_new_or_updated_pdfs(before, after) == 2


def test_count_detects_updated_file(tmp_path: Path) -> None:
    pdf = tmp_path / "stmt.pdf"
    pdf.write_bytes(b"%PDF v1")
    before = snapshot_pdf_state([tmp_path])

    # Advance mtime_ns by 10 ms to simulate an update
    stat = pdf.stat()
    os.utime(pdf, ns=(stat.st_atime_ns, stat.st_mtime_ns + 10_000_000))

    after = snapshot_pdf_state([tmp_path])
    assert count_new_or_updated_pdfs(before, after) == 1


def test_count_ignores_unchanged_files(tmp_path: Path) -> None:
    (tmp_path / "old.pdf").write_bytes(b"%PDF")
    before = snapshot_pdf_state([tmp_path])
    (tmp_path / "new.pdf").write_bytes(b"%PDF")
    after = snapshot_pdf_state([tmp_path])
    # Only the new file should be counted
    assert count_new_or_updated_pdfs(before, after) == 1


def test_count_empty_before_and_after() -> None:
    assert count_new_or_updated_pdfs({}, {}) == 0

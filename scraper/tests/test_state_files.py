"""Crash-safe state files (audit SRV-16): atomic writes, quarantined corrupt files,
and the server's filename normalisation."""
from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest

from scraper import json_state
from scraper.bank_map import BankMap
from scraper.upload_state import UploadedState, server_filename


def _corrupt_copies(directory: Path, name: str) -> list[Path]:
    return sorted(directory.glob(f"{name}.*.corrupt"))


# ---------------------------------------------------------------------------
# corrupt files are kept aside, with a warning
# ---------------------------------------------------------------------------


def test_corrupt_uploaded_json_is_kept_aside_with_a_warning(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    (tmp_path / "uploaded.json").write_text("{not json")
    state = UploadedState(tmp_path)

    with caplog.at_level(logging.WARNING, logger="ccs_scraper.state"):
        assert state.is_uploaded("abc") is False

    copies = _corrupt_copies(tmp_path, "uploaded.json")
    assert len(copies) == 1
    assert copies[0].read_text() == "{not json"
    assert not (tmp_path / "uploaded.json").exists()
    assert any("corrupt" in r.getMessage() and copies[0].name in r.getMessage() for r in caplog.records)

    # The next write starts a fresh, valid file; the corrupt copy stays.
    state.record_many({"sha1": {"filename": "a.pdf", "status": "queued"}})
    assert set(json.loads((tmp_path / "uploaded.json").read_text())) == {"sha1"}
    assert _corrupt_copies(tmp_path, "uploaded.json") == copies


def test_non_object_uploaded_json_is_kept_aside(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    (tmp_path / "uploaded.json").write_text("[1, 2]")

    with caplog.at_level(logging.WARNING, logger="ccs_scraper.state"):
        assert UploadedState(tmp_path).get("abc") is None

    assert len(_corrupt_copies(tmp_path, "uploaded.json")) == 1
    assert any("expected a JSON object" in r.getMessage() for r in caplog.records)


def test_corrupt_bank_map_is_kept_aside(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    (tmp_path / "bank_map.json").write_text('{"truncated": ')

    with caplog.at_level(logging.WARNING, logger="ccs_scraper.state"):
        assert BankMap(tmp_path).get(tmp_path / "a.pdf") is None

    assert len(_corrupt_copies(tmp_path, "bank_map.json")) == 1
    assert caplog.records


def test_missing_file_is_empty_without_warning(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.WARNING, logger="ccs_scraper.state"):
        assert UploadedState(tmp_path / "state").is_uploaded("abc") is False
    assert not caplog.records


# ---------------------------------------------------------------------------
# atomic writes
# ---------------------------------------------------------------------------


def test_interrupted_write_leaves_previous_file_intact(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    state = UploadedState(tmp_path)
    state.record_many({"sha1": {"filename": "a.pdf", "status": "queued"}})
    before = (tmp_path / "uploaded.json").read_text()

    def _boom(*_args: object, **_kwargs: object) -> None:
        raise KeyboardInterrupt  # e.g. Ctrl-C mid-write

    monkeypatch.setattr(json_state.json, "dump", _boom)
    with pytest.raises(KeyboardInterrupt):
        state.record_many({"sha2": {"filename": "b.pdf", "status": "queued"}})

    assert (tmp_path / "uploaded.json").read_text() == before
    assert sorted(p.name for p in tmp_path.iterdir()) == ["uploaded.json"]  # no temp file left behind


def test_write_json_atomic_creates_directory_and_round_trips(tmp_path: Path) -> None:
    target = tmp_path / "nested" / "state.json"
    json_state.write_json_atomic(target, {"b": 1, "a": 2}, sort_keys=True)

    assert json_state.load_json_object(target) == {"a": 2, "b": 1}
    text = target.read_text()
    assert text.index('"a"') < text.index('"b"')
    assert sorted(p.name for p in target.parent.iterdir()) == ["state.json"]


# ---------------------------------------------------------------------------
# server_filename mirrors sanitizeFilename() in _shared/documents.ts
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("sent", "echoed"),
    [
        ("statement.pdf", "statement.pdf"),
        ("  padded.pdf\t", "padded.pdf"),
        ("﻿bom.pdf", "bom.pdf"),
        ("dir/sub\\win.pdf", "win.pdf"),
        ("ctrl\x00\x1f\x7fchars.pdf", "ctrlchars.pdf"),
        ("   ", "statement.pdf"),
        ("", "statement.pdf"),
    ],
)
def test_server_filename(sent: str, echoed: str) -> None:
    assert server_filename(sent) == echoed


def test_server_filename_keeps_the_last_200_utf16_units() -> None:
    name = "a" * 250 + ".pdf"
    assert server_filename(name) == name[-200:]


def test_server_filename_counts_astral_characters_as_two_units() -> None:
    name = "\U0001F4C4" * 150 + ".pdf"  # 300 + 4 UTF-16 code units
    out = server_filename(name)
    assert len(out.encode("utf-16-le", "surrogatepass")) == 400  # 200 units
    assert out == "\U0001F4C4" * 98 + ".pdf"

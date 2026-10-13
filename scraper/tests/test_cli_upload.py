from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest
import typer
from typer.testing import CliRunner

from scraper import cli
from scraper.bank_map import BankMap
from scraper.upload_state import UploadedState, sha256_file


def _pdf(directory: Path, name: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    p = directory / name
    p.write_bytes(b"%PDF-1.4 " + name.encode())
    return p


class FakeClient:
    """Stand-in for ScraperClient: echoes v2 responses, fails for given banks."""

    upload_url = "https://abc.supabase.co/functions/v1/statements-upload"

    def __init__(self, fail_banks: set[str] | None = None, status: str = "queued") -> None:
        self.fail_banks = fail_banks or set()
        self.status = status
        self.calls: list[tuple[str | None, list[str]]] = []

    def upload_pdfs(self, files: list[Path], bank_code: str | None = None) -> dict:
        self.calls.append((bank_code, [f.name for f in files]))
        if bank_code in self.fail_banks:
            raise RuntimeError("Upload failed 500: boom")
        return {
            "uploads": [
                {"filename": f.name, "doc_code": f"doc_{f.stem}", "status": self.status} for f in files
            ]
        }


# ---------------------------------------------------------------------------
# continue-on-failure
# ---------------------------------------------------------------------------


def test_upload_groups_continues_after_failure(tmp_path: Path) -> None:
    incoming = tmp_path / "incoming"
    fab = _pdf(incoming, "fab.pdf")
    adcb = _pdf(incoming, "adcb.pdf")
    sib = _pdf(incoming, "sib.pdf")
    state = UploadedState(tmp_path / "state")
    client = FakeClient(fail_banks={"ADCB"})

    failures = cli._upload_groups(client, {"FAB": [fab], "ADCB": [adcb], "SIB": [sib]}, state)

    assert [c[0] for c in client.calls] == ["FAB", "ADCB", "SIB"]
    assert [(code, [p.name for p in files]) for code, files, _ in failures] == [("ADCB", ["adcb.pdf"])]
    assert state.is_uploaded(sha256_file(fab))
    assert state.is_uploaded(sha256_file(sib))
    assert not state.is_uploaded(sha256_file(adcb))


def test_report_failures_exits_non_zero(tmp_path: Path) -> None:
    with pytest.raises(typer.Exit) as exc_info:
        cli._report_failures([("ADCB", [tmp_path / "a.pdf"], "boom")], "alice")
    assert exc_info.value.exit_code == 1


def test_report_failures_noop_when_empty() -> None:
    cli._report_failures([], "alice")  # does not raise


# ---------------------------------------------------------------------------
# uploaded.json recording
# ---------------------------------------------------------------------------


def test_record_uploaded_v2_stores_doc_code_and_status(tmp_path: Path) -> None:
    a = _pdf(tmp_path / "in", "a.pdf")
    b = _pdf(tmp_path / "in", "b.pdf")
    state = UploadedState(tmp_path / "state")
    result = {"uploads": [{"filename": "a.pdf", "doc_code": "doc_a", "status": "duplicate"}]}

    cli._record_uploaded(state, [a, b], result, "FAB")

    entry = state.get(sha256_file(a))
    assert entry is not None
    assert entry["doc_code"] == "doc_a"
    assert entry["status"] == "duplicate"
    assert entry["bank_code"] == "FAB"
    assert entry["filename"] == "a.pdf"
    assert "uploaded_at" in entry
    # b.pdf was not echoed back by the server, so it is not marked uploaded.
    assert not state.is_uploaded(sha256_file(b))


def test_record_uploaded_legacy_response_marks_all(tmp_path: Path) -> None:
    a = _pdf(tmp_path / "in", "a.pdf")
    state = UploadedState(tmp_path / "state")

    cli._record_uploaded(state, [a], {"job_id": "123"}, None)

    entry = state.get(sha256_file(a))
    assert entry is not None and entry["status"] == "uploaded" and entry["doc_code"] is None


def test_uploaded_state_corrupt_file_starts_fresh(tmp_path: Path) -> None:
    (tmp_path / "uploaded.json").write_text("{not json")
    assert UploadedState(tmp_path).is_uploaded("abc") is False


def test_record_uploaded_matches_padded_name(tmp_path: Path) -> None:
    padded = _pdf(tmp_path / "in", " fab statement.pdf ")
    state = UploadedState(tmp_path / "state")
    result = {"uploads": [{"filename": "fab statement.pdf", "doc_code": "doc_p", "status": "queued"}]}

    cli._record_uploaded(state, [padded], result, "FAB")

    entry = state.get(sha256_file(padded))
    assert entry is not None and entry["doc_code"] == "doc_p"
    assert entry["filename"] == " fab statement.pdf "  # the local name is what is kept


def test_record_uploaded_matches_long_name_truncated_by_server(tmp_path: Path) -> None:
    long_pdf = _pdf(tmp_path / "in", "x" * 230 + ".pdf")
    state = UploadedState(tmp_path / "state")
    echoed = long_pdf.name[-200:]
    result = {"uploads": [{"filename": echoed, "doc_code": "doc_l", "status": "queued"}]}

    cli._record_uploaded(state, [long_pdf], result, None)

    entry = state.get(sha256_file(long_pdf))
    assert entry is not None and entry["doc_code"] == "doc_l"


def test_record_uploaded_same_name_matches_entries_in_order(tmp_path: Path) -> None:
    first = _pdf(tmp_path / "a", "stmt.pdf")
    second = tmp_path / "b" / "stmt.pdf"
    second.parent.mkdir()
    second.write_bytes(b"%PDF-1.4 other")
    state = UploadedState(tmp_path / "state")
    result = {
        "uploads": [
            {"filename": "stmt.pdf", "doc_code": "doc_1", "status": "queued"},
            {"filename": "stmt.pdf", "doc_code": "doc_2", "status": "duplicate"},
        ]
    }

    cli._record_uploaded(state, [first, second], result, None)

    assert state.get(sha256_file(first))["doc_code"] == "doc_1"  # type: ignore[index]
    assert state.get(sha256_file(second))["doc_code"] == "doc_2"  # type: ignore[index]


# ---------------------------------------------------------------------------
# upload-pending selection
# ---------------------------------------------------------------------------


def _setup_profile(tmp_path: Path) -> tuple[Path, BankMap, UploadedState, dict[str, Path]]:
    incoming = tmp_path / "incoming"
    state_dir = tmp_path / "state"
    bank_map = BankMap(state_dir)
    files = {
        "fab1": _pdf(incoming, "fab1.pdf"),
        "fab2": _pdf(incoming, "fab2.pdf"),
        "adcb": _pdf(incoming, "adcb.PDF"),
        "untracked": _pdf(incoming, "untracked.pdf"),
    }
    bank_map.record(files["fab1"], "FAB")
    bank_map.record(files["fab2"], "fab")
    bank_map.record(files["adcb"], "ADCB")
    uploaded = UploadedState(state_dir)
    uploaded.record_many({sha256_file(files["fab1"]): {"filename": "fab1.pdf", "status": "queued"}})
    return incoming, bank_map, uploaded, files


def test_collect_pending_skips_uploaded_and_untracked(tmp_path: Path) -> None:
    incoming, bank_map, uploaded, files = _setup_profile(tmp_path)

    groups, skipped = cli._collect_pending(incoming, bank_map, uploaded)

    assert skipped == 1
    assert groups == {"FAB": [files["fab2"]], "ADCB": [files["adcb"]]}


def test_collect_pending_force_includes_uploaded(tmp_path: Path) -> None:
    incoming, bank_map, uploaded, files = _setup_profile(tmp_path)

    groups, skipped = cli._collect_pending(incoming, bank_map, uploaded, force=True)

    assert skipped == 0
    assert groups == {"FAB": [files["fab1"], files["fab2"]], "ADCB": [files["adcb"]]}


def test_collect_pending_bank_filter(tmp_path: Path) -> None:
    incoming, bank_map, uploaded, files = _setup_profile(tmp_path)

    groups, _ = cli._collect_pending(incoming, bank_map, uploaded, bank_filter={"ADCB"})

    assert groups == {"ADCB": [files["adcb"]]}


def test_collect_pending_missing_incoming_dir(tmp_path: Path) -> None:
    groups, skipped = cli._collect_pending(
        tmp_path / "nope", BankMap(tmp_path / "state"), UploadedState(tmp_path / "state")
    )
    assert groups == {} and skipped == 0


# ---------------------------------------------------------------------------
# upload-pending command end to end (fake config + client)
# ---------------------------------------------------------------------------


def _patch_cli(monkeypatch: pytest.MonkeyPatch, download_dir: Path, client: FakeClient) -> None:
    cfg = SimpleNamespace(download_dir=download_dir)
    monkeypatch.setattr("scraper.config.get_config", lambda profile: cfg)
    monkeypatch.setattr(cli, "_make_client", lambda _cfg: client)


def test_upload_pending_command_uploads_then_skips(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _, _, _, files = _setup_profile(tmp_path)
    client = FakeClient()
    _patch_cli(monkeypatch, tmp_path, client)
    runner = CliRunner()

    first = runner.invoke(cli.app, ["upload-pending", "--profile", "alice"])
    assert first.exit_code == 0, first.output
    assert sorted(client.calls) == [("ADCB", ["adcb.PDF"]), ("FAB", ["fab2.pdf"])]

    client.calls.clear()
    second = runner.invoke(cli.app, ["upload-pending", "--profile", "alice"])
    assert second.exit_code == 0, second.output
    assert client.calls == []
    assert "No pending PDFs" in second.output

    forced = runner.invoke(cli.app, ["upload-pending", "--profile", "alice", "--force", "--banks", "fab"])
    assert forced.exit_code == 0, forced.output
    assert client.calls == [("FAB", ["fab1.pdf", "fab2.pdf"])]


def test_upload_pending_command_exits_non_zero_on_failure(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _setup_profile(tmp_path)
    client = FakeClient(fail_banks={"FAB"})
    _patch_cli(monkeypatch, tmp_path, client)

    result = CliRunner().invoke(cli.app, ["upload-pending", "--profile", "alice"])

    assert result.exit_code == 1
    # ADCB was still uploaded even though FAB failed.
    assert ("ADCB", ["adcb.PDF"]) in client.calls
    assert UploadedState(tmp_path / "state").is_uploaded(sha256_file(tmp_path / "incoming" / "adcb.PDF"))


def test_upload_groups_records_the_batches_that_succeeded(tmp_path: Path) -> None:
    from scraper.client import UploadBatchError

    ok = [_pdf(tmp_path, f"ok{i}.pdf") for i in range(2)]
    bad = [_pdf(tmp_path, "bad.pdf")]

    class PartialClient(FakeClient):
        def upload_pdfs(self, files, bank_code=None):
            raise UploadBatchError(
                "1 of 3 file(s) failed to upload: Upload failed 500: boom",
                result={"uploads": [{"filename": f.name, "doc_code": "doc", "status": "queued"} for f in ok]},
                uploaded_files=ok,
                failed_files=bad,
            )

    state = UploadedState(tmp_path / "state")
    failures = cli._upload_groups(PartialClient(), {"FAB": ok + bad}, state)
    assert [(code, [f.name for f in files]) for code, files, _ in failures] == [("FAB", ["bad.pdf"])]
    assert state.is_uploaded(sha256_file(ok[0])) and state.is_uploaded(sha256_file(ok[1]))
    assert not state.is_uploaded(sha256_file(bad[0]))


# ---------------------------------------------------------------------------
# SRV-16r: `upload` on a partial batch failure
# ---------------------------------------------------------------------------


def test_upload_command_records_succeeded_batches_on_partial_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import re

    import httpx

    from scraper.client import ScraperClient

    first = _pdf(tmp_path / "jan", "stmt.pdf")
    second = _pdf(tmp_path / "feb", "stmt.pdf")
    second.write_bytes(b"%PDF-1.4 february")
    requests: list[list[str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        names = [n.decode() for n in re.findall(rb'name="files"; filename="([^"]+)"', request.read())]
        requests.append(names)
        if len(requests) > 1:
            return httpx.Response(500, json={"error": "boom"})
        uploads = [{"filename": n, "doc_code": "doc_jan", "status": "queued"} for n in names]
        return httpx.Response(200, json={"uploads": uploads})

    client = ScraperClient(
        "https://abc.supabase.co", "tok", "alice", upload_path="/functions/v1/statements-upload",
        transport=httpx.MockTransport(handler), retry_delays=(), sleep=lambda _s: None,
        max_files_per_request=1,
    )
    _patch_cli(monkeypatch, tmp_path, client)  # type: ignore[arg-type]

    result = CliRunner().invoke(cli.app, ["upload", "--profile", "alice", str(first), str(second)])

    assert result.exit_code == 1
    assert isinstance(result.exception, SystemExit)  # a clean exit, not a traceback
    assert requests == [["stmt.pdf"], ["stmt.pdf"]]
    state = UploadedState(tmp_path / "state")
    entry = state.get(sha256_file(first))
    assert entry is not None and entry["doc_code"] == "doc_jan"
    assert not state.is_uploaded(sha256_file(second))
    assert "PARTIALLY FAILED" in result.output
    assert f"    {second}" in result.output
    assert f"Retry with: ccs-scraper upload --profile alice {second}" in result.output


def test_upload_command_total_failure_exits_cleanly(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pdf = _pdf(tmp_path / "in", "a.pdf")
    _patch_cli(monkeypatch, tmp_path, FakeClient(fail_banks={None}))  # type: ignore[arg-type]

    result = CliRunner().invoke(cli.app, ["upload", "--profile", "alice", str(pdf)])

    assert result.exit_code == 1
    assert isinstance(result.exception, SystemExit)
    assert "Upload FAILED" in result.output and f"    {pdf}" in result.output
    assert not UploadedState(tmp_path / "state").is_uploaded(sha256_file(pdf))


def test_upload_command_records_all_on_success(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pdf = _pdf(tmp_path / "in", "a.pdf")
    _patch_cli(monkeypatch, tmp_path, FakeClient())

    result = CliRunner().invoke(cli.app, ["upload", "--profile", "alice", str(pdf)])

    assert result.exit_code == 0, result.output
    assert UploadedState(tmp_path / "state").get(sha256_file(pdf))["doc_code"] == "doc_a"  # type: ignore[index]

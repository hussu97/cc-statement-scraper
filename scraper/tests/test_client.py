from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from scraper.client import ScraperClient


def test_upload_raises_on_empty_file_list() -> None:
    client = ScraperClient("http://localhost:8040", "tok", "profile")
    with pytest.raises(ValueError, match="No files"):
        client.upload_pdfs([])


def test_upload_raises_without_api_token(tmp_path: Path) -> None:
    pdf = tmp_path / "stmt.pdf"
    pdf.write_bytes(b"%PDF")
    client = ScraperClient("http://localhost:8040", "", "profile")
    with pytest.raises(RuntimeError, match="API_TOKEN"):
        client.upload_pdfs([pdf])


def test_upload_posts_to_correct_url(tmp_path: Path) -> None:
    pdf = tmp_path / "statement.pdf"
    pdf.write_bytes(b"%PDF-1.4 content")

    with patch("scraper.client.httpx.Client") as MockClient:
        mock_http = MagicMock()
        MockClient.return_value.__enter__ = MagicMock(return_value=mock_http)
        mock_http.post.return_value.json.return_value = {"job_id": "123"}
        mock_http.post.return_value.raise_for_status.return_value = None

        ScraperClient("http://api.example.com", "tok_abc", "hussain").upload_pdfs([pdf])

    url = mock_http.post.call_args[0][0]
    assert url == "http://api.example.com/api/v1/jobs/upload"


def test_upload_sends_auth_headers(tmp_path: Path) -> None:
    pdf = tmp_path / "statement.pdf"
    pdf.write_bytes(b"%PDF-1.4")

    with patch("scraper.client.httpx.Client") as MockClient:
        mock_http = MagicMock()
        MockClient.return_value.__enter__ = MagicMock(return_value=mock_http)
        mock_http.post.return_value.json.return_value = {}
        mock_http.post.return_value.raise_for_status.return_value = None

        ScraperClient("http://api.example.com", "tok_secret", "myprofile").upload_pdfs([pdf])

    headers = mock_http.post.call_args[1]["headers"]
    assert headers["Authorization"] == "Bearer tok_secret"
    assert headers["X-Profile-Key"] == "myprofile"


def test_upload_sends_file_as_multipart(tmp_path: Path) -> None:
    pdf = tmp_path / "my_statement.pdf"
    pdf.write_bytes(b"%PDF-1.4")

    with patch("scraper.client.httpx.Client") as MockClient:
        mock_http = MagicMock()
        MockClient.return_value.__enter__ = MagicMock(return_value=mock_http)
        mock_http.post.return_value.json.return_value = {}
        mock_http.post.return_value.raise_for_status.return_value = None

        ScraperClient("http://localhost", "tok", "p").upload_pdfs([pdf])

    files = mock_http.post.call_args[1]["files"]
    assert len(files) == 1
    field_name, (filename, _fh, mime_type) = files[0]
    assert field_name == "files"
    assert filename == "my_statement.pdf"
    assert mime_type == "application/pdf"


def test_upload_returns_response_json(tmp_path: Path) -> None:
    pdf = tmp_path / "stmt.pdf"
    pdf.write_bytes(b"%PDF")
    expected = {"job_id": "abc-123", "status": "queued"}

    with patch("scraper.client.httpx.Client") as MockClient:
        mock_http = MagicMock()
        MockClient.return_value.__enter__ = MagicMock(return_value=mock_http)
        mock_http.post.return_value.json.return_value = expected
        mock_http.post.return_value.raise_for_status.return_value = None

        result = ScraperClient("http://localhost", "tok", "p").upload_pdfs([pdf])

    assert result == expected


def test_upload_multiple_files_sends_all_in_multipart(tmp_path: Path) -> None:
    pdfs = []
    for name in ["jan.pdf", "feb.pdf", "mar.pdf"]:
        p = tmp_path / name
        p.write_bytes(b"%PDF")
        pdfs.append(p)

    with patch("scraper.client.httpx.Client") as MockClient:
        mock_http = MagicMock()
        MockClient.return_value.__enter__ = MagicMock(return_value=mock_http)
        mock_http.post.return_value.json.return_value = {}
        mock_http.post.return_value.raise_for_status.return_value = None

        ScraperClient("http://localhost", "tok", "p").upload_pdfs(pdfs)

    files = mock_http.post.call_args[1]["files"]
    assert len(files) == 3
    filenames = [f[1][0] for f in files]
    assert set(filenames) == {"jan.pdf", "feb.pdf", "mar.pdf"}


def test_trailing_slash_stripped_from_base_url() -> None:
    client = ScraperClient("http://api.example.com/", "tok", "profile")
    assert client._base_url == "http://api.example.com"


# ---------------------------------------------------------------------------
# URL building, headers, response parsing and retries (httpx.MockTransport)
# ---------------------------------------------------------------------------

import httpx  # noqa: E402

from scraper.client import build_upload_url, parse_upload_response, summarize_uploads  # noqa: E402

_V2_PATH = "/functions/v1/statements-upload"


def _pdf(tmp_path: Path, name: str = "stmt.pdf") -> Path:
    p = tmp_path / name
    p.write_bytes(b"%PDF-1.4 " + name.encode())
    return p


def _client(handler, *, anon_key: str | None = None, upload_path: str = _V2_PATH, sleeps: list | None = None) -> ScraperClient:
    return ScraperClient(
        "https://abc.supabase.co",
        "tok",
        "hussain",
        upload_path=upload_path,
        anon_key=anon_key,
        transport=httpx.MockTransport(handler),
        retry_delays=(1, 2, 3),
        sleep=(sleeps.append if sleeps is not None else (lambda _s: None)),
    )


@pytest.mark.parametrize(
    ("base", "path", "expected"),
    [
        ("http://127.0.0.1:8040", "/api/v1/jobs/upload", "http://127.0.0.1:8040/api/v1/jobs/upload"),
        ("https://abc.supabase.co/", _V2_PATH, "https://abc.supabase.co/functions/v1/statements-upload"),
        ("https://abc.supabase.co", "functions/v1/statements-upload", "https://abc.supabase.co/functions/v1/statements-upload"),
        ("http://127.0.0.1:8040", "", "http://127.0.0.1:8040/api/v1/jobs/upload"),
    ],
)
def test_build_upload_url(base: str, path: str, expected: str) -> None:
    assert build_upload_url(base, path) == expected


def test_default_upload_path_is_legacy() -> None:
    assert ScraperClient("http://127.0.0.1:8040", "tok", "p").upload_url == "http://127.0.0.1:8040/api/v1/jobs/upload"


def test_upload_posts_to_v2_path_with_hint(tmp_path: Path) -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"uploads": []})

    _client(handler).upload_pdfs([_pdf(tmp_path)], bank_code="FAB")

    req = seen[0]
    assert str(req.url) == "https://abc.supabase.co/functions/v1/statements-upload"
    body = req.read()
    assert b'name="bank_code_hint"' in body and b"FAB" in body
    assert b'name="files"; filename="stmt.pdf"' in body
    assert b"application/pdf" in body


def test_apikey_header_sent_when_configured(tmp_path: Path) -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={})

    _client(handler, anon_key="anon_123").upload_pdfs([_pdf(tmp_path)])
    headers = seen[0].headers
    assert headers["apikey"] == "anon_123"
    assert headers["Authorization"] == "Bearer tok"
    assert headers["X-Profile-Key"] == "hussain"


def test_apikey_header_omitted_when_not_configured(tmp_path: Path) -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={})

    _client(handler).upload_pdfs([_pdf(tmp_path)])
    assert "apikey" not in seen[0].headers


def test_upload_returns_parsed_v2_response(tmp_path: Path) -> None:
    payload = {
        "uploads": [
            {"filename": "a.pdf", "doc_code": "doc_1", "status": "queued"},
            {"filename": "b.pdf", "doc_code": "doc_2", "status": "duplicate"},
        ]
    }
    result = _client(lambda r: httpx.Response(200, json=payload)).upload_pdfs(
        [_pdf(tmp_path, "a.pdf"), _pdf(tmp_path, "b.pdf")]
    )
    assert result == payload
    assert summarize_uploads(parse_upload_response(result)) == {"queued": 1, "duplicate": 1}


def test_upload_non_json_success_body_wrapped(tmp_path: Path) -> None:
    result = _client(lambda r: httpx.Response(200, text="ok")).upload_pdfs([_pdf(tmp_path)])
    assert result == {"raw": "ok"}


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        ({"uploads": [{"filename": "a.pdf", "status": "queued"}]}, [{"filename": "a.pdf", "status": "queued"}]),
        ({"job_id": "123"}, []),
        ({"uploads": "nope"}, []),
        ({"uploads": [1, {"status": "duplicate"}]}, [{"status": "duplicate"}]),
        ("text", []),
        (None, []),
    ],
)
def test_parse_upload_response(body, expected) -> None:
    assert parse_upload_response(body) == expected


def test_summarize_uploads_counts_missing_status_as_unknown() -> None:
    uploads = [{"status": "queued"}, {"status": "queued"}, {}]
    assert summarize_uploads(uploads) == {"queued": 2, "unknown": 1}


def test_4xx_fails_without_retry(tmp_path: Path) -> None:
    calls: list[int] = []
    sleeps: list[float] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        return httpx.Response(403, json={"error": "missing scope statements:upload"})

    with pytest.raises(RuntimeError, match="403"):
        _client(handler, sleeps=sleeps).upload_pdfs([_pdf(tmp_path)])
    assert len(calls) == 1
    assert sleeps == []


def test_5xx_retried_then_succeeds(tmp_path: Path) -> None:
    statuses = iter([500, 502, 200])
    sleeps: list[float] = []

    def handler(request: httpx.Request) -> httpx.Response:
        status = next(statuses)
        return httpx.Response(status, json={"uploads": []} if status == 200 else {"error": "boom"})

    result = _client(handler, sleeps=sleeps).upload_pdfs([_pdf(tmp_path)])
    assert result == {"uploads": []}
    assert sleeps == [1, 2]


def test_retry_resends_identical_file_bytes(tmp_path: Path) -> None:
    bodies: list[bytes] = []
    statuses = iter([503, 200])

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append(request.read())
        return httpx.Response(next(statuses), json={})

    _client(handler).upload_pdfs([_pdf(tmp_path, "x.pdf")])
    assert len(bodies) == 2
    assert b"%PDF-1.4 x.pdf" in bodies[0] and b"%PDF-1.4 x.pdf" in bodies[1]


def test_network_errors_retried_then_raised(tmp_path: Path) -> None:
    calls: list[int] = []
    sleeps: list[float] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        raise httpx.ConnectError("connection refused", request=request)

    with pytest.raises(httpx.ConnectError):
        _client(handler, sleeps=sleeps).upload_pdfs([_pdf(tmp_path)])
    assert len(calls) == 4
    assert sleeps == [1, 2, 3]


def test_persistent_5xx_raises_after_all_attempts(tmp_path: Path) -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        return httpx.Response(500, text="internal")

    with pytest.raises(RuntimeError, match="500"):
        _client(handler).upload_pdfs([_pdf(tmp_path)])
    assert len(calls) == 4


def test_single_http_client_reused_across_retries(tmp_path: Path) -> None:
    statuses = iter([500, 200])
    real_client = httpx.Client

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(next(statuses), json={})

    with patch("scraper.client.httpx.Client", side_effect=real_client) as spy:
        _client(handler).upload_pdfs([_pdf(tmp_path)])
    assert spy.call_count == 1


# ---------------------------------------------------------------------------
# SRV-02: batching to the server's per-request limits, 413 splitting
# ---------------------------------------------------------------------------

from scraper.client import UploadBatchError, chunk_payload, merge_results  # noqa: E402
from scraper.config import UPLOAD_MAX_FILES_PER_REQUEST, upload_max_bytes, upload_max_files  # noqa: E402


def _filenames(request: httpx.Request) -> list[str]:
    import re

    return re.findall(rb'name="files"; filename="([^"]+)"', request.read())


def _echo(request: httpx.Request) -> httpx.Response:
    return httpx.Response(
        200,
        json={"uploads": [{"filename": n.decode(), "doc_code": "doc", "status": "queued"} for n in _filenames(request)]},
    )


def test_chunk_payload_by_count_and_bytes() -> None:
    items = [(f"{i}.pdf", b"x" * 10) for i in range(45)]
    assert [len(b) for b in chunk_payload(items, 20, 10_000)] == [20, 20, 5]
    assert [len(b) for b in chunk_payload(items, 20, 35)] == [3] * 15
    big = [("big.pdf", b"x" * 100), ("a.pdf", b"x")]
    assert [len(b) for b in chunk_payload(big, 20, 50)] == [1, 1]


def test_upload_limits_default_and_clamped(monkeypatch) -> None:
    assert UPLOAD_MAX_FILES_PER_REQUEST == 20
    monkeypatch.setenv("CCS_SCRAPER_UPLOAD_MAX_FILES", "5")
    assert upload_max_files() == 5
    monkeypatch.setenv("CCS_SCRAPER_UPLOAD_MAX_FILES", "500")
    assert upload_max_files() == 20
    monkeypatch.setenv("CCS_SCRAPER_UPLOAD_MAX_MB", "999")
    assert upload_max_bytes() == 32 * 1024 * 1024


def test_45_files_go_in_three_requests_of_at_most_20(tmp_path: Path) -> None:
    seen: list[list[bytes]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(_filenames(request))
        return _echo(request)

    files = [_pdf(tmp_path, f"s{i:02}.pdf") for i in range(45)]
    result = _client(handler).upload_pdfs(files, bank_code="FAB")
    assert [len(names) for names in seen] == [20, 20, 5]
    assert len(result["uploads"]) == 45
    assert [u["filename"] for u in result["uploads"]] == [f.name for f in files]


def test_413_splits_the_batch_and_retries(tmp_path: Path) -> None:
    sizes: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        names = _filenames(request)
        sizes.append(len(names))
        if len(names) > 3:
            return httpx.Response(413, json={"error": {"code": "TOO_MANY_FILES"}})
        return _echo(request)

    files = [_pdf(tmp_path, f"s{i}.pdf") for i in range(8)]
    result = _client(handler).upload_pdfs(files)
    assert sizes == [8, 4, 2, 2, 4, 2, 2]
    assert len(result["uploads"]) == 8


def test_413_for_a_single_file_fails_without_retry(tmp_path: Path) -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        return httpx.Response(413, json={"error": {"code": "FILE_TOO_LARGE"}})

    with pytest.raises(RuntimeError, match="413"):
        _client(handler).upload_pdfs([_pdf(tmp_path)])
    assert calls == [1]


def test_partial_failure_reports_uploaded_and_failed_files(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if b"s20.pdf" in _filenames(request):
            return httpx.Response(422, json={"error": {"code": "NOT_A_PDF"}})
        return _echo(request)

    files = [_pdf(tmp_path, f"s{i:02}.pdf") for i in range(25)]
    with pytest.raises(UploadBatchError) as err:
        _client(handler).upload_pdfs(files)
    assert [f.name for f in err.value.uploaded_files] == [f.name for f in files[:20]]
    assert [f.name for f in err.value.failed_files] == [f.name for f in files[20:]]
    assert len(err.value.result["uploads"]) == 20


def test_merge_results_legacy_and_v2() -> None:
    assert merge_results([{"job_id": 1}]) == {"job_id": 1}
    assert merge_results([{"uploads": [1]}, {"uploads": [2]}]) == {"uploads": [1, 2]}
    assert merge_results([{"job_id": 1}, {"job_id": 2}]) == {"batches": [{"job_id": 1}, {"job_id": 2}]}

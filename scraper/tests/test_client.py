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

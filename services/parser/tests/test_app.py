from __future__ import annotations

import httpx
import pytest
from fastapi.testclient import TestClient

from ccs_parser import app as app_module
from ccs_parser.contract import ErrorResponse
from ccs_parser.domain.parsing.models import ParserError

SECRET = "test-secret-value"
URL = "https://abc.supabase.co/storage/v1/object/sign/statements/ADCB_20260801.pdf?token=t0k3n"


@pytest.fixture
def client(monkeypatch) -> TestClient:
    monkeypatch.setenv("PARSER_SECRET", SECRET)
    monkeypatch.delenv("SENTRY_DSN", raising=False)
    monkeypatch.delenv("PARSER_ALLOWED_HOSTS", raising=False)
    return TestClient(app_module.create_app(), raise_server_exceptions=False)


def _post(client: TestClient, body: dict | None = None, secret: str | None = SECRET):
    headers = {"X-Parser-Secret": secret} if secret is not None else {}
    return client.post("/parse", json=body or {"document_url": URL}, headers=headers)


def _assert_error(response, status: int, code: str) -> None:
    assert response.status_code == status, response.text
    ErrorResponse.model_validate(response.json())
    assert response.json()["error"]["code"] == code


def test_health(client) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


@pytest.mark.parametrize("secret", [None, "", "wrong-secret", SECRET + "x"])
def test_parse_rejects_bad_secret(client, secret) -> None:
    _assert_error(_post(client, secret=secret), 401, "UNAUTHORIZED")


def test_parse_fails_closed_without_configured_secret(client, monkeypatch) -> None:
    monkeypatch.delenv("PARSER_SECRET", raising=False)
    _assert_error(_post(client), 401, "UNAUTHORIZED")


def test_auth_checked_before_body_validation(client) -> None:
    _assert_error(client.post("/parse", json={"nope": 1}), 401, "UNAUTHORIZED")


def test_invalid_body_is_422_invalid_request(client) -> None:
    _assert_error(_post(client, body={"filename": "x.pdf"}), 422, "INVALID_REQUEST")


@pytest.mark.parametrize(
    ("code", "status"),
    [
        ("PDF_DECRYPT_FAILED", 422),
        ("UNSUPPORTED_BANK", 422),
        ("UNSUPPORTED_LAYOUT", 422),
        ("BANK_UNDETECTED", 422),
        ("SOMETHING_ELSE", 500),
    ],
)
def test_parser_error_mapping(client, monkeypatch, code, status) -> None:
    monkeypatch.setattr(app_module, "download_document", lambda url, dest: dest.write_bytes(b"%PDF") or 4)

    def _raise(*_a, **_k):
        raise ParserError(code, "boom")

    monkeypatch.setattr(app_module, "parse_document", _raise)
    _assert_error(_post(client), status, code if status == 422 else "INTERNAL_ERROR")


def test_unexpected_exception_is_500(client, monkeypatch) -> None:
    monkeypatch.setattr(app_module, "download_document", lambda url, dest: dest.write_bytes(b"%PDF") or 4)
    monkeypatch.setattr(app_module, "parse_document", lambda *_a, **_k: 1 / 0)
    _assert_error(_post(client), 500, "INTERNAL_ERROR")


def test_parse_success_passes_request_through(client, monkeypatch) -> None:
    seen: dict = {}
    monkeypatch.setattr(app_module, "download_document", lambda url, dest: dest.write_bytes(b"%PDF") or 4)

    def _parse(path, *, filename, bank_code_hint, settings):
        seen.update(filename=filename, hint=bank_code_hint, settings=settings, exists=path.exists())
        return {"bank_code": "ADCB", "document_kind": "statement_pdf", "statements": []}

    monkeypatch.setattr(app_module, "parse_document", _parse)
    body = {"document_url": URL, "bank_code_hint": "ADCB", "settings": {"ADCB_PDF_PASSWORD": "pw"}}
    response = _post(client, body=body)
    assert response.status_code == 200
    assert response.json()["bank_code"] == "ADCB"
    # filename defaults to the URL path's basename (never the signed query string)
    assert seen == {
        "filename": "ADCB_20260801.pdf",
        "hint": "ADCB",
        "settings": {"ADCB_PDF_PASSWORD": "pw"},
        "exists": True,
    }


def test_debug_sentry_route_only_outside_production(monkeypatch) -> None:
    monkeypatch.setenv("PARSER_SECRET", SECRET)
    monkeypatch.setenv("SENTRY_ENVIRONMENT", "production")
    prod = TestClient(app_module.create_app(), raise_server_exceptions=False)
    assert prod.get("/debug-sentry", headers={"X-Parser-Secret": SECRET}).status_code == 404
    monkeypatch.setenv("SENTRY_ENVIRONMENT", "staging")
    dev = TestClient(app_module.create_app(), raise_server_exceptions=False)
    assert dev.get("/debug-sentry", headers={"X-Parser-Secret": SECRET}).status_code == 500


# ------------------------------------------------------------------ download


def _transport(status: int = 200, body: bytes = b"%PDF-1.4 data", headers: dict | None = None) -> httpx.MockTransport:
    return httpx.MockTransport(lambda request: httpx.Response(status, content=body, headers=headers or {}))


def test_download_writes_file(tmp_path) -> None:
    dest = tmp_path / "d.pdf"
    assert app_module.download_document(URL, dest, transport=_transport()) == 13
    assert dest.read_bytes() == b"%PDF-1.4 data"


@pytest.mark.parametrize(
    ("status", "expected"), [(404, 422), (403, 422), (400, 422), (500, 502), (503, 502), (429, 502)]
)
def test_download_status_mapping(tmp_path, status, expected) -> None:
    with pytest.raises(app_module.ServiceError) as exc:
        app_module.download_document(URL, tmp_path / "d.pdf", transport=_transport(status=status))
    assert exc.value.status_code == expected
    assert exc.value.code == "DOWNLOAD_FAILED"


def test_download_too_large(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("PARSER_MAX_DOWNLOAD_MB", "0.001")  # ~1 KB
    with pytest.raises(app_module.ServiceError) as exc:
        app_module.download_document(URL, tmp_path / "d.pdf", transport=_transport(body=b"x" * 5000))
    assert (exc.value.status_code, exc.value.code) == (422, "DOWNLOAD_FAILED")


def test_download_timeout_is_transient(tmp_path) -> None:
    def _timeout(request):
        raise httpx.ReadTimeout("slow", request=request)

    with pytest.raises(app_module.ServiceError) as exc:
        app_module.download_document(URL, tmp_path / "d.pdf", transport=httpx.MockTransport(_timeout))
    assert exc.value.status_code == 502


@pytest.mark.parametrize(
    "url", ["http://abc.supabase.co/x.pdf", "file:///etc/passwd", "ftp://h/x.pdf", "https:///x.pdf"]
)
def test_download_rejects_bad_urls(tmp_path, url) -> None:
    with pytest.raises(app_module.ServiceError) as exc:
        app_module.download_document(url, tmp_path / "d.pdf", transport=_transport())
    assert exc.value.status_code == 422


def test_download_host_allow_list(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("PARSER_ALLOWED_HOSTS", "other.supabase.co")
    with pytest.raises(app_module.ServiceError):
        app_module.download_document(URL, tmp_path / "d.pdf", transport=_transport())
    monkeypatch.setenv("PARSER_ALLOWED_HOSTS", "abc.supabase.co")
    assert app_module.download_document(URL, tmp_path / "d.pdf", transport=_transport()) > 0

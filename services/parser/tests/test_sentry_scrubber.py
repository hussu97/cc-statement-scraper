from __future__ import annotations

import json

from ccs_parser.sentry import FILTERED, scrub_event, strip_query

SIGNED_URL = "https://abc.supabase.co/storage/v1/object/sign/statements/doc.pdf?token=eyJhbGciOiJIUzI1NiJ9.secret-part"


def _event() -> dict:
    return {
        "request": {
            "url": SIGNED_URL,
            "method": "POST",
            "query_string": "token=eyJhbGciOiJIUzI1NiJ9.secret-part",
            "data": {
                "document_url": SIGNED_URL,
                "settings": {"ADCB_PDF_PASSWORD": "hunter2", "SIB_PDF_PASSWORD": "pw-sib"},
            },
            "cookies": {"session": "abc"},
            "headers": {
                "X-Parser-Secret": "super-secret-value",
                "Authorization": "Bearer abc.def",
                "Content-Type": "application/json",
                "sentry-trace": "0123456789abcdef0123456789abcdef-0123456789abcdef-1",
            },
        },
        "extra": {
            "settings": {"FAB_PDF_PASSWORD": "fab-pw"},
            "ENBD_PDF_PASSWORD": "enbd-pw",
            "note": f"failed fetching {SIGNED_URL}",
        },
        "exception": {
            "values": [{"type": "HTTPError", "value": f"GET {SIGNED_URL} failed"}],
        },
        "breadcrumbs": {"values": [{"category": "httpx", "data": {"url": SIGNED_URL}}]},
    }


def test_scrubber_removes_body_passwords_tokens_and_auth_headers() -> None:
    scrubbed = scrub_event(_event(), None)
    dumped = json.dumps(scrubbed)

    for secret in ("hunter2", "pw-sib", "fab-pw", "enbd-pw", "super-secret-value", "Bearer abc.def", "secret-part"):
        assert secret not in dumped, secret

    request = scrubbed["request"]
    assert "data" not in request
    assert "cookies" not in request
    assert "query_string" not in request
    assert request["url"] == "https://abc.supabase.co/storage/v1/object/sign/statements/doc.pdf"
    assert request["headers"]["X-Parser-Secret"] == FILTERED
    assert request["headers"]["Authorization"] == FILTERED
    assert request["headers"]["Content-Type"] == "application/json"
    # Trace propagation headers are not secrets and stay intact.
    assert request["headers"]["sentry-trace"].startswith("0123456789abcdef")
    assert scrubbed["extra"]["settings"] == FILTERED
    assert scrubbed["extra"]["ENBD_PDF_PASSWORD"] == FILTERED


def test_scrubber_handles_list_headers_and_missing_request() -> None:
    event = {"request": {"headers": [["x-parser-secret", "s3cr3t"], ["accept", "*/*"]]}}
    scrubbed = scrub_event(event, None)
    assert ["x-parser-secret", FILTERED] in scrubbed["request"]["headers"]
    assert scrub_event({"message": "plain"}, None) == {"message": "plain"}


def test_strip_query_removes_query_and_fragment() -> None:
    assert strip_query("https://h/p/a.pdf?token=x&y=1#frag") == "https://h/p/a.pdf"
    assert strip_query("https://h/p/a.pdf") == "https://h/p/a.pdf"


def test_init_sentry_disabled_without_dsn(monkeypatch) -> None:
    from ccs_parser.sentry import init_sentry

    monkeypatch.delenv("SENTRY_DSN", raising=False)
    assert init_sentry() is False


def test_init_sentry_wires_scrubber(monkeypatch) -> None:
    import sentry_sdk

    from ccs_parser.sentry import init_sentry

    monkeypatch.setenv("SENTRY_DSN", "https://public@o0.ingest.invalid/1")
    monkeypatch.setenv("SENTRY_ENVIRONMENT", "test")
    monkeypatch.setenv("SENTRY_RELEASE", "ccs-parser@test")
    monkeypatch.delenv("SENTRY_TRACES_SAMPLE_RATE", raising=False)
    try:
        assert init_sentry() is True
        options = sentry_sdk.get_client().options
        assert options["before_send"] is scrub_event
        assert options["send_default_pii"] is False
        assert options["traces_sample_rate"] == 0.2
        assert options["release"] == "ccs-parser@test"
        assert options["environment"] == "test"
    finally:
        sentry_sdk.init(dsn=None)

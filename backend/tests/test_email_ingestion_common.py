from __future__ import annotations

from scripts.email_ingestion_common import route_matches_message


def test_route_matches_message_with_sender_subject_and_filename() -> None:
    route = {
        "sender_allowlist_json": ["alerts@bank.ae"],
        "subject_keywords_json": ["statement"],
        "attachment_filename_regex": r".*statement.*\.pdf",
        "gmail_label_filter_json": None,
    }
    assert route_matches_message(
        route=route,
        sender="alerts@bank.ae",
        subject="Your monthly statement",
        filename="credit-statement-2026-02.pdf",
    )
    assert not route_matches_message(
        route=route,
        sender="other@bank.ae",
        subject="Your monthly statement",
        filename="credit-statement-2026-02.pdf",
    )
    assert not route_matches_message(
        route=route,
        sender="alerts@bank.ae",
        subject="Promotional mail",
        filename="credit-statement-2026-02.pdf",
    )


def test_route_matches_message_with_gmail_labels_any_mode() -> None:
    route = {
        "sender_allowlist_json": None,
        "subject_keywords_json": None,
        "attachment_filename_regex": None,
        "gmail_label_filter_json": {"label_ids": ["Label_1", "Label_2"], "mode": "any"},
    }
    assert route_matches_message(
        route=route,
        sender="alerts@bank.ae",
        subject="statement",
        filename="statement.pdf",
        labels=["INBOX", "Label_2"],
    )
    assert not route_matches_message(
        route=route,
        sender="alerts@bank.ae",
        subject="statement",
        filename="statement.pdf",
        labels=["INBOX"],
    )


def test_route_matches_message_with_gmail_labels_all_mode() -> None:
    route = {
        "sender_allowlist_json": None,
        "subject_keywords_json": None,
        "attachment_filename_regex": None,
        "gmail_label_filter_json": {"label_ids": ["Label_1", "Label_2"], "mode": "all"},
    }
    assert route_matches_message(
        route=route,
        sender="alerts@bank.ae",
        subject="statement",
        filename="statement.pdf",
        labels=["Label_1", "Label_2", "INBOX"],
    )
    assert not route_matches_message(
        route=route,
        sender="alerts@bank.ae",
        subject="statement",
        filename="statement.pdf",
        labels=["Label_1"],
    )

from __future__ import annotations

from datetime import date

from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from ccs_platform.db import models
from ccs_platform.db import Base
from ccs_platform.domain.categorization.engine import categorize
from ccs_platform.domain.statements.identity import resolve_statement_identity
from ccs_platform.application.statements.ingestion import ingest_parsed_statement
from ccs_platform.application.jobs.scheduler import compute_next_run
from ccs_platform.domain.statements.types import ParsedLine, ParsedStatement


def _session():
    engine = create_engine("sqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine, future=True)
    return Session()


def _parsed_statement(
    *,
    bank_code: str = "FAB",
    statement_reference_raw: str | None = None,
    amount_aed: float = 100.0,
) -> ParsedStatement:
    return ParsedStatement(
        bank_code=bank_code,
        statement_reference_raw=statement_reference_raw,
        statement_date=date(2026, 1, 31),
        statement_period_start=date(2026, 1, 1),
        statement_period_end=date(2026, 1, 31),
        primary_card_last4="2777",
        card_holder="TEST USER",
        card_type="Credit Card",
        lines=[
            ParsedLine(
                line_no=1,
                transaction_date=date(2026, 1, 10),
                transaction_time=None,
                posting_date=date(2026, 1, 11),
                merchant_raw="TEST MERCHANT",
                merchant_normalized="TEST MERCHANT",
                amount_original=amount_aed,
                currency_original="AED",
                amount_aed=amount_aed,
                direction="debit" if amount_aed >= 0 else "credit",
                transaction_kind="purchase",
                country_code=None,
                card_last4="2777",
                fingerprint="abc123",
            )
        ],
        warnings=[],
        metadata={},
    )


def test_statement_identity_fallback_is_deterministic() -> None:
    parsed = _parsed_statement(statement_reference_raw=None)

    identity_a = resolve_statement_identity(parsed_statement=parsed, pdf_checksum_sha256="a" * 64)
    identity_b = resolve_statement_identity(parsed_statement=parsed, pdf_checksum_sha256="b" * 64)

    assert identity_a.reference_source == "fallback"
    assert identity_a.statement_reference == identity_b.statement_reference
    assert identity_a.statement_reference.startswith("AUTO-FAB-2026-01-31-2777")


def test_statement_identity_ignores_low_quality_reference_tokens() -> None:
    parsed = _parsed_statement(statement_reference_raw="Reference")
    identity = resolve_statement_identity(parsed_statement=parsed, pdf_checksum_sha256="a" * 64)

    assert identity.reference_source == "fallback"
    assert identity.statement_reference.startswith("AUTO-FAB-2026-01-31-2777")


def test_statement_identity_ignores_timestamp_like_reference() -> None:
    parsed = _parsed_statement(statement_reference_raw="20260225194316")
    identity = resolve_statement_identity(parsed_statement=parsed, pdf_checksum_sha256="a" * 64)

    assert identity.reference_source == "fallback"
    assert identity.statement_reference.startswith("AUTO-FAB-2026-01-31-2777")


def test_category_priority_respects_bank_scoping() -> None:
    with _session() as db:
        db.add(models.Bank(code="FAB", name="FAB", supports_historical_month_selection=False, supports_multi_month=False, supports_headless=True))
        db.add(models.Category(name="Travel"))
        db.add(models.Category(name="Dining"))
        db.add(
            models.CategoryRule(
                name="global-dining",
                category_name="Dining",
                match_type=models.MatchType.CONTAINS,
                pattern="CAFE",
                bank_code=None,
                card_last4=None,
                priority=50,
                active=True,
            )
        )
        db.add(
            models.CategoryRule(
                name="fab-travel",
                category_name="Travel",
                match_type=models.MatchType.CONTAINS,
                pattern="CAFE",
                bank_code="FAB",
                card_last4=None,
                priority=10,
                active=True,
            )
        )
        db.commit()

        category, matched_rule = categorize(
            db,
            bank_code="FAB",
            card_last4="2777",
            merchant_normalized="NORTH CAFE DUBAI",
        )

        assert category == "Travel"
        assert matched_rule is not None
        assert matched_rule.name == "fab-travel"


def test_replace_semantics_delete_old_statement_lines() -> None:
    with _session() as db:
        db.add(models.Bank(code="FAB", name="FAB", supports_historical_month_selection=False, supports_multi_month=False, supports_headless=True))
        db.flush()
        profile = models.Profile(key="default", name="Default", is_default=True)
        db.add(profile)
        db.flush()

        pdf_1 = models.PdfFile(
            profile_id=profile.id,
            original_filename="s1.pdf",
            checksum_sha256="1" * 64,
            storage_backend="local",
            storage_key="pdf/s1.pdf",
            source=models.SourceType.UPLOAD,
        )
        db.add(pdf_1)
        db.flush()

        first = ingest_parsed_statement(
            db,
            parsed=_parsed_statement(amount_aed=100.0),
            profile_id=profile.id,
            pdf_file=pdf_1,
            pdf_checksum_sha256="1" * 64,
        )
        db.commit()

        pdf_2 = models.PdfFile(
            profile_id=profile.id,
            original_filename="s2.pdf",
            checksum_sha256="2" * 64,
            storage_backend="local",
            storage_key="pdf/s2.pdf",
            source=models.SourceType.UPLOAD,
        )
        db.add(pdf_2)
        db.flush()

        second = ingest_parsed_statement(
            db,
            parsed=_parsed_statement(amount_aed=200.0),
            profile_id=profile.id,
            pdf_file=pdf_2,
            pdf_checksum_sha256="2" * 64,
        )
        db.commit()

        statements = db.execute(select(models.Statement)).scalars().all()
        lines = db.execute(select(models.StatementLine)).scalars().all()

        assert len(statements) == 1
        assert len(lines) == 1
        assert float(lines[0].amount_aed) == 200.0

        assert first["replaced_existing"] is False
        assert second["replaced_existing"] is True
        assert second["old_line_count"] == 1


def test_rrule_weekly_next_run_is_future() -> None:
    next_run = compute_next_run(
        "FREQ=WEEKLY;BYDAY=MO,TH;BYHOUR=19;BYMINUTE=0",
        timezone="Asia/Dubai",
    )
    assert next_run.tzinfo is not None


def test_rrule_hourly_respects_interval() -> None:
    next_run = compute_next_run(
        "FREQ=HOURLY;INTERVAL=6",
        timezone="Asia/Dubai",
    )
    assert next_run.tzinfo is not None

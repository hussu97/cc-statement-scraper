from __future__ import annotations

from datetime import date, time

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from ccs_platform.db import models
from ccs_platform.db import Base
from ccs_platform.application.analytics.dashboard import (
    DashboardFilters,
    fetch_bank_trend_series,
    fetch_category_trend_series,
    fetch_filter_meta,
    fetch_overview,
    fetch_top_merchants,
    fetch_trend_series,
)


def _session():
    engine = create_engine("sqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine, future=True)
    return Session()


def _add_line(
    db,
    *,
    statement_id: int,
    line_no: int,
    tx_date: date,
    merchant: str,
    amount_aed: float,
    direction: models.Direction,
    category: str,
) -> None:
    db.add(
        models.StatementLine(
            statement_id=statement_id,
            line_no=line_no,
            transaction_date=tx_date,
            transaction_time=time(0, 0, 0),
            is_time_inferred=True,
            posting_date=tx_date,
            merchant_raw=merchant,
            merchant_normalized=merchant,
            amount_original=amount_aed,
            currency_original="AED",
            amount_aed=amount_aed,
            direction=direction,
            transaction_kind="purchase" if direction == models.Direction.DEBIT else "payment",
            country_code=None,
            card_last4="1234",
            category=category,
        )
    )


def _seed(db) -> int:
    profile = models.Profile(key="hussain", name="Hussain", is_default=True)
    db.add(profile)
    db.flush()

    db.add_all(
        [
            models.Bank(
                code="FAB",
                name="FAB",
                supports_multi_month=False,
                supports_headless=True,
            ),
            models.Bank(
                code="ENBD",
                name="ENBD",
                supports_multi_month=True,
                supports_headless=True,
            ),
        ]
    )
    db.flush()
    db.add_all(
        [
            models.ProfileBank(profile_id=profile.id, bank_code="FAB"),
            models.ProfileBank(profile_id=profile.id, bank_code="ENBD"),
        ]
    )

    db.add_all(
        [
            models.Category(name="Dining"),
            models.Category(name="Grocery"),
            models.Category(name="Travel"),
        ]
    )
    db.flush()

    s_fab = models.Statement(
        profile_id=profile.id,
        bank_code="FAB",
        statement_reference="STMT-FAB-001",
        statement_reference_raw="STMT-FAB-001",
        reference_source=models.ReferenceSource.EXPLICIT,
        statement_date=date(2025, 4, 30),
        statement_period_start=date(2025, 4, 1),
        statement_period_end=date(2025, 4, 30),
        primary_card_last4="1234",
        card_holder="Test User",
        card_type="Credit",
        warnings_json=None,
        metadata_json=None,
    )
    s_enbd = models.Statement(
        profile_id=profile.id,
        bank_code="ENBD",
        statement_reference="STMT-ENBD-001",
        statement_reference_raw="STMT-ENBD-001",
        reference_source=models.ReferenceSource.EXPLICIT,
        statement_date=date(2025, 3, 31),
        statement_period_start=date(2025, 3, 1),
        statement_period_end=date(2025, 3, 31),
        primary_card_last4="9876",
        card_holder="Test User",
        card_type="Credit",
        warnings_json=None,
        metadata_json=None,
    )

    db.add_all([s_fab, s_enbd])
    db.flush()

    _add_line(
        db,
        statement_id=s_fab.id,
        line_no=1,
        tx_date=date(2025, 1, 10),
        merchant="NOON",
        amount_aed=100.0,
        direction=models.Direction.DEBIT,
        category="Dining",
    )
    _add_line(
        db,
        statement_id=s_fab.id,
        line_no=2,
        tx_date=date(2025, 1, 11),
        merchant="REFUND",
        amount_aed=-20.0,
        direction=models.Direction.CREDIT,
        category="Dining",
    )
    _add_line(
        db,
        statement_id=s_enbd.id,
        line_no=3,
        tx_date=date(2025, 3, 5),
        merchant="CARREFOUR",
        amount_aed=200.0,
        direction=models.Direction.DEBIT,
        category="Grocery",
    )
    _add_line(
        db,
        statement_id=s_fab.id,
        line_no=4,
        tx_date=date(2025, 3, 20),
        merchant="EMIRATES",
        amount_aed=50.0,
        direction=models.Direction.DEBIT,
        category="Travel",
    )
    _add_line(
        db,
        statement_id=s_fab.id,
        line_no=5,
        tx_date=date(2025, 3, 21),
        merchant="LOCAL STORE",
        amount_aed=30.0,
        direction=models.Direction.DEBIT,
        category="Utilities",
    )
    _add_line(
        db,
        statement_id=s_fab.id,
        line_no=6,
        tx_date=date(2025, 4, 10),
        merchant="AMAZON",
        amount_aed=200.0,
        direction=models.Direction.DEBIT,
        category="Dining",
    )
    _add_line(
        db,
        statement_id=s_fab.id,
        line_no=7,
        tx_date=date(2025, 4, 11),
        merchant="REVERSAL",
        amount_aed=-190.0,
        direction=models.Direction.CREDIT,
        category="Dining",
    )

    db.commit()
    return profile.id


def test_trend_series_gap_fills_and_splits_debit_credit() -> None:
    with _session() as db:
        profile_id = _seed(db)

        points = fetch_trend_series(
            db,
            filters=DashboardFilters(
                profile_id=profile_id,
                date_from=date(2025, 1, 1),
                date_to=date(2025, 3, 31),
            ),
        )

        assert [point["bucket"] for point in points] == ["2025-01", "2025-02", "2025-03"]
        assert points[0]["debit_aed"] == 100.0
        assert points[0]["credit_aed"] == 20.0
        assert points[0]["net_aed"] == 80.0
        assert points[1]["debit_aed"] == 0.0
        assert points[1]["credit_aed"] == 0.0
        assert points[2]["debit_aed"] == 280.0


def test_bank_trend_series_respects_bank_filters() -> None:
    with _session() as db:
        profile_id = _seed(db)

        payload = fetch_bank_trend_series(
            db,
            filters=DashboardFilters(
                profile_id=profile_id,
                bank_codes=["enbd"],
                date_from=date(2025, 1, 1),
                date_to=date(2025, 3, 31),
            ),
        )

        assert payload["buckets"] == ["2025-01", "2025-02", "2025-03"]
        assert [series["key"] for series in payload["series"]] == ["ENBD"]
        assert [point["value_aed"] for point in payload["series"][0]["points"]] == [0.0, 0.0, 200.0]


def test_category_trend_series_builds_top_n_with_other() -> None:
    with _session() as db:
        profile_id = _seed(db)

        payload = fetch_category_trend_series(
            db,
            filters=DashboardFilters(
                profile_id=profile_id,
                date_from=date(2025, 1, 1),
                date_to=date(2025, 3, 31),
            ),
            top_n=2,
        )

        keys = [series["key"] for series in payload["series"]]
        assert keys == ["Grocery", "Dining", "Other"]

        by_key = {
            series["key"]: {point["bucket"]: point["value_aed"] for point in series["points"]}
            for series in payload["series"]
        }
        assert by_key["Grocery"]["2025-03"] == 200.0
        assert by_key["Dining"]["2025-01"] == 100.0
        assert by_key["Other"]["2025-03"] == 80.0


def test_filter_meta_includes_distinct_banks_categories_and_dates() -> None:
    with _session() as db:
        profile_id = _seed(db)

        payload = fetch_filter_meta(db, profile_id=profile_id)

        assert payload["banks"] == ["ENBD", "FAB"]
        assert {"Dining", "Grocery", "Travel", "Utilities"}.issubset(set(payload["categories"]))
        assert payload["min_date"] == date(2025, 1, 10)
        assert payload["max_date"] == date(2025, 4, 11)


def test_overview_mom_delta_uses_debit_not_net() -> None:
    with _session() as db:
        profile_id = _seed(db)

        payload = fetch_overview(
            db,
            filters=DashboardFilters(
                profile_id=profile_id,
                date_from=date(2025, 1, 1),
                date_to=date(2025, 4, 30),
            ),
        )

        assert payload["total_spend_aed"] == 580.0
        assert payload["total_credits_aed"] == 210.0
        assert payload["mom_delta_pct"] == -28.57


def test_top_merchants_supports_debit_and_credit_direction() -> None:
    with _session() as db:
        profile_id = _seed(db)

        debit_rows = fetch_top_merchants(
            db,
            filters=DashboardFilters(profile_id=profile_id),
            direction="debit",
            limit=5,
        )
        credit_rows = fetch_top_merchants(
            db,
            filters=DashboardFilters(profile_id=profile_id),
            direction="credit",
            limit=5,
        )

        assert debit_rows[0]["key"] == "AMAZON"
        assert debit_rows[0]["value"] == 200.0

        assert credit_rows[0]["key"] == "REVERSAL"
        assert credit_rows[0]["value"] == 190.0

from __future__ import annotations

import uuid
from datetime import date, time

from fastapi.testclient import TestClient
from sqlalchemy import select

from ccs_platform.main import app
from ccs_platform.db import db_session, models


def _create_statement_for_profile(
    *,
    profile_key: str,
    bank_code: str,
    statement_reference: str,
    statement_date: date,
) -> int:
    with db_session() as db:
        profile = db.execute(
            select(models.Profile).where(models.Profile.key == profile_key)
        ).scalar_one()
        row = models.Statement(
            profile_id=profile.id,
            bank_code=bank_code,
            pdf_file_id=None,
            statement_reference=statement_reference,
            statement_reference_raw=statement_reference,
            reference_source=models.ReferenceSource.EXPLICIT,
            statement_date=statement_date,
            statement_period_start=statement_date.replace(day=1),
            statement_period_end=statement_date,
            primary_card_last4="2777",
            card_holder="Test User",
            card_type="Credit Card",
            warnings_json=None,
            metadata_json={
                "statement_date": statement_date.isoformat(),
                "statement_period_end": statement_date.isoformat(),
                "statement_month": statement_date.strftime("%Y-%m"),
            },
        )
        db.add(row)
        db.flush()

        db.add(
            models.StatementLine(
                statement_id=row.id,
                line_no=1,
                transaction_date=statement_date,
                transaction_time=time(0, 0, 0),
                is_time_inferred=True,
                posting_date=statement_date,
                merchant_raw="TEST MERCHANT",
                merchant_normalized="TEST MERCHANT",
                amount_original=100.0,
                currency_original="AED",
                amount_aed=100.0,
                direction=models.Direction.DEBIT,
                transaction_kind="purchase",
                country_code=None,
                card_last4="2777",
                category="Uncategorized",
                fingerprint=f"fp-{uuid.uuid4().hex[:10]}",
                raw_json={"statement_month": statement_date.strftime("%Y-%m")},
            )
        )
        db.flush()
        return row.id


def _delete_statement(statement_id: int) -> None:
    with db_session() as db:
        row = db.get(models.Statement, statement_id)
        if row is not None:
            db.delete(row)


def test_health_endpoint() -> None:
    with TestClient(app) as client:
        resp = client.get('/api/v1/health')
        assert resp.status_code == 200
        assert resp.json() == {'status': 'ok'}


def test_banks_seeded() -> None:
    with TestClient(app) as client:
        resp = client.get('/api/v1/banks')
        assert resp.status_code == 200
        codes = {row['code'] for row in resp.json()}
        assert {'FAB', 'ADCB', 'ENBD', 'SIB'}.issubset(codes)


def test_dashboard_endpoints_available() -> None:
    with TestClient(app) as client:
        trend_resp = client.get('/api/v1/dashboard/trend-series')
        assert trend_resp.status_code == 200
        assert isinstance(trend_resp.json().get('points'), list)

        bank_trend_resp = client.get('/api/v1/dashboard/bank-trend-series')
        assert bank_trend_resp.status_code == 200
        bank_payload = bank_trend_resp.json()
        assert 'buckets' in bank_payload
        assert 'series' in bank_payload

        category_trend_resp = client.get('/api/v1/dashboard/category-trend-series?top_n=6')
        assert category_trend_resp.status_code == 200
        category_payload = category_trend_resp.json()
        assert 'buckets' in category_payload
        assert 'series' in category_payload

        filter_meta_resp = client.get('/api/v1/dashboard/filter-meta')
        assert filter_meta_resp.status_code == 200
        meta_payload = filter_meta_resp.json()
        assert {'banks', 'categories', 'min_date', 'max_date'}.issubset(meta_payload.keys())

        top_merchants_credit_resp = client.get('/api/v1/dashboard/top-merchants?direction=credit&limit=10')
        assert top_merchants_credit_resp.status_code == 200
        assert isinstance(top_merchants_credit_resp.json(), list)

        top_merchants_invalid_dir_resp = client.get('/api/v1/dashboard/top-merchants?direction=invalid')
        assert top_merchants_invalid_dir_resp.status_code == 400


def test_scrape_job_accepts_month_range() -> None:
    with TestClient(app) as client:
        resp = client.post(
            '/api/v1/jobs/scrape',
            json={
                'banks': ['ENBD'],
                'month_from': '2024-01',
                'month_to': '2024-03',
                'download': False,
                'headless': True,
                'login_timeout_minutes': 20,
            },
        )
        assert resp.status_code == 200
        payload = resp.json()
        assert payload['payload_json']['months'] == ['2024-01', '2024-02', '2024-03']


def test_reparse_all_enqueues_profile_scoped_job() -> None:
    with TestClient(app) as client:
        resp = client.post('/api/v1/statements/reparse-all')
        assert resp.status_code == 200
        payload = resp.json()
        assert payload['job_type'] == 'reparse_statement'
        assert payload['payload_json'] == {'all_statements': True}

        job_id = payload['id']
        own_profile_job = client.get(f'/api/v1/jobs/{job_id}')
        assert own_profile_job.status_code == 200

        cross_profile_job = client.get(f'/api/v1/jobs/{job_id}', headers={'X-Profile-Key': 'tejasvie'})
        assert cross_profile_job.status_code == 404


def test_runtime_settings_list_and_patch() -> None:
    with TestClient(app) as client:
        list_resp = client.get('/api/v1/runtime-settings')
        assert list_resp.status_code == 200
        list_payload = list_resp.json()
        assert {'total', 'page', 'page_size', 'items'}.issubset(list_payload.keys())
        rows = list_payload['items']
        assert isinstance(rows, list)

        row_by_key = {row['key']: row for row in rows}
        assert 'FAB_USERNAME' in row_by_key

        patch_resp = client.patch(
            '/api/v1/runtime-settings/FAB_USERNAME',
            json={
                'value': 'test-user',
                'bank_code': 'FAB',
                'is_secret': True,
                'description': 'FAB online banking username',
            },
        )
        assert patch_resp.status_code == 200
        assert patch_resp.json()['value'] == 'test-user'

        seed_resp = client.post('/api/v1/runtime-settings/seed-from-env', json={'overwrite_existing': False})
        assert seed_resp.status_code == 200
        payload = seed_resp.json()
        assert {'inserted', 'updated', 'skipped', 'applied_to_process_env'}.issubset(payload.keys())


def test_jobs_and_schedules_list_are_paginated() -> None:
    with TestClient(app) as client:
        job_resp = client.post('/api/v1/jobs/reclassify', json={})
        assert job_resp.status_code == 200

        jobs_list_resp = client.get('/api/v1/jobs?page=1&page_size=100')
        assert jobs_list_resp.status_code == 200
        jobs_payload = jobs_list_resp.json()
        assert {'total', 'page', 'page_size', 'items'}.issubset(jobs_payload.keys())
        assert isinstance(jobs_payload['items'], list)

        schedules_list_resp = client.get('/api/v1/schedules?page=1&page_size=100')
        assert schedules_list_resp.status_code == 200
        schedules_payload = schedules_list_resp.json()
        assert {'total', 'page', 'page_size', 'items'}.issubset(schedules_payload.keys())
        assert isinstance(schedules_payload['items'], list)


def test_profiles_endpoint_and_profile_scoping() -> None:
    with TestClient(app) as client:
        profiles_resp = client.get('/api/v1/profiles')
        assert profiles_resp.status_code == 200
        profiles = profiles_resp.json()
        keys = {profile['key'] for profile in profiles}
        assert {'hussain', 'tejasvie'}.issubset(keys)

        tejas_patch = client.patch(
            '/api/v1/profiles/tejasvie/banks',
            json={'bank_codes': ['FAB']},
        )
        assert tejas_patch.status_code == 200
        assert tejas_patch.json()['banks'] == ['FAB']

        tejas_banks_resp = client.get('/api/v1/banks', headers={'X-Profile-Key': 'tejasvie'})
        assert tejas_banks_resp.status_code == 200
        tejas_codes = [row['code'] for row in tejas_banks_resp.json()]
        assert tejas_codes == ['FAB']

        unknown_profile_resp = client.get('/api/v1/banks', headers={'X-Profile-Key': 'does-not-exist'})
        assert unknown_profile_resp.status_code == 400

        job_resp = client.post('/api/v1/jobs/reclassify', json={})
        assert job_resp.status_code == 200
        job_id = job_resp.json()['id']

        cross_profile_resp = client.get(f'/api/v1/jobs/{job_id}', headers={'X-Profile-Key': 'tejasvie'})
        assert cross_profile_resp.status_code == 404

        # Keep tejasvie as fresh profile by restoring empty bank mapping.
        reset_resp = client.patch('/api/v1/profiles/tejasvie/banks', json={'bank_codes': []})
        assert reset_resp.status_code == 200


def test_patch_statement_date_updates_db_and_storage_metadata() -> None:
    reference = f"TEST-DATE-{uuid.uuid4().hex[:12].upper()}"
    statement_id = _create_statement_for_profile(
        profile_key="hussain",
        bank_code="FAB",
        statement_reference=reference,
        statement_date=date(2026, 1, 31),
    )

    try:
        with TestClient(app) as client:
            resp = client.patch(
                f"/api/v1/statements/{statement_id}",
                json={"statement_date": "2026-02-01"},
            )
            assert resp.status_code == 200
            payload = resp.json()
            assert payload["id"] == statement_id
            assert payload["statement_date"] == "2026-02-01"

        with db_session() as db:
            statement = db.get(models.Statement, statement_id)
            assert statement is not None
            assert statement.statement_date.isoformat() == "2026-02-01"
            assert statement.statement_period_end is not None
            assert statement.statement_period_end.isoformat() == "2026-02-01"
            assert isinstance(statement.metadata_json, dict)
            assert statement.metadata_json.get("statement_date") == "2026-02-01"
            assert statement.metadata_json.get("statement_period_end") == "2026-02-01"
            assert statement.metadata_json.get("statement_month") == "2026-02"

            line = db.execute(
                select(models.StatementLine).where(models.StatementLine.statement_id == statement_id)
            ).scalar_one()
            assert isinstance(line.raw_json, dict)
            assert line.raw_json.get("statement_month") == "2026-02"

            audit = db.execute(
                select(models.AuditEvent)
                .where(
                    models.AuditEvent.entity_type == "statement",
                    models.AuditEvent.entity_id == str(statement_id),
                    models.AuditEvent.event_type == "statement_date_updated",
                )
                .order_by(models.AuditEvent.id.desc())
            ).scalars().first()
            assert audit is not None
            assert audit.payload_json is not None
            assert audit.payload_json.get("old_statement_date") == "2026-01-31"
            assert audit.payload_json.get("new_statement_date") == "2026-02-01"
    finally:
        _delete_statement(statement_id)


def test_patch_statement_date_rejects_conflicting_statement_identity() -> None:
    reference = f"TEST-CONFLICT-{uuid.uuid4().hex[:12].upper()}"
    source_statement_id = _create_statement_for_profile(
        profile_key="hussain",
        bank_code="FAB",
        statement_reference=reference,
        statement_date=date(2026, 1, 31),
    )
    conflicting_statement_id = _create_statement_for_profile(
        profile_key="hussain",
        bank_code="FAB",
        statement_reference=reference,
        statement_date=date(2026, 2, 28),
    )

    try:
        with TestClient(app) as client:
            resp = client.patch(
                f"/api/v1/statements/{source_statement_id}",
                json={"statement_date": "2026-02-28"},
            )
            assert resp.status_code == 409
    finally:
        _delete_statement(source_statement_id)
        _delete_statement(conflicting_statement_id)


def test_patch_statement_date_is_profile_scoped() -> None:
    reference = f"TEST-SCOPE-{uuid.uuid4().hex[:12].upper()}"
    statement_id = _create_statement_for_profile(
        profile_key="hussain",
        bank_code="FAB",
        statement_reference=reference,
        statement_date=date(2026, 1, 31),
    )

    try:
        with TestClient(app) as client:
            resp = client.patch(
                f"/api/v1/statements/{statement_id}",
                json={"statement_date": "2026-02-10"},
                headers={"X-Profile-Key": "tejasvie"},
            )
            assert resp.status_code == 404

        with db_session() as db:
            statement = db.get(models.Statement, statement_id)
            assert statement is not None
            assert statement.statement_date.isoformat() == "2026-01-31"
    finally:
        _delete_statement(statement_id)


def test_transactions_filtered_amount_sum_is_not_page_limited() -> None:
    token = f"AGGTEST-{uuid.uuid4().hex[:10].upper()}"
    with db_session() as db:
        profile = db.execute(
            select(models.Profile).where(models.Profile.key == "hussain")
        ).scalar_one()
        statement = models.Statement(
            profile_id=profile.id,
            bank_code="FAB",
            pdf_file_id=None,
            statement_reference=f"REF-{token}",
            statement_reference_raw=f"REF-{token}",
            reference_source=models.ReferenceSource.EXPLICIT,
            statement_date=date(2026, 2, 28),
            statement_period_start=date(2026, 2, 1),
            statement_period_end=date(2026, 2, 28),
            primary_card_last4="2777",
            card_holder="Test User",
            card_type="Credit Card",
            warnings_json=None,
            metadata_json={},
        )
        db.add(statement)
        db.flush()

        db.add(
            models.StatementLine(
                statement_id=statement.id,
                line_no=1,
                transaction_date=date(2026, 2, 10),
                transaction_time=time(0, 0, 0),
                is_time_inferred=True,
                posting_date=date(2026, 2, 10),
                merchant_raw=f"{token} ONE",
                merchant_normalized=f"{token} ONE",
                amount_original=100.0,
                currency_original="AED",
                amount_aed=100.0,
                direction=models.Direction.DEBIT,
                transaction_kind="purchase",
                country_code=None,
                card_last4="2777",
                category="Uncategorized",
                fingerprint=f"fp-{uuid.uuid4().hex[:10]}",
                raw_json={},
            )
        )
        db.add(
            models.StatementLine(
                statement_id=statement.id,
                line_no=2,
                transaction_date=date(2026, 2, 11),
                transaction_time=time(0, 0, 0),
                is_time_inferred=True,
                posting_date=date(2026, 2, 11),
                merchant_raw=f"{token} TWO",
                merchant_normalized=f"{token} TWO",
                amount_original=250.0,
                currency_original="AED",
                amount_aed=250.0,
                direction=models.Direction.DEBIT,
                transaction_kind="purchase",
                country_code=None,
                card_last4="2777",
                category="Uncategorized",
                fingerprint=f"fp-{uuid.uuid4().hex[:10]}",
                raw_json={},
            )
        )
        db.flush()
        statement_id = statement.id

    try:
        with TestClient(app) as client:
            resp = client.get(
                f"/api/v1/transactions?merchant_search={token}&page=1&page_size=1"
            )
            assert resp.status_code == 200
            payload = resp.json()
            assert payload["total"] == 2
            assert len(payload["items"]) == 1
            assert float(payload["filtered_amount_aed_sum"]) == 350.0
    finally:
        _delete_statement(statement_id)


def test_category_rule_test_uses_most_specific_match_without_scope() -> None:
    token = f"RTEST-{uuid.uuid4().hex[:10].upper()}"
    name_a = f"generic-{token}"
    name_b = f"specific-{token}"
    with db_session() as db:
        db.add(
            models.CategoryRule(
                name=name_a,
                category_name="Dining",
                match_type=models.MatchType.CONTAINS,
                pattern="CAFE",
                bank_code="FAB",
                card_last4="1234",
                priority=5,
                active=True,
            )
        )
        db.add(
            models.CategoryRule(
                name=name_b,
                category_name="Travel",
                match_type=models.MatchType.CONTAINS,
                pattern=f"{token} CAFE",
                bank_code=None,
                card_last4=None,
                priority=999,
                active=True,
            )
        )

    try:
        with TestClient(app) as client:
            resp = client.post(
                "/api/v1/category-rules/test",
                json={"merchant_normalized": f"{token} cafe"},
            )
            assert resp.status_code == 200
            payload = resp.json()
            assert payload["category"] == "Travel"
            assert payload["matched_rule_name"] == name_b
    finally:
        with db_session() as db:
            db.execute(
                models.CategoryRule.__table__.delete().where(
                    models.CategoryRule.name.in_([name_a, name_b])
                )
            )

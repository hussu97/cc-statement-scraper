from __future__ import annotations

import uuid
from datetime import UTC, date, datetime, time

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from ccs_platform.core.settings import clear_settings_caches
from ccs_platform.main import app, create_app
from ccs_platform.db import db_session, models

# Precomputed bcrypt hash (rounds=4) of "Apple123!" — kept here so tests can
# run without the real .env credentials and without slow per-test hashing.
_TEST_PASSWORD_HASH = "$2b$04$ZbobdUJwQZLVRQcOjUz4ouJ3L2mWPKaGO8jWtPWBbnG.F0z7N0Bl."


@pytest.fixture(autouse=True)
def _test_platform_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Isolate each test to a fresh temp SQLite DB and provide login credentials.

    This prevents tests from reading/writing the real platform.db and makes
    the suite runnable in CI without any secrets configured.

    The DB is initialised and seeded here so that tests which call db_session()
    before starting a TestClient (i.e. before the app lifespan runs) can still
    find tables and seed data.
    """
    from ccs_platform.db.session import init_db
    from ccs_platform.application.bootstrap.seed import seed_defaults

    tmp_db = f"/tmp/ccs_platform_test_{uuid.uuid4().hex}.db"
    monkeypatch.setenv("CCS_PLATFORM_DATABASE_URL", f"sqlite:///{tmp_db}")
    monkeypatch.setenv("CCS_PLATFORM_LOGIN_HASH_HUSSAIN", _TEST_PASSWORD_HASH)
    monkeypatch.setenv("CCS_PLATFORM_LOGIN_HASH_TEJASVIE", _TEST_PASSWORD_HASH)
    clear_settings_caches()
    init_db()
    with db_session() as db:
        seed_defaults(db)
    yield
    clear_settings_caches()


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


def _create_app_with_env(monkeypatch: pytest.MonkeyPatch, **kwargs: str) -> object:
    for key, value in kwargs.items():
        monkeypatch.setenv(key, value)
    clear_settings_caches()
    return create_app()


def _login_default(client: TestClient) -> dict[str, object]:
    resp = client.post(
        "/api/v1/auth/login",
        json={
            "email": "h_abbasi97@hotmail.com",
            "password": "Apple123!",
        },
    )
    assert resp.status_code == 200
    return resp.json()


def test_health_endpoint() -> None:
    with TestClient(app) as client:
        resp = client.get('/api/v1/health')
        assert resp.status_code == 200
        payload = resp.json()
        assert payload['status'] == 'ok'


def test_health_ready_and_metrics_endpoints() -> None:
    with TestClient(app) as client:
        ready_resp = client.get('/api/v1/health/ready')
        assert ready_resp.status_code == 200
        ready_payload = ready_resp.json()
        assert ready_payload['status'] == 'ok'
        assert 'checks' in ready_payload
        assert 'database' in ready_payload['checks']
        assert 'storage' in ready_payload['checks']

        _login_default(client)
        metrics_resp = client.get('/api/v1/metrics')
        assert metrics_resp.status_code == 200
        metrics_payload = metrics_resp.json()
        assert 'requests' in metrics_payload
        assert 'jobs' in metrics_payload
        assert isinstance(metrics_payload['requests'].get('total'), int)
        assert 'queue_backlog' in metrics_payload['jobs']
        assert 'total_queued' in metrics_payload['jobs']['queue_backlog']
        assert 'slo' in metrics_payload['jobs']['queue_backlog']
        assert metrics_payload['jobs']['queue_backlog']['slo']['status'] in {'ok', 'breached'}


def test_health_ready_degrades_when_queue_slo_breached(monkeypatch: pytest.MonkeyPatch) -> None:
    backlog_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_EMBEDDED_WORKER="false",
        CCS_PLATFORM_QUEUE_BACKLOG_SLO_DEFAULT="0",
    )

    created_job_id: int | None = None
    try:
        with TestClient(backlog_app) as client:
            _login_default(client)
            with db_session() as db:
                profile = db.execute(
                    select(models.Profile).where(models.Profile.key == "hussain")
                ).scalar_one()
                queued = models.Job(
                    profile_id=profile.id,
                    job_type=models.JobType.RECLASSIFY,
                    queue_name="default",
                    status=models.JobStatus.QUEUED,
                    payload_json={},
                )
                db.add(queued)
                db.flush()
                created_job_id = queued.id

            ready_resp = client.get("/api/v1/health/ready")
            assert ready_resp.status_code == 503
            ready_payload = ready_resp.json()
            assert ready_payload["status"] == "degraded"
            assert ready_payload["checks"]["job_queue"]["status"] == "error"
            assert ready_payload["checks"]["job_queue"]["slo"]["status"] == "breached"

            metrics_resp = client.get("/api/v1/metrics")
            assert metrics_resp.status_code == 200
            metrics_payload = metrics_resp.json()
            assert metrics_payload["jobs"]["queue_backlog"]["slo"]["status"] == "breached"
    finally:
        if created_job_id is not None:
            with db_session() as db:
                row = db.get(models.Job, created_job_id)
                if row is not None:
                    db.delete(row)
        clear_settings_caches()


def test_banks_seeded() -> None:
    with TestClient(app) as client:
        _login_default(client)
        resp = client.get('/api/v1/banks')
        assert resp.status_code == 200
        codes = {row['code'] for row in resp.json()}
        assert {'FAB', 'ADCB', 'ENBD', 'SIB'}.issubset(codes)


def test_dashboard_endpoints_available() -> None:
    with TestClient(app) as client:
        _login_default(client)
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
        _login_default(client)
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
        assert payload['queue_name'] == 'scrape'
        assert payload['payload_json']['months'] == ['2024-01', '2024-02', '2024-03']


def test_scrape_job_rejects_duplicate_payload_while_active(monkeypatch: pytest.MonkeyPatch) -> None:
    workerless_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_EMBEDDED_WORKER="false",
    )
    body = {
        'banks': ['ENBD'],
        'month_from': '2025-11',
        'month_to': '2025-11',
        'download': False,
        'headless': True,
        'login_timeout_minutes': 20,
    }
    try:
        with TestClient(workerless_app) as client:
            _login_default(client)
            first = client.post('/api/v1/jobs/scrape', json=body)
            assert first.status_code == 200

            second = client.post('/api/v1/jobs/scrape', json=body)
            assert second.status_code == 409
            assert "already" in second.json()["detail"].lower()
    finally:
        clear_settings_caches()


def test_scrape_job_creates_new_after_cancelled_duplicate_payload(monkeypatch: pytest.MonkeyPatch) -> None:
    workerless_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_EMBEDDED_WORKER="false",
    )
    timeout_minutes = 5 + (int(uuid.uuid4().hex[:2], 16) % 56)
    body = {
        "banks": ["ENBD"],
        "month_from": "2025-10",
        "month_to": "2025-10",
        "download": False,
        "headless": True,
        "login_timeout_minutes": timeout_minutes,
    }

    try:
        with TestClient(workerless_app) as client:
            _login_default(client)
            first = client.post("/api/v1/jobs/scrape", json=body)
            assert first.status_code == 200
            first_payload = first.json()
            first_job_id = int(first_payload["id"])

            cancel = client.post(f"/api/v1/jobs/{first_job_id}/cancel")
            assert cancel.status_code == 200
            assert cancel.json()["status"] == "cancelled"

            second = client.post("/api/v1/jobs/scrape", json=body)
            assert second.status_code == 200
            second_payload = second.json()
            second_job_id = int(second_payload["id"])
            assert second_job_id != first_job_id
            assert second_payload["status"] == "queued"

        with db_session() as db:
            first_row = db.get(models.Job, first_job_id)
            second_row = db.get(models.Job, second_job_id)
            assert first_row is not None and second_row is not None
            assert first_row.idempotency_key is None
            assert second_row.idempotency_key is not None

            second_items = db.execute(
                select(models.JobItem.id).where(models.JobItem.job_id == second_job_id)
            ).scalars().all()
            assert len(second_items) == 1
    finally:
        clear_settings_caches()


def test_scrape_job_creates_new_after_previous_succeeded(monkeypatch: pytest.MonkeyPatch) -> None:
    workerless_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_EMBEDDED_WORKER="false",
    )
    body = {
        "banks": ["ENBD"],
        "month_from": "2025-09",
        "month_to": "2025-09",
        "download": False,
        "headless": True,
        "login_timeout_minutes": 20,
    }

    first_job_id: int | None = None
    second_job_id: int | None = None
    try:
        with TestClient(workerless_app) as client:
            _login_default(client)
            first = client.post("/api/v1/jobs/scrape", json=body)
            assert first.status_code == 200
            first_payload = first.json()
            first_job_id = int(first_payload["id"])

            with db_session() as db:
                row = db.get(models.Job, first_job_id)
                assert row is not None
                row.status = models.JobStatus.SUCCEEDED
                row.finished_at = datetime.now(UTC)
                db.flush()

            second = client.post("/api/v1/jobs/scrape", json=body)
            assert second.status_code == 200
            second_payload = second.json()
            second_job_id = int(second_payload["id"])

            assert second_job_id != first_job_id
            assert second_payload["status"] == "queued"

        with db_session() as db:
            first_row = db.get(models.Job, first_job_id)
            second_row = db.get(models.Job, second_job_id)
            assert first_row is not None and second_row is not None
            assert first_row.idempotency_key is None
            assert second_row.idempotency_key is not None
    finally:
        clear_settings_caches()


def test_scrape_job_creates_new_after_previous_failed(monkeypatch: pytest.MonkeyPatch) -> None:
    workerless_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_EMBEDDED_WORKER="false",
    )
    body = {
        "banks": ["ENBD"],
        "month_from": "2025-08",
        "month_to": "2025-08",
        "download": False,
        "headless": True,
        "login_timeout_minutes": 20,
    }

    first_job_id: int | None = None
    second_job_id: int | None = None
    try:
        with TestClient(workerless_app) as client:
            _login_default(client)
            first = client.post("/api/v1/jobs/scrape", json=body)
            assert first.status_code == 200
            first_payload = first.json()
            first_job_id = int(first_payload["id"])

            with db_session() as db:
                row = db.get(models.Job, first_job_id)
                assert row is not None
                row.status = models.JobStatus.FAILED
                row.error_message = "simulated failure"
                row.finished_at = datetime.now(UTC)
                db.flush()

            second = client.post("/api/v1/jobs/scrape", json=body)
            assert second.status_code == 200
            second_payload = second.json()
            second_job_id = int(second_payload["id"])

            assert second_job_id != first_job_id
            assert second_payload["status"] == "queued"

        with db_session() as db:
            first_row = db.get(models.Job, first_job_id)
            second_row = db.get(models.Job, second_job_id)
            assert first_row is not None and second_row is not None
            assert first_row.idempotency_key is None
            assert second_row.idempotency_key is not None
    finally:
        clear_settings_caches()


def test_reclassify_job_honors_idempotency_key_header(monkeypatch: pytest.MonkeyPatch) -> None:
    workerless_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_EMBEDDED_WORKER="false",
    )

    created_job_id: int | None = None
    idem_key = f"reclassify-{uuid.uuid4().hex}"
    try:
        with TestClient(workerless_app) as client:
            _login_default(client)
            headers = {"Idempotency-Key": idem_key}
            first = client.post(
                "/api/v1/jobs/reclassify",
                json={"statement_ids": [1]},
                headers=headers,
            )
            assert first.status_code == 200
            first_payload = first.json()
            created_job_id = first_payload["id"]

            second = client.post(
                "/api/v1/jobs/reclassify",
                json={"statement_ids": [2]},
                headers=headers,
            )
            assert second.status_code == 200
            second_payload = second.json()

            assert first_payload["id"] == second_payload["id"]
            assert second_payload["idempotency_key"] == idem_key
    finally:
        if created_job_id is not None:
            with db_session() as db:
                row = db.get(models.Job, created_job_id)
                if row is not None:
                    db.delete(row)
        clear_settings_caches()


def test_workbook_export_idempotency_header_avoids_duplicate_exports(monkeypatch: pytest.MonkeyPatch) -> None:
    workerless_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_EMBEDDED_WORKER="false",
    )

    created_job_id: int | None = None
    idem_key = f"export-{uuid.uuid4().hex}"
    try:
        with TestClient(workerless_app) as client:
            _login_default(client)
            headers = {"Idempotency-Key": idem_key}
            first = client.post("/api/v1/exports/workbook", json={"year": 2025}, headers=headers)
            assert first.status_code == 200
            first_payload = first.json()
            created_job_id = first_payload["id"]

            second = client.post("/api/v1/exports/workbook", json={"year": 2025}, headers=headers)
            assert second.status_code == 200
            second_payload = second.json()

            assert first_payload["id"] == second_payload["id"]

        with db_session() as db:
            export_ids = db.execute(
                select(models.Export.id).where(models.Export.job_id == created_job_id)
            ).scalars().all()
            assert len(export_ids) == 1
    finally:
        if created_job_id is not None:
            with db_session() as db:
                export_rows = db.execute(
                    select(models.Export).where(models.Export.job_id == created_job_id)
                ).scalars().all()
                for export_row in export_rows:
                    db.delete(export_row)

                job_row = db.get(models.Job, created_job_id)
                if job_row is not None:
                    db.delete(job_row)
        clear_settings_caches()


def test_reparse_all_enqueues_profile_scoped_job() -> None:
    with TestClient(app) as client:
        _login_default(client)
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


def test_cancel_running_job_sets_cancel_request_token() -> None:
    with db_session() as db:
        profile = db.execute(
            select(models.Profile).where(models.Profile.key == "hussain")
        ).scalar_one()
        job = models.Job(
            profile_id=profile.id,
            job_type=models.JobType.RECLASSIFY,
            queue_name="default",
            status=models.JobStatus.RUNNING,
            payload_json={},
            started_at=datetime.now(UTC),
        )
        db.add(job)
        db.flush()
        job_id = job.id

    try:
        with TestClient(app) as client:
            _login_default(client)
            resp = client.post(f"/api/v1/jobs/{job_id}/cancel")
            assert resp.status_code == 200
            payload = resp.json()
            assert payload["id"] == job_id
            assert payload["status"] == "running"
            assert payload["cancel_requested_at"] is not None
    finally:
        with db_session() as db:
            row = db.get(models.Job, job_id)
            if row is not None:
                db.delete(row)


def test_runtime_settings_list_and_patch() -> None:
    with TestClient(app) as client:
        _login_default(client)
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


def test_login_guard_rejects_unauthenticated_requests() -> None:
    with TestClient(app) as client:
        unauthorized = client.get("/api/v1/banks")
        assert unauthorized.status_code == 401

        health = client.get("/api/v1/health")
        assert health.status_code == 200

        me = client.get("/api/v1/auth/me")
        assert me.status_code == 401


@pytest.mark.parametrize(
    ("email", "default_profile_key"),
    (
        ("h_abbasi97@hotmail.com", "hussain"),
        ("tejasvie.vemuri@gmail.com", "tejasvie"),
    ),
)
def test_login_and_me_endpoints_for_seeded_accounts(email: str, default_profile_key: str) -> None:
    with TestClient(app) as client:
        login = client.post(
            "/api/v1/auth/login",
            json={"email": email, "password": "Apple123!"},
        )
        assert login.status_code == 200
        login_payload = login.json()
        assert login_payload["user"]["email"] == email
        assert login_payload["user"]["default_profile_key"] == default_profile_key

        me = client.get("/api/v1/auth/me")
        assert me.status_code == 200
        me_payload = me.json()
        assert me_payload["user"]["email"] == email
        assert me_payload["user"]["default_profile_key"] == default_profile_key

        logout = client.post("/api/v1/auth/logout")
        assert logout.status_code == 204

        after_logout = client.get("/api/v1/auth/me")
        assert after_logout.status_code == 401


def test_login_rejects_invalid_password() -> None:
    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/auth/login",
            json={"email": "h_abbasi97@hotmail.com", "password": "wrong-password"},
        )
        assert resp.status_code == 401


def test_runtime_settings_hide_secret_values_in_production(monkeypatch: pytest.MonkeyPatch) -> None:
    # Purge any runtime settings encrypted with a different key from previous
    # runs so that apply_runtime_settings_to_process_env never tries to decrypt
    # values it cannot decode.
    with db_session() as db:
        db.execute(delete(models.RuntimeSetting))

    prod_app = _create_app_with_env(
        monkeypatch,
        CCS_PLATFORM_ENVIRONMENT="production",
        CCS_PLATFORM_SESSION_SECRET_KEY="test-secret-key-long-enough-for-production-x",
        CCS_PLATFORM_SESSION_COOKIE_SECURE="false",
        CCS_PLATFORM_RUNTIME_SETTINGS_ENCRYPTION_KEY="V33IhV4J0EAOQnq2STxwJK6I2Gv5u9W1tnM0B8f9Lh4=",
    )

    try:
        with TestClient(prod_app) as client:
            _login_default(client)
            patch_resp = client.patch(
                "/api/v1/runtime-settings/FAB_USERNAME",
                json={"value": "prod-secret-user"},
            )
            assert patch_resp.status_code == 200
            patched = patch_resp.json()
            assert patched["is_secret"] is True
            assert patched["value"] == ""
            assert patched["has_value"] is True
    finally:
        clear_settings_caches()


def test_runtime_setting_patch_emits_actor_audit_event(monkeypatch: pytest.MonkeyPatch) -> None:
    auth_app = _create_app_with_env(monkeypatch)

    try:
        with TestClient(auth_app) as client:
            _login_default(client)
            patch_resp = client.patch(
                "/api/v1/runtime-settings/FAB_USERNAME",
                json={"value": "audit-user"},
            )
            assert patch_resp.status_code == 200

        with db_session() as db:
            profile = db.execute(
                select(models.Profile).where(models.Profile.key == "hussain")
            ).scalar_one()
            audit = db.execute(
                select(models.AuditEvent)
                .where(
                    models.AuditEvent.profile_id == profile.id,
                    models.AuditEvent.event_type == "runtime_setting_updated",
                    models.AuditEvent.entity_type == "runtime_setting",
                    models.AuditEvent.entity_id == "FAB_USERNAME",
                )
                .order_by(models.AuditEvent.id.desc())
            ).scalars().first()

            assert audit is not None
            assert isinstance(audit.payload_json, dict)
            actor = audit.payload_json.get("actor")
            assert isinstance(actor, dict)
            assert actor.get("role") == "admin"
            assert str(actor.get("subject", "")).startswith("user:")
    finally:
        clear_settings_caches()


def test_jobs_and_schedules_list_are_paginated() -> None:
    with TestClient(app) as client:
        _login_default(client)
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
        _login_default(client)
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
            _login_default(client)
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
            assert isinstance(audit.payload_json.get("actor"), dict)
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
            _login_default(client)
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
            _login_default(client)
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
            _login_default(client)
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
                active=True,
            )
        )
        db.add(
            models.CategoryRule(
                name=name_b,
                category_name="Travel",
                match_type=models.MatchType.CONTAINS,
                pattern=f"{token} CAFE",
                active=True,
            )
        )

    try:
        with TestClient(app) as client:
            _login_default(client)
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

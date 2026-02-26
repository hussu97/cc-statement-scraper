from __future__ import annotations

from fastapi.testclient import TestClient

from ccs_platform.main import app


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


def test_runtime_settings_list_and_patch() -> None:
    with TestClient(app) as client:
        list_resp = client.get('/api/v1/runtime-settings')
        assert list_resp.status_code == 200
        rows = list_resp.json()
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

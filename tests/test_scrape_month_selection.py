from __future__ import annotations

from datetime import date

import pytest

from ccs_platform.db import models
from ccs_platform.application.banks.capabilities import (
    MIN_SCRAPE_MONTH,
    current_month_token,
    build_bank_scrape_config,
    is_month_supported,
    month_tokens_between,
    parse_month_token,
    resolve_requested_months,
    supports_multi_month,
)


def test_month_tokens_between_is_inclusive() -> None:
    assert month_tokens_between('2024-01', '2024-03') == ['2024-01', '2024-02', '2024-03']


def test_resolve_requested_months_range() -> None:
    resolved = resolve_requested_months(month_from='2024-05', month_to='2024-07')
    assert resolved == ['2024-05', '2024-06', '2024-07']


def test_resolve_requested_months_validates_lower_bound() -> None:
    with pytest.raises(ValueError, match='before supported minimum'):
        resolve_requested_months(month_from='2023-12', month_to='2024-01')


def test_resolve_requested_months_rejects_future_month() -> None:
    future = date.today().replace(day=1)
    future_token = f"{future.year + 2:04d}-{future.month:02d}"
    with pytest.raises(ValueError, match='after current month'):
        resolve_requested_months(months=[future_token])


def test_resolve_requested_months_normalizes_latest() -> None:
    resolved = resolve_requested_months(months=['latest'])
    assert len(resolved) == 1
    assert resolved[0] >= f"{MIN_SCRAPE_MONTH.year:04d}-{MIN_SCRAPE_MONTH.month:02d}"


def test_build_bank_scrape_config_is_bank_specific() -> None:
    enbd = build_bank_scrape_config('ENBD', '2025-11')
    fab = build_bank_scrape_config('FAB', '2025-11')
    adcb = build_bank_scrape_config('ADCB', '2025-11')
    sib = build_bank_scrape_config('SIB', '2025-11')

    assert enbd['requested_month'] == '2025-11'
    assert enbd['enbd_statement_year'] == 2025
    assert enbd['enbd_statement_month'] == 11

    assert fab['requested_month'] == '2025-11'
    assert fab['fab_statement_period'] == '2025-11'
    assert 'enbd_statement_year' not in fab

    assert adcb['requested_month'] == '2025-11'
    assert adcb['adcb_statement_period'] == '2025-11'
    assert 'fab_statement_period' not in adcb

    assert sib['requested_month'] == '2025-11'
    assert sib['sib_statement_period'] == '2025-11'
    assert sib['sib_statement_year'] == 2025
    assert sib['sib_statement_month'] == 11


def test_latest_only_bank_supports_current_month_only_when_no_static_capability() -> None:
    bank = models.Bank(
        code='LEGACY',
        name='LEGACY',
        supports_historical_month_selection=False,
        supports_multi_month=False,
        supports_headless=True,
    )
    current = current_month_token()
    assert is_month_supported(bank, current)

    current_date = parse_month_token(current)
    if current_date.month == 1:
        previous = f'{current_date.year - 1:04d}-12'
    else:
        previous = f'{current_date.year:04d}-{current_date.month - 1:02d}'
    assert is_month_supported(bank, previous) is False


def test_fab_static_capabilities_enable_historical_and_multi_month() -> None:
    bank = models.Bank(
        code='FAB',
        name='FAB',
        supports_historical_month_selection=False,
        supports_multi_month=False,
        supports_headless=True,
    )
    assert supports_multi_month(bank) is True
    assert is_month_supported(bank, "2024-01") is True


def test_adcb_static_capabilities_enable_historical_and_multi_month() -> None:
    bank = models.Bank(
        code='ADCB',
        name='ADCB',
        supports_historical_month_selection=False,
        supports_multi_month=False,
        supports_headless=True,
    )
    assert supports_multi_month(bank) is True
    assert is_month_supported(bank, "2024-01") is True


def test_static_capabilities_enable_enbd_multi_month_even_if_row_is_stale() -> None:
    bank = models.Bank(
        code='ENBD',
        name='ENBD',
        supports_historical_month_selection=False,
        supports_multi_month=False,
        supports_headless=True,
    )
    assert supports_multi_month(bank) is True


def test_static_capabilities_enable_sib_multi_month_even_if_row_is_stale() -> None:
    bank = models.Bank(
        code='SIB',
        name='SIB',
        supports_historical_month_selection=False,
        supports_multi_month=False,
        supports_headless=True,
    )
    assert supports_multi_month(bank) is True
    assert is_month_supported(bank, "2024-01") is True

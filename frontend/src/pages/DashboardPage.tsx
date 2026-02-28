import { useEffect, useMemo, useState } from 'react';

import { api } from '../api';
import { isAbortError } from '../lib/errors';
import { formatAmount } from '../lib/format';
import { useDebouncedValue } from '../lib/useDebounce';
import { DashboardFilters } from '../components/DashboardFilters';
import { DonutBreakdownChart } from '../components/charts/DonutBreakdownChart';
import { SpendTrendChart } from '../components/charts/SpendTrendChart';
import { StackedTrendChart } from '../components/charts/StackedTrendChart';
import { TopMerchantsBarChart } from '../components/charts/TopMerchantsBarChart';
import { Panel } from '../components/Panel';
import { useActiveProfileKey } from '../profileStore';
import {
  BreakdownPoint,
  DashboardFilterMeta,
  DashboardFiltersValue,
  DashboardOverview,
  StackedSeriesResponse,
  TrendSeriesResponse,
} from '../types/dashboard';

const EMPTY_FILTER_META: DashboardFilterMeta = {
  banks: [],
  categories: [],
  min_date: null,
  max_date: null,
};

const EMPTY_OVERVIEW: DashboardOverview = {
  total_spend_aed: 0,
  total_credits_aed: 0,
  uncategorized_count: 0,
  uncategorized_ratio: 0,
  statement_count: 0,
  mom_delta_pct: null,
};

const EMPTY_TREND: TrendSeriesResponse = { points: [] };
const EMPTY_STACKED: StackedSeriesResponse = { buckets: [], series: [] };

function dateInput(value: Date): string {
  return value.toISOString().slice(0, 10);
}

function monthWindowFromBucket(bucket: string): { dateFrom: string; dateTo: string } | null {
  const match = /^(\d{4})-(\d{2})$/.exec((bucket || '').trim());
  if (!match) {
    return null;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  if (!Number.isFinite(year) || !Number.isFinite(month) || month < 1 || month > 12) {
    return null;
  }

  const lastDay = new Date(year, month, 0).getDate();
  return {
    dateFrom: `${match[1]}-${match[2]}-01`,
    dateTo: `${match[1]}-${match[2]}-${String(lastDay).padStart(2, '0')}`,
  };
}

function toggleSingleSelection(values: string[], raw: string): string[] {
  const token = raw.trim();
  if (!token) {
    return values;
  }
  if (values.length === 1 && values[0] === token) {
    return [];
  }
  return [token];
}

function defaultLastTwelveMonthsWindow(): Pick<DashboardFiltersValue, 'dateFrom' | 'dateTo'> {
  const now = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth() - 11, 1);
  return {
    dateFrom: dateInput(monthStart),
    dateTo: dateInput(now),
  };
}

function dashboardQueryParams(filters: DashboardFiltersValue, debouncedMerchant: string): URLSearchParams {
  const params = new URLSearchParams();

  if (filters.dateFrom) {
    params.set('date_from', filters.dateFrom);
  }
  if (filters.dateTo) {
    params.set('date_to', filters.dateTo);
  }
  filters.bankCodes.forEach((code) => params.append('bank_codes', code));
  filters.categories.forEach((category) => params.append('categories', category));

  const merchant = debouncedMerchant.trim();
  if (merchant) {
    params.set('merchant_search', merchant);
  }

  return params;
}

function toQuerySuffix(params: URLSearchParams): string {
  const encoded = params.toString();
  return encoded ? `?${encoded}` : '';
}

export function DashboardPage() {
  const activeProfileKey = useActiveProfileKey();
  const defaultWindow = useMemo(() => defaultLastTwelveMonthsWindow(), []);

  const [filters, setFilters] = useState<DashboardFiltersValue>({
    dateFrom: defaultWindow.dateFrom,
    dateTo: defaultWindow.dateTo,
    bankCodes: [],
    categories: [],
    merchantSearch: '',
  });

  const [filterMeta, setFilterMeta] = useState<DashboardFilterMeta>(EMPTY_FILTER_META);
  const [overview, setOverview] = useState<DashboardOverview>(EMPTY_OVERVIEW);
  const [trendSeries, setTrendSeries] = useState<TrendSeriesResponse>(EMPTY_TREND);
  const [bankTrendSeries, setBankTrendSeries] = useState<StackedSeriesResponse>(EMPTY_STACKED);
  const [categoryTrendSeries, setCategoryTrendSeries] = useState<StackedSeriesResponse>(EMPTY_STACKED);
  const [bankBreakdown, setBankBreakdown] = useState<BreakdownPoint[]>([]);
  const [categoryBreakdown, setCategoryBreakdown] = useState<BreakdownPoint[]>([]);
  const [topMerchantsDebit, setTopMerchantsDebit] = useState<BreakdownPoint[]>([]);
  const [topMerchantsCredit, setTopMerchantsCredit] = useState<BreakdownPoint[]>([]);

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const debouncedMerchantSearch = useDebouncedValue(filters.merchantSearch, 300);

  const filterSignature = useMemo(
    () => [activeProfileKey, filters.dateFrom, filters.dateTo, filters.bankCodes.join('|'), filters.categories.join('|')].join('::'),
    [activeProfileKey, filters.dateFrom, filters.dateTo, filters.bankCodes, filters.categories],
  );

  useEffect(() => {
    const controller = new AbortController();

    async function loadFilterMeta() {
      try {
        const meta = await api.get<DashboardFilterMeta>('/dashboard/filter-meta', {
          signal: controller.signal,
        });
        setFilterMeta(meta);
        setFilters((prev) => ({
          ...prev,
          bankCodes: prev.bankCodes.filter((bank) => meta.banks.includes(bank)),
          categories: prev.categories.filter((category) => meta.categories.includes(category)),
        }));
      } catch (loadError) {
        if (!isAbortError(loadError)) {
          setError((loadError as Error).message);
        }
      }
    }

    loadFilterMeta();
    return () => controller.abort();
  }, [activeProfileKey]);

  useEffect(() => {
    const controller = new AbortController();

    async function loadDashboardData() {
      try {
        setLoading(true);
        setError(null);

        const params = dashboardQueryParams(filters, debouncedMerchantSearch);
        const commonSuffix = toQuerySuffix(params);
        const categoryTrendParams = new URLSearchParams(params);
        categoryTrendParams.set('top_n', '12');
        const topMerchantsDebitParams = new URLSearchParams(params);
        topMerchantsDebitParams.set('limit', '10');
        topMerchantsDebitParams.set('direction', 'debit');
        const topMerchantsCreditParams = new URLSearchParams(params);
        topMerchantsCreditParams.set('limit', '10');
        topMerchantsCreditParams.set('direction', 'credit');

        const [
          overviewResp,
          trendResp,
          bankTrendResp,
          categoryTrendResp,
          bankBreakdownResp,
          categoryBreakdownResp,
          topMerchantsDebitResp,
          topMerchantsCreditResp,
        ] = await Promise.all([
          api.get<DashboardOverview>(`/dashboard/overview${commonSuffix}`, { signal: controller.signal }),
          api.get<TrendSeriesResponse>(`/dashboard/trend-series${commonSuffix}`, {
            signal: controller.signal,
          }),
          api.get<StackedSeriesResponse>(`/dashboard/bank-trend-series${commonSuffix}`, {
            signal: controller.signal,
          }),
          api.get<StackedSeriesResponse>(`/dashboard/category-trend-series?${categoryTrendParams.toString()}`, {
            signal: controller.signal,
          }),
          api.get<BreakdownPoint[]>(`/dashboard/bank-breakdown${commonSuffix}`, {
            signal: controller.signal,
          }),
          api.get<BreakdownPoint[]>(`/dashboard/category-breakdown${commonSuffix}`, {
            signal: controller.signal,
          }),
          api.get<BreakdownPoint[]>(`/dashboard/top-merchants?${topMerchantsDebitParams.toString()}`, {
            signal: controller.signal,
          }),
          api.get<BreakdownPoint[]>(`/dashboard/top-merchants?${topMerchantsCreditParams.toString()}`, {
            signal: controller.signal,
          }),
        ]);

        setOverview(overviewResp);
        setTrendSeries(trendResp);
        setBankTrendSeries(bankTrendResp);
        setCategoryTrendSeries(categoryTrendResp);
        setBankBreakdown(bankBreakdownResp);
        setCategoryBreakdown(categoryBreakdownResp);
        setTopMerchantsDebit(topMerchantsDebitResp);
        setTopMerchantsCredit(topMerchantsCreditResp);
      } catch (loadError) {
        if (!isAbortError(loadError)) {
          setError((loadError as Error).message);
        }
      } finally {
        setLoading(false);
      }
    }

    loadDashboardData();
    return () => controller.abort();
  }, [filterSignature, debouncedMerchantSearch]);

  const topCategoriesSpent = useMemo(
    () => categoryBreakdown.filter((point) => point.value > 0).slice(0, 10),
    [categoryBreakdown],
  );

  function applyChartFilter(
    updater: (value: DashboardFiltersValue) => DashboardFiltersValue,
    bucket?: string,
  ) {
    setFilters((prev) => {
      const next = updater(prev);
      if (!bucket) {
        return next;
      }
      const monthWindow = monthWindowFromBucket(bucket);
      if (!monthWindow) {
        return next;
      }
      return {
        ...next,
        dateFrom: monthWindow.dateFrom,
        dateTo: monthWindow.dateTo,
      };
    });
  }

  function handleBankClick(bankCode: string, bucket?: string) {
    const bank = bankCode.trim().toUpperCase();
    if (!bank) {
      return;
    }
    applyChartFilter((prev) => ({ ...prev, bankCodes: toggleSingleSelection(prev.bankCodes, bank) }), bucket);
  }

  function handleCategoryClick(categoryName: string, bucket?: string) {
    const category = categoryName.trim();
    if (!category) {
      return;
    }
    if (category === 'Other') {
      applyChartFilter((prev) => ({ ...prev }), bucket);
      return;
    }
    applyChartFilter((prev) => ({ ...prev, categories: toggleSingleSelection(prev.categories, category) }), bucket);
  }

  function handleMerchantClick(merchantName: string, bucket?: string) {
    const merchant = merchantName.trim();
    if (!merchant) {
      return;
    }
    applyChartFilter(
      (prev) => ({
        ...prev,
        merchantSearch:
          prev.merchantSearch.trim().toUpperCase() === merchant.toUpperCase() ? '' : merchant,
      }),
      bucket,
    );
  }

  const momLabel =
    overview.mom_delta_pct === null
      ? 'N/A'
      : `${overview.mom_delta_pct >= 0 ? '+' : ''}${overview.mom_delta_pct.toFixed(2)}%`;

  return (
    <div className="dashboard-stack">
      <Panel title="Dashboard Filters">
        <DashboardFilters
          value={filters}
          meta={filterMeta}
          onChange={setFilters}
        />
      </Panel>

      {error ? <p className="error">{error}</p> : null}
      {loading ? <p className="muted">Loading analytics...</p> : null}

      <section className="kpi-grid">
        <article className="kpi-card">
          <span className="kpi-label">Total Debit</span>
          <strong className="kpi-value">AED {formatAmount(overview.total_spend_aed)}</strong>
        </article>
        <article className="kpi-card">
          <span className="kpi-label">Total Credit</span>
          <strong className="kpi-value">AED {formatAmount(overview.total_credits_aed)}</strong>
        </article>
        <article className="kpi-card">
          <span className="kpi-label">Uncategorized</span>
          <strong className="kpi-value">{overview.uncategorized_count}</strong>
          <small className="muted">{(overview.uncategorized_ratio * 100).toFixed(1)}% of lines</small>
        </article>
        <article className="kpi-card">
          <span className="kpi-label">Active Statements</span>
          <strong className="kpi-value">{overview.statement_count}</strong>
        </article>
        <article className="kpi-card">
          <span className="kpi-label">MoM Delta (Debit)</span>
          <strong className="kpi-value">{momLabel}</strong>
        </article>
      </section>

      <Panel title="Spend Trend Over Time">
        <p className="muted">Monthly debit and credit shown as side-by-side bars. Click a month to filter.</p>
        <SpendTrendChart
          points={trendSeries.points}
          onBarClick={({ bucket }) => applyChartFilter((prev) => ({ ...prev }), bucket)}
        />
      </Panel>

      <div className="dashboard-split">
        <Panel title="Bank Spend Trend">
          <p className="muted">Debit trend broken out by bank. Click a segment to filter bank + month.</p>
          <StackedTrendChart
            data={bankTrendSeries}
            mode="bar"
            onPointClick={({ seriesKey, bucket }) => handleBankClick(seriesKey, bucket)}
          />
        </Panel>

        <Panel title="Category Spend Trend">
          <p className="muted">Top categories over time, split as separate lines (not cumulative). Click a point to filter.</p>
          <StackedTrendChart
            data={categoryTrendSeries}
            mode="line"
            onPointClick={({ seriesKey, bucket }) => handleCategoryClick(seriesKey, bucket)}
          />
        </Panel>
      </div>

      <div className="dashboard-split">
        <Panel title="Current Window Bank Mix">
          <DonutBreakdownChart data={bankBreakdown} onSliceClick={(key) => handleBankClick(key)} />
        </Panel>

        <Panel title="Current Window Category Mix">
          <DonutBreakdownChart data={categoryBreakdown} onSliceClick={(key) => handleCategoryClick(key)} />
        </Panel>
      </div>

      <Panel title="Top Merchants (Debit)">
        <TopMerchantsBarChart
          data={topMerchantsDebit}
          emptyMessage="No debit merchant data for this selection."
          onBarClick={(point) => handleMerchantClick(point.key)}
        />
      </Panel>

      <Panel title="Top Merchants (Credit)">
        <TopMerchantsBarChart
          data={topMerchantsCredit}
          color="#f97316"
          emptyMessage="No credit merchant data for this selection."
          onBarClick={(point) => handleMerchantClick(point.key)}
        />
      </Panel>

      <Panel title="Top Categories (Debit)">
        <TopMerchantsBarChart
          data={topCategoriesSpent}
          color="#1d4ed8"
          emptyMessage="No category spend data for this selection."
          onBarClick={(point) => handleCategoryClick(point.key)}
        />
      </Panel>
    </div>
  );
}

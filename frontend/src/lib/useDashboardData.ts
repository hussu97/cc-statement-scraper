import { useEffect, useMemo, useState } from 'react';

import { api } from '../api';
import { isAbortError } from './errors';
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

export type DashboardData = {
  filterMeta: DashboardFilterMeta;
  overview: DashboardOverview;
  trendSeries: TrendSeriesResponse;
  bankTrendSeries: StackedSeriesResponse;
  categoryTrendSeries: StackedSeriesResponse;
  bankBreakdown: BreakdownPoint[];
  categoryBreakdown: BreakdownPoint[];
  topMerchantsDebit: BreakdownPoint[];
  topMerchantsCredit: BreakdownPoint[];
  loading: boolean;
  error: string | null;
};

export function useDashboardData(
  filters: DashboardFiltersValue,
  debouncedMerchantSearch: string,
  setFilters: React.Dispatch<React.SetStateAction<DashboardFiltersValue>>,
): DashboardData {
  const activeProfileKey = useActiveProfileKey();

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

  const filterSignature = useMemo(
    () => [activeProfileKey, filters.dateFrom, filters.dateTo, filters.bankCodes.join('|'), filters.categories.join('|')].join('::'),
    [activeProfileKey, filters.dateFrom, filters.dateTo, filters.bankCodes, filters.categories],
  );

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
          api.get<TrendSeriesResponse>(`/dashboard/trend-series${commonSuffix}`, { signal: controller.signal }),
          api.get<StackedSeriesResponse>(`/dashboard/bank-trend-series${commonSuffix}`, { signal: controller.signal }),
          api.get<StackedSeriesResponse>(`/dashboard/category-trend-series?${categoryTrendParams.toString()}`, { signal: controller.signal }),
          api.get<BreakdownPoint[]>(`/dashboard/bank-breakdown${commonSuffix}`, { signal: controller.signal }),
          api.get<BreakdownPoint[]>(`/dashboard/category-breakdown${commonSuffix}`, { signal: controller.signal }),
          api.get<BreakdownPoint[]>(`/dashboard/top-merchants?${topMerchantsDebitParams.toString()}`, { signal: controller.signal }),
          api.get<BreakdownPoint[]>(`/dashboard/top-merchants?${topMerchantsCreditParams.toString()}`, { signal: controller.signal }),
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

  return {
    filterMeta,
    overview,
    trendSeries,
    bankTrendSeries,
    categoryTrendSeries,
    bankBreakdown,
    categoryBreakdown,
    topMerchantsDebit,
    topMerchantsCredit,
    loading,
    error,
  };
}

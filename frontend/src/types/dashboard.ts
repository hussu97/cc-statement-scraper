export type DashboardOverview = {
  total_spend_aed: number;
  total_credits_aed: number;
  uncategorized_count: number;
  uncategorized_ratio: number;
  statement_count: number;
  mom_delta_pct: number | null;
};

export type TrendPoint = {
  bucket: string;
  debit_aed: number;
  credit_aed: number;
  net_aed: number;
};

export type TrendSeriesResponse = {
  points: TrendPoint[];
};

export type StackedSeriesPoint = {
  bucket: string;
  value_aed: number;
};

export type StackedSeries = {
  key: string;
  points: StackedSeriesPoint[];
};

export type StackedSeriesResponse = {
  buckets: string[];
  series: StackedSeries[];
};

export type BreakdownPoint = {
  key: string;
  value: number;
};

export type DashboardFilterMeta = {
  banks: string[];
  categories: string[];
  min_date: string | null;
  max_date: string | null;
};

export type DashboardFiltersValue = {
  dateFrom: string;
  dateTo: string;
  bankCodes: string[];
  categories: string[];
  merchantSearch: string;
};

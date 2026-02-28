export type Statement = {
  id: number;
  bank_code: string;
  statement_reference: string;
  statement_date: string;
  ingested_at: string | null;
  line_count: number;
  pdf_file_id: number | null;
};

export type JobLogEntry = {
  id: number;
  level: string;
  logger: string;
  message: string;
  created_at: string;
};

export type StatementLine = {
  id: number;
  line_no: number;
  transaction_date: string;
  transaction_time: string | null;
  merchant_normalized: string;
  amount_aed: number;
  direction: string;
  category: string | null;
};

export type PagedResponse<T> = {
  items: T[];
  total: number;
};

export type Schedule = {
  id: number;
  name: string;
  job_type: string;
  rrule: string;
  timezone: string;
  status: string;
  payload_json: unknown;
  next_run_at: string | null;
  last_run_at: string | null;
};

export type JobItem = {
  id: number;
  bank_code: string | null;
  target_month: string | null;
  status: string;
  message: string | null;
  metadata_json: unknown;
};

export type Job = {
  id: number;
  job_type: string;
  status: string;
  progress_percent: number | null;
  created_at: string | null;
  started_at: string | null;
  finished_at: string | null;
  error_message: string | null;
  items: JobItem[];
  [key: string]: unknown;
};

export type Bank = {
  code: string;
  name: string;
  supports_historical_month_selection: boolean;
  supports_multi_month: boolean;
  supports_headless: boolean;
};

export type Category = {
  id: number;
  name: string;
};

export type CategoryRule = {
  id: number;
  name: string;
  category_name: string;
  match_type: string;
  pattern: string;
  active: boolean;
};

export type RuleTestResult = {
  matched: boolean;
  category_name: string | null;
  rule_name: string | null;
};

export type RawLine = {
  id: number;
  transaction_date: string;
  transaction_time: string | null;
  merchant_raw: string;
  merchant_normalized: string;
  amount_aed: number;
  direction: string;
  category: string | null;
  bank_code: string;
  statement_id: number;
};

export type RuntimeSetting = {
  id: number;
  profile_id: number;
  bank_code: string;
  key: string;
  value: string;
};

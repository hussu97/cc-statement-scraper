// CSV for the Activity export (WEB-24). Pure, so it is unit-tested; the rows come from
// public.activity_export and money stays the decimal strings the server returned (§2.2).

/** A plain decimal number ("-40.00", "1234.5"): safe as is, never a formula. */
const DECIMAL = /^-?\d+(\.\d+)?$/;
/** A spreadsheet reads a cell starting with these as a formula (CSV injection). */
const FORMULA_START = /^[=+\-@\t\r]/;

/**
 * One CSV cell. A text that a spreadsheet would run as a formula gets a leading apostrophe;
 * a plain decimal number passes through, so "-40.00" stays a number. Cells holding a comma,
 * quote, line break or edge whitespace are quoted (RFC 4180).
 */
export function csvCell(value: string | null | undefined): string {
  if (value === null || value === undefined) return "";
  let s = value;
  if (FORMULA_START.test(s) && !DECIMAL.test(s)) s = `'${s}`;
  if (/[",\r\n]/.test(s) || s !== s.trim()) s = `"${s.replace(/"/g, '""')}"`;
  return s;
}

/** Header and rows as CSV text, CRLF line endings, one trailing line break. */
export function toCsv(header: readonly string[], rows: readonly (readonly (string | null | undefined)[])[]): string {
  return [header, ...rows].map((r) => r.map(csvCell).join(",")).join("\r\n") + "\r\n";
}

/** One row of public.activity_export. Money fields are decimal strings. */
export interface ExportRow {
  txn_code: string;
  txn_date: string;
  txn_time: string | null;
  description: string | null;
  merchant_name: string | null;
  category_name: string | null;
  bank_code: string | null;
  card_last4: string | null;
  account_nickname: string | null;
  direction: "debit" | "credit";
  amount_original: string | null;
  currency_original: string | null;
  amount_aed: string | null;
  net_aed: string | null;
  amount_aed_is_estimate: boolean | null;
  status: string;
  source: "sms" | "statement" | "both" | null;
  exclude_from_spend: boolean | null;
  notes: string | null;
}

const yesNo = (v: boolean | null) => (v ? "yes" : "no");

const COLUMNS: [string, (r: ExportRow) => string | null][] = [
  ["Date", (r) => r.txn_date],
  ["Time", (r) => r.txn_time],
  ["Description", (r) => r.description],
  ["Merchant", (r) => r.merchant_name],
  ["Category", (r) => r.category_name],
  ["Card", (r) => [r.bank_code, r.card_last4 && `•${r.card_last4}`].filter(Boolean).join(" ") || null],
  ["Account", (r) => r.account_nickname],
  ["Direction", (r) => r.direction],
  ["Amount", (r) => r.amount_original],
  ["Currency", (r) => r.currency_original],
  ["Amount AED", (r) => r.amount_aed],
  ["Net AED", (r) => r.net_aed],
  ["AED estimated", (r) => yesNo(r.amount_aed_is_estimate)],
  ["Status", (r) => r.status],
  ["Source", (r) => r.source],
  ["Excluded from spend", (r) => yesNo(r.exclude_from_spend)],
  ["Notes", (r) => r.notes],
  ["Transaction code", (r) => r.txn_code],
];

/** The Activity export as CSV text, one line per transaction in the server's order. */
export function activityCsv(rows: readonly ExportRow[]): string {
  return toCsv(
    COLUMNS.map(([h]) => h),
    rows.map((r) => COLUMNS.map(([, get]) => get(r))),
  );
}

/** "bank-ledger-activity-2026-10-13.csv" for the given Dubai date. */
export function activityCsvFilename(day: string): string {
  return `bank-ledger-activity-${day}.csv`;
}

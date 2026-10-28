// What the sync adds to Zerodha's holdings (tasks/todo.md §13), all optional: a failure leaves the
// position as Kite reported it.
//   GET api.kite.trade/instruments/{NSE,BSE}        public CSV: a share's or ETF's company name
//   GET api.kite.trade/mf/instruments              CSV: a fund's scheme type and fund house (AMC)
//   GET portal.amfiindia.com/spages/NAVAll.txt      public: each fund's latest NAV, its date and fund
//                                                   house (Coin's NAV lags AMFI's by days and is undated)
//   GET /mf/sips, /mf/orders                        Coin SIPs and their latest instalment's outcome
// Parsers are pure (tested in _tests/zerodha_sync_test.ts).

import { dec } from "../swissquote-sync/swissquote.ts";

export const AMFI_NAV_URL = "https://portal.amfiindia.com/spages/NAVAll.txt";

/** RFC 4180-ish CSV: quoted fields, doubled quotes; returns rows of cells. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ",") {
      row.push(cell);
      cell = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(cell);
      if (row.length > 1 || row[0] !== "") rows.push(row);
      row = [];
      cell = "";
    } else cell += ch;
  }
  if (cell !== "" || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }
  return rows;
}

/** Rows keyed by the header line's names. */
function records(text: string): Record<string, string>[] {
  const [head, ...rows] = parseCsv(text);
  if (!head) return [];
  return rows.map((r) => Object.fromEntries(head.map((h, i) => [h.trim(), (r[i] ?? "").trim()])));
}

/** An exchange's instrument list → company names for the symbols asked, keyed `EXCHANGE:SYMBOL`. */
export function instrumentNames(csv: string, exchange: string, symbols: Set<string>): Map<string, string> {
  const out = new Map<string, string>();
  for (const r of records(csv)) {
    if (r.exchange !== exchange || !symbols.has(r.tradingsymbol) || !r.name) continue;
    out.set(`${exchange}:${r.tradingsymbol}`, r.name.replace(/\s+/g, " "));
  }
  return out;
}

export interface FundInfo {
  category: string | null;
  issuer: string | null;
}

/** /mf/instruments → each asked fund's scheme type and fund house, by ISIN (its tradingsymbol). */
export function fundCatalogue(csv: string, isins: Set<string>): Map<string, FundInfo> {
  const out = new Map<string, FundInfo>();
  for (const r of records(csv)) {
    if (!isins.has(r.tradingsymbol)) continue;
    out.set(r.tradingsymbol, { category: r.scheme_type || null, issuer: r.amc || null });
  }
  return out;
}

const MONTHS: Record<string, string> = {
  Jan: "01",
  Feb: "02",
  Mar: "03",
  Apr: "04",
  May: "05",
  Jun: "06",
  Jul: "07",
  Aug: "08",
  Sep: "09",
  Oct: "10",
  Nov: "11",
  Dec: "12",
};

export interface AmfiNav {
  nav: string;
  date: string;
  /** The fund house, as AMFI names it ("Northwind Mutual Fund"). */
  house: string | null;
}

/** AMFI's NAVAll.txt → NAV, ISO date and fund house for the ISINs asked. Scheme lines are
 * `code;ISIN;ISIN reinvestment;name;plan;option;NAV;27-Oct-2026` (NAV and date always last);
 * between them, a line naming a category (`Open Ended Schemes(…)`) or a fund house. */
export function amfiNavs(text: string, isins: Set<string>): Map<string, AmfiNav> {
  const out = new Map<string, AmfiNav>();
  let house: string | null = null;
  for (const line of text.split(/\r?\n/)) {
    const f = line.split(";").map((x) => x.trim());
    if (f.length === 1) {
      if (f[0] && !/Schemes?\s*\(/i.test(f[0])) house = f[0].slice(0, 80);
      continue;
    }
    if (f.length < 6) continue;
    const m = /^(\d{2})-([A-Z][a-z]{2})-(\d{4})$/.exec(f[f.length - 1]);
    const nav = dec(f[f.length - 2], 8);
    if (!m || !MONTHS[m[2]] || nav === null || !(Number(nav) > 0)) continue;
    const date = `${m[3]}-${MONTHS[m[2]]}-${m[1]}`;
    for (const isin of [f[1], f[2]]) if (isins.has(isin)) out.set(isin, { nav, date, house });
  }
  return out;
}

export interface KiteSip {
  sip_id?: string;
  tradingsymbol?: string;
  fund?: string;
  status?: string;
  frequency?: string;
  instalment_amount?: number;
  instalment_day?: number;
  next_instalment?: string;
  last_instalment?: string;
  completed_instalments?: number;
  step_up?: Record<string, number> | null;
  created?: string;
}

export interface KiteMfOrder {
  instruction_id?: string;
  status?: string;
  status_message?: string;
  order_timestamp?: string;
}

export interface ZerodhaSip {
  sip_id: string;
  isin: string;
  fund: string;
  status: string;
  frequency: string | null;
  amount: string | null;
  day: number | null;
  next_instalment: string | null;
  last_instalment: string | null;
  completed: number | null;
  step_up: Record<string, number> | null;
  created: string | null;
  last_order: { status: string; message: string | null; at: string | null } | null;
}

/** Kite's timestamps are IST wall-clock (`2026-10-05 01:50:30`) → ISO with the offset. */
export function istTimestamp(v: string | undefined | null): string | null {
  const m = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})$/.exec((v ?? "").trim());
  return m ? `${m[1]}T${m[2]}+05:30` : null;
}

const day = (v: string | undefined) => (/^\d{4}-\d{2}-\d{2}/.exec(v ?? "")?.[0] ?? null);

/** /mf/sips + /mf/orders → the SIPs, each with its latest order (an order's instruction_id is
 * its SIP's sip_id). Kite's statuses (ACTIVE, PAUSED, CANCELLED) and order statuses (OPEN,
 * COMPLETE, REJECTED, CANCELLED) are lower-cased. */
export function normalizeSips(sips: KiteSip[], orders: KiteMfOrder[] | null): ZerodhaSip[] {
  const latest = new Map<string, KiteMfOrder>();
  for (const o of orders ?? []) {
    const id = o.instruction_id ?? "";
    const prev = latest.get(id);
    if (id && (!prev || (o.order_timestamp ?? "") > (prev.order_timestamp ?? ""))) latest.set(id, o);
  }
  const out: ZerodhaSip[] = [];
  for (const s of sips ?? []) {
    const id = (s.sip_id ?? "").trim();
    const isin = (s.tradingsymbol ?? "").trim().toUpperCase();
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id) || !/^[A-Z]{2}[A-Z0-9]{9}[0-9]$/.test(isin)) continue;
    const o = latest.get(id);
    const status = (o?.status ?? "").toLowerCase();
    out.push({
      sip_id: id,
      isin,
      fund: (s.fund ?? "").trim() || isin,
      status: (s.status ?? "").toLowerCase(),
      frequency: (s.frequency ?? "").trim() || null,
      amount: dec(s.instalment_amount, 2),
      day: Number.isInteger(s.instalment_day) ? s.instalment_day! : null,
      next_instalment: day(s.next_instalment),
      last_instalment: istTimestamp(s.last_instalment),
      completed: Number.isInteger(s.completed_instalments) ? s.completed_instalments! : null,
      step_up: s.step_up && typeof s.step_up === "object" && Object.keys(s.step_up).length > 0 ? s.step_up : null,
      created: istTimestamp(s.created),
      last_order: o
        ? {
          status: ["complete", "rejected", "cancelled"].includes(status) ? status : "open",
          message: (o.status_message ?? "").trim().slice(0, 200) || null,
          at: istTimestamp(o.order_timestamp),
        }
        : null,
    });
  }
  return out;
}

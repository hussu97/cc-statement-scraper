// RL360's Online Service Centre (service.rl360.com): sign-in and the pages the sync reads,
// mapped read-only on 21 Oct 2026 (tasks/todo.md §8). Plain HTML, no JavaScript needed:
//   POST customer.cgi?option=login           USERNAME, PASSWORD, option=login → session cookie
//   GET  customer.cgi/SC/                    dashboard: links to servicing/summary.php?PolNumber=…
//   GET  SC/servicing/valuation.php          plan header + holdings; `day/month/year` gives the
//                                            value on a past date (the `Total` row's policy value)
//   GET  SC/servicing/history.php            subtab=premiums with a date range: every premium
//   GET  customer.cgi?option=logout
// Parsers are pure (tested in _tests/rl360_sync_test.ts); errors never carry page text or logins.

export const RL360_BASE = "https://service.rl360.com/scripts/customer.cgi";
const SERVICING = `${RL360_BASE}/SC/servicing`;

export interface Rl360Login {
  profile_code: string;
  username: string;
  password: string;
}

export interface PlanValuation {
  plan: string;
  currency: string;
  started_on: string; // YYYY-MM-DD
  as_of: string; // the valuation date asked for
  value: string; // decimal string, policy currency
}

export interface Premium {
  ref: string; // premium:<due date>, unique per plan
  date: string; // date received
  amount: string; // amount received, policy currency
}

const MONTHS: Record<string, string> = {
  jan: "01",
  feb: "02",
  mar: "03",
  apr: "04",
  may: "05",
  jun: "06",
  jul: "07",
  aug: "08",
  sep: "09",
  oct: "10",
  nov: "11",
  dec: "12",
};

/** "10 Jan 2022" → "2022-01-10"; null when it is not such a date. */
export function rl360Date(text: string): string | null {
  const m = text.trim().match(/^(\d{1,2}) ([A-Za-z]{3}) (\d{4})$/);
  const month = m && MONTHS[m[2].toLowerCase()];
  return m && month ? `${m[3]}-${month}-${m[1].padStart(2, "0")}` : null;
}

/** "123,456.78" → "123456.78"; null unless a plain non-negative amount. */
export function rl360Amount(text: string): string | null {
  const s = text.trim().replace(/,/g, "");
  return /^\d+(\.\d+)?$/.test(s) ? s : null;
}

/** RL360_LOGINS: a JSON array of {profile_code, username, password}. Never echoes values. */
export function parseLogins(raw: string | undefined): Rl360Login[] {
  if (!raw || !raw.trim()) return [];
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    throw new Error("RL360_LOGINS is not JSON");
  }
  if (!Array.isArray(data)) throw new Error("RL360_LOGINS must be a JSON array");
  return data.map((x, i) => {
    const o = x as Record<string, unknown>;
    if (
      typeof o?.profile_code !== "string" || !/^prf_[0-9a-z]{26}$/.test(o.profile_code) ||
      typeof o.username !== "string" || !o.username || typeof o.password !== "string" || !o.password
    ) {
      throw new Error(`RL360_LOGINS[${i}] needs profile_code (prf_…), username and password`);
    }
    return { profile_code: o.profile_code, username: o.username, password: o.password };
  });
}

/** Signed in: the page offers sign-out. */
export function isSignedIn(html: string): boolean {
  return /customer\.cgi\?option=logout/.test(html);
}

/** The plan numbers on the dashboard, in page order. */
export function parsePlans(html: string): string[] {
  const out: string[] = [];
  for (const m of html.matchAll(/summary\.php\?PolNumber=([A-Za-z0-9-]{3,40})/g)) {
    if (!out.includes(m[1])) out.push(m[1]);
  }
  return out;
}

function headerField(html: string, label: string): string | null {
  const m = html.match(new RegExp(`<b>\\s*${label}:\\s*</b>\\s*([^<]+?)\\s*<`, "i"));
  return m ? m[1] : null;
}

/** A valuation page (today's or a past date's): plan, currency, start date, date and value. */
export function parseValuation(html: string): PlanValuation {
  const plan = headerField(html, "Policy number");
  const currency = headerField(html, "Currency");
  const started = headerField(html, "Start date");
  const asOf = html.match(/Valuation date:\s*(\d{1,2} [A-Za-z]{3} \d{4})/);
  const total = html.match(/<b>\s*Total\s*<\/b>\s*<\/td>[\s\S]*?id="t2header7"[^>]*>\s*([\d,]+\.\d{2})\s*<\/td>/);
  const out = {
    plan: plan && /^[A-Za-z0-9-]{3,40}$/.test(plan) ? plan : null,
    currency: currency && /^[A-Z]{3}$/.test(currency) ? currency : null,
    started_on: started ? rl360Date(started) : null,
    as_of: asOf ? rl360Date(asOf[1]) : null,
    value: total ? rl360Amount(total[1]) : null,
  };
  const missing = Object.entries(out).filter(([, v]) => v === null).map(([k]) => k);
  if (missing.length > 0) throw new Error(`RL360 valuation page: no ${missing.join(", ")} (layout changed?)`);
  return out as PlanValuation;
}

function cell(row: string, id: string): string | null {
  const m = row.match(new RegExp(`id="${id}"[^>]*>\\s*([^<]*?)\\s*</td>`));
  return m ? m[1] : null;
}

/** The premium history: premiums actually received (incentive rows of 0 are bonuses, skipped). */
export function parsePremiums(html: string): Premium[] {
  if (!/Premium history/.test(html) || !/id="t2header4"/.test(html)) {
    throw new Error("RL360 premium history: no premium table (layout changed?)");
  }
  const out: Premium[] = [];
  const seen = new Map<string, number>();
  for (const row of html.split(/<tr\b/).slice(1)) {
    const due = rl360Date(cell(row, "t2header2") ?? "");
    const received = rl360Date(cell(row, "t2header4") ?? "");
    const amount = rl360Amount(cell(row, "t2header5") ?? "");
    if (!due || !received || !amount || Number(amount) <= 0) continue;
    const n = (seen.get(due) ?? 0) + 1;
    seen.set(due, n);
    out.push({ ref: n === 1 ? `premium:${due}` : `premium:${due}#${n}`, date: received, amount });
  }
  return out;
}

/** "Withdrawal total" on the history page, as a decimal string (null if absent). */
export function parseWithdrawalTotal(html: string): string | null {
  const m = html.match(/Withdrawal<br\s*\/?>\s*total:\s*<\/p>\s*<p[^>]*>\s*[A-Z]{3}\s*([\d,]+\.\d{2})/);
  return m ? rl360Amount(m[1]) : null;
}

function dmy(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `day=${Number(d)}&month=${Number(m)}&year=${y}`;
}

export function valuationUrl(plan: string, asOf?: string): string {
  const base = `${SERVICING}/valuation.php?PolNumber=${encodeURIComponent(plan)}`;
  return asOf ? `${base}&SortField=InvestmentFund&SortOrder=up&${dmy(asOf)}&continue=Continue` : base;
}

export function premiumsUrl(plan: string, from: string, to: string): string {
  return `${SERVICING}/history.php?PolNumber=${encodeURIComponent(plan)}&SortField=ReceivedDate&SortOrder=down&${
    dmy(from)
  }&${dmy(to).replace(/(day|month|year)=/g, "e$1=")}&continue=Continue&subtab=premiums`;
}

/** A cookie-keeping session for one login. Redirects are followed by hand to keep cookies. */
export class Rl360Session {
  #cookies = new Map<string, string>();
  constructor(
    private readonly fetchFn: typeof fetch = fetch,
    private readonly userAgent = "Mozilla/5.0 (compatible; BankLedger/1.0)",
  ) {}

  async #request(url: string, init: RequestInit = {}, hops = 0): Promise<string> {
    const headers = new Headers(init.headers);
    headers.set("user-agent", this.userAgent);
    if (this.#cookies.size > 0) {
      headers.set("cookie", [...this.#cookies].map(([k, v]) => `${k}=${v}`).join("; "));
    }
    const res = await this.fetchFn(url, { ...init, headers, redirect: "manual", signal: AbortSignal.timeout(20_000) });
    for (const c of res.headers.getSetCookie?.() ?? []) {
      const [pair] = c.split(";");
      const i = pair.indexOf("=");
      if (i > 0) this.#cookies.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
    }
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      await res.body?.cancel();
      if (hops >= 5) throw new Error("RL360: too many redirects");
      return await this.#request(new URL(res.headers.get("location")!, url).toString(), {}, hops + 1);
    }
    if (!res.ok) {
      await res.body?.cancel();
      throw new Error(`RL360 ${new URL(url).pathname.split("/").pop()} HTTP ${res.status}`);
    }
    return await res.text();
  }

  get(url: string): Promise<string> {
    return this.#request(url);
  }

  async login(username: string, password: string): Promise<void> {
    const body = new URLSearchParams({ USERNAME: username, PASSWORD: password, option: "login", login: "Sign in" });
    await this.#request(`${RL360_BASE}?option=login`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    if (!isSignedIn(await this.get(`${RL360_BASE}/SC/`))) {
      throw new Error("RL360: sign-in refused (check the login in RL360_LOGINS)");
    }
  }

  async logout(): Promise<void> {
    await this.get(`${RL360_BASE}?option=logout`).catch(() => {});
  }
}

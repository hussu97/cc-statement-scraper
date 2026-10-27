// Swissquote's web platform (trade.swissquote.ch): sign-in and the JSON the sync reads, mapped
// read-only on 27 Oct 2026 (tasks/todo.md §11). No browser is needed:
//   GET  /                                   → /my.policy (F5 session cookies)
//   POST /my.policy                          username, password, vhost=standard → …?url_id=<id>
//   GET  /sq-thirdlevel-plugin/api/thirdlevel/l3Code/challenge?urlId=…   {challenge: "a8", sessionId}
//   POST /sq-thirdlevel-plugin/api/thirdlevel/l3Code/validate            {answer, sessionId, urlId}
//   GET  <redirectionBaseUrl>?urlId=…        the session is signed in
// (`challenge/preference` would start the app's push approval instead: never called.)
// Then, with header x-sq-application-id: WLS:
//   GET  …portfoliooverview-plugin/api/portfolio-overview/        portfolioId, iban
//   GET  …accountsummary-plugin/api/config                         portfolioCreationDate
//   GET  …assets-plugin/api/assets/CHF/<ccy>                       cash per currency
//   GET  …positions-plugin/api/positions/CHF/<ccy>?groupingType=PRODUCT_TYPE
//   POST /eding_fox-transactions-plugin/rest-api/transactions      every movement, running balance
//   GET  …accountsummary-plugin/api/performance/portfolio/<from>/<ccy>   daily TWR/MWR %
//   GET  …fullquote-plugin/api/fullQuote/<isin>/<exchange>_<ccy>   a product's type
//   POST /sqc-messages-plugin/webapi/messages/findMessages         trade tickets and attachments
//   GET  /sqc-messages-plugin/webapi/issues/attachment/<message>/<attachment>
// A new sign-in ends any other open Swissquote session. Parsers are pure (tested in
// _tests/swissquote_sync_test.ts); errors never carry logins, codes or response bodies.

export const SQ_BASE = "https://trade.swissquote.ch";
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/141.0.0.0 Safari/537.36";

export interface SwissquoteLogin {
  profile_code: string;
  username: string;
  password: string;
  /** The Level-3 matrix card: cell ("a1".."j10") → code. */
  card: Record<string, string>;
  currency: string;
}

const CELL = /^[a-j]([1-9]|10)$/;

/** SWISSQUOTE_LOGINS: a JSON array of {profile_code, username, password, card, currency?}. Never echoes values. */
export function parseLogins(raw: string | undefined): SwissquoteLogin[] {
  if (!raw || !raw.trim()) return [];
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    throw new Error("SWISSQUOTE_LOGINS is not JSON");
  }
  if (!Array.isArray(data)) throw new Error("SWISSQUOTE_LOGINS must be a JSON array");
  return data.map((x, i) => {
    const o = x as Record<string, unknown>;
    const card = o?.card as Record<string, unknown> | undefined;
    const cardOk = !!card && typeof card === "object" && Object.keys(card).length >= 10 &&
      Object.entries(card).every(([k, v]) =>
        CELL.test(k.toLowerCase()) && typeof v === "string" && /^\d{2,8}$/.test(v)
      );
    if (
      typeof o?.profile_code !== "string" || !/^prf_[0-9a-z]{26}$/.test(o.profile_code) ||
      typeof o.username !== "string" || !o.username || typeof o.password !== "string" || !o.password || !cardOk
    ) {
      throw new Error(`SWISSQUOTE_LOGINS[${i}] needs profile_code (prf_…), username, password and card {a1: "…", …}`);
    }
    const currency = typeof o.currency === "string" && /^[A-Z]{3}$/.test(o.currency) ? o.currency : "USD";
    const cells = Object.fromEntries(Object.entries(card!).map(([k, v]) => [k.toLowerCase(), v as string]));
    return { profile_code: o.profile_code, username: o.username, password: o.password, card: cells, currency };
  });
}

/** "a8", "A 8", "8a" → "a8"; null when the text names no card cell. */
export function cardCell(text: string): string | null {
  const t = text.trim().toLowerCase().replace(/\s+/g, "");
  if (CELL.test(t)) return t;
  const m = t.match(/^(10|[1-9])([a-j])$/);
  return m ? `${m[2]}${m[1]}` : null;
}

/** A cookie-keeping session for one login. Redirects are followed by hand to keep cookies. */
export class SwissquoteSession {
  #cookies = new Map<string, string>();
  constructor(private readonly fetchFn: typeof fetch = fetch) {}

  async #request(url: string, init: RequestInit = {}, hops = 0): Promise<{ res: Response; url: string }> {
    const headers = new Headers(init.headers);
    headers.set("user-agent", UA);
    headers.set("accept-language", "en-US,en;q=0.9");
    if (this.#cookies.size > 0) {
      headers.set("cookie", [...this.#cookies].map(([k, v]) => `${k}=${v}`).join("; "));
    }
    const res = await this.fetchFn(url, { ...init, headers, redirect: "manual", signal: AbortSignal.timeout(30_000) });
    for (const c of res.headers.getSetCookie?.() ?? []) {
      const [pair] = c.split(";");
      const i = pair.indexOf("=");
      if (i > 0) this.#cookies.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
    }
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      await res.body?.cancel();
      if (hops >= 8) throw new Error("Swissquote: too many redirects");
      return await this.#request(new URL(res.headers.get("location")!, url).toString(), {}, hops + 1);
    }
    return { res, url };
  }

  async #ok(path: string, init: RequestInit = {}): Promise<{ res: Response; url: string }> {
    const out = await this.#request(path.startsWith("http") ? path : SQ_BASE + path, init);
    if (!out.res.ok) {
      await out.res.body?.cancel();
      throw new Error(`Swissquote ${new URL(out.url).pathname} HTTP ${out.res.status}`);
    }
    return out;
  }

  async getJson<T>(path: string): Promise<T> {
    const { res } = await this.#ok(path, { headers: apiHeaders() });
    return await res.json() as T;
  }

  async postJson<T>(path: string, body: unknown): Promise<T> {
    const { res } = await this.#ok(path, {
      method: "POST",
      headers: { ...apiHeaders(), "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    return await res.json() as T;
  }

  async getBytes(path: string): Promise<Uint8Array> {
    const { res } = await this.#ok(path);
    return new Uint8Array(await res.arrayBuffer());
  }

  async login(login: SwissquoteLogin): Promise<void> {
    const start = await this.#ok("/");
    await start.res.body?.cancel();
    const form = new URLSearchParams({ username: login.username, password: login.password, vhost: "standard" });
    const posted = await this.#ok("/my.policy", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        origin: SQ_BASE,
        referer: `${SQ_BASE}/my.policy`,
      },
      body: form.toString(),
    });
    await posted.res.body?.cancel();
    const urlId = new URL(posted.url).searchParams.get("url_id");
    if (!urlId) throw new Error("Swissquote: sign-in refused (check the login in SWISSQUOTE_LOGINS)");
    const tz = "timezone=Asia/Dubai";
    const ch = await this.getJson<{ l3CodeChallenge?: { challenge?: string; sessionId?: string } }>(
      `/sq-thirdlevel-plugin/api/thirdlevel/l3Code/challenge?urlId=${encodeURIComponent(urlId)}&${tz}`,
    );
    const cell = cardCell(ch.l3CodeChallenge?.challenge ?? "");
    const answer = cell ? login.card[cell] : undefined;
    if (!cell || !ch.l3CodeChallenge?.sessionId) throw new Error("Swissquote: no matrix card challenge");
    if (!answer) throw new Error("Swissquote: the card in SWISSQUOTE_LOGINS has no code for the cell asked");
    const v = await this.postJson<{ status?: string; redirectionBaseUrl?: string }>(
      `/sq-thirdlevel-plugin/api/thirdlevel/l3Code/validate?queryRedirectBaseUrl=true&${tz}`,
      { answer, sessionId: ch.l3CodeChallenge.sessionId, urlId },
    );
    if (v.status !== "SUCCESS" || !v.redirectionBaseUrl?.startsWith("/")) {
      throw new Error(`Swissquote: card code refused (${v.status ?? "no status"})`);
    }
    const done = await this.#ok(`${v.redirectionBaseUrl}?urlId=${encodeURIComponent(urlId)}`);
    await done.res.body?.cancel();
  }

  async logout(): Promise<void> {
    await this.#request(`${SQ_BASE}/my.logout.php3`).then((o) => o.res.body?.cancel()).catch(() => {});
  }
}

function apiHeaders(): Record<string, string> {
  return {
    accept: "application/json",
    "x-sq-application-id": "WLS",
    origin: SQ_BASE,
    referer: `${SQ_BASE}/eding_trading-platform/`,
  };
}

// ── normalisers: the platform's JSON → import_broker_data's payload (decimal strings) ──

/** A number as a plain decimal string (no exponent, at most `dp` places); null when absent. */
export function dec(v: unknown, dp = 8): string | null {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : Number(v);
  if (!Number.isFinite(n)) return null;
  const s = n.toFixed(dp);
  return s.includes(".") ? s.replace(/0+$/, "").replace(/\.$/, "") : s;
}

export interface SqTransaction {
  transactionId: number | string;
  isReversal?: boolean;
  date: string;
  action?: string | null;
  label?: string | null;
  isin?: string | null;
  name?: string | null;
  stockSymbol?: string | null;
  quantity?: number | null;
  unitPrice?: number | null;
  netAmount?: number | null;
  currency?: string | null;
  commissions?: number | null;
  balance?: number | null;
  noContract?: number | string | null;
  exchangeId?: number | null;
  securityCurrency?: string | null;
}

export interface BrokerTransaction {
  id: string;
  booked_at: string;
  action: string;
  label: string;
  reversal: boolean;
  isin: string | null;
  name: string | null;
  symbol: string | null;
  quantity: string | null;
  unit_price: string | null;
  net_amount: string;
  currency: string;
  commission: string;
  balance: string | null;
  contract_ref: string | null;
}

const ISIN = /^[A-Z]{2}[A-Z0-9]{9}[0-9]$/;

/** One row per movement; a reversal shares its original's id, so it gets "-R". */
export function normalizeTransactions(rows: SqTransaction[]): BrokerTransaction[] {
  return rows
    .filter((t) => t.transactionId !== undefined && t.transactionId !== null && t.date)
    .map((t) => {
      const reversal = t.isReversal === true;
      const isin = t.isin && ISIN.test(t.isin) ? t.isin : null;
      return {
        id: `${t.transactionId}${reversal ? "-R" : ""}`,
        booked_at: new Date(t.date).toISOString(),
        action: (t.action ?? "?").slice(0, 10),
        label: (t.label ?? t.action ?? "?").trim().slice(0, 60),
        reversal,
        isin,
        name: t.name?.trim() || null,
        symbol: t.stockSymbol?.trim() || null,
        quantity: dec(t.quantity, 6),
        unit_price: dec(t.unitPrice, 8),
        net_amount: dec(t.netAmount ?? 0, 2) ?? "0",
        currency: (t.currency ?? t.securityCurrency ?? "USD").toUpperCase(),
        commission: dec(t.commissions ?? 0, 2) ?? "0",
        balance: dec(t.balance, 2),
        contract_ref: t.noContract === null || t.noContract === undefined ? null : String(t.noContract),
      };
    });
}

interface SqPosition {
  symbol?: string;
  isin?: string;
  name?: string;
  productDisplayName?: string;
  detailedProductType?: string;
  positionProductGroupType?: string;
  quantity?: number;
  unitCost?: number;
  totalValue?: number;
  price?: number;
  currency?: string;
  profitAndLoss?: { valueProductCcy?: number };
  quotationType?: string;
}

export interface BrokerPosition {
  isin: string;
  name: string;
  symbol: string | null;
  product_type: string;
  quantity: string;
  price: string | null;
  price_in_pct: boolean;
  value: string | null;
  cost_price: string | null;
  profit: string | null;
  currency: string;
}

/** The positions API groups by product type; a note is quoted in % (PERCENT) of its nominal. */
export function normalizePositions(
  body: { groupedPositions?: Record<string, { positions?: SqPosition[] }> },
): BrokerPosition[] {
  const out: BrokerPosition[] = [];
  for (const [group, g] of Object.entries(body.groupedPositions ?? {})) {
    for (const p of g.positions ?? []) {
      if (!p.isin || !ISIN.test(p.isin) || typeof p.quantity !== "number") continue;
      const pct = p.quotationType === "PERCENT";
      const type = p.detailedProductType === "SHARE" || group === "SHARES"
        ? "SHARE"
        : (group || p.detailedProductType || "OTHER");
      // totalValue is in the product currency; a note at 93.42% of 25,000 is 23,355.
      const value = typeof p.totalValue === "number" ? p.totalValue : null;
      out.push({
        isin: p.isin,
        name: (p.name || p.productDisplayName || p.symbol || p.isin).trim(),
        symbol: p.symbol?.trim() || null,
        product_type: type,
        quantity: dec(p.quantity, 6)!,
        price: dec(p.price, 8),
        price_in_pct: pct,
        value: dec(value, 2),
        cost_price: dec(p.unitCost, 8),
        profit: value !== null && typeof p.unitCost === "number"
          ? dec(value - p.quantity * p.unitCost * (pct ? 0.01 : 1), 2)
          : dec(p.profitAndLoss?.valueProductCcy, 2),
        currency: (p.currency ?? "USD").toUpperCase(),
      });
    }
  }
  return out;
}

/** Cash in one currency from the assets API (balance includes trades booked but not yet settled). */
export function cashIn(
  body: { assets?: { currency?: string; cashBalance?: number }[] },
  currency: string,
): string | null {
  const a = body.assets?.find((x) => x.currency === currency);
  return a && typeof a.cashBalance === "number" ? dec(a.cashBalance, 2) : null;
}

/** A day's move beyond this is a valuation artifact of the platform's index, not a return. */
export const MAX_DAILY_MOVE = 0.12;

export interface Snapshot {
  as_of: string;
  total_value: string;
  estimated: true;
}

/**
 * The account's value per day before the sync kept its own marks, rebuilt from the platform's
 * daily time-weighted return index (cumulative %, `twrPerf`) and the money paid in or out:
 * walking back from today's value, V(d-1) = (V(d) - F(d)) / (1 + r(d)), where r(d) is the day's
 * return and F(d) the net deposits booked that day. Days with no index point are skipped; the
 * walk stops at the first day the account held nothing. The platform's index jumps around a note
 * bought between its trade and settlement dates (+30% on the trade day, −21% when it settles):
 * a daily move beyond MAX_DAILY_MOVE is taken as such an artifact and read as flat.
 */
export function rebuildValues(
  entries: { date: string; twrPerf: number }[],
  flows: Map<string, number>,
  today: string,
  todayValue: number,
): Snapshot[] {
  const pts = entries.filter((e) => typeof e.twrPerf === "number" && e.date < today).sort((a, b) =>
    a.date < b.date ? -1 : 1
  );
  if (pts.length === 0) return [];
  const out: Snapshot[] = [];
  let value = todayValue;
  let nextIndex = 1 + pts[pts.length - 1].twrPerf / 100;
  // Flows booked after the last index day count against today.
  let pending = 0;
  for (const [d, f] of flows) if (d > pts[pts.length - 1].date) pending += f;
  value -= pending;
  for (let i = pts.length - 1; i >= 0; i--) {
    const index = 1 + pts[i].twrPerf / 100;
    if (i < pts.length - 1) {
      const raw = index > 0 ? nextIndex / index - 1 : 0;
      const r = Math.abs(raw) > MAX_DAILY_MOVE ? 0 : raw;
      value = value / (1 + r);
    }
    if (value <= 0.005) break;
    out.push({ as_of: pts[i].date, total_value: value.toFixed(2), estimated: true });
    value -= flows.get(pts[i].date) ?? 0;
    nextIndex = index;
  }
  return out.reverse();
}

/** Net deposits per Dubai day from the normalised transactions. */
export function depositsByDay(rows: BrokerTransaction[], dubaiDay: (iso: string) => string): Map<string, number> {
  const m = new Map<string, number>();
  for (const t of rows) {
    if (t.action !== "G" || t.reversal) continue;
    const d = dubaiDay(t.booked_at);
    m.set(d, (m.get(d) ?? 0) + Number(t.net_amount));
  }
  return m;
}

export interface SqMessage {
  id: string;
  date?: string;
  body?: string;
  subject?: string;
  attachments?: { id: number | string; name?: string; isClientAttachment?: boolean }[];
}

/** The term sheet for an ISIN among the trade tickets: a PDF whose name or ticket names the ISIN. */
export function termSheetFor(
  messages: SqMessage[],
  isin: string,
): { messageId: string; attachmentId: string; name: string } | null {
  for (const m of messages) {
    for (const a of m.attachments ?? []) {
      const name = a.name ?? "";
      if (!/\.pdf$/i.test(name)) continue;
      if (name.toUpperCase().includes(isin) || (m.body ?? "").toUpperCase().includes(isin)) {
        return { messageId: String(m.id), attachmentId: String(a.id), name };
      }
    }
  }
  return null;
}

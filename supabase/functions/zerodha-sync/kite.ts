// Zerodha Kite Connect (the free "Personal" plan, the user's own app): an automatic sign-in and
// the portfolio the sync reads (tasks/todo.md §12). No browser is needed:
//   GET  kite.trade/connect/login?v=3&api_key=…     → kite.zerodha.com/connect/login?…&sess_id=…
//   POST kite.zerodha.com/api/login                  user_id, password → request_id
//   POST kite.zerodha.com/api/twofa                  user_id, request_id, twofa_value (TOTP) → session cookies
//   GET  <the connect URL>&skip_session=true         → … → <redirect_url>?request_token=…  (never followed)
//   POST api.kite.trade/session/token                api_key, request_token, checksum → access_token
// Then, with Authorization: token <api_key>:<access_token>:
//   GET  /user/profile                               the user id (must be the login's)
//   GET  /portfolio/holdings                         Kite: per ISIN, quantity, average and last price
//   GET  /mf/holdings                                Coin: per fund ISIN, units, average price, NAV
//   GET  /user/margins/equity                        Funds: available cash
//   DELETE /session/token                            sign out
// The app must have been authorised once by a sign-in in the browser. Market data (quotes,
// history) is not in the free plan. Parsers are pure (tested in _tests/zerodha_sync_test.ts);
// errors never carry logins, codes, tokens or response bodies.

import { dec } from "../swissquote-sync/swissquote.ts";

export const KITE_WEB = "https://kite.zerodha.com";
export const KITE_CONNECT = "https://kite.trade";
export const KITE_API = "https://api.kite.trade";
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/141.0.0.0 Safari/537.36";

export interface ZerodhaLogin {
  profile_code: string;
  user_id: string;
  password: string;
  /** The base32 seed of the account's TOTP (the authenticator app's key). */
  totp_secret: string;
  api_key: string;
  api_secret: string;
}

/** ZERODHA_LOGINS: a JSON array of {profile_code, user_id, password, totp_secret, api_key, api_secret}. Never echoes values. */
export function parseLogins(raw: string | undefined): ZerodhaLogin[] {
  if (!raw || !raw.trim()) return [];
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    throw new Error("ZERODHA_LOGINS is not JSON");
  }
  if (!Array.isArray(data)) throw new Error("ZERODHA_LOGINS must be a JSON array");
  return data.map((x, i) => {
    const o = (x ?? {}) as Record<string, unknown>;
    const s = (k: string) => (typeof o[k] === "string" ? (o[k] as string).trim() : "");
    const seed = s("totp_secret").replace(/\s+/g, "").toUpperCase();
    if (
      !/^prf_[0-9a-z]{26}$/.test(s("profile_code")) || !/^[A-Za-z0-9]{4,12}$/.test(s("user_id")) ||
      !s("password") || !/^[A-Z2-7]{16,}=*$/.test(seed) || !/^[A-Za-z0-9]{6,64}$/.test(s("api_key")) ||
      !/^[A-Za-z0-9]{6,128}$/.test(s("api_secret"))
    ) {
      throw new Error(
        `ZERODHA_LOGINS[${i}] needs profile_code (prf_…), user_id, password, totp_secret (base32), api_key and api_secret`,
      );
    }
    return {
      profile_code: s("profile_code"),
      user_id: s("user_id").toUpperCase(),
      password: o.password as string,
      totp_secret: seed,
      api_key: s("api_key"),
      api_secret: s("api_secret"),
    };
  });
}

// ── TOTP (RFC 6238: HMAC-SHA1, 30 s steps, 6 digits) ─────────────────────────

/** RFC 4648 base32 → bytes; spaces, padding and case are ignored. */
export function base32Decode(s: string): Uint8Array<ArrayBuffer> {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const clean = s.replace(/[\s=]/g, "").toUpperCase();
  const out: number[] = [];
  let bits = 0;
  let value = 0;
  for (const ch of clean) {
    const i = alphabet.indexOf(ch);
    if (i < 0) throw new Error("TOTP seed is not base32");
    value = (value << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

/** The TOTP for a base32 seed at a time (ms since the epoch). */
export async function totp(seed: string, at = Date.now(), digits = 6, step = 30): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    base32Decode(seed),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const counter = new DataView(new ArrayBuffer(8));
  const t = Math.floor(at / 1000 / step);
  counter.setUint32(0, Math.floor(t / 2 ** 32));
  counter.setUint32(4, t >>> 0);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, counter.buffer));
  const offset = mac[mac.length - 1] & 0x0f;
  const code = ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3];
  return String(code % 10 ** digits).padStart(digits, "0");
}

/** sha256(api_key + request_token + api_secret), hex: the session exchange's checksum. */
export async function checksum(apiKey: string, requestToken: string, apiSecret: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(apiKey + requestToken + apiSecret));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** The request_token in a redirect target, or null. */
export function requestTokenIn(location: string | null): string | null {
  if (!location) return null;
  try {
    const t = new URL(location, KITE_WEB).searchParams.get("request_token");
    return t && /^[A-Za-z0-9]{8,64}$/.test(t) ? t : null;
  } catch {
    return null;
  }
}

/** A Kite error in words that carry nothing of the account: the error type and status only. */
function kiteError(what: string, status: number, body: unknown): Error {
  const type = (body as { error_type?: unknown } | null)?.error_type;
  const t = typeof type === "string" && /^[A-Za-z]{1,40}$/.test(type) ? ` ${type}` : "";
  return new Error(`Kite ${what}: HTTP ${status}${t}`);
}

/** A cookie-keeping session for one login. Redirects are followed by hand, and a redirect carrying the request_token stops. */
export class KiteSession {
  #cookies = new Map<string, string>();
  #accessToken: string | null = null;
  constructor(private readonly login: ZerodhaLogin, private readonly fetchFn: typeof fetch = fetch) {}

  async #request(url: string, init: RequestInit = {}): Promise<Response> {
    const headers = new Headers(init.headers);
    headers.set("user-agent", UA);
    headers.set("x-kite-version", "3");
    if (this.#cookies.size > 0 && new URL(url).hostname !== new URL(KITE_API).hostname) {
      headers.set("cookie", [...this.#cookies].map(([k, v]) => `${k}=${v}`).join("; "));
    }
    const res = await this.fetchFn(url, { ...init, headers, redirect: "manual", signal: AbortSignal.timeout(30_000) });
    for (const c of res.headers.getSetCookie?.() ?? []) {
      const [pair] = c.split(";");
      const i = pair.indexOf("=");
      if (i > 0) this.#cookies.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
    }
    return res;
  }

  /** Follow redirects from url; the URL the chain ends on, or the request_token met on the way. */
  async #walk(url: string): Promise<{ url: string; requestToken: string | null }> {
    let at = url;
    for (let hop = 0; hop < 10; hop++) {
      const res = await this.#request(at);
      const location = res.headers.get("location");
      await res.body?.cancel();
      if (res.status >= 300 && res.status < 400 && location) {
        const token = requestTokenIn(location);
        if (token) return { url: at, requestToken: token };
        at = new URL(location, at).toString();
        continue;
      }
      if (!res.ok) throw new Error(`Kite ${new URL(at).pathname}: HTTP ${res.status}`);
      return { url: at, requestToken: null };
    }
    throw new Error("Kite: too many redirects");
  }

  async #postForm<T>(url: string, form: Record<string, string>, what: string): Promise<T> {
    const res = await this.#request(url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", origin: KITE_WEB, referer: `${KITE_WEB}/` },
      body: new URLSearchParams(form).toString(),
    });
    const body = await res.json().catch(() => null) as { status?: string; data?: T } | null;
    if (!res.ok || body?.status !== "success") throw kiteError(what, res.status, body);
    return body.data as T;
  }

  /** Sign in (password + TOTP), finish the Connect flow and exchange its request_token for an access token. */
  async signIn(now = Date.now): Promise<void> {
    const l = this.login;
    const start = await this.#walk(`${KITE_CONNECT}/connect/login?v=3&api_key=${encodeURIComponent(l.api_key)}`);
    const step1 = await this.#postForm<{ request_id?: string; twofa_type?: string }>(
      `${KITE_WEB}/api/login`,
      { user_id: l.user_id, password: l.password },
      "sign-in",
    );
    if (!step1?.request_id) throw new Error("Kite sign-in: no request id");
    await this.#postForm(
      `${KITE_WEB}/api/twofa`,
      {
        user_id: l.user_id,
        request_id: step1.request_id,
        twofa_value: await totp(l.totp_secret, now()),
        twofa_type: "totp",
        skip_totp: "true",
      },
      "two-factor",
    );
    const sep = start.url.includes("?") ? "&" : "?";
    const finish = await this.#walk(`${start.url}${sep}skip_session=true`);
    if (!finish.requestToken) {
      throw new Error(
        "Kite: no request token (authorise the app once by signing in through its login URL in a browser)",
      );
    }
    const res = await this.#request(`${KITE_API}/session/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        api_key: l.api_key,
        request_token: finish.requestToken,
        checksum: await checksum(l.api_key, finish.requestToken, l.api_secret),
      }).toString(),
    });
    const body = await res.json().catch(() => null) as { status?: string; data?: { access_token?: string } } | null;
    const token = body?.data?.access_token;
    if (!res.ok || body?.status !== "success" || !token) throw kiteError("session", res.status, body);
    this.#accessToken = token;
  }

  async get<T>(path: string): Promise<T> {
    if (!this.#accessToken) throw new Error("Kite: not signed in");
    const res = await this.#request(`${KITE_API}${path}`, {
      headers: { authorization: `token ${this.login.api_key}:${this.#accessToken}` },
    });
    const body = await res.json().catch(() => null) as { status?: string; data?: T } | null;
    if (!res.ok || body?.status !== "success") throw kiteError(path, res.status, body);
    return body.data as T;
  }

  /** Sign out: the access token dies now rather than at 06:00 IST. Never throws. */
  async signOut(): Promise<void> {
    if (!this.#accessToken) return;
    const q = new URLSearchParams({ api_key: this.login.api_key, access_token: this.#accessToken });
    this.#accessToken = null;
    await this.#request(`${KITE_API}/session/token?${q}`, { method: "DELETE" })
      .then((r) => r.body?.cancel())
      .catch(() => undefined);
  }
}

// ── what the sync sends to import_zerodha_data ──────────────────────────────

export interface ZerodhaPosition {
  segment: "kite" | "coin";
  isin: string;
  name: string;
  symbol: string | null;
  quantity: string;
  price: string | null;
  cost_price: string | null;
}

const ISIN = /^[A-Z]{2}[A-Z0-9]{9}[0-9]$/;
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : Number(v ?? NaN));

export interface KiteHolding {
  tradingsymbol?: string;
  isin?: string;
  quantity?: number;
  t1_quantity?: number;
  used_quantity?: number;
  average_price?: number;
  last_price?: number;
  close_price?: number;
}

/** /portfolio/holdings → Kite positions: units held (settled + T1 − sold today), last price (else the close), average price. */
export function normalizeEquity(rows: KiteHolding[]): ZerodhaPosition[] {
  const out: ZerodhaPosition[] = [];
  for (const h of rows ?? []) {
    const isin = (h.isin ?? "").trim().toUpperCase();
    const qty = (num(h.quantity) || 0) + (num(h.t1_quantity) || 0) - (num(h.used_quantity) || 0);
    if (!ISIN.test(isin) || !(qty > 0)) continue;
    const last = num(h.last_price) > 0 ? num(h.last_price) : num(h.close_price);
    const symbol = (h.tradingsymbol ?? "").trim() || null;
    out.push({
      segment: "kite",
      isin,
      name: symbol ?? isin,
      symbol,
      quantity: dec(qty, 6)!,
      price: last > 0 ? dec(last, 8) : null,
      cost_price: dec(h.average_price, 8),
    });
  }
  return out;
}

export interface KiteMfHolding {
  fund?: string;
  tradingsymbol?: string;
  quantity?: number;
  average_price?: number;
  last_price?: number;
}

/** /mf/holdings → Coin positions: the fund's ISIN (its tradingsymbol), units, NAV, average NAV. */
export function normalizeMf(rows: KiteMfHolding[]): ZerodhaPosition[] {
  const out: ZerodhaPosition[] = [];
  for (const h of rows ?? []) {
    const isin = (h.tradingsymbol ?? "").trim().toUpperCase();
    const qty = num(h.quantity);
    if (!ISIN.test(isin) || !(qty > 0)) continue;
    out.push({
      segment: "coin",
      isin,
      name: (h.fund ?? "").trim() || isin,
      symbol: isin,
      quantity: dec(qty, 6)!,
      price: num(h.last_price) > 0 ? dec(h.last_price, 8) : null,
      cost_price: dec(h.average_price, 8),
    });
  }
  return out;
}

/** /user/margins/equity → the available cash, as a decimal string; null when absent. */
export function cashIn(margins: { available?: { cash?: number } } | null | undefined): string | null {
  return dec(margins?.available?.cash, 2);
}

// ── one read ─────────────────────────────────────────────────────────────────

const defaultPause = () => new Promise((r) => setTimeout(r, 400));

export const why = (e: unknown) => (e instanceof Error ? e.message : String(e)).slice(0, 200);

/** Reads the portfolio; a segment that fails is left out of segments_read and named in `failed`. */
export async function readPortfolio(s: Pick<KiteSession, "get">, userId: string, pause = defaultPause) {
  const profile = await s.get<{ user_id?: string }>("/user/profile");
  if ((profile.user_id ?? "").toUpperCase() !== userId) throw new Error("Kite: signed in as another user");
  const positions: ZerodhaPosition[] = [];
  const read: string[] = [];
  const failed: string[] = [];
  await pause();
  try {
    positions.push(...normalizeEquity(await s.get<KiteHolding[]>("/portfolio/holdings")));
    read.push("kite");
  } catch (e) {
    failed.push(`Kite holdings: ${why(e)}`);
  }
  await pause();
  try {
    positions.push(...normalizeMf(await s.get<KiteMfHolding[]>("/mf/holdings")));
    read.push("coin");
  } catch (e) {
    failed.push(`Coin holdings: ${why(e)}`);
  }
  await pause();
  const cash = await s.get<{ available?: { cash?: number } }>("/user/margins/equity")
    .then(cashIn)
    .catch((e) => {
      failed.push(`Funds: ${why(e)}`);
      return null;
    });
  return {
    data: {
      user_id: userId,
      fetched_at: new Date().toISOString(),
      cash,
      segments_read: read,
      positions,
    },
    failed,
  };
}

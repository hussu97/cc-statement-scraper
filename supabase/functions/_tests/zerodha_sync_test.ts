import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1.0.13";
import {
  base32Decode,
  cashIn,
  checksum,
  KITE_API,
  KITE_CONNECT,
  KITE_WEB,
  KiteSession,
  normalizeEquity,
  normalizeMf,
  parseLogins,
  readPortfolio,
  requestTokenIn,
  totp,
} from "../zerodha-sync/kite.ts";

const login = {
  profile_code: "prf_01k4dnbdpbztxjfe7mej2fpqt2",
  user_id: "ab1234",
  password: "pw-secret",
  totp_secret: "gezd gnbv gy3t qojq gezd gnbv gy3t qojq",
  api_key: "kiteapikey1",
  api_secret: "kiteapisecret1",
};

Deno.test("parseLogins: a JSON array; user id upper-cased, seed cleaned; values never echoed", () => {
  assertEquals(parseLogins(undefined), []);
  assertEquals(parseLogins("  "), []);
  const [l] = parseLogins(JSON.stringify([login]));
  assertEquals(l.user_id, "AB1234");
  assertEquals(l.totp_secret, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ");
  assertThrows(() => parseLogins("{"), Error, "not JSON");
  assertThrows(() => parseLogins(JSON.stringify({})), Error, "array");
  const err = assertThrows(() => parseLogins(JSON.stringify([{ ...login, totp_secret: "not base32!" }])), Error);
  assertEquals(err.message.includes("pw-secret"), false);
  assertEquals(err.message.includes("kiteapisecret1"), false);
  assertThrows(() => parseLogins(JSON.stringify([{ ...login, profile_code: "p1" }])), Error, "profile_code");
  assertThrows(() => parseLogins(JSON.stringify([{ ...login, api_secret: "" }])), Error, "api_secret");
});

Deno.test("totp: RFC 6238 SHA-1 vectors", async () => {
  const seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"; // "12345678901234567890"
  assertEquals(new TextDecoder().decode(base32Decode(seed)), "12345678901234567890");
  assertEquals(await totp(seed, 59_000, 8), "94287082");
  assertEquals(await totp(seed, 1111111109_000, 8), "07081804");
  assertEquals(await totp(seed, 1234567890_000, 8), "89005924");
  assertEquals(await totp(seed, 2000000000_000, 8), "69279037");
  assertEquals(await totp(seed, 20000000000_000, 8), "65353130");
  assertEquals(await totp(seed, 59_000), "287082");
  assertThrows(() => base32Decode("AB1"), Error, "base32");
});

Deno.test("checksum: sha256 of key + token + secret, hex", async () => {
  assertEquals(await checksum("a", "b", "c"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

Deno.test("requestTokenIn: the token in a redirect target", () => {
  assertEquals(
    requestTokenIn("http://127.0.0.1/?action=login&type=login&status=success&request_token=Abc123xyz9"),
    "Abc123xyz9",
  );
  assertEquals(requestTokenIn("/connect/finish?api_key=k&sess_id=s"), null);
  assertEquals(requestTokenIn(null), null);
  assertEquals(requestTokenIn("http://x/?request_token=a b"), null);
});

Deno.test("normalizeEquity: units held (settled + T1 − sold), last price else the close, cost; others dropped", () => {
  const out = normalizeEquity([
    {
      tradingsymbol: "INFY",
      isin: "INE009A01021",
      quantity: 10,
      t1_quantity: 2,
      used_quantity: 1,
      average_price: 1450.1234,
      last_price: 1520.5,
      close_price: 1500,
    },
    { tradingsymbol: "SUSP", isin: "ine000a01999", quantity: 5, average_price: 10, last_price: 0, close_price: 9.5 },
    { tradingsymbol: "GONE", isin: "INE000A01011", quantity: 3, used_quantity: 3, average_price: 10, last_price: 11 },
    { tradingsymbol: "NOISIN", isin: "", quantity: 3, average_price: 10, last_price: 11 },
  ]);
  assertEquals(out, [
    {
      segment: "kite",
      isin: "INE009A01021",
      name: "INFY",
      symbol: "INFY",
      quantity: "11",
      price: "1520.5",
      cost_price: "1450.1234",
    },
    {
      segment: "kite",
      isin: "INE000A01999",
      name: "SUSP",
      symbol: "SUSP",
      quantity: "5",
      price: "9.5",
      cost_price: "10",
    },
  ]);
});

Deno.test("normalizeMf: the fund's ISIN, units, NAV and average NAV", () => {
  const out = normalizeMf([
    {
      fund: "Parag Parikh Flexi Cap Fund - Direct Plan",
      tradingsymbol: "INF879O01027",
      quantity: 123.456,
      average_price: 55.1234,
      last_price: 80.9876,
    },
    { fund: "Redeemed", tradingsymbol: "INF000A01011", quantity: 0, average_price: 10, last_price: 11 },
  ]);
  assertEquals(out, [{
    segment: "coin",
    isin: "INF879O01027",
    name: "Parag Parikh Flexi Cap Fund - Direct Plan",
    symbol: "INF879O01027",
    quantity: "123.456",
    price: "80.9876",
    cost_price: "55.1234",
  }]);
});

Deno.test("cashIn: available cash as a decimal string", () => {
  assertEquals(cashIn({ available: { cash: 12345.678 } }), "12345.68");
  assertEquals(cashIn({}), null);
  assertEquals(cashIn(null), null);
});

/** Kite's sign-in, faked: the connect redirect, login, TOTP, the finish chain and the session exchange. */
function fakeKite(opts: { authorised?: boolean; loginStatus?: number } = {}) {
  const calls: { url: string; method: string; body: string; cookie: string | null; auth: string | null }[] = [];
  const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
  const redirect = (to: string, cookie?: string) => {
    const h = new Headers({ location: to });
    if (cookie) h.append("set-cookie", cookie);
    return new Response(null, { status: 302, headers: h });
  };
  const route = (input: string | URL | Request, init?: RequestInit): Response => {
    const url = String(input);
    const headers = new Headers(init?.headers);
    calls.push({
      url,
      method: init?.method ?? "GET",
      body: typeof init?.body === "string" ? init.body : "",
      cookie: headers.get("cookie"),
      auth: headers.get("authorization"),
    });
    const u = new URL(url);
    if (url.startsWith(`${KITE_CONNECT}/connect/login`)) {
      return redirect(`${KITE_WEB}/connect/login?api_key=kiteapikey1&sess_id=S1`);
    }
    if (u.origin === KITE_WEB && u.pathname === "/connect/login") {
      if (u.searchParams.get("skip_session") === "true") {
        return redirect(`/connect/finish?api_key=kiteapikey1&sess_id=S1`);
      }
      return new Response("<html></html>", { status: 200, headers: { "set-cookie": "kf_session=K1; Path=/" } });
    }
    if (u.pathname === "/connect/finish") {
      return opts.authorised === false
        ? redirect(`/connect/authorize?api_key=kiteapikey1&sess_id=S1`)
        : redirect("http://127.0.0.1/?action=login&type=login&status=success&request_token=RT12345678");
    }
    if (u.pathname === "/connect/authorize") return new Response("<html>authorise</html>", { status: 200 });
    if (u.pathname === "/api/login") {
      return opts.loginStatus
        ? json(opts.loginStatus, { status: "error", message: "Invalid `password`.", error_type: "InputException" })
        : json(200, { status: "success", data: { user_id: "AB1234", request_id: "REQ1", twofa_type: "totp" } });
    }
    if (u.pathname === "/api/twofa") {
      return json(200, { status: "success", data: {} }, { "set-cookie": "enctoken=E1; Path=/" });
    }
    if (url === `${KITE_API}/session/token` && init?.method === "POST") {
      return json(200, { status: "success", data: { access_token: "AT1", user_id: "AB1234" } });
    }
    if (u.origin === KITE_API && init?.method === "DELETE") return json(200, { status: "success", data: true });
    if (u.origin === KITE_API && u.pathname === "/user/profile") {
      return json(200, { status: "success", data: { user_id: "AB1234" } });
    }
    return json(404, { status: "error", error_type: "GeneralException" });
  };
  const fetchFn =
    ((input: string | URL | Request, init?: RequestInit) => Promise.resolve(route(input, init))) as typeof fetch;
  return { fetchFn, calls };
}

Deno.test("KiteSession: password + TOTP, the request token from the redirect (never followed), the exchange", async () => {
  const [l] = parseLogins(JSON.stringify([login]));
  const k = fakeKite();
  const s = new KiteSession(l, k.fetchFn);
  await s.signIn(() => 59_000);
  const twofa = k.calls.find((c) => c.url.endsWith("/api/twofa"))!;
  assertEquals(new URLSearchParams(twofa.body).get("twofa_value"), "287082");
  assertEquals(new URLSearchParams(twofa.body).get("request_id"), "REQ1");
  assertEquals(twofa.cookie?.includes("kf_session=K1"), true);
  assertEquals(k.calls.some((c) => c.url.startsWith("http://127.0.0.1")), false);
  const exchange = new URLSearchParams(k.calls.find((c) => c.url === `${KITE_API}/session/token`)!.body);
  assertEquals(exchange.get("request_token"), "RT12345678");
  assertEquals(exchange.get("checksum"), await checksum("kiteapikey1", "RT12345678", "kiteapisecret1"));
  assertEquals(await s.get("/user/profile"), { user_id: "AB1234" });
  const api = k.calls.find((c) => c.url === `${KITE_API}/user/profile`)!;
  assertEquals(api.auth, "token kiteapikey1:AT1");
  assertEquals(api.cookie, null);
  await s.signOut();
  assertEquals(k.calls.at(-1)!.method, "DELETE");
  await assertRejects(() => s.get("/user/profile"), Error, "not signed in");
});

Deno.test("KiteSession: a refused sign-in names the step and error type, never the password or Kite's text", async () => {
  const [l] = parseLogins(JSON.stringify([login]));
  const e = await assertRejects(() => new KiteSession(l, fakeKite({ loginStatus: 400 }).fetchFn).signIn(), Error);
  assertEquals(e.message, "Kite sign-in: HTTP 400 InputException");
  await assertRejects(
    () => new KiteSession(l, fakeKite({ authorised: false }).fetchFn).signIn(),
    Error,
    "authorise the app once",
  );
});

Deno.test("readPortfolio: Kite, Coin and Funds; a segment that fails is left out and named", async () => {
  const ok = (data: unknown) => Promise.resolve(data);
  const s = {
    get: (path: string) => {
      if (path === "/user/profile") return ok({ user_id: "AB1234" });
      if (path === "/portfolio/holdings") {
        return ok([{ tradingsymbol: "INFY", isin: "INE009A01021", quantity: 1, average_price: 1, last_price: 2 }]);
      }
      if (path === "/mf/holdings") return Promise.reject(new Error("Kite /mf/holdings: HTTP 403 PermissionException"));
      return ok({ available: { cash: 10 } });
    },
  } as never;
  const { data, failed } = await readPortfolio(s, "AB1234", () => Promise.resolve());
  assertEquals(data.segments_read, ["kite"]);
  assertEquals(data.positions.length, 1);
  assertEquals(data.cash, "10");
  assertEquals(failed, ["Coin holdings: Kite /mf/holdings: HTTP 403 PermissionException"]);
  await assertRejects(() => readPortfolio(s, "ZZ9999", () => Promise.resolve()), Error, "another user");
});

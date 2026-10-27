import { assertAlmostEquals, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1.0.13";
import {
  cardCell,
  cashIn,
  dec,
  depositsByDay,
  normalizePositions,
  normalizeTransactions,
  parseLogins,
  rebuildValues,
  SwissquoteSession,
  termSheetFor,
} from "../swissquote-sync/swissquote.ts";

const card = Object.fromEntries(
  "abcdefghij".split("").flatMap((l, i) =>
    Array.from({ length: 10 }, (_, r) => [`${l}${r + 1}`, String(1000 + i * 10 + r)])
  ),
);
const login = {
  profile_code: "prf_01m4dnbdpbztxjfe7mej2fpqt2",
  username: "user",
  password: "pw",
  card,
  currency: "USD",
};

Deno.test("parseLogins: a JSON array with a card; values never echoed", () => {
  assertEquals(parseLogins(undefined), []);
  assertEquals(parseLogins(JSON.stringify([{ ...login, currency: undefined }]))[0].currency, "USD");
  assertEquals(parseLogins(JSON.stringify([{ ...login, card: { ...card, A1: "1234" } }]))[0].card.a1, "1234");
  assertThrows(() => parseLogins("{"), Error, "not JSON");
  assertThrows(() => parseLogins(JSON.stringify({})), Error, "array");
  const err = assertThrows(() => parseLogins(JSON.stringify([{ ...login, card: { a1: "12" } }])), Error);
  assertEquals(err.message.includes("pw"), false);
  assertThrows(() => parseLogins(JSON.stringify([{ ...login, card: { ...card, k1: "1" } }])), Error, "card");
});

Deno.test("cardCell: the cell the challenge names", () => {
  assertEquals(cardCell("a8"), "a8");
  assertEquals(cardCell(" J 10 "), "j10");
  assertEquals(cardCell("8a"), "a8");
  assertEquals(cardCell("k1"), null);
  assertEquals(cardCell(""), null);
});

Deno.test("dec: plain decimal strings", () => {
  assertEquals(dec(0.745), "0.745");
  assertEquals(dec(920.5300000000061, 2), "920.53");
  assertEquals(dec(22000.0, 6), "22000");
  assertEquals(dec(-16440, 2), "-16440");
  assertEquals(dec(null), null);
  assertEquals(dec("x"), null);
});

const sqTx = (o: Record<string, unknown>) => ({
  transactionId: 1401204376,
  date: "2026-10-20T10:40:44.417+02:00",
  action: "E",
  label: "Coupon",
  isin: "XS2747459241",
  name: "EURO MED T NOTE",
  stockSymbol: "10.5 NATX 31",
  quantity: 1.0,
  unitPrice: 87.5,
  netAmount: 87.5,
  currency: "USD",
  commissions: 0,
  balance: 17360.53,
  noContract: 1197993173,
  isReversal: false,
  ...o,
});

Deno.test("normalizeTransactions: ids, times, amounts; a reversal gets -R", () => {
  const [c, r, b] = normalizeTransactions([
    sqTx({}),
    sqTx({ transactionId: 769504622, isReversal: true, action: "b", label: "Reversal", isin: null, netAmount: -11.71 }),
    sqTx({
      transactionId: 1408309027,
      action: "B",
      label: "Buy",
      quantity: 22000.0,
      unitPrice: 0.745,
      netAmount: -16440.0,
      commissions: 50,
    }),
  ]);
  assertEquals(c, {
    id: "1401204376",
    booked_at: "2026-10-20T08:40:44.417Z",
    action: "E",
    label: "Coupon",
    reversal: false,
    isin: "XS2747459241",
    name: "EURO MED T NOTE",
    symbol: "10.5 NATX 31",
    quantity: "1",
    unit_price: "87.5",
    net_amount: "87.5",
    currency: "USD",
    commission: "0",
    balance: "17360.53",
    contract_ref: "1197993173",
  });
  assertEquals([r.id, r.reversal, r.isin, r.net_amount], ["769504622-R", true, null, "-11.71"]);
  assertEquals([b.quantity, b.unit_price, b.net_amount, b.commission], ["22000", "0.745", "-16440", "50"]);
});

Deno.test("normalizePositions: shares by unit, notes in % of nominal; missing price stays null", () => {
  const out = normalizePositions({
    groupedPositions: {
      SHARES: {
        positions: [{
          symbol: "NVDA",
          isin: "US67066G1040",
          name: "NVIDIA ORD",
          detailedProductType: "SHARE",
          quantity: 35,
          unitCost: 180,
          totalValue: 7655.55,
          price: 218.73,
          currency: "USD",
          quotationType: "UNIT",
        }],
      },
      STRUCTURED_PRODUCTS: {
        positions: [
          {
            symbol: "BSKT-BBVA 29",
            isin: "XS3413107338",
            name: "AUTOCALLABLE ON SHARE BASKET",
            detailedProductType: "WARRANT",
            quantity: 25000,
            unitCost: 100,
            totalValue: 23355,
            price: 93.42,
            currency: "USD",
            quotationType: "PERCENT",
          },
          { isin: "XS3536529152", name: "New note", quantity: 22000, unitCost: 74.5, quotationType: "PERCENT" },
          { isin: "bad", quantity: 1 },
        ],
      },
    },
  });
  assertEquals(out.length, 3);
  assertEquals([out[0].product_type, out[0].price_in_pct, out[0].value, out[0].profit], [
    "SHARE",
    false,
    "7655.55",
    "1355.55",
  ]);
  assertEquals([out[1].product_type, out[1].price_in_pct, out[1].price, out[1].profit], [
    "STRUCTURED_PRODUCTS",
    true,
    "93.42",
    "-1645",
  ]);
  assertEquals([out[2].price, out[2].value, out[2].currency], [null, null, "USD"]);
});

Deno.test("cashIn: the account currency's cash", () => {
  const body = { assets: [{ currency: "CHF", cashBalance: 0 }, { currency: "USD", cashBalance: 920.53 }] };
  assertEquals(cashIn(body, "USD"), "920.53");
  assertEquals(cashIn(body, "EUR"), null);
});

Deno.test("rebuildValues: walks the daily return index back from today, net of deposits", () => {
  // Day 1: 1,000 deposited. Day 2: +10%. Day 3: 500 more deposited, flat. Today: 1,600.
  const entries = [
    { date: "2026-01-01", twrPerf: 0 },
    { date: "2026-01-02", twrPerf: 10 },
    { date: "2026-01-03", twrPerf: 10 },
  ];
  const flows = new Map([["2026-01-01", 1000], ["2026-01-03", 500]]);
  const out = rebuildValues(entries, flows, "2026-01-04", 1600);
  assertEquals(out.map((s) => s.as_of), ["2026-01-01", "2026-01-02", "2026-01-03"]);
  assertAlmostEquals(Number(out[2].total_value), 1600, 0.01);
  assertAlmostEquals(Number(out[1].total_value), 1100, 0.01);
  assertAlmostEquals(Number(out[0].total_value), 1000, 0.01);
  assertEquals(out.every((s) => s.estimated), true);
  assertEquals(rebuildValues([], flows, "2026-01-04", 1), []);
});

Deno.test("rebuildValues: a trade-date jump in the index and its fall at settlement are read as flat", () => {
  const entries = [
    { date: "2026-01-01", twrPerf: 0 },
    { date: "2026-01-02", twrPerf: 30 }, // the note counted before its cash left
    { date: "2026-01-03", twrPerf: 30 },
    { date: "2026-01-04", twrPerf: 2 }, // settled
  ];
  const out = rebuildValues(
    [{ date: "2025-12-31", twrPerf: 0 }, ...entries],
    new Map([["2026-01-01", 1000]]),
    "2026-01-05",
    1000,
  );
  assertEquals(out.map((s) => s.total_value), ["1000.00", "1000.00", "1000.00", "1000.00"]);
});

Deno.test("depositsByDay: payments only, by Dubai day", () => {
  const rows = normalizeTransactions([
    sqTx({ action: "G", netAmount: 5000, date: "2024-10-08T22:00:00+00:00" }),
    sqTx({ transactionId: 2, action: "G", netAmount: 1000, date: "2024-10-08T10:00:00+00:00" }),
    sqTx({ transactionId: 3 }),
  ]);
  const m = depositsByDay(rows, (iso) => new Date(new Date(iso).getTime() + 4 * 3600_000).toISOString().slice(0, 10));
  assertEquals([...m], [["2024-10-09", 5000], ["2024-10-08", 1000]]);
});

Deno.test("termSheetFor: the PDF whose name or ticket names the ISIN", () => {
  const msgs = [
    { id: "1", body: "ISIN: XS3379888228", attachments: [{ id: 9, name: "Trade for Swissquote.pdf" }] },
    { id: "2", body: "", attachments: [{ id: 7, name: "FinalTS-XS3536529152.pdf" }, { id: 8, name: "x.docx" }] },
  ];
  assertEquals(termSheetFor(msgs, "XS3379888228"), {
    messageId: "1",
    attachmentId: "9",
    name: "Trade for Swissquote.pdf",
  });
  assertEquals(termSheetFor(msgs, "XS3536529152")?.attachmentId, "7");
  assertEquals(termSheetFor(msgs, "XS0000000000"), null);
});

function fakeSwissquote(opts: { answer?: string; refuse?: boolean }) {
  const seen: { url: string; body?: string }[] = [];
  const fake: typeof fetch = (input, init) => {
    const url = new URL(String(input));
    const body = typeof init?.body === "string" ? init.body : undefined;
    seen.push({ url: url.pathname + url.search, body });
    const redirect = (to: string, cookie?: string) =>
      new Response(null, { status: 302, headers: { location: to, ...(cookie ? { "set-cookie": cookie } : {}) } });
    if (url.pathname === "/") return Promise.resolve(redirect("/my.policy", "MRHSession=s1; path=/"));
    if (url.pathname === "/my.policy" && init?.method === "POST") {
      return Promise.resolve(
        opts.refuse ? new Response("<html>login</html>") : redirect("/sq-thirdlevel-plugin/?url_id=u123"),
      );
    }
    if (url.pathname === "/my.policy" || url.pathname === "/sq-thirdlevel-plugin/") {
      return Promise.resolve(new Response("<html/>"));
    }
    if (url.pathname.endsWith("/l3Code/challenge")) {
      return Promise.resolve(Response.json({ l3CodeChallenge: { challenge: "c4", sessionId: "s-1" } }));
    }
    if (url.pathname.endsWith("/l3Code/validate")) {
      const ok = JSON.parse(body ?? "{}").answer === (opts.answer ?? card.c4);
      return Promise.resolve(
        Response.json(
          ok
            ? { status: "SUCCESS", redirectionBaseUrl: "/bank_security/login/RedirectAtLogin.action" }
            : { status: "FAILURE" },
        ),
      );
    }
    if (url.pathname === "/bank_security/login/RedirectAtLogin.action") {
      return Promise.resolve(redirect("/eding_trading-platform/", "LastMRH_Session=s2; path=/"));
    }
    if (url.pathname === "/eding_trading-platform/") return Promise.resolve(new Response("<html/>"));
    return Promise.resolve(new Response("no", { status: 404 }));
  };
  return { fake, seen };
}

Deno.test("SwissquoteSession.login: password, then the card cell asked; never the phone push", async () => {
  const { fake, seen } = fakeSwissquote({});
  await new SwissquoteSession(fake).login(login);
  const posted = seen.find((s) => s.url === "/my.policy" && s.body)!;
  assertEquals(new URLSearchParams(posted.body).get("vhost"), "standard");
  const v = seen.find((s) => s.url.includes("/l3Code/validate"))!;
  assertEquals(JSON.parse(v.body!), { answer: card.c4, sessionId: "s-1", urlId: "u123" });
  assertEquals(seen.some((s) => s.url.includes("preference") || s.url.includes("smartL3")), false);
});

Deno.test("SwissquoteSession.login: refusals name the step, not the secrets", async () => {
  const refused = await assertRejects(
    () => new SwissquoteSession(fakeSwissquote({ refuse: true }).fake).login(login),
    Error,
    "sign-in refused",
  );
  assertEquals(refused.message.includes("pw"), false);
  const wrong = await assertRejects(
    () => new SwissquoteSession(fakeSwissquote({ answer: "0000" }).fake).login(login),
    Error,
    "card code refused",
  );
  assertEquals(wrong.message.includes(card.c4), false);
});

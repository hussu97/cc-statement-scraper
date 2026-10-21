import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1.0.13";
import {
  isSignedIn,
  parseLogins,
  parsePlans,
  parsePremiums,
  parseValuation,
  parseWithdrawalTotal,
  premiumsUrl,
  rl360Amount,
  rl360Date,
  Rl360Session,
  valuationUrl,
} from "../rl360-sync/rl360.ts";

// Trimmed from service.rl360.com (21 Oct 2026), plan number and names anonymised.
const DASHBOARD = `
<li><a href="/scripts/customer.cgi?option=logout">SIGN OUT</a></li>
<b>My policies</b>
<br/>
<a href="../SC/servicing/summary.php?PolNumber=RS00000001">RS00000001</a><br/>
<a href="../SC/servicing/summary.php?PolNumber=RS00000001">again</a>
<a href="../SC/servicing/summary.php?PolNumber=RS00000002">RS00000002</a><br/>`;

const HEADER = `
<div id="titlebox">
<div class="formleft">
<p class="par100"><b>Product:</b> Regular Savings Plan</p>
<p class="par100"><b>Policy number:</b> RS00000001</p>
</div>
<div class="formleft">
<p class="par100"><b>Status:</b> Active</p>
<p class="par100"><b>Start date:</b> 10 Jan 2022</p>
<p class="par100"><b>Maturity date:</b> 10 Jan 2121</p>
</div>
<div class="formleft">
<p class="par100"><b>Currency:</b> USD</p>
</div>
</div>`;

const holdings = (date: string, value: string) => `
<p>
<a target="_blank" href="PDF.php?Tab=valuation&amp;PolNumber=RS00000001">Printable PDF version </a> |
<br/>
Valuation date: ${date} </p>
<table border="0" cellspacing="0" cellpadding="0" summary="">
<tbody>
<tr class="row1">
<td width="20%" id="t2header1" class="one" style="font-size: 0.7em; padding: 4px;">
<div>RL360 Model Portfolio Solutions Growth USD</div></td>
<td width="8%" id="t2header8" class="two">USD</td>
<td width="11%" id="t2header10" class="two" style="text-align: right;">${value}</td>
<td width="11%" id="t2header9" class="two" style="text-align: right;">1.00000</td>
<td width="11%" id="t2header7" class="two" style="text-align: right;">${value}</td>
</tr>
<tr>
<td width="20%" id="t2header1" class="one" style="font-size: 0.7em; padding: 4px;"><b>Total</b></td>
<td width="8%" id="t2header8" class="two"></td>
<td width="11%" id="t2header10" class="two"></td>
<td width="11%" id="t2header9" class="two"></td>
<td width="11%" id="t2header7" class="two" style="font-size: 0.7em; padding: 4px; text-align: right;">
${value}</td>
</tr>
</tbody>
</table>`;

const VALUATION_TODAY = HEADER + `
<div class="rightsa"><h2>Current policy value</h2><div class="rightsa2"><p class="par100">USD 145,468.57</p></div></div>
` + holdings("21 Oct 2026", "145,468.57");
const VALUATION_PAST = HEADER + holdings("31 Dec 2024", "81,768.91");

const premiumRow = (desc: string, due: string, amount: string, received: string, got: string, bonus: string) => `
<tr class="row1">
<td id="t2header1" class="one" style="font-size: 0.7em;">${desc}</td>
<td id="t2header2" class="two">${due}</td>
<td id="t2header3" class="two">${amount}</td>
<td id="t2header4" class="two">${received}</td>
<td id="t2header5" class="two">${got}</td>
<td id="t2header6" class="two">
${bonus}</td>
</tr>`;

const HISTORY = HEADER + `
<div class="formleft">
<p class="par100">Withdrawal<br>total:</p>
<p class="par100">USD 0.00<br><br></p>
</div>
<p class="par100">Premium history<span class="hide"> current sub tab</span></p>
<table border="0" cellspacing="0" cellpadding="0" summary="">
<thead><tr><th id="t2header1" class="htopleft"><h5>Description</h5></th>
<th id="t2header4" class="htopmid"><h5>Date received</h5></th></tr></thead>
<tbody>` +
  premiumRow("Premium payment", "10 Oct 2026", "2,000.00", "08 Oct 2026", "2,000.00", "40.00") +
  premiumRow("Payment with currency conversion", "10 Apr 2026", "2,000.00", "01 Apr 2026", "2,000.00", "40.00") +
  premiumRow("Premium Incentive", "10 Jan 2022", "0.00", "10 Jan 2022", "0.00", "6,120.00") +
  premiumRow("Premium payment", "10 Jan 2022", "2,000.00", "10 Jan 2022", "2,000.00", "40.00") +
  premiumRow("Premium payment", "10 Jan 2022", "500.00", "12 Jan 2022", "500.00", "0.00") +
  `</tbody></table>`;

Deno.test("rl360Date / rl360Amount", () => {
  assertEquals(rl360Date("10 Jan 2022"), "2022-01-10");
  assertEquals(rl360Date(" 8 Oct 2026 "), "2026-10-08");
  assertEquals(rl360Date("Jan 2022"), null);
  assertEquals(rl360Date("10 Foo 2022"), null);
  assertEquals(rl360Amount("145,468.57"), "145468.57");
  assertEquals(rl360Amount("-5.00"), null);
  assertEquals(rl360Amount(""), null);
});

Deno.test("parseLogins: an array of profile logins; errors never echo values", () => {
  const p = "prf_" + "0".repeat(26);
  assertEquals(parseLogins(undefined), []);
  assertEquals(parseLogins(" "), []);
  assertEquals(parseLogins(JSON.stringify([{ profile_code: p, username: "u", password: "pw" }])), [
    { profile_code: p, username: "u", password: "pw" },
  ]);
  assertThrows(() => parseLogins("{secret"), Error, "not JSON");
  assertThrows(() => parseLogins("{}"), Error, "JSON array");
  const err = assertThrows(() => parseLogins(JSON.stringify([{ profile_code: p, username: "u", password: "" }])));
  assertEquals((err as Error).message.includes("pw"), false);
  assertThrows(() => parseLogins(JSON.stringify([{ profile_code: "x", username: "u", password: "p" }])), Error, "[0]");
});

Deno.test("isSignedIn / parsePlans: the dashboard's plan links, once each", () => {
  assertEquals(isSignedIn(DASHBOARD), true);
  assertEquals(isSignedIn('<form action="customer.cgi?option=login">'), false);
  assertEquals(parsePlans(DASHBOARD), ["RS00000001", "RS00000002"]);
});

Deno.test("parseValuation: today's and a past date's policy value from the Total row", () => {
  assertEquals(parseValuation(VALUATION_TODAY), {
    plan: "RS00000001",
    currency: "USD",
    started_on: "2022-01-10",
    as_of: "2026-10-21",
    value: "145468.57",
  });
  assertEquals(parseValuation(VALUATION_PAST).value, "81768.91");
  assertEquals(parseValuation(VALUATION_PAST).as_of, "2024-12-31");
  assertThrows(() => parseValuation(HEADER), Error, "no as_of, value");
});

Deno.test("parsePremiums: received premiums, bonuses skipped, one ref per due date", () => {
  assertEquals(parsePremiums(HISTORY), [
    { ref: "premium:2026-10-10", date: "2026-10-08", amount: "2000.00" },
    { ref: "premium:2026-04-10", date: "2026-04-01", amount: "2000.00" },
    { ref: "premium:2022-01-10", date: "2022-01-10", amount: "2000.00" },
    { ref: "premium:2022-01-10#2", date: "2022-01-12", amount: "500.00" },
  ]);
  assertThrows(() => parsePremiums(HEADER), Error, "no premium table");
  assertEquals(parseWithdrawalTotal(HISTORY), "0.00");
  assertEquals(parseWithdrawalTotal(HEADER), null);
});

Deno.test("urls: dates as day/month/year, end dates as eday/emonth/eyear", () => {
  assertEquals(
    valuationUrl("RS00000001", "2024-12-31"),
    "https://service.rl360.com/scripts/customer.cgi/SC/servicing/valuation.php?PolNumber=RS00000001&SortField=InvestmentFund&SortOrder=up&day=31&month=12&year=2024&continue=Continue",
  );
  assertEquals(
    premiumsUrl("RS00000001", "2022-01-10", "2026-10-21").split("?")[1],
    "PolNumber=RS00000001&SortField=ReceivedDate&SortOrder=down&day=10&month=1&year=2022&eday=21&emonth=10&eyear=2026&continue=Continue&subtab=premiums",
  );
});

Deno.test("Rl360Session: posts the login form, keeps cookies across redirects", async () => {
  const seen: { url: string; method: string; cookie: string | null; body?: string }[] = [];
  const fake = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const headers = new Headers(init?.headers);
    seen.push({ url, method: init?.method ?? "GET", cookie: headers.get("cookie"), body: init?.body as string });
    if (url.endsWith("option=login")) {
      return Promise.resolve(
        new Response(null, {
          status: 302,
          headers: [["location", "/scripts/customer.cgi/SC/"], ["set-cookie", "SID=abc; Path=/; HttpOnly"]],
        }),
      );
    }
    return Promise.resolve(new Response(headers.get("cookie") === "SID=abc" ? DASHBOARD : "<form>login</form>"));
  }) as typeof fetch;
  const s = new Rl360Session(fake);
  await s.login("user", "p&ss word");
  assertEquals(seen[0].method, "POST");
  assertEquals(new URLSearchParams(seen[0].body).get("PASSWORD"), "p&ss word");
  assertEquals(seen[1].url, "https://service.rl360.com/scripts/customer.cgi/SC/");
  assertEquals(seen[1].cookie, "SID=abc");

  const refused = new Rl360Session((() => Promise.resolve(new Response("<form>login</form>"))) as typeof fetch);
  await assertRejects(() => refused.login("user", "wrong"), Error, "sign-in refused");
  const down = new Rl360Session((() => Promise.resolve(new Response("x", { status: 503 }))) as typeof fetch);
  await assertRejects(() => down.get(valuationUrl("RS00000001")), Error, "HTTP 503");
});

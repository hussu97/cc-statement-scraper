import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import { decimal, normalizeExtraction, NotATermSheet, payoutAt } from "../termsheet-extract/termsheet.ts";

// What the model answers for Example Bank B's 5Y Athena on AMZN / META / MSFT (27 Aug 2026), first rows.
const ATHENA = {
  is_term_sheet: true,
  short_name: "Example Bank B Athena AMZN/META/MSFT 2031",
  product_name: "5Y Athena Worst-of on Amazon.com Inc, Meta Platforms Inc and MICROSOFT CORP in USD",
  isin: "XS0000000603",
  issuer: "Example Bank B Issuance B.V.",
  guarantor: "Example Bank B",
  currency: "usd",
  denomination: "1",
  issue_price_pct: "54%",
  strike_date: "2026-08-27",
  issue_date: "2026-09-11",
  final_valuation_date: "2031-08-27",
  maturity_date: "2031-09-04",
  underlyings: [
    {
      name: "Amazon.com Inc",
      bloomberg_code: "AMZN UW",
      isin: null,
      exchange: null,
      initial_level: "256.26",
      printed_levels: [{ label: "Automatic Early Redemption Price", pct: "105", value: "269.0730" }],
    },
    {
      name: "Meta Platforms Inc",
      bloomberg_code: "META UW",
      isin: null,
      exchange: null,
      initial_level: "571.10",
      printed_levels: [{ label: "Strike Price", pct: "145", value: "828.0950" }],
    },
    {
      name: "MICROSOFT CORP",
      bloomberg_code: "MSFT UW",
      isin: null,
      exchange: null,
      initial_level: "505.06",
      printed_levels: [{ label: "Automatic Early Redemption Price", pct: "105", value: "531.3130" }], // misread
    },
  ],
  observations: [
    {
      obs_date: "2027-06-28",
      pay_date: "2027-07-06",
      coupon_rate_pct: null,
      coupon_barrier_pct: null,
      coupon_memory: false,
      autocall_trigger_pct: "105",
      autocall_amount_pct: "65",
    },
    {
      obs_date: "2027-05-27",
      pay_date: "2027-06-04",
      coupon_rate_pct: null,
      coupon_barrier_pct: null,
      coupon_memory: true,
      autocall_trigger_pct: "105",
      autocall_amount_pct: "64",
    },
  ],
  payout: [
    { min_worst_pct: "45", intercept_pct: "-45", slope: "1", settlement: "cash", description: "100% + (WP − 145%)" },
    { min_worst_pct: "100", intercept_pct: "100", slope: "0", settlement: "cash", description: "100%" },
    { min_worst_pct: "0", intercept_pct: "0", slope: "0", settlement: "cash", description: "0%" },
  ],
  unsupported: [],
};

Deno.test("normalizeExtraction: the Athena sheet becomes draft terms", () => {
  const x = normalizeExtraction(ATHENA);
  assertEquals(x.name, "Example Bank B Athena AMZN/META/MSFT 2031");
  assertEquals(x.terms.currency, "USD");
  assertEquals(x.terms.issue_price_pct, "54");
  assertEquals(x.terms.underlyings.map((u) => [u.symbol, u.initial_level]), [
    ["AMZN", "256.26"],
    ["META", "571.1"],
    ["MSFT", "505.06"],
  ]);
  // Sorted by date; memory needs a coupon.
  assertEquals(x.terms.observations.map((o) => [o.obs_date, o.autocall_amount_pct, o.coupon_memory]), [
    ["2027-05-27", "64", false],
    ["2027-06-28", "65", false],
  ]);
  // Highest branch first.
  assertEquals(x.terms.payout.map((b) => b.min_worst_pct), ["100", "45", "0"]);
  // The misread MSFT level is the one warning.
  assertEquals(x.warnings.length, 1);
  assertEquals(
    x.warnings[0].startsWith("MICROSOFT CORP: the sheet prints Automatic Early Redemption Price 531.313"),
    true,
  );
});

Deno.test("normalizeExtraction: half a coupon, a falling payout and unsupported features are warnings", () => {
  const raw = structuredClone(ATHENA);
  raw.observations[0].coupon_rate_pct = "1.25" as unknown as null;
  raw.payout[1].intercept_pct = "50"; // 99.5 → 54.5 but 100 → 50
  raw.unsupported = ["Knock-in observed daily"] as never[];
  const w = normalizeExtraction(raw).warnings;
  assertEquals(w.some((s) => s.startsWith("2027-06-28: a coupon needs both a rate and a barrier")), true);
  assertEquals(w.some((s) => s.startsWith("The payout falls as the worst share rises")), true);
  assertEquals(w.includes("Not modelled: Knock-in observed daily"), true);
});

Deno.test("normalizeExtraction: a required field missing, or not a term sheet", () => {
  assertThrows(() => normalizeExtraction({ ...ATHENA, strike_date: "27 Aug 2026" }), Error, "strike date");
  assertThrows(() => normalizeExtraction({ ...ATHENA, is_term_sheet: false }), NotATermSheet);
  assertThrows(
    () => normalizeExtraction({ ...ATHENA, underlyings: [{ ...ATHENA.underlyings[0], initial_level: "n/a" }] }),
    Error,
    "initial level of Amazon.com Inc",
  );
});

Deno.test("an unknown Bloomberg code leaves the symbol to the user", () => {
  const raw = structuredClone(ATHENA);
  raw.underlyings[0].bloomberg_code = null as unknown as string;
  const x = normalizeExtraction(raw);
  assertEquals(x.terms.underlyings[0].symbol, "");
  assertEquals(
    x.warnings.some((s) => s === "Set the price symbol for Amazon.com Inc: no ticker could be derived."),
    true,
  );
});

Deno.test("decimal and payoutAt", () => {
  assertEquals(decimal("1,000.50"), "1000.5");
  assertEquals(decimal("74.50%"), "74.5");
  assertEquals(decimal("-24.50"), "-24.5");
  assertEquals(decimal("USD 324.22"), "324.22");
  assertEquals(decimal("abc"), null);
  const b = normalizeExtraction(ATHENA).terms.payout;
  assertEquals([payoutAt(b, 120), payoutAt(b, 80), payoutAt(b, 40)], [100, 35, 0]);
});

// What the model answers for Example Bank N's Example Airlines CLN (16 Sep 2024): a monthly coupon.
const CLN = {
  is_term_sheet: true,
  note_type: "credit_linked",
  short_name: "Example Bank N CLN Example Airlines 10.5% 2031",
  product_name: "Fixed Rate Credit Linked Notes referenced to Example Airlines Group Inc due 20 December 2031",
  isin: "XS0000000108",
  issuer: "EXAMPLE BANK N STRUCTURED ISSUANCE SA",
  guarantor: "EXAMPLE BANK N",
  currency: "USD",
  denomination: "1,000",
  issue_price_pct: "100%",
  strike_date: null,
  issue_date: "2024-10-15",
  final_valuation_date: null,
  maturity_date: "2031-12-20",
  underlyings: [],
  observations: [],
  payout: [],
  credit: {
    reference_entity: "Example Airlines Group Inc",
    seniority: "Senior Level",
    transaction_type: "Standard North American Corporate",
    reference_obligation_isin: "US0000AA0001",
    coupon_rate_pct: "10.50%",
    coupon_frequency: "monthly",
    day_count: "30/360",
    interest_start_date: "2024-10-15",
    first_coupon_date: "2024-10-20",
    longstop_maturity_date: "2032-12-20",
    call_dates: [],
    call_notice_days: null,
  },
  unsupported: [],
};

Deno.test("normalizeExtraction: a credit-linked note becomes its credit block", () => {
  const x = normalizeExtraction(CLN);
  assertEquals(x.name, "Example Bank N CLN Example Airlines 10.5% 2031");
  assertEquals(x.terms.note_type, "credit_linked");
  assertEquals([x.terms.strike_date, x.terms.final_valuation_date], [null, null]);
  assertEquals([x.terms.underlyings.length, x.terms.observations.length, x.terms.payout.length], [0, 0, 0]);
  assertEquals(x.terms.denomination, "1000");
  assertEquals(x.terms.credit, {
    reference_entity: "Example Airlines Group Inc",
    seniority: "Senior Level",
    transaction_type: "Standard North American Corporate",
    reference_obligation_isin: "US0000AA0001",
    coupon_rate_pct: "10.5",
    coupon_frequency: "monthly",
    day_count: "30/360",
    interest_start_date: "2024-10-15",
    first_coupon_date: "2024-10-20",
    longstop_maturity_date: "2032-12-20",
    call_dates: [],
    call_notice_days: null,
  });
  assertEquals(x.warnings, []);
});

Deno.test("normalizeExtraction: a CLN paid at maturity keeps its call dates in range", () => {
  const x = normalizeExtraction({
    ...CLN,
    issue_date: "2025-02-13",
    maturity_date: "2034-12-20",
    credit: {
      ...CLN.credit,
      coupon_rate_pct: "13.25",
      coupon_frequency: "At maturity",
      interest_start_date: null,
      first_coupon_date: "2034-12-20",
      call_dates: ["2026-12-20", "2025-12-20", "2025-12-20", "2035-01-01"],
      call_notice_days: "10",
    },
  });
  assertEquals(x.terms.credit?.coupon_frequency, "at_maturity");
  assertEquals(x.terms.credit?.interest_start_date, "2025-02-13"); // the issue date
  assertEquals(x.terms.credit?.first_coupon_date, null);
  assertEquals(x.terms.credit?.call_dates, ["2025-12-20", "2026-12-20"]);
  assertEquals(x.terms.credit?.call_notice_days, 10);
  assertEquals(x.warnings, ["Call date 2035-01-01 falls outside the interest start and maturity; it was left out."]);
});

Deno.test("normalizeExtraction: a CLN without its reference entity, rate or schedule fails", () => {
  assertThrows(
    () => normalizeExtraction({ ...CLN, credit: { ...CLN.credit, reference_entity: " " } }),
    Error,
    "reference entity",
  );
  assertThrows(
    () => normalizeExtraction({ ...CLN, credit: { ...CLN.credit, coupon_rate_pct: null } }),
    Error,
    "coupon rate",
  );
  assertThrows(
    () => normalizeExtraction({ ...CLN, credit: { ...CLN.credit, coupon_frequency: "weekly" } }),
    Error,
    "coupon frequency",
  );
  assertThrows(
    () => normalizeExtraction({ ...CLN, credit: { ...CLN.credit, first_coupon_date: null } }),
    Error,
    "first coupon date",
  );
  const off = normalizeExtraction({ ...CLN, credit: { ...CLN.credit, first_coupon_date: "2024-10-21" } });
  assertEquals(off.warnings, [
    "The first coupon date and maturity are not on the same schedule: check the coupon dates.",
  ]);
});

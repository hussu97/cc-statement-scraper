import { describe, expect, it } from "vitest";
import {
  depositValueNote,
  valuationSourceLabel,
  aedEquivalent,
  allocationSlices,
  canRemoveFlow,
  visibleValues,
  VALUE_LIST_LIMIT,
  FLOW_SOURCE_LABEL,
  emptyInvestmentForm,
  flowSign,
  formatOwnValue,
  formatRate,
  formatUnitPrice,
  formatUnits,
  groupHoldings,
  holdingsForLinking,
  incompleteDetail,
  incompleteNote,
  incompleteReason,
  investmentFacts,
  investmentToForm,
  kindOf,
  linkRuleText,
  normalizePositive,
  normalizeRate,
  returnsParts,
  savingLines,
  validateFlowForm,
  validateInvestmentForm,
  validateValueForm,
  valueInput,
  type InvestmentForm,
} from "./investments";

const TODAY = "2026-10-21";

describe("kinds and groups", () => {
  it("treats a holding without a kind as a metal (older server)", () => {
    expect(kindOf({})).toBe("metal");
    expect(kindOf({ kind: "plan" })).toBe("plan");
    expect(kindOf({ kind: "nonsense" })).toBe("metal");
  });

  it("groups in the page's order, keeps the server's order inside, drops empty groups", () => {
    const hs = [
      { id: 1, kind: "deposit" },
      { id: 2, kind: "plan" },
      { id: 3, kind: "metal" },
      { id: 4, kind: "plan" },
    ];
    const g = groupHoldings(hs);
    expect(g.map((x) => x.label)).toEqual(["Metals", "Plans", "Deposits"]);
    expect(g[1]!.holdings.map((h) => h.id)).toEqual([2, 4]);
  });

  it("lists plans, brokers, shares and deposits before metals for linking", () => {
    const hs = [{ id: 1, kind: "metal" }, { id: 2, kind: "deposit" }, { id: 3, kind: "plan" }, { id: 4, kind: "security" }, { id: 5, kind: "broker" }];
    expect(holdingsForLinking(hs).map((h) => h.id)).toEqual([3, 5, 4, 2, 1]);
  });

  it("offers Update value for plans, broker accounts and shares only", () => {
    expect(valueInput("plan")).toBe("value");
    expect(valueInput("broker")).toBe("value");
    expect(valueInput("security")).toBe("unit_price");
    expect(valueInput("metal")).toBeNull();
    expect(valueInput("deposit")).toBeNull();
  });
});

describe("display", () => {
  it("formats units, rates and unit prices without rounding them away", () => {
    expect(formatUnits("20000.000000")).toBe("20,000");
    expect(formatUnits("12.500000")).toBe("12.5");
    expect(formatRate("4.250")).toBe("4.25%");
    expect(formatUnitPrice("1.420000", "AED")).toBe("AED 1.42");
    expect(formatUnitPrice("0.001234", "USD")).toBe("USD 0.001234");
    expect(formatUnitPrice("1250", "AED")).toBe("AED 1,250.00");
    expect(formatUnitPrice(null, "AED")).toBe("—");
  });

  it("describes each kind in one line", () => {
    expect(investmentFacts({ kind: "plan", institution: "RL360", currency: "USD" })).toBe("RL360 · USD");
    expect(investmentFacts({ kind: "broker", institution: null, currency: "AED" })).toBe("Broker account");
    expect(investmentFacts({ kind: "security", institution: "DFM", symbol: "TALABAT", units: "20000.000000", currency: "AED" })).toBe("DFM · TALABAT · 20,000 units");
    expect(investmentFacts({ kind: "deposit", institution: "Wio", rate_pct: "4.250", maturity_on: "2027-06-23", currency: "AED" })).toMatch(/^Wio · 4\.25% · matures 23 Jun 2027$/);
  });

  it("shows a value in its own currency, and AED beside a foreign one only", () => {
    expect(formatOwnValue("14650.00", "USD")).toBe("USD 14,650");
    expect(formatOwnValue(null, "USD")).toBeNull();
    expect(aedEquivalent("53800.00", "USD")).toBe("≈ AED 53,800");
    expect(aedEquivalent("53800.00", "AED")).toBeNull();
  });

  it("signs money put in and taken out, not income", () => {
    expect([flowSign("contribution"), flowSign("withdrawal"), flowSign("income")]).toEqual(["+", "−", ""]);
  });

  it("keeps a metal's purchase cost out of Remove", () => {
    expect(canRemoveFlow("holding_cost")).toBe(false);
    expect(canRemoveFlow("rule")).toBe(true);
    expect(canRemoveFlow("manual")).toBe(true);
  });
});

describe("typed amounts", () => {
  it("parses positive decimals within their scale", () => {
    expect(normalizePositive("12,500.50", 2)).toBe("12500.50");
    expect(normalizePositive("USD 2000", 2)).toBe("2000");
    expect(normalizePositive("0", 2)).toBeNull();
    expect(normalizePositive("1.234", 2)).toBeNull();
    expect(normalizePositive("1.234567", 6)).toBe("1.234567");
    expect(normalizePositive("-5", 2)).toBeNull();
  });

  it("takes rates from 0 to 100 with up to 3 decimals", () => {
    expect(normalizeRate("4.25")).toBe("4.25");
    expect(normalizeRate("4.25%")).toBe("4.25");
    expect(normalizeRate("100")).toBe("100");
    expect(normalizeRate("100.001")).toBeNull();
    expect(normalizeRate("4.2501")).toBeNull();
  });
});

describe("the investment form", () => {
  const form = (patch: Partial<InvestmentForm>): InvestmentForm => ({ ...emptyInvestmentForm("plan"), ...patch });

  it("builds a plan with its currency and link rule", () => {
    const v = validateInvestmentForm(form({ name: " RL360 plan ", institution: "RL360", linkPattern: " RL360 " }), TODAY);
    expect(v).toEqual({ ok: true, input: { kind: "plan", name: "RL360 plan", currency: "USD", institution: "RL360", link_pattern: "RL360", link_exact: false } });
  });

  it("allows a 2-character rule only when it must match the whole description", () => {
    expect(validateInvestmentForm(form({ name: "RL360 plan", linkPattern: "RI" }), TODAY)).toMatchObject({ ok: false, error: expect.stringMatching(/Match the whole description/) });
    expect(validateInvestmentForm(form({ name: "RL360 plan", linkPattern: " RI ", linkExact: true }), TODAY)).toMatchObject({ ok: true, input: { link_pattern: "RI", link_exact: true } });
    expect(validateInvestmentForm(form({ name: "RL360 plan", linkPattern: "R", linkExact: true }), TODAY)).toMatchObject({ ok: false });
    // No rule: exact is off whatever the box says.
    expect(validateInvestmentForm(form({ name: "RL360 plan", linkExact: true }), TODAY)).toMatchObject({ ok: true, input: { link_exact: false } });
    expect(linkRuleText("RI", true)).toBe("Links payments whose description is exactly “RI”");
    expect(linkRuleText("RL360", false)).toBe("Links payments whose description contains “RL360”");
    expect(linkRuleText(null, true)).toBeNull();
  });

  it("needs a share's units, and a deposit's principal, rate, start and later maturity", () => {
    const sec = { ...emptyInvestmentForm("security"), name: "Talabat" };
    expect(validateInvestmentForm(sec, TODAY)).toMatchObject({ ok: false, error: expect.stringMatching(/units/) });
    expect(validateInvestmentForm({ ...sec, units: "20,000", symbol: "talabat" }, TODAY)).toEqual({
      ok: true,
      input: { kind: "security", name: "Talabat", currency: "AED", units: "20000", symbol: "TALABAT", link_exact: false },
    });
    const dep = { ...emptyInvestmentForm("deposit"), name: "Wio FD", principal: "100000", rate: "4.25", startOn: "2026-06-23" };
    expect(validateInvestmentForm(dep, TODAY)).toMatchObject({ ok: false, error: expect.stringMatching(/maturity/) });
    expect(validateInvestmentForm({ ...dep, maturityOn: "2026-06-23" }, TODAY)).toMatchObject({ ok: false });
    expect(validateInvestmentForm({ ...dep, maturityOn: "2027-06-23" }, TODAY)).toEqual({
      ok: true,
      input: { kind: "deposit", name: "Wio FD", currency: "AED", principal: "100000", rate_pct: "4.25", acquired_on: "2026-06-23", maturity_on: "2027-06-23", link_exact: false },
    });
  });

  it("says what to fix", () => {
    expect(validateInvestmentForm(form({ name: "" }), TODAY)).toMatchObject({ ok: false, error: expect.stringMatching(/name/) });
    expect(validateInvestmentForm(form({ name: "X", linkPattern: "ab" }), TODAY)).toMatchObject({ ok: false, error: expect.stringMatching(/3 to 60/) });
    expect(validateInvestmentForm(form({ name: "X", startOn: "2026-10-22" }), TODAY)).toMatchObject({ ok: false, error: expect.stringMatching(/future/) });
  });

  it("starts an edit from the holding", () => {
    const f = investmentToForm({ kind: "security", name: "Talabat", currency: "AED", institution: "DFM", units: "20000.000000", symbol: "TALABAT", link_pattern: null, acquired_on: "2026-01-05" });
    expect(f).toMatchObject({ kind: "security", units: "20000", symbol: "TALABAT", startOn: "2026-01-05", linkPattern: "", linkExact: false });
    expect(investmentToForm({ kind: "plan", name: "RL360", link_pattern: "RI", link_exact: true })).toMatchObject({ linkPattern: "RI", linkExact: true });
  });
});

describe("values and flows", () => {
  it("records a value for a plan and a unit price for a share; today needs no date", () => {
    expect(validateValueForm("plan", { amount: "53,800", asOf: TODAY }, TODAY)).toEqual({ ok: true, input: { value: "53800" } });
    expect(validateValueForm("security", { amount: "1.42", asOf: "2026-10-20" }, TODAY)).toEqual({ ok: true, input: { unit_price: "1.42", as_of: "2026-10-20" } });
    expect(validateValueForm("deposit", { amount: "1", asOf: TODAY }, TODAY)).toMatchObject({ ok: false });
    expect(validateValueForm("plan", { amount: "1", asOf: "2026-10-22" }, TODAY)).toMatchObject({ ok: false });
  });

  it("adds a flow in the holding's currency, AED only when foreign", () => {
    const f = { kind: "income" as const, date: "2026-10-01", amount: "120", amountAed: "440.70", notes: " Dividend " };
    expect(validateFlowForm("USD", f, TODAY)).toEqual({ ok: true, input: { kind: "income", flow_date: "2026-10-01", amount: "120", amount_aed: "440.70", notes: "Dividend" } });
    expect(validateFlowForm("AED", f, TODAY)).toEqual({ ok: true, input: { kind: "income", flow_date: "2026-10-01", amount: "120", notes: "Dividend" } });
    expect(validateFlowForm("AED", { ...f, amount: "0" }, TODAY)).toMatchObject({ ok: false });
    expect(validateFlowForm("AED", { ...f, date: "2026-10-22" }, TODAY)).toMatchObject({ ok: false });
  });
});

describe("returns", () => {
  const r = { start_value_aed: "0.00", end_value_aed: "53800.00", added_aed: "44100.00", income_aed: "0.00", growth_aed: "9700.00", simple_pct: "22.00", annual_pct: "18.40", complete: true };

  it("words the server's figures", () => {
    expect(returnsParts(r)).toEqual({ added: "Added AED 44,100", grew: "Grew AED 9,700 (+22%)", annual: "+18.4% a year" });
    expect(returnsParts({ ...r, growth_aed: "-300.00", simple_pct: "-1.5", annual_pct: null })).toEqual({
      added: "Added AED 44,100",
      grew: "Lost AED 300 (−1.5%)",
      annual: "Yearly return after 90 days",
    });
    expect(returnsParts({ ...r, growth_aed: null, simple_pct: null, annual_pct: null, complete: false }).grew).toBeNull();
  });

  it("names the holdings left out of the total, and why, by period", () => {
    const h = (name: string, end: string | null) => ({ name, complete: false, end_value_aed: end });
    expect(incompleteNote([{ name: "A", complete: true, end_value_aed: "1" }], "all")).toBeNull();
    // No value yet: any period.
    for (const p of ["all", "ytd", "12m"] as const) expect(incompleteNote([h("New plan", null)], p)).toBe("New plan has no value yet, so it is left out of the total.");
    // All time: no money recorded going in.
    expect(incompleteNote([h("Bangles", "39086.00")], "all")).toBe("Bangles has no money recorded going in, so it is left out of the total.");
    // This year / 12 months: no value at the start.
    expect(incompleteNote([h("Gold bar", "10.00")], "ytd")).toMatch(/^Gold bar has no value at the start of this period.*it is left out/);
    expect(incompleteNote([1, 2, 3, 4].map((i) => h(`H${i}`, "1")), "12m")).toMatch(/^H1, H2, H3 and 1 more have no value at the start.*they are left out/);
    expect(incompleteNote([h("New plan", null), h("Bangles", "1")], "all")).toBe("New plan has no value yet; Bangles has no money recorded going in, so they are left out of the total.");
  });

  it("gives each incomplete holding its reason, by period", () => {
    expect(incompleteReason({ end_value_aed: null }, "all")).toBe("No value yet");
    expect(incompleteReason({ end_value_aed: null }, "ytd")).toBe("No value yet");
    expect(incompleteReason({ end_value_aed: "5" }, "all")).toBe("No money recorded going in");
    expect(incompleteReason({ end_value_aed: "5" }, "ytd")).toBe("No value at the start");
    expect(incompleteReason({ end_value_aed: "5" }, "12m")).toBe("No value at the start");
    expect(incompleteDetail({ end_value_aed: null }, "12m")).toMatch(/^It has no value yet/);
    expect(incompleteDetail({ end_value_aed: "5" }, "all")).toMatch(/^No money is recorded going into it/);
    expect(incompleteDetail({ end_value_aed: "5" }, "ytd")).toMatch(/^No value at the start of this period/);
  });
});

describe("allocation and saving", () => {
  it("keeps owed apart from the assets and colours each class", () => {
    const a = allocationSlices([
      { class: "cash", value_aed: "120000.00", share_pct: "50.00" },
      { class: "gold", value_aed: "120000.00", share_pct: "50.00" },
      { class: "owed", value_aed: "-8000.00", share_pct: null },
    ]);
    expect(a.assets.map((s) => [s.label, s.token, s.width])).toEqual([
      ["Cash", "cat-4", 50],
      ["Gold", "cat-3", 50],
    ]);
    expect(a.owed).toBe("-8000.00");
    expect(allocationSlices([]).owed).toBeNull();
  });

  it("lists the month's saving by holding, Unassigned for none", () => {
    const rows = [
      { month: "2026-10-01", holding_code: "hld_1", holding_name: "RL360 plan", holding_kind: "plan", amount_aed: "7345.00", txn_count: 1 },
      { month: "2026-10-01", holding_code: null, holding_name: null, holding_kind: null, amount_aed: "500.00", txn_count: 2 },
      { month: "2026-09-01", holding_code: "hld_1", holding_name: "RL360 plan", holding_kind: "plan", amount_aed: "7345.00", txn_count: 1 },
    ];
    expect(savingLines(rows, "2026-10-01").map((l) => [l.label, l.amount, l.count])).toEqual([
      ["RL360 plan", "7345.00", 1],
      ["Unassigned", "500.00", 2],
    ]);
  });
});

describe("synced values and flows", () => {
  it("labels provider imports", () => {
    expect(FLOW_SOURCE_LABEL.import).toBe("Synced from the provider");
    expect(canRemoveFlow("import")).toBe(true);
  });
  it("shows the latest values until asked for all", () => {
    const values = Array.from({ length: 30 }, (_, i) => i);
    expect(visibleValues(values, false)).toEqual({ shown: values.slice(0, VALUE_LIST_LIMIT), hidden: 30 - VALUE_LIST_LIMIT });
    expect(visibleValues(values, true)).toEqual({ shown: values, hidden: 0 });
    expect(visibleValues([1, 2], false)).toEqual({ shown: [1, 2], hidden: 0 });
  });
});

describe("statement-valued deposits", () => {
  it("labels a stored value by where it came from", () => {
    expect(valuationSourceLabel("deposit", "import")).toBe("From statement");
    expect(valuationSourceLabel("plan", "import")).toBe("Synced");
    expect(valuationSourceLabel("deposit", "manual")).toBeNull();
  });
  it("says how a deposit is valued", () => {
    const h = { rate_pct: "2.000", maturity_on: "2027-04-01" };
    expect(depositValueNote(h, true)).toBe(
      "From the bank's statements: the latest value, plus simple profit at 2% a year since, to maturity on 1 Apr 2027.",
    );
    expect(depositValueNote(h, false)).toBe(
      "An estimate: the principal plus simple profit at 2% a year, accrued day by day to maturity on 1 Apr 2027.",
    );
    expect(depositValueNote({}, false)).toBe("An estimate: the principal plus simple profit at its rate a year, accrued day by day to maturity.");
  });
});

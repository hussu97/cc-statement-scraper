import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import {
  decimalText,
  dubaiDate,
  midDecimal,
  parseDjgAjax,
  parseDjgRates,
  parseGoldApi,
  parseKhaleejTimes,
  parseSwissquote,
} from "../metal-prices/quotes.ts";

// The list as dubaicityofgold.com serves it (admin-ajax, 21 Oct 2026).
const DJG_LIST = `
    <div class="sortd-gold-price-item">
      <span class="sortd-gold-type">24K Gold</span>
      <span class="sortd-gold-value">AED 496.00</span>
    </div>
    <div class="sortd-gold-price-item">
      <span class="sortd-gold-type">22K Gold</span>
      <span class="sortd-gold-value">AED 459.25</span>
    </div>
    <div class="sortd-gold-price-item">
      <span class="sortd-gold-type">21K Gold</span>
      <span class="sortd-gold-value">AED 440.25</span>
    </div>
    <div class="sortd-gold-price-item">
      <span class="sortd-gold-type">18K Gold</span>
      <span class="sortd-gold-value">AED 1,377.50</span>
    </div>
    <div class="sortd-gold-price-item">
      <span class="sortd-gold-type">14K Gold</span>
      <span class="sortd-gold-value">AED 292.75</span>
    </div>`;

Deno.test("parseDjgRates: one quote per known karat, commas dropped, 14K ignored", () => {
  assertEquals(parseDjgRates(DJG_LIST), [
    { quote: "gold_24k", aed_per_gram: "496.00", source: "dubaicityofgold.com" },
    { quote: "gold_22k", aed_per_gram: "459.25", source: "dubaicityofgold.com" },
    { quote: "gold_21k", aed_per_gram: "440.25", source: "dubaicityofgold.com" },
    { quote: "gold_18k", aed_per_gram: "1377.50", source: "dubaicityofgold.com" },
  ]);
});

Deno.test("parseDjgRates: a page without a 24K rate throws (layout changed)", () => {
  assertThrows(() => parseDjgRates("<p>Rates unavailable</p>"), Error, "no 24K rate");
  assertThrows(() => parseDjgRates(DJG_LIST.replace("24K Gold", "Gold 24")), Error, "no 24K rate");
});

Deno.test("parseDjgAjax: needs success and an HTML list", () => {
  assertEquals(parseDjgAjax({ success: true, data: DJG_LIST })[0].aed_per_gram, "496.00");
  assertThrows(() => parseDjgAjax({ success: false, data: "" }), Error, "without a price list");
  assertThrows(() => parseDjgAjax(null), Error, "without a price list");
});

Deno.test("parseGoldApi: USD per ounce for the asked metal", () => {
  assertEquals(
    parseGoldApi({ currency: "USD", name: "Gold", price: 4115.299805, symbol: "XAU" }, "XAU"),
    { quote: "gold_spot", usd_per_oz: "4115.299805", source: "gold-api.com" },
  );
  assertEquals(parseGoldApi({ currency: "USD", price: 57.34, symbol: "XAG" }, "XAG").quote, "silver_spot");
  assertThrows(() => parseGoldApi({ currency: "USD", price: 57.34, symbol: "XAG" }, "XAU"), Error, "expected XAU");
  assertThrows(() => parseGoldApi({ currency: "EUR", price: 1, symbol: "XAU" }, "XAU"), Error, "in USD");
  assertThrows(() => parseGoldApi({ currency: "USD", price: 0, symbol: "XAU" }, "XAU"), Error, "no usable price");
});

Deno.test("midDecimal: exact mid of two decimal strings", () => {
  assertEquals(midDecimal("4113.196", "4113.834"), "4113.515");
  assertEquals(midDecimal("57.1722", "57.2193"), "57.19575");
  assertEquals(midDecimal("1", "2"), "1.5");
  assertEquals(midDecimal("10.00", "10.00"), "10");
});

Deno.test("parseSwissquote: the first bid/ask pair, as a mid", () => {
  const body = [
    { topo: { platform: "x" }, spreadProfilePrices: [] },
    {
      topo: { platform: "SwissquoteCapitalMarkets" },
      spreadProfilePrices: [{ spreadProfile: "premium", bid: 4113.186, ask: 4113.844 }],
    },
  ];
  assertEquals(parseSwissquote(body, "XAU"), { quote: "gold_spot", usd_per_oz: "4113.515", source: "swissquote.com" });
  assertThrows(() => parseSwissquote([], "XAG"), Error, "no XAG bid and ask");
  assertThrows(() => parseSwissquote({ error: 1 }, "XAG"), Error, "no XAG bid and ask");
});

Deno.test("decimalText: positive decimals only", () => {
  assertEquals(decimalText(496), "496");
  assertEquals(decimalText("1,234.50"), "1234.50");
  for (const bad of [0, -1, NaN, Infinity, "", "0.00", "abc", "1e3", null, undefined]) {
    assertEquals(decimalText(bad), null, String(bad));
  }
});

Deno.test("dubaiDate: UTC+4", () => {
  assertEquals(dubaiDate(new Date("2026-10-20T19:59:59Z")), "2026-10-20");
  assertEquals(dubaiDate(new Date("2026-10-20T20:00:00Z")), "2026-10-21");
});

// Khaleej Times' gold page carries its rates as JSON-LD (21 Oct 2026, trimmed).
const KT_PAGE = `<html><head>
<script type="application/ld+json">{"@context":"https://schema.org","@type":"WebPage","name":"Gold"}</script>
<script type="application/ld+json">{"@context":"https://schema.org","@graph":[
  {"@type":"ExchangeRateSpecification","name":"Gold Rate (AED/Gram)","currency":"AED",
   "currentExchangeRate":{"@type":"UnitPriceSpecification","price":"496.00","priceCurrency":"AED","unitText":"Gram"}},
  {"@type":"ExchangeRateSpecification","name":"AED to INR Exchange Rate","currency":"INR",
   "currentExchangeRate":{"@type":"UnitPriceSpecification","price":"25.76","priceCurrency":"AED"}},
  {"@type":"ExchangeRateSpecification","name":"Silver Rate (AED/Kilo)","currency":"AED",
   "currentExchangeRate":{"@type":"UnitPriceSpecification","price":"7,960","priceCurrency":"AED","unitText":"Kilo"}}
]}</script>
<script type="application/ld+json">not json</script>
</head></html>`;

Deno.test("parseKhaleejTimes: Dubai retail silver per kilo and the 24K rate from JSON-LD", () => {
  assertEquals(parseKhaleejTimes(KT_PAGE), {
    silver: { quote: "silver_retail", aed_per_kg: "7960", source: "khaleejtimes.com" },
    gold24k: { quote: "gold_24k", aed_per_gram: "496.00", source: "khaleejtimes.com" },
  });
});

Deno.test("parseKhaleejTimes: a page without the rates yields nothing", () => {
  assertEquals(parseKhaleejTimes("<html></html>"), { silver: undefined, gold24k: undefined });
});

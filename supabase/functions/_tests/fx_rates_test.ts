import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import { aedPerUnit, FX_SOURCE, invertRate, parseErApi } from "../fx-rates/rates.ts";

Deno.test("invertRate: units per AED → AED per unit, 8 places, half-up, no float", () => {
  assertEquals(invertRate(1), "1.00000000");
  assertEquals(invertRate(0.272294), "3.67250105"); // USD
  assertEquals(invertRate(13.2381), "0.07553954"); // EGP
  assertEquals(invertRate("22.6797"), "0.04409229"); // INR as text
  assertEquals(invertRate(0.0817), "12.23990208"); // KWD (> 1 AED per unit)
  assertEquals(invertRate(3), "0.33333333");
  assertEquals(invertRate(1.5), "0.66666667"); // rounds half-up on the 8th place
  assertEquals(invertRate(8), "0.12500000");
});

Deno.test("invertRate: exponent notation and range limits", () => {
  assertEquals(invertRate(2.5e-7), "4000000.00000000");
  assertEquals(invertRate("1e3"), "0.00100000");
  assertEquals(invertRate(1e9), null); // 1e-9 AED rounds to 0 at 8 places
  assertEquals(invertRate(2e8), "0.00000001"); // 5e-9 rounds half-up to the smallest unit
  assertEquals(invertRate(1e-10), null); // 1e10 AED exceeds numeric(18,8)
});

Deno.test("invertRate: rejects non-positive and non-numeric quotes", () => {
  for (const bad of [0, -1, NaN, Infinity, "", "abc", "1,000", "-2", "0.000"]) {
    assertEquals(invertRate(bad), null, String(bad));
  }
});

Deno.test("aedPerUnit keeps only 3-letter upper-case codes with usable quotes", () => {
  assertEquals(
    aedPerUnit({
      AED: 1,
      EGP: 13.2381,
      INR: 22.6797,
      usd: 0.27,
      XAUX: 1,
      X1Y: 2,
      JPY: 0,
      GBP: null,
      CHF: "0.2165",
      EUR: {},
    }),
    { AED: "1.00000000", EGP: "0.07553954", INR: "0.04409229", CHF: "4.61893764" },
  );
});

Deno.test("parseErApi builds the upsert payload from a success response", () => {
  const out = parseErApi({
    result: "success",
    base_code: "AED",
    time_last_update_unix: 1791417601, // 2026-10-08T00:00:01Z
    rates: { AED: 1, EGP: 13.2381, INR: 22.6797, bad: 4 },
  });
  assertEquals(out, {
    rates: { AED: "1.00000000", EGP: "0.07553954", INR: "0.04409229" },
    source: FX_SOURCE,
    asOf: "2026-10-08",
  });
});

Deno.test("parseErApi falls back to now for a missing timestamp", () => {
  const out = parseErApi(
    { result: "success", base_code: "AED", rates: { EGP: 13.2381 } },
    new Date("2026-10-07T23:00:00Z"),
  );
  assertEquals(out.asOf, "2026-10-07");
});

Deno.test("parseErApi throws on provider errors and unusable payloads", () => {
  assertThrows(() => parseErApi({ result: "error", "error-type": "unsupported-code" }), Error, "unsupported-code");
  assertThrows(() => parseErApi({ result: "success", base_code: "USD", rates: { EGP: 1 } }), Error, "expected AED");
  assertThrows(() => parseErApi({ result: "success", base_code: "AED" }), Error, "no rates");
  assertThrows(() => parseErApi({ result: "success", base_code: "AED", rates: [1, 2] }), Error, "no rates");
  assertThrows(
    () => parseErApi({ result: "success", base_code: "AED", rates: { egp: 1, EGP: 0 } }),
    Error,
    "no usable",
  );
});

// The Edge Functions' own base64 (_shared/base64.ts), which replaced jsr:@std/encoding: Supabase's
// bundler timed out fetching it from jsr.io during production deploys.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import { decodeBase64, decodeBase64Portable, encodeBase64, encodeBase64Portable } from "../_shared/base64.ts";

const bytes = (s: string) => new TextEncoder().encode(s);
const text = (b: Uint8Array) => new TextDecoder().decode(b);

Deno.test("portable encode matches btoa for every tail length, and round-trips", () => {
  for (const s of ["", "f", "fo", "foo", "foob", "fooba", "foobar", "%PDF-???"]) {
    assertEquals(encodeBase64Portable(bytes(s)), btoa(s), s);
    assertEquals(encodeBase64(bytes(s)), btoa(s), s);
    assertEquals(text(decodeBase64Portable(btoa(s))), s, s);
    assertEquals(text(decodeBase64(btoa(s))), s, s);
  }
  const all = Uint8Array.from({ length: 256 * 3 + 1 }, (_, i) => i % 256);
  assertEquals(decodeBase64Portable(encodeBase64Portable(all)), all);
  assertEquals(encodeBase64Portable(all), btoa(String.fromCharCode(...all)));
});

Deno.test("portable decode: both alphabets, padding optional; bad input throws", () => {
  assertEquals(text(decodeBase64Portable("JVBERi0_Pz8")), "%PDF-???"); // base64url, no padding
  assertEquals(text(decodeBase64Portable("JVBERi0/Pz8=")), "%PDF-???"); // standard, padded
  assertEquals(decodeBase64Portable("").length, 0);
  assertThrows(() => decodeBase64Portable("!!!!"), TypeError);
  assertThrows(() => decodeBase64Portable("Q"), TypeError); // a 1-char tail is never valid
  assertThrows(() => decodeBase64Portable("QU=D"), TypeError); // padding inside the data
  assertThrows(() => decodeBase64Portable("QQ==="), TypeError); // too much padding
});

Deno.test("portable encode of a 25 MB document stays well inside the Edge CPU limit", () => {
  const big = new Uint8Array(25 * 1024 * 1024).fill(65);
  const t0 = performance.now();
  const b64 = encodeBase64Portable(big);
  const ms = performance.now() - t0;
  assertEquals(b64.length, Math.ceil(big.length / 3) * 4);
  assert(ms < 1000, `encode took ${ms} ms`);
});

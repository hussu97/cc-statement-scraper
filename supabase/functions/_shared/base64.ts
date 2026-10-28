// Base64 without a third-party import. @std/encoding came from jsr.io, and Supabase's bundler
// timed out fetching it during production deploys (28 Oct: three failed deploys in a row), so
// the Edge Functions carry their own codec.
//
// The native `Uint8Array.fromBase64` / `toBase64` (V8 ≥ 14) are used when the runtime has
// them; the portable versions below are table-driven and stay well inside the 2 s Edge CPU
// limit for a 25 MB attachment (SRV-07: an `atob` + charCodeAt loop cost ~1 s per 20 MB).

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const INVALID = 255;
// Both alphabets decode: standard (+ /) and URL-safe (- _).
const LOOKUP = (() => {
  const t = new Uint8Array(128).fill(INVALID);
  for (let i = 0; i < ALPHABET.length; i++) t[ALPHABET.charCodeAt(i)] = i;
  t["-".charCodeAt(0)] = 62;
  t["_".charCodeAt(0)] = 63;
  return t;
})();
const ENCODE = Uint8Array.from(ALPHABET, (c) => c.charCodeAt(0));
const PAD = "=".charCodeAt(0);

type Native = {
  fromBase64?: (s: string, opts: { alphabet: "base64" | "base64url" }) => Uint8Array;
};
const nativeFromBase64 = typeof (Uint8Array as unknown as Native).fromBase64 === "function"
  ? (Uint8Array as unknown as Required<Native>).fromBase64.bind(Uint8Array)
  : null;
const nativeToBase64 = typeof (Uint8Array.prototype as unknown as { toBase64?: unknown }).toBase64 === "function";

/**
 * Decode base64 in either alphabet, padded or not (no whitespace: strip it first). Throws a
 * TypeError on a character outside the alphabet, padding inside the data or a 1-char tail.
 */
export function decodeBase64Portable(s: string): Uint8Array {
  let end = s.length;
  while (end > 0 && s.charCodeAt(end - 1) === PAD) end--;
  if (s.length - end > 2) throw new TypeError("invalid base64: too much padding");
  const tail = end % 4;
  if (tail === 1) throw new TypeError("invalid base64: bad length");
  const out = new Uint8Array(Math.floor(end / 4) * 3 + (tail === 0 ? 0 : tail - 1));
  const at = (i: number): number => {
    const code = s.charCodeAt(i);
    const v = code < 128 ? LOOKUP[code] : INVALID;
    if (v === INVALID) throw new TypeError(`invalid base64 character at ${i}`);
    return v;
  };
  let o = 0;
  let i = 0;
  for (; i + 4 <= end; i += 4) {
    const n = (at(i) << 18) | (at(i + 1) << 12) | (at(i + 2) << 6) | at(i + 3);
    out[o++] = n >> 16;
    out[o++] = (n >> 8) & 0xff;
    out[o++] = n & 0xff;
  }
  if (tail === 2) {
    out[o++] = (at(i) << 2) | (at(i + 1) >> 4);
  } else if (tail === 3) {
    const n = (at(i) << 10) | (at(i + 1) << 4) | (at(i + 2) >> 2);
    out[o++] = n >> 8;
    out[o++] = n & 0xff;
  }
  return out;
}

/** Decode base64 (either alphabet, padding optional), natively when the runtime can. */
export function decodeBase64(s: string, alphabet: "base64" | "base64url" = "base64"): Uint8Array {
  return nativeFromBase64 ? nativeFromBase64(s, { alphabet }) : decodeBase64Portable(s);
}

/** Standard, padded base64 of the bytes (what the Anthropic API takes for a document). */
export function encodeBase64Portable(bytes: Uint8Array): string {
  const full = bytes.length - (bytes.length % 3);
  const out = new Uint8Array(Math.ceil(bytes.length / 3) * 4);
  let o = 0;
  for (let i = 0; i < full; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out[o++] = ENCODE[n >> 18];
    out[o++] = ENCODE[(n >> 12) & 63];
    out[o++] = ENCODE[(n >> 6) & 63];
    out[o++] = ENCODE[n & 63];
  }
  const rest = bytes.length - full;
  if (rest > 0) {
    const n = (bytes[full] << 16) | (rest === 2 ? bytes[full + 1] << 8 : 0);
    out[o++] = ENCODE[n >> 18];
    out[o++] = ENCODE[(n >> 12) & 63];
    out[o++] = rest === 2 ? ENCODE[(n >> 6) & 63] : PAD;
    out[o++] = PAD;
  }
  // ASCII only, so UTF-8 decoding is the identity.
  return new TextDecoder().decode(out);
}

/** Standard, padded base64 of the bytes, natively when the runtime can. */
export function encodeBase64(bytes: Uint8Array): string {
  return nativeToBase64 ? (bytes as unknown as { toBase64(): string }).toBase64() : encodeBase64Portable(bytes);
}

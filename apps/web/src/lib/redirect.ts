// Where /signin sends you back to (BACKLOG WEB-39). The address bar is
// attacker-controlled, so only a same-origin relative path is accepted:
// it starts with one "/", has no "//" prefix, no scheme, no backslash, no
// whitespace or control character (browsers drop tabs and newlines, so
// "/\t/evil.com" would become "//evil.com"), and no encoded slash or backslash
// a router could decode into one. Anything else is ignored, never "fixed".

const BASE = "https://ledger.invalid";
const MAX_LENGTH = 2048;

/** The path to return to after sign-in, or undefined when `raw` isn't a safe one. */
export function safeRedirect(raw: unknown): string | undefined {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > MAX_LENGTH) return undefined;
  if (raw[0] !== "/" || raw[1] === "/") return undefined;
  // eslint-disable-next-line no-control-regex -- control characters are exactly what this rejects
  if (/[\\\s\u0000-\u001f\u007f]/.test(raw)) return undefined;
  if (/%(2f|5c)/i.test(raw)) return undefined;
  let url: URL;
  try {
    url = new URL(raw, BASE);
  } catch {
    return undefined;
  }
  if (url.origin !== BASE) return undefined;
  // Dot segments can normalise "/.//host" into "//host": never hand back a protocol-relative path.
  if (url.pathname.startsWith("//")) return undefined;
  // Back to /signin would loop; "/" is where sign-in goes anyway.
  if (url.pathname === "/" && !url.search && !url.hash) return undefined;
  if (url.pathname === "/signin" || url.pathname.startsWith("/signin/")) return undefined;
  return url.pathname + url.search + url.hash;
}

/** The /signin search that brings you back to `href` (the current location's path, search and hash). */
export function signInSearch(href: string): { redirect?: string } {
  const redirect = safeRedirect(href);
  return redirect ? { redirect } : {};
}

/** /signin's validateSearch: keeps `redirect` only when it is safe. */
export function parseSignInSearch(raw: Record<string, unknown>): { redirect?: string } {
  return signInSearch(typeof raw.redirect === "string" ? raw.redirect : "");
}

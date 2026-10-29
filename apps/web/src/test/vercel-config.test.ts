// Guard for apps/web/vercel.json: SPA fallback, immutable hashed assets, a CSP
// that still allows the inline theme script in index.html, Supabase (REST +
// Realtime) and Sentry ingest, and no crawling or indexing. The file names no
// production host: the build pins Supabase to one host (scripts/deploy-config.ts). Editing the inline script changes its
// hash: recompute it with
//   node -e "const s=require('fs').readFileSync('index.html','utf8').match(/<script>([\s\S]*?)<\/script>/)[1];console.log(require('crypto').createHash('sha256').update(s).digest('base64'))"
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));

interface Header {
  key: string;
  value: string;
}
interface VercelConfig {
  redirects: { source: string; has: { type: string; key: string; value: string }[]; destination: string; permanent: boolean }[];
  rewrites: { source: string; destination: string }[];
  headers: { source: string; headers: Header[] }[];
}

const raw = readFileSync(`${ROOT}/vercel.json`, "utf8");
const config = JSON.parse(raw) as VercelConfig;
const html = readFileSync(`${ROOT}/index.html`, "utf8");

function headerFor(source: string, key: string): string | undefined {
  return config.headers.find((h) => h.source === source)?.headers.find((h) => h.key === key)?.value;
}

function cspDirectives(): Map<string, string[]> {
  const csp = headerFor("/(.*)", "Content-Security-Policy") ?? "";
  return new Map(
    csp
      .split(";")
      .map((d) => d.trim().split(/\s+/))
      .filter((parts) => parts[0])
      .map(([name, ...values]) => [name ?? "", values]),
  );
}

describe("vercel.json", () => {
  it("rewrites app routes to index.html but never hashed assets", () => {
    expect(config.rewrites).toHaveLength(1);
    const rewrite = config.rewrites[0]!;
    expect(rewrite.destination).toBe("/index.html");
    const re = new RegExp(`^${rewrite.source}$`);
    expect(re.test("/activity")).toBe(true);
    expect(re.test("/settings/members")).toBe(true);
    expect(re.test("/assets/index-abc123.js")).toBe(false);
  });

  it("caches hashed assets immutably", () => {
    expect(headerFor("/assets/(.*)", "Cache-Control")).toBe("public, max-age=31536000, immutable");
  });

  it("sets baseline security headers", () => {
    expect(headerFor("/(.*)", "X-Content-Type-Options")).toBe("nosniff");
    expect(headerFor("/(.*)", "Referrer-Policy")).toBe("strict-origin-when-cross-origin");
  });

  it("CSP allows the inline theme script by hash", () => {
    const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1] ?? "");
    expect(scripts.length).toBeGreaterThan(0);
    const allowed = cspDirectives().get("script-src") ?? [];
    expect(allowed).not.toContain("'unsafe-inline'");
    for (const body of scripts) {
      const hash = createHash("sha256").update(body).digest("base64");
      expect(allowed).toContain(`'sha256-${hash}'`);
    }
  });

  it("CSP allows Supabase (https + wss) and Sentry ingest only", () => {
    const connect = cspDirectives().get("connect-src") ?? [];
    expect(connect).toContain("https://*.supabase.co");
    expect(connect).toContain("wss://*.supabase.co");
    expect(connect).toContain("https://*.ingest.sentry.io");
    expect(connect).not.toContain("*");
    expect(cspDirectives().get("default-src")).toEqual(["'self'"]);
    expect(cspDirectives().get("frame-ancestors")).toEqual(["'none'"]);
  });

  it("CSP frames only our own documents and blob: (the term-sheet PDF viewer), never plugins", () => {
    expect(cspDirectives().get("frame-src")).toEqual(["'self'", "blob:"]);
    expect(cspDirectives().get("object-src")).toEqual(["'none'"]);
  });

  it("names no production host", () => {
    expect(raw).not.toMatch(/https?:\/\/[a-z0-9]{20}\.supabase\.co/);
    expect(raw).not.toMatch(/vercel\.app/);
  });

  it("asks every crawler not to index, follow, archive or train", () => {
    const tag = headerFor("/(.*)", "X-Robots-Tag") ?? "";
    for (const d of ["noindex", "nofollow", "noarchive", "nosnippet", "noai"]) expect(tag).toContain(d);
    expect(html).toMatch(/<meta name="robots" content="noindex, nofollow[^"]*"/);
    expect(html).not.toMatch(/<meta name="description"/);
    expect(readFileSync(`${ROOT}/public/robots.txt`, "utf8")).toMatch(/^User-agent: \*\nDisallow: \/$/m);
  });

  it("sends known bots to robots.txt, but never Apple's AASA fetcher or robots.txt itself", () => {
    expect(config.redirects).toHaveLength(1);
    const r = config.redirects[0]!;
    expect(r.destination).toBe("/robots.txt");
    expect(r.permanent).toBe(false);
    const path = new RegExp(`^${r.source}$`);
    expect(path.test("/")).toBe(true);
    expect(path.test("/activity")).toBe(true);
    expect(path.test("/robots.txt")).toBe(false);
    expect(path.test("/.well-known/apple-app-site-association")).toBe(false);
    const ua = new RegExp(`^${r.has[0]!.value}$`);
    for (const bot of [
      "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
      "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)",
      "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)",
      "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
      "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
      "Mozilla/5.0 (Linux; Android 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; Bytespider; spider-feedback@bytedance.com)",
    ])
      expect(ua.test(bot)).toBe(true);
    for (const person of [
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
      "curl/8.7.1",
    ])
      expect(ua.test(person)).toBe(false);
  });
});

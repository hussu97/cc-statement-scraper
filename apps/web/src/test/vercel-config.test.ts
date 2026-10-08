// Guard for apps/web/vercel.json: SPA fallback, immutable hashed assets, and a
// CSP that still allows the inline theme script in index.html, Supabase
// (REST + Realtime) and Sentry ingest. Editing the inline script changes its
// hash: recompute it with
//   node -e "const s=require('fs').readFileSync('index.html','utf8').match(/<script>([\s\S]*?)<\/script>/)[1];console.log(require('crypto').createHash('sha256').update(s).digest('base64'))"
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const SUPABASE_REF = "nkmylznisjcnmqbxosey";

interface Header {
  key: string;
  value: string;
}
interface VercelConfig {
  rewrites: { source: string; destination: string }[];
  headers: { source: string; headers: Header[] }[];
}

const config = JSON.parse(readFileSync(`${ROOT}/vercel.json`, "utf8")) as VercelConfig;
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
    expect(connect).toContain(`https://${SUPABASE_REF}.supabase.co`);
    expect(connect).toContain(`wss://${SUPABASE_REF}.supabase.co`);
    expect(connect).toContain("https://*.ingest.sentry.io");
    expect(connect).not.toContain("*");
    expect(cspDirectives().get("default-src")).toEqual(["'self'"]);
    expect(cspDirectives().get("frame-ancestors")).toEqual(["'none'"]);
  });
});

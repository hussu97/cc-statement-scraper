// Public routes must sit outside the authenticated AppShell layout (which
// redirects to /signin) and be served by the Vercel SPA rewrite as deep links.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { appRoute, router } from "@/router";
import { PRIVACY_LAST_UPDATED, PUBLIC_PATHS } from "@/lib/public-routes";

type AnyRoute = { id: string; parentRoute?: AnyRoute };

function isUnderAppShell(path: string): boolean {
  let r = (router.routesByPath as Record<string, AnyRoute | undefined>)[path];
  if (!r) throw new Error(`no route for ${path}`);
  while (r) {
    if (r.id === appRoute.id) return true;
    r = r.parentRoute;
  }
  return false;
}

describe("public routes", () => {
  it.each(PUBLIC_PATHS)("%s is reachable without the auth guard", (path) => {
    expect(isUnderAppShell(path)).toBe(false);
  });

  it("app screens stay behind the auth guard", () => {
    for (const path of ["/", "/settings", "/activity"]) expect(isUnderAppShell(path)).toBe(true);
  });

  it("vercel rewrite serves /privacy as a deep link", () => {
    const config = JSON.parse(readFileSync(fileURLToPath(new URL("../../vercel.json", import.meta.url)), "utf8")) as {
      rewrites: { source: string; destination: string }[];
    };
    const rewrite = config.rewrites.find((r) => new RegExp(`^${r.source}$`).test("/privacy"));
    expect(rewrite?.destination).toBe("/index.html");
  });

  it("last-updated date is a valid ISO date", () => {
    expect(PRIVACY_LAST_UPDATED).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(Number.isNaN(Date.parse(PRIVACY_LAST_UPDATED))).toBe(false);
  });
});

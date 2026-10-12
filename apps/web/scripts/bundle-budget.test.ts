import { describe, expect, it } from "vitest";
import { evaluateBudget, formatBudget, LEDGER_BUDGET, staticClosure, type BudgetChunk } from "./bundle-budget";

const NM = "/repo/node_modules/.pnpm/x@1/node_modules";
const chunk = (fileName: string, over: Partial<BudgetChunk> = {}): BudgetChunk => ({
  fileName,
  isEntry: false,
  imports: [],
  facadeModuleId: null,
  moduleIds: [`/repo/apps/web/src/${fileName}.ts`],
  gzipBytes: 1_000,
  ...over,
});

/** A bundle shaped like the real one: entry → react, supabase; lazy auth and privacy routes; a lazy shell with Radix. */
function bundle(over: Record<string, Partial<BudgetChunk>> = {}): BudgetChunk[] {
  const base: Record<string, Partial<BudgetChunk>> = {
    index: { isEntry: true, imports: ["react", "supabase"], gzipBytes: 30_000 },
    react: { moduleIds: [`${NM}/react-dom/index.js`], gzipBytes: 68_000 },
    supabase: { moduleIds: [`${NM}/@supabase/auth-js/index.js`], gzipBytes: 55_000 },
    auth: { facadeModuleId: "/repo/apps/web/src/routes/auth.tsx", imports: ["index", "chrome"], gzipBytes: 3_000 },
    chrome: { gzipBytes: 1_000 },
    privacy: { facadeModuleId: "/repo/apps/web/src/routes/privacy.tsx", imports: ["index", "chrome"], gzipBytes: 2_000 },
    shell: { facadeModuleId: "/repo/apps/web/src/components/shell.tsx", imports: ["index", "primitives"] },
    primitives: { moduleIds: [`${NM}/@radix-ui/react-menu/dist/index.mjs`], gzipBytes: 36_000 },
    charts: { facadeModuleId: "/repo/apps/web/src/components/charts/spend-split-chart.tsx", moduleIds: [`${NM}/recharts/lib/index.js`] },
    "sentry-client": { facadeModuleId: "/repo/apps/web/src/lib/sentry-client.ts", moduleIds: [`${NM}/@sentry/core/index.js`] },
  };
  return Object.entries({ ...base, ...over }).map(([name, o]) => chunk(name, { ...base[name], ...o }));
}

describe("staticClosure", () => {
  it("follows static imports transitively, once each, and ignores unknown names", () => {
    const byName = new Map(bundle().map((c) => [c.fileName, c]));
    expect(staticClosure(byName, ["auth"])).toEqual(["auth", "index", "chrome", "react", "supabase"]);
    expect(staticClosure(byName, ["nope"])).toEqual([]);
  });
});

describe("evaluateBudget", () => {
  it("passes the bundle as it is meant to be", () => {
    const r = evaluateBudget(bundle(), LEDGER_BUDGET);
    expect(r.problems).toEqual([]);
    expect(r.entryFiles).toEqual(["index", "react", "supabase"]);
    expect(r.entryGzipBytes).toBe(153_000);
    expect(r.routes).toEqual([
      { label: "/signin", files: ["auth", "chrome"], gzipBytes: 4_000 },
      { label: "/privacy", files: ["privacy", "chrome"], gzipBytes: 3_000 },
    ]);
    expect(formatBudget(r, LEDGER_BUDGET)).toBe(
      "bundle budget: first load 153.0 kB gzipped of 200.0 kB (3 files); /signin +4.0 kB, /privacy +3.0 kB",
    );
  });

  it("fails a first load over budget", () => {
    const r = evaluateBudget(bundle({ supabase: { gzipBytes: 120_000 } }), LEDGER_BUDGET);
    expect(r.problems).toEqual(["first load is 218.0 kB gzipped, over the 200.0 kB budget (index, react, supabase)"]);
  });

  it("fails when the Sentry SDK is back in the first load", () => {
    const r = evaluateBudget(bundle({ index: { imports: ["react", "supabase", "sentry-client"] } }), LEDGER_BUDGET);
    expect(r.problems).toContain("the first load includes the Sentry SDK (sentry-client)");
  });

  it("fails when sign-in pulls in Radix or the charts", () => {
    const r = evaluateBudget(bundle({ auth: { imports: ["index", "chrome", "shell"] }, chrome: { imports: ["charts"] } }), LEDGER_BUDGET);
    expect(r.problems).toEqual(["/signin loads Radix (primitives)", "/signin loads charts (charts)", "/privacy loads charts (charts)"]);
  });

  it("matches the umbrella radix-ui package too", () => {
    const r = evaluateBudget(bundle({ chrome: { moduleIds: [`${NM}/radix-ui/dist/index.mjs`] } }), LEDGER_BUDGET);
    expect(r.problems).toEqual(["/signin loads Radix (chrome)", "/privacy loads Radix (chrome)"]);
  });

  it("fails loudly when a light route's chunk is gone, instead of passing it", () => {
    const r = evaluateBudget(
      bundle().filter((c) => c.fileName !== "privacy"),
      LEDGER_BUDGET,
    );
    expect(r.problems).toEqual([`/privacy: no chunk for ${LEDGER_BUDGET.lightRoutes[1]!.module} (renamed? update the budget rules)`]);
  });
});

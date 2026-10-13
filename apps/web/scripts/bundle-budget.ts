// First-load bundle budget (WEB-11), checked on every `vite build` (pnpm web:build, pnpm check,
// CI and Vercel). It fails the build when:
//   - the entry chunk plus everything it imports statically (what every route downloads before
//     the first screen) is over budget, gzipped, or
//   - a light route (sign-in, privacy) loads Radix, the chart library or the Sentry SDK, or
//   - Overview loads the chart library before it renders (WEB-53: its bars load it lazily).
// The evaluation is pure and unit-tested (bundle-budget.test.ts); the plugin only feeds it.
import { gzipSync } from "node:zlib";
import type { Plugin } from "vite";

export interface BudgetChunk {
  fileName: string;
  isEntry: boolean;
  /** Chunks this one imports statically (they load with it). */
  imports: string[];
  /** The module the chunk was created for (a route's lazy import), if any. */
  facadeModuleId: string | null;
  moduleIds: string[];
  gzipBytes: number;
}

export interface BudgetRules {
  /** Gzipped bytes allowed for the entry and its static imports. */
  entryGzipBytes: number;
  /**
   * Routes that must stay light: the lazy chunk whose facade module matches `module`. `heavy`
   * names the heavy modules (by label) it may not load statically; all of them when absent.
   */
  lightRoutes: { label: string; module: RegExp; heavy?: string[] }[];
  /** Modules the first load and a light route may not contain. */
  heavyModules: { label: string; test: RegExp }[];
}

export interface BudgetReport {
  entryFiles: string[];
  entryGzipBytes: number;
  /** Per light route: what it adds to the first load. */
  routes: { label: string; files: string[]; gzipBytes: number }[];
  problems: string[];
}

/** `roots` and every chunk they import statically, transitively, in visit order. */
export function staticClosure(byName: Map<string, BudgetChunk>, roots: string[]): string[] {
  const seen = new Set<string>();
  const queue = [...roots];
  while (queue.length) {
    const name = queue.shift()!;
    const chunk = byName.get(name);
    if (!chunk || seen.has(name)) continue;
    seen.add(name);
    queue.push(...chunk.imports);
  }
  return [...seen];
}

const sum = (byName: Map<string, BudgetChunk>, files: string[]) => files.reduce((n, f) => n + (byName.get(f)?.gzipBytes ?? 0), 0);
const kB = (bytes: number) => `${(bytes / 1000).toFixed(1)} kB`;

export function evaluateBudget(chunks: BudgetChunk[], rules: BudgetRules): BudgetReport {
  const byName = new Map(chunks.map((c) => [c.fileName, c]));
  const problems: string[] = [];
  const entries = chunks.filter((c) => c.isEntry).map((c) => c.fileName);
  if (entries.length === 0) problems.push("no entry chunk in the bundle");
  const entryFiles = staticClosure(byName, entries);
  const entryGzipBytes = sum(byName, entryFiles);
  if (entryGzipBytes > rules.entryGzipBytes) {
    problems.push(`first load is ${kB(entryGzipBytes)} gzipped, over the ${kB(rules.entryGzipBytes)} budget (${entryFiles.join(", ")})`);
  }

  const heavyIn = (files: string[], only?: string[]) =>
    rules.heavyModules.flatMap(({ label, test }) => {
      if (only && !only.includes(label)) return [];
      const hits = files.filter((f) => byName.get(f)!.moduleIds.some((id) => test.test(id)));
      return hits.length ? [`${label} (${hits.join(", ")})`] : [];
    });
  for (const heavy of heavyIn(entryFiles)) problems.push(`the first load includes ${heavy}`);

  const routes = rules.lightRoutes.map(({ label, module, heavy }) => {
    for (const h of heavy ?? []) if (!rules.heavyModules.some((m) => m.label === h)) problems.push(`${label}: no heavy module labelled "${h}"`);
    const chunk = chunks.find((c) => c.facadeModuleId !== null && module.test(c.facadeModuleId));
    if (!chunk) {
      problems.push(`${label}: no chunk for ${module} (renamed? update the budget rules)`);
      return { label, files: [], gzipBytes: 0 };
    }
    const files = staticClosure(byName, [chunk.fileName]).filter((f) => !entryFiles.includes(f));
    for (const hit of heavyIn(files, heavy)) problems.push(`${label} loads ${hit}`);
    return { label, files, gzipBytes: sum(byName, files) };
  });
  return { entryFiles, entryGzipBytes, routes, problems };
}

/** One line for the build log. */
export function formatBudget(report: BudgetReport, rules: BudgetRules): string {
  const routes = report.routes.map((r) => `${r.label} +${kB(r.gzipBytes)}`).join(", ");
  return `bundle budget: first load ${kB(report.entryGzipBytes)} gzipped of ${kB(rules.entryGzipBytes)} (${report.entryFiles.length} files)${routes ? `; ${routes}` : ""}`;
}

const NODE_MODULE = (pkg: string) => new RegExp(`[\\\\/]node_modules[\\\\/]${pkg}[\\\\/]`);

/**
 * Bank Ledger's budget: ~200 kB gzipped first load; sign-in and privacy free of Radix, charts
 * and Sentry; Overview free of the charts until its bars ask for them.
 */
export const LEDGER_BUDGET: BudgetRules = {
  entryGzipBytes: 200_000,
  lightRoutes: [
    { label: "/signin", module: /[\\/]src[\\/]routes[\\/]auth\.tsx$/ },
    { label: "/privacy", module: /[\\/]src[\\/]routes[\\/]privacy\.tsx$/ },
    { label: "Overview", module: /[\\/]src[\\/]routes[\\/]overview\.tsx$/, heavy: ["charts"] },
  ],
  heavyModules: [
    { label: "Radix", test: NODE_MODULE("(@radix-ui[\\\\/][^\\\\/]+|radix-ui)") },
    { label: "charts", test: NODE_MODULE("(recharts|d3-[a-z-]+)") },
    { label: "the Sentry SDK", test: NODE_MODULE("(@sentry[\\\\/][^\\\\/]+|@supabase[\\\\/]sentry-js-integration)") },
  ],
};

export function bundleBudget(rules: BudgetRules = LEDGER_BUDGET): Plugin {
  return {
    name: "ledger-bundle-budget",
    apply: "build",
    generateBundle(_options, bundle) {
      const chunks: BudgetChunk[] = Object.values(bundle).flatMap((c) =>
        c.type === "chunk"
          ? [
              {
                fileName: c.fileName,
                isEntry: c.isEntry,
                imports: c.imports,
                facadeModuleId: c.facadeModuleId ?? null,
                moduleIds: Object.keys(c.modules),
                gzipBytes: gzipSync(c.code).length,
              },
            ]
          : [],
      );
      const report = evaluateBudget(chunks, rules);
      this.info(formatBudget(report, rules));
      if (report.problems.length) this.error(`bundle budget (WEB-11):\n  - ${report.problems.join("\n  - ")}`);
    },
  };
}

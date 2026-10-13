import { createRootRoute, createRoute, createRouter, lazyRouteComponent, Outlet } from "@tanstack/react-router";
import { parseActivitySearch } from "@/lib/activity-filters";
import { parseInsightsSearch, parseRangeSearch, parseTabSearch } from "@/lib/search";
import { parsePageSearch } from "@/lib/infinite";
import { parseSignInSearch } from "@/lib/redirect";

const rootRoute = createRootRoute({
  component: () => <Outlet />,
  // Inside the app shell when signed in, a plain page when not (WEB-52). Lazy, as it loads the shell.
  notFoundComponent: lazyRouteComponent(() => import("@/routes/not-found"), "NotFoundPage"),
});

const signInRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/signin",
  // Where to go after signing in: a same-origin path only (WEB-39).
  validateSearch: parseSignInSearch,
  component: lazyRouteComponent(() => import("@/routes/auth"), "SignInPage"),
});

const welcomeRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/welcome",
  validateSearch: (s: Record<string, unknown>): { new?: 1 } => (s.new ? { new: 1 } : {}),
  component: lazyRouteComponent(() => import("@/routes/auth"), "WelcomePage"),
});

// Public: rendered outside AppShell so it works signed out and as a deep link.
const privacyRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/privacy",
  component: lazyRouteComponent(() => import("@/routes/privacy"), "PrivacyPage"),
});

/**
 * Authenticated layout: AppShell redirects to /signin without a session. Lazy, like every
 * screen, so /signin and /privacy load neither the shell nor its Radix menus (WEB-11).
 */
export const appRoute = createRoute({
  getParentRoute: () => rootRoute,
  id: "app",
  component: lazyRouteComponent(() => import("@/components/shell"), "AppShell"),
});

const overviewRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/",
  validateSearch: (s: Record<string, unknown>): { month?: string } =>
    typeof s.month === "string" && /^\d{4}-\d{2}-01$/.test(s.month) ? { month: s.month } : {},
  component: lazyRouteComponent(() => import("@/routes/overview"), "OverviewPage"),
});

export const activityRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/activity",
  validateSearch: parseActivitySearch,
  component: lazyRouteComponent(() => import("@/routes/activity"), "ActivityPage"),
});

export const insightsRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/insights",
  validateSearch: parseInsightsSearch,
  component: lazyRouteComponent(() => import("@/routes/insights"), "InsightsPage"),
});

/** One category over time (MA-1): `$categoryCode` is a cat_ code or "none"; the range is the Insights range. */
export const categoryRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/insights/category/$categoryCode",
  validateSearch: parseRangeSearch,
  component: lazyRouteComponent(() => import("@/routes/category"), "CategoryPage"),
});

const budgetsRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/budgets",
  component: lazyRouteComponent(() => import("@/routes/budgets"), "BudgetsPage"),
});

const cardsRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/cards",
  validateSearch: (raw: Record<string, unknown>) => ({ ...parseTabSearch(raw), ...parsePageSearch(raw) }),
  component: lazyRouteComponent(() => import("@/routes/cards"), "CardsPage"),
});

/** One statement: header, totals, debits and credits, reconciliation, processing log. `?txn=` opens a line's transaction. */
export const statementRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/statements/$stmtCode",
  validateSearch: (s: Record<string, unknown>): { txn?: string } =>
    typeof s.txn === "string" && /^txn_[0-9a-z]{26}$/.test(s.txn) ? { txn: s.txn } : {},
  component: lazyRouteComponent(() => import("@/routes/statement"), "StatementPage"),
});

export const reviewRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/review",
  validateSearch: parsePageSearch,
  component: lazyRouteComponent(() => import("@/routes/review"), "ReviewPage"),
});

const rulesRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/rules",
  validateSearch: parseTabSearch,
  component: lazyRouteComponent(() => import("@/routes/rules"), "RulesPage"),
});

const settingsRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/settings",
  validateSearch: parseTabSearch,
  component: lazyRouteComponent(() => import("@/routes/settings"), "SettingsPage"),
});

const routeTree = rootRoute.addChildren([
  signInRoute,
  welcomeRoute,
  privacyRoute,
  appRoute.addChildren([overviewRoute, activityRoute, insightsRoute, categoryRoute, budgetsRoute, cardsRoute, statementRoute, reviewRoute, rulesRoute, settingsRoute]),
]);

export const router = createRouter({ routeTree, defaultPreload: "intent", scrollRestoration: true });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

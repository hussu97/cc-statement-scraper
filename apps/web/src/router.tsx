import { createRootRoute, createRoute, createRouter, lazyRouteComponent, Outlet, redirect } from "@tanstack/react-router";
import { activityRouteSearch } from "@/lib/activity-filters";
import { insightsRouteSearch, parseRangeSearch, parseTabSearch } from "@/lib/search";
import { parsePageSearch } from "@/lib/infinite";
import { parseSignInSearch } from "@/lib/redirect";
import { parseCashFlowSearch } from "@/lib/cash-flow";
import { parseAccountSearch, parsePortfolioSearch } from "@/lib/wealth";
import { parseInvestmentsSearch } from "@/lib/investments";
import { parseIndiaAccountSearch, parseIndiaSearch } from "@/lib/india";

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
  validateSearch: activityRouteSearch,
  component: lazyRouteComponent(() => import("@/routes/activity"), "ActivityPage"),
});

export const insightsRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/insights",
  validateSearch: insightsRouteSearch,
  component: lazyRouteComponent(() => import("@/routes/insights"), "InsightsPage"),
});

/** One category over time (MA-1): `$categoryCode` is a cat_ code or "none"; the range is the Insights range. */
export const categoryRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/insights/category/$categoryCode",
  validateSearch: parseRangeSearch,
  component: lazyRouteComponent(() => import("@/routes/category"), "CategoryPage"),
});

/** The old Cash flow address (Phase 2d): Cash flow moved under Wealth; the month comes along. */
const cashFlowRedirectRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/cash-flow",
  validateSearch: (s: Record<string, unknown>) => parseCashFlowSearch(s),
  beforeLoad: ({ search }) => {
    throw redirect({ to: "/wealth/cash-flow", search: { month: search.month, account: search.account }, replace: true });
  },
});

// ── Wealth mode (tasks/todo.md §5, §6): bank accounts, their ledgers, investments, cash flow and net worth ──

/** Net worth, bank accounts, what the cards owe, this month's cash flow and wealth insights. */
const wealthRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/wealth",
  component: lazyRouteComponent(() => import("@/routes/wealth"), "WealthOverviewPage"),
});

const wealthAccountsRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/wealth/accounts",
  component: lazyRouteComponent(() => import("@/routes/wealth-accounts"), "AccountsPage"),
});

/**
 * One bank account: balance, balance chart and the month's ledger. `?month=YYYY-MM`, this month
 * when absent. A broker account's portfolio is under Investments (wealthPortfolioRoute).
 */
export const wealthAccountRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/wealth/accounts/$accountCode",
  validateSearch: (s: Record<string, unknown>) => parseAccountSearch(s),
  component: lazyRouteComponent(() => import("@/routes/wealth-account"), "AccountPage"),
});

/** Investments: metals, plans, broker accounts, shares and funds, deposits (values, gains, returns). `?period=` drives the chart and the returns. */
export const wealthInvestmentsRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/wealth/investments",
  validateSearch: (s: Record<string, unknown>) => parseInvestmentsSearch(s),
  component: lazyRouteComponent(() => import("@/routes/wealth-investments"), "InvestmentsPage"),
});

/**
 * A synced broker account's portfolio: the portfolio card, then Portfolio / Transactions / Past
 * tabs. `?tab=` (Portfolio when absent) and the Transactions tab's `?month=YYYY-MM`.
 */
export const wealthPortfolioRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/wealth/investments/accounts/$accountCode",
  validateSearch: (s: Record<string, unknown>) => parsePortfolioSearch(s),
  component: lazyRouteComponent(() => import("@/routes/wealth-portfolio"), "PortfolioPage"),
});

/** One holding: value, cost, income, gain, returns, flows (with linked payments) and value history. */
export const wealthHoldingRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/wealth/investments/$holdingCode",
  component: lazyRouteComponent(() => import("@/routes/wealth-holding"), "HoldingPage"),
});

/** Each month's money in and out. `?month=` is a first-of-month (this month when absent); `?account=` narrows to one bank account. */
export const wealthCashFlowRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/wealth/cash-flow",
  validateSearch: (s: Record<string, unknown>) => parseCashFlowSearch(s),
  component: lazyRouteComponent(() => import("@/routes/wealth-cash-flow"), "CashFlowPage"),
});

// ── India mode (tasks/todo.md §12): Zerodha Kite and Coin, in INR, apart from Wealth ──

/** Kite and Coin together: value, P&L, the last 24 hours, a period's chart and returns, a row per account. `?period=` (90 days when absent). */
export const indiaRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/india",
  validateSearch: (s: Record<string, unknown>) => parseIndiaSearch(s),
  component: lazyRouteComponent(() => import("@/routes/india"), "IndiaOverviewPage"),
});

/** The Kite account's portfolio: the portfolio card, then Portfolio / Sold tabs (`?tab=past`). */
export const indiaKiteRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/india/kite",
  validateSearch: (s: Record<string, unknown>) => parseIndiaAccountSearch(s),
  component: lazyRouteComponent(() => import("@/routes/india-account"), "IndiaKitePage"),
});

/** The Coin account's portfolio, as Kite's. */
export const indiaCoinRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/india/coin",
  validateSearch: (s: Record<string, unknown>) => parseIndiaAccountSearch(s),
  component: lazyRouteComponent(() => import("@/routes/india-account"), "IndiaCoinPage"),
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
  appRoute.addChildren([overviewRoute, activityRoute, insightsRoute, categoryRoute, cashFlowRedirectRoute, wealthRoute, wealthAccountsRoute, wealthAccountRoute, wealthInvestmentsRoute, wealthPortfolioRoute, wealthHoldingRoute, wealthCashFlowRoute, indiaRoute, indiaKiteRoute, indiaCoinRoute, budgetsRoute, cardsRoute, statementRoute, reviewRoute, rulesRoute, settingsRoute]),
]);

export const router = createRouter({ routeTree, defaultPreload: "intent", scrollRestoration: true });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

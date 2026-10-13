// Query keys. Every profile-scoped key starts with ["p", profileCode, domain],
// so a profile switch or a realtime event can invalidate by prefix.
import type { ActivitySearch } from "@/lib/activity-filters";

export const keys = {
  session: ["session"] as const,
  profiles: ["profiles"] as const,
  /** Reference data (not profile-scoped). */
  banks: ["banks"] as const,
  passkeys: (userId: string) => ["passkeys", userId] as const,
  profile: (p: string) => ["p", p] as const,
  domain: (p: string, d: Domain) => ["p", p, d] as const,

  overview: (p: string, month: string) => ["p", p, "overview", month] as const,
  insights: (p: string) => ["p", p, "insights"] as const,
  filterMeta: (p: string) => ["p", p, "meta"] as const,

  transactions: (p: string, s: ActivitySearch) => ["p", p, "transactions", "list", s] as const,
  activitySummary: (p: string, s: ActivitySearch) => ["p", p, "transactions", "summary", s] as const,
  dayTotals: (p: string, s: ActivitySearch, days: readonly string[]) => ["p", p, "transactions", "days", s, days.join(",")] as const,
  selectionSummary: (p: string, selection: unknown) => ["p", p, "transactions", "selection", selection] as const,
  transaction: (p: string, code: string) => ["p", p, "transactions", "one", code] as const,
  merchantContext: (p: string, merchantCode: string) => ["p", p, "transactions", "merchant", merchantCode] as const,
  evidence: (p: string, code: string) => ["p", p, "transactions", "evidence", code] as const,
  smsBody: (p: string, code: string) => ["p", p, "sms", "body", code] as const,

  analytics: (p: string, name: string, ...args: unknown[]) => ["p", p, "analytics", name, ...args] as const,

  budgetStatus: (p: string, month: string) => ["p", p, "budgets", "status", month] as const,

  accounts: (p: string) => ["p", p, "accounts"] as const,
  cycles: (p: string) => ["p", p, "statements", "cycles"] as const,
  documents: (p: string) => ["p", p, "documents"] as const,
  statement: (p: string, stmtCode: string) => ["p", p, "statements", "one", stmtCode] as const,
  documentEvents: (p: string, docCodes: readonly string[]) => ["p", p, "documents", "events", [...docCodes].sort().join(",")] as const,

  reviews: (p: string) => ["p", p, "reviews", "open"] as const,
  reviewCount: (p: string) => ["p", p, "reviews", "count"] as const,

  categories: (p: string) => ["p", p, "categories"] as const,
  rules: (p: string) => ["p", p, "rules"] as const,
  rulePreview: (p: string, args: unknown) => ["p", p, "rules", "preview", args] as const,
  merchants: (p: string) => ["p", p, "merchants"] as const,

  members: (p: string) => ["p", p, "members"] as const,
  tokens: (p: string) => ["p", p, "tokens"] as const,
  secrets: (p: string) => ["p", p, "secrets"] as const,
  mailboxes: (p: string) => ["p", p, "mail"] as const,
  sourceHealth: (p: string) => ["p", p, "health"] as const,
};

export type Domain =
  | "overview"
  | "insights"
  | "meta"
  | "transactions"
  | "sms"
  | "analytics"
  | "budgets"
  | "accounts"
  | "statements"
  | "documents"
  | "reviews"
  | "categories"
  | "rules"
  | "merchants"
  | "members"
  | "tokens"
  | "secrets"
  | "mail"
  | "health";

/** Domains whose numbers depend on the ledger's transactions. */
export const LEDGER_DOMAINS: Domain[] = [
  "overview",
  "transactions",
  "analytics",
  "budgets",
  "accounts",
  "statements",
  "reviews",
  "merchants",
  "health",
];

import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type RpcReturn, type Tables, type Views } from "@/lib/supabase";
import type { Json } from "@ledger/db-types";
import { keys, LEDGER_DOMAINS } from "./keys";
import { fetchPage, must, mustList, toApiError, type Page } from "./api";
import { useAuth } from "./auth";
import { useInfiniteList } from "./infinite";
import { pageRange } from "@/lib/pagination";

export type Review = Tables<"match_reviews">;

export const REVIEW_REASONS: Record<string, { title: string; help: string }> = {
  ambiguous: {
    title: "Ambiguous matches",
    help: "More than one transaction fits this evidence. Pick the right one, or keep it as a new transaction.",
  },
  low_score: {
    title: "Weak matches",
    help: "The closest transaction is only a partial match. Link it if it's the same purchase.",
  },
  amount_drift: { title: "Amount changed", help: "The posted amount differs from the alert." },
  unknown_card: {
    title: "Unknown cards",
    help: "An SMS or Wallet payment mentions a card Bank Ledger doesn't know. Tell it which account the card belongs to.",
  },
  unparsed_sms: {
    title: "New SMS formats",
    help: "A bank message didn't match any format. Bank Ledger proposed a template; accept it to parse similar messages.",
  },
  orphaned: {
    title: "Orphaned transactions",
    help: "Their only evidence was removed (for example, a statement was re-parsed), so they count in no total. Void them once checked.",
  },
  missing_from_statement: {
    title: "Missing from statement",
    help: "An SMS purchase never appeared on the statement that covers its date. It may have been released.",
  },
  period_overlap: {
    title: "Overlapping statements",
    help: "Two statements of the same card cover the same days. Supersede the older one if it was replaced.",
  },
};

/** Stable display order for review groups. */
export const REASON_ORDER = [
  "unknown_card",
  "ambiguous",
  "low_score",
  "amount_drift",
  "unparsed_sms",
  "period_overlap",
  "missing_from_statement",
  "orphaned",
];

export function groupReviews<T extends Pick<Review, "reason">>(list: T[]): { reason: string; items: T[] }[] {
  const map = new Map<string, T[]>();
  for (const r of list) map.set(r.reason, [...(map.get(r.reason) ?? []), r]);
  const order = (r: string) => {
    const i = REASON_ORDER.indexOf(r);
    return i === -1 ? 99 : i;
  };
  return [...map.entries()].sort((a, b) => order(a[0]) - order(b[0])).map(([reason, items]) => ({ reason, items }));
}

/**
 * Open-review count for the nav badge: a head request, no rows. Gated on a
 * restored session and a profile, so it never runs with the anon key (anon has
 * no grant on match_reviews: "permission denied for table match_reviews").
 */
export function useOpenReviewCount(profileCode: string | null | undefined) {
  const { session } = useAuth();
  return useQuery({
    queryKey: keys.reviewCount(profileCode ?? ""),
    enabled: reviewQueriesEnabled(session, profileCode),
    queryFn: async () => {
      const res = await supabase
        .from("match_reviews")
        .select("review_code", { count: "exact", head: true })
        .eq("profile_code", profileCode!)
        .eq("status", "open");
      if (res.error) throw toApiError(res.error, res.status);
      return res.count ?? 0;
    },
  });
}

/** Review queries need a signed-in session and an active profile. Pure, unit-tested. */
export function reviewQueriesEnabled(session: unknown, profileCode: string | null | undefined): boolean {
  return !!session && !!profileCode;
}

/**
 * Rows [from, to] of open reviews, newest first, with the exact total, each with its context:
 * one page read plus one `review_context` call for the whole page (WEB-10r), so a page costs two
 * requests however many cards it holds, and the contexts refresh with the list.
 */
export async function fetchOpenReviews(profileCode: string, from: number, to: number): Promise<Page<ReviewItem>> {
  const head = () =>
    supabase.from("match_reviews").select("review_code", { count: "exact", head: true }).eq("profile_code", profileCode).eq("status", "open");
  const page = await fetchPage<Review>(
    () =>
      supabase
        .from("match_reviews")
        .select("*", { count: "exact" })
        .eq("profile_code", profileCode)
        .eq("status", "open")
        .order("created_at", { ascending: false })
        .order("review_code", { ascending: false })
        .range(from, to),
    head,
  );
  if (page.rows.length === 0) return { rows: [], total: page.total };
  const contexts = mustList(
    await supabase.rpc("review_context", { p_profile_code: profileCode, p_review_codes: page.rows.map((r) => r.review_code) }),
  );
  return { rows: attachContexts(page.rows, contexts), total: page.total };
}

/** One page of open reviews (with their contexts), newest first, with the exact total. */
export function useOpenReviews(profileCode: string, page: number, size: number, enabled = true) {
  const { session } = useAuth();
  return useQuery({
    queryKey: [...keys.reviews(profileCode), page, size],
    enabled: enabled && reviewQueriesEnabled(session, profileCode),
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<Page<ReviewItem>> => {
      const { from, to } = pageRange(page, size);
      return fetchOpenReviews(profileCode, from, to);
    },
  });
}

const reviewId = (r: ReviewItem) => r.review_code;
/** Phones: every open review (with its context), 100 at a time. */
export function useInfiniteOpenReviews(profileCode: string, enabled = true) {
  const { session } = useAuth();
  return useInfiniteList<ReviewItem>({
    queryKey: [...keys.reviews(profileCode), "infinite"],
    enabled: enabled && reviewQueriesEnabled(session, profileCode),
    fetch: (from, to) => fetchOpenReviews(profileCode, from, to),
    idOf: reviewId,
  });
}

/** Actions in a review card's footer (besides per-candidate links and the card/template pickers). */
export type ReviewFooterAction = "separate" | "supersede" | "retry_ai" | "not_a_transaction" | "dismiss";

/**
 * Which footer actions a review offers. Every open review has at least one way
 * to be cleared: an unparsed SMS without a proposed format (the LLM proposed
 * nothing, or the proposal is gone) can be sent to the AI again, marked "not a
 * card transaction", or dismissed (WEB-07). An SMS from an unknown card can
 * also be marked "not a card transaction" (e.g. a debit-card alert). Pure,
 * unit-tested.
 */
export function reviewFooterActions(r: Pick<Review, "reason" | "subject_type">, hasTemplate: boolean): ReviewFooterAction[] {
  if (r.reason === "unparsed_sms") return hasTemplate ? [] : ["retry_ai", "not_a_transaction", "dismiss"];
  const out: ReviewFooterAction[] = [];
  if ((r.subject_type === "statement_line" || r.subject_type === "sms") && r.reason !== "unknown_card") out.push("separate");
  if (r.reason === "period_overlap") out.push("supersede");
  if (r.reason === "unknown_card" && r.subject_type === "sms") out.push("not_a_transaction");
  out.push("dismiss");
  return out;
}

export interface ReviewCandidate {
  txn_code?: string;
  score?: number;
  bank_code?: string;
  last4?: string;
  /** unknown_card on an SMS that names the card by its first six digits (EIB: "starting with 529205"). */
  first6?: string;
  template_code?: string;
  stmt_code?: string;
  statement_date?: string;
  /** unknown_card on a Wallet row: the pass name the shortcut sent. */
  wallet_name?: string;
}

export function candidatesOf(r: Pick<Review, "candidates">): ReviewCandidate[] {
  return Array.isArray(r.candidates) ? (r.candidates as unknown as ReviewCandidate[]) : [];
}

/**
 * The Wallet pass name behind an unknown_card review, or null when the review
 * is about a bank SMS (or anything else). A Wallet row is matched to a card by
 * cards.wallet_name, never by registering a card number, so resolve_review's
 * card action refuses it (22023): the UI points to the Cards page instead.
 * Reads the review's candidates first, then the loaded SMS row. A Wallet row
 * without a pass name gives "" (still a Wallet row, still not a card number).
 * Pure, unit-tested.
 */
export function walletPassNameOf(
  r: Pick<Review, "reason" | "subject_type" | "candidates">,
  sms?: { source?: string | null; wallet_pass_name?: string | null } | null,
): string | null {
  if (r.reason !== "unknown_card" || r.subject_type !== "sms") return null;
  const fromCandidates = candidatesOf(r).find((c) => typeof c.wallet_name === "string" && c.wallet_name.trim())?.wallet_name;
  if (fromCandidates) return fromCandidates.trim();
  if (sms?.source === "wallet") return sms.wallet_pass_name?.trim() || "";
  return null;
}

/**
 * How an unknown_card review names the card: "EIB •9212" by its last four digits, "EIB card
 * starting 529205" when the SMS shows only the first six (the BIN), "EIB •????" when neither.
 * A BIN-only message is put on the chosen account without registering a card. Pure, unit-tested.
 */
export function unknownCardLabel(bank: string | null | undefined, last4: string | null | undefined, first6?: string | null): string {
  const b = bank ?? "";
  if (last4) return `${b} •${last4}`.trim();
  if (first6) return `${b} card starting ${first6}`.trim();
  return `${b} •????`.trim();
}

export interface ReviewContext {
  line: Tables<"statement_lines"> | null;
  sms: Omit<Tables<"sms_messages">, "body"> | null;
  txn: Views<"v_transactions"> | null;
  statement: Tables<"statements"> | null;
  candidates: Views<"v_transactions">[];
  template: Omit<Tables<"sms_templates">, "examples"> | null;
}

/** A review with its context, as the Review page lists it. */
export type ReviewItem = Review & { ctx: ReviewContext };

export type ReviewContextRow = RpcReturn<"review_context">[number];

const asRow = <T>(v: Json | null | undefined): T | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as unknown as T) : null);

/** One review_context row as the card reads it; jsonb nulls (or a missing row) become null/[]. Pure, unit-tested. */
export function contextOf(row: ReviewContextRow | undefined): ReviewContext {
  return {
    line: asRow<ReviewContext["line"]>(row?.line),
    sms: asRow<ReviewContext["sms"]>(row?.sms),
    txn: asRow<ReviewContext["txn"]>(row?.txn),
    statement: asRow<ReviewContext["statement"]>(row?.statement),
    candidates: Array.isArray(row?.candidates) ? (row.candidates as unknown as ReviewContext["candidates"]) : [],
    template: asRow<ReviewContext["template"]>(row?.template),
  };
}

/** Pair each review with its review_context row (by code; a review without one gets an empty context). Pure, unit-tested. */
export function attachContexts(rows: Review[], contexts: ReviewContextRow[]): ReviewItem[] {
  const byCode = new Map(contexts.map((c) => [c.review_code, c]));
  return rows.map((r) => ({ ...r, ctx: contextOf(byCode.get(r.review_code)) }));
}

export type ResolveAction =
  | { link: string }
  | { create_new: true }
  | { dismiss: true }
  | { not_a_transaction: true }
  | { card: { account_code: string } }
  | { supersede: string };

/**
 * resolve_review's "not a card transaction" payload: exactly this object. The
 * server checks `dismiss` first, so adding `dismiss` would only dismiss the
 * review and leave the SMS unmarked. Outcome: `ignored`.
 */
export const NOT_A_TRANSACTION: ResolveAction = { not_a_transaction: true };

/**
 * Friendly text for resolve_review / retry_sms_fallback errors. P0002: the
 * review (or a code in the answer) is gone or belongs to another ledger —
 * usually it was already resolved elsewhere. 22023: the answer doesn't fit the
 * review (e.g. linking to a transaction on another account). Pure, unit-tested.
 */
export function reviewActionError(e: { code?: string; message?: string } | null | undefined): string {
  const code = e?.code;
  const msg = e?.message ?? "";
  if (code === "P0002") {
    return /review .* is not open/i.test(msg)
      ? "This review was already answered, or it's no longer in this ledger. The list has been refreshed."
      : "Something this answer refers to no longer exists in this ledger. The list has been refreshed.";
  }
  if (code === "22023") {
    if (/different account|not on this message's account/i.test(msg)) return "That transaction is on a different card account, so it can't be linked here.";
    if (/already part of a transaction/i.test(msg)) return "This message is already part of a transaction, so it can't be marked as not a card transaction.";
    if (/already has a confirmed/i.test(msg)) return "That transaction already has its own statement line or SMS, so it can't take this one.";
    if (/not an open unparsed_sms review/i.test(msg)) return "Only an open unrecognised-SMS review can be sent to the AI again.";
    if (/no account or amount/i.test(msg)) return "Bank Ledger doesn't know this message's card or amount yet. Add the card first.";
    return "That answer doesn't fit this review. The list has been refreshed.";
  }
  return msg || "Something went wrong.";
}

function useInvalidateAfterReview(profileCode: string) {
  const qc = useQueryClient();
  return () => Promise.all(LEDGER_DOMAINS.map((d) => qc.invalidateQueries({ queryKey: ["p", profileCode, d] })));
}

export function useResolveReview(profileCode: string) {
  const invalidate = useInvalidateAfterReview(profileCode);
  return useMutation({
    mutationFn: async (v: { reviewCode: string; action: ResolveAction }) =>
      must(await supabase.rpc("resolve_review", { p_review_code: v.reviewCode, p_action: v.action as unknown as Json })),
    onSettled: invalidate,
  });
}

/** Ask the LLM fallback to look at an unparsed SMS again; the review is closed and reopens if it still can't parse it. */
export function useRetrySmsFallback(profileCode: string) {
  const invalidate = useInvalidateAfterReview(profileCode);
  return useMutation({
    mutationFn: async (reviewCode: string) => must(await supabase.rpc("retry_sms_fallback", { p_review_code: reviewCode })),
    onSettled: invalidate,
  });
}

export function useDecideTemplate(profileCode: string) {
  const invalidate = useInvalidateAfterReview(profileCode);
  return useMutation({
    mutationFn: async (v: { templateCode: string; active: boolean }) =>
      must(await supabase.rpc("set_sms_template_active", { p_template_code: v.templateCode, p_active: v.active })),
    onSettled: invalidate,
  });
}

import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type Tables, type Views } from "@/lib/supabase";
import type { Json } from "@ledger/db-types";
import { keys, LEDGER_DOMAINS } from "./keys";
import { fetchPage, must, mustList, toApiError, type Page } from "./api";
import { useAuth } from "./auth";
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
    help: "An SMS mentions a card Ledger doesn't know. Tell it which account the card belongs to.",
  },
  unparsed_sms: {
    title: "New SMS formats",
    help: "A bank message didn't match any format. Ledger proposed a template; accept it to parse similar messages.",
  },
  orphaned: {
    title: "Orphaned transactions",
    help: "Their only evidence was removed (for example, a statement was re-parsed). Dismiss once checked.",
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

export function groupReviews(list: Review[]): { reason: string; items: Review[] }[] {
  const map = new Map<string, Review[]>();
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

/** One page of open reviews, newest first, with the exact total. */
export function useOpenReviews(profileCode: string, page: number, size: number) {
  const { session } = useAuth();
  return useQuery({
    queryKey: [...keys.reviews(profileCode), page, size],
    enabled: reviewQueriesEnabled(session, profileCode),
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<Page<Review>> => {
      const { from, to } = pageRange(page, size);
      const head = () =>
        supabase.from("match_reviews").select("review_code", { count: "exact", head: true }).eq("profile_code", profileCode).eq("status", "open");
      return fetchPage<Review>(
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
    },
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
  template_code?: string;
  stmt_code?: string;
  statement_date?: string;
}

export function candidatesOf(r: Pick<Review, "candidates">): ReviewCandidate[] {
  return Array.isArray(r.candidates) ? (r.candidates as unknown as ReviewCandidate[]) : [];
}

export interface ReviewContext {
  line: Tables<"statement_lines"> | null;
  sms: Omit<Tables<"sms_messages">, "body"> | null;
  txn: Views<"v_transactions"> | null;
  statement: Tables<"statements"> | null;
  candidates: Views<"v_transactions">[];
  template: Omit<Tables<"sms_templates">, "examples"> | null;
}

const SMS_META =
  "sms_code, profile_code, client_msg_id, received_at, sender, body_hash, parse_status, ignore_reason, template_code, template_version, bank_code, msg_kind, card_last4, card_code, account_code, amount, currency, merchant_raw, description, available_limit, event_at, parsed_fields, created_at, updated_at";

export function useReviewContext(profileCode: string, review: Review) {
  return useQuery({
    queryKey: keys.reviewContext(profileCode, review.review_code),
    queryFn: async (): Promise<ReviewContext> => {
      const ctx: ReviewContext = { line: null, sms: null, txn: null, statement: null, candidates: [], template: null };
      const cands = candidatesOf(review);
      const jobs: Promise<void>[] = [];
      if (review.subject_type === "statement_line") {
        jobs.push(
          (async () => {
            ctx.line = must(await supabase.from("statement_lines").select("*").eq("line_code", review.subject_code).maybeSingle());
          })(),
        );
      } else if (review.subject_type === "sms") {
        jobs.push(
          (async () => {
            ctx.sms = must(
              await supabase.from("sms_messages").select(SMS_META).eq("sms_code", review.subject_code).maybeSingle(),
            ) as ReviewContext["sms"];
          })(),
        );
      } else if (review.subject_type === "transaction") {
        jobs.push(
          (async () => {
            ctx.txn = must(await supabase.from("v_transactions").select("*").eq("txn_code", review.subject_code).maybeSingle());
          })(),
        );
      } else if (review.subject_type === "statement") {
        jobs.push(
          (async () => {
            ctx.statement = must(await supabase.from("statements").select("*").eq("stmt_code", review.subject_code).maybeSingle());
          })(),
        );
      }
      const txnCodes = cands.map((c) => c.txn_code).filter((c): c is string => !!c);
      if (txnCodes.length) {
        jobs.push(
          (async () => {
            const rows = mustList(await supabase.from("v_transactions").select("*").in("txn_code", txnCodes));
            ctx.candidates = txnCodes.map((c) => rows.find((r) => r.txn_code === c)).filter((r): r is NonNullable<typeof r> => !!r);
          })(),
        );
      }
      const tpl = cands.find((c) => c.template_code)?.template_code;
      if (tpl) {
        jobs.push(
          (async () => {
            ctx.template = must(
              await supabase
                .from("sms_templates")
                .select("template_code, bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, active, version, source, created_at, updated_at")
                .eq("template_code", tpl)
                .maybeSingle(),
            ) as ReviewContext["template"];
          })(),
        );
      }
      await Promise.all(jobs);
      return ctx;
    },
  });
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
    if (/no account or amount/i.test(msg)) return "Ledger doesn't know this message's card or amount yet. Add the card first.";
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

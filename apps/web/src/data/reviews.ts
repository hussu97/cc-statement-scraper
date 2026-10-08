import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type Tables, type Views } from "@/lib/supabase";
import type { Json } from "@ledger/db-types";
import { keys, LEDGER_DOMAINS } from "./keys";
import { must, mustList } from "./api";

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

export function useOpenReviews(profileCode: string) {
  return useQuery({
    queryKey: keys.reviews(profileCode),
    queryFn: async () =>
      mustList(
        await supabase
          .from("match_reviews")
          .select("*")
          .eq("profile_code", profileCode)
          .eq("status", "open")
          .order("created_at", { ascending: false })
          .limit(500),
      ),
  });
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
  | { card: { account_code: string } }
  | { supersede: string };

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

export function useDecideTemplate(profileCode: string) {
  const invalidate = useInvalidateAfterReview(profileCode);
  return useMutation({
    mutationFn: async (v: { templateCode: string; active: boolean }) =>
      must(await supabase.rpc("set_sms_template_active", { p_template_code: v.templateCode, p_active: v.active })),
    onSettled: invalidate,
  });
}

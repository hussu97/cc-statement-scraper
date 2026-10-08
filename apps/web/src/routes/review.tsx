import { useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { Check, ChevronDown, Inbox, Link2, Plus, X } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { REVIEW_REASONS, candidatesOf, groupReviews, useDecideTemplate, useOpenReviews, useResolveReview, useReviewContext, type ResolveAction, type Review } from "@/data/reviews";
import { useAccounts } from "@/data/cards";
import { accountLabel } from "@/data/overview";
import { useSmsBody, type TxnRow } from "@/data/transactions";
import { errorMessage } from "@/data/api";
import { formatDate, formatDateTime, formatRelative } from "@/lib/dates";

import { cn } from "@/lib/cn";
import { Badge, Card, PageHeader, Dot } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Select } from "@/components/ui/select";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { Money, StatusBadge } from "@/components/ledger";

export function ReviewPage() {
  const { profile_code } = useActiveProfile();
  const q = useOpenReviews(profile_code);
  const groups = groupReviews(q.data ?? []);
  return (
    <div>
      <PageHeader
        title="Review"
        description="Things Ledger couldn't decide on its own. Each answer also teaches the matcher for next time."
        actions={q.data ? <span className="tabular text-sm text-muted">{q.data.length} open</span> : null}
      />
      {q.isLoading ? (
        <Card><LoadingRows rows={5} /></Card>
      ) : q.isError ? (
        <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>
      ) : groups.length === 0 ? (
        <Card><EmptyState icon={<Inbox />} title="Nothing to review">Every SMS and statement line found its match.</EmptyState></Card>
      ) : (
        <div className="flex flex-col gap-8">
          {groups.map((g) => (
            <section key={g.reason} aria-labelledby={`r-${g.reason}`}>
              <div className="mb-3">
                <h2 id={`r-${g.reason}`} className="flex items-center gap-2 text-[15px] font-semibold text-ink">
                  {REVIEW_REASONS[g.reason]?.title ?? g.reason}
                  <span className="tabular rounded-pill bg-surface-2 px-2 text-[12px] font-normal text-muted">{g.items.length}</span>
                </h2>
                {REVIEW_REASONS[g.reason] && <p className="mt-1 max-w-2xl text-[13px] text-muted">{REVIEW_REASONS[g.reason]!.help}</p>}
              </div>
              <div className="flex flex-col gap-3">
                {g.items.map((r) => (
                  <ReviewCard key={r.review_code} review={r} />
                ))}
              </div>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}

function ReviewCard({ review }: { review: Review }) {
  const { profile_code, isOwner } = useActiveProfile();
  const ctx = useReviewContext(profile_code, review);
  const resolve = useResolveReview(profile_code);
  const toast = useToast();
  const act = (action: ResolveAction, done: string) =>
    resolve.mutate(
      { reviewCode: review.review_code, action },
      {
        onSuccess: () => toast({ title: done, tone: "positive" }),
        onError: (e) => toast({ title: "Couldn't resolve", description: errorMessage(e), tone: "danger" }),
      },
    );
  const busy = resolve.isPending;

  return (
    <Card className={cn("p-5 transition-opacity", busy && "opacity-60")}>
      <div className="mb-3 flex items-center justify-between gap-3 text-[12px] text-subtle">
        <span>{subjectLabel(review.subject_type)}</span>
        <span>{formatRelative(review.created_at)}</span>
      </div>
      {ctx.isLoading ? (
        <LoadingRows rows={2} className="p-0" />
      ) : ctx.isError || !ctx.data ? (
        <ErrorState error={ctx.error} onRetry={() => void ctx.refetch()} className="py-4" />
      ) : (
        <div className="flex flex-col gap-4">
          {ctx.data.line && (
            <Subject
              title={ctx.data.line.description_raw}
              meta={`${formatDate(ctx.data.line.txn_date)} · ${ctx.data.line.evidence_type === "history_line" ? "history export" : "statement"} line${ctx.data.line.card_last4 ? ` · •${ctx.data.line.card_last4}` : ""}`}
              amount={<Money value={ctx.data.line.amount_aed ?? ctx.data.line.amount_original} direction={ctx.data.line.direction} currency={ctx.data.line.amount_aed !== null ? "AED" : ctx.data.line.currency_original} />}
            />
          )}
          {ctx.data.sms && (
            <SmsSubject sms={ctx.data.sms} />
          )}
          {ctx.data.txn && <TxnSubject t={ctx.data.txn} />}
          {ctx.data.statement && (
            <Subject
              title={`Statement of ${formatDate(ctx.data.statement.statement_date)}`}
              meta={ctx.data.statement.period_start ? `${formatDate(ctx.data.statement.period_start)} – ${formatDate(ctx.data.statement.period_end)}` : undefined}
              amount={<Money value={ctx.data.statement.closing_balance} />}
            />
          )}

          {(review.reason === "ambiguous" || review.reason === "low_score") && (
            <div className="flex flex-col gap-2">
              <p className="text-[12px] font-medium text-ink-2">Possible matches</p>
              {ctx.data.candidates.length === 0 && <p className="text-[13px] text-muted">The candidate transactions no longer exist.</p>}
              {ctx.data.candidates.map((c) => {
                const score = candidatesOf(review).find((x) => x.txn_code === c.txn_code)?.score;
                return (
                  <div key={c.txn_code} className="flex flex-wrap items-center gap-3 rounded-md border border-border bg-bg px-3 py-2">
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-[13px] text-ink">{c.merchant_name ?? c.description}</p>
                      <p className="text-[12px] text-muted">
                        {c.txn_at ? formatDateTime(c.txn_at) : formatDate(c.txn_date)} · {c.bank_code} •{c.card_last4} {score !== undefined && `· match ${Math.round(Number(score))}/100`}
                      </p>
                    </div>
                    <Money value={c.amount_aed} direction={c.direction} className="text-[13px]" />
                    {isOwner && (
                      <Button size="sm" variant="secondary" icon={<Link2 className="size-3.5" />} disabled={busy} onClick={() => act({ link: c.txn_code! }, "Linked")}>
                        Same purchase
                      </Button>
                    )}
                  </div>
                );
              })}
            </div>
          )}

          {review.reason === "unknown_card" && isOwner && <UnknownCardAction review={review} bank={ctx.data.sms?.bank_code ?? candidatesOf(review)[0]?.bank_code} last4={ctx.data.sms?.card_last4 ?? candidatesOf(review)[0]?.last4} onRegister={(account) => act({ card: { account_code: account } }, "Card added")} busy={busy} />}

          {review.reason === "unparsed_sms" && ctx.data.template && <TemplateProposal review={review} template={ctx.data.template} />}

          {isOwner && review.reason !== "unparsed_sms" && (
            <div className="flex flex-wrap justify-end gap-2 border-t border-border pt-3">
              {(review.subject_type === "statement_line" || review.subject_type === "sms") && review.reason !== "unknown_card" && review.reason !== "unparsed_sms" && (
                <Button size="sm" icon={<Plus className="size-3.5" />} disabled={busy} onClick={() => act({ create_new: true }, "Kept as a new transaction")}>
                  It's a separate purchase
                </Button>
              )}
              {review.reason === "period_overlap" &&
                candidatesOf(review)
                  .filter((c) => c.stmt_code)
                  .map((c) => (
                    <Button key={c.stmt_code} size="sm" disabled={busy} onClick={() => act({ supersede: c.stmt_code! }, "Older statement superseded")}>
                      Replace statement of {formatDate(c.statement_date)}
                    </Button>
                  ))}
              {review.reason !== "unparsed_sms" && (
                <Button size="sm" variant="ghost" icon={<X className="size-3.5" />} disabled={busy} onClick={() => act({ dismiss: true }, "Dismissed")}>
                  {review.reason === "orphaned" || review.reason === "missing_from_statement" ? "Mark as checked" : "Dismiss"}
                </Button>
              )}
            </div>
          )}
        </div>
      )}
    </Card>
  );
}

function subjectLabel(t: string): string {
  return { statement_line: "Statement line", sms: "Bank SMS", transaction: "Transaction", statement: "Statement" }[t] ?? t;
}

function Subject({ title, meta, amount, children }: { title: ReactNode; meta?: ReactNode; amount?: ReactNode; children?: ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div className="min-w-0">
        <p className="text-sm font-medium break-words text-ink">{title}</p>
        {meta && <p className="mt-0.5 text-[12px] text-muted">{meta}</p>}
        {children}
      </div>
      {amount && <div className="shrink-0 text-sm">{amount}</div>}
    </div>
  );
}

function SmsSubject({ sms }: { sms: NonNullable<ReturnType<typeof useReviewContext>["data"]>["sms"] }) {
  const { profile_code } = useActiveProfile();
  const [open, setOpen] = useState(false);
  const body = useSmsBody(profile_code, open ? sms!.sms_code : null);
  if (!sms) return null;
  return (
    <Subject
      title={sms.merchant_raw ?? (sms.parse_status === "unparsed" ? "Unrecognised message" : "Card alert")}
      meta={`${sms.sender} · ${formatDateTime(sms.received_at)}${sms.card_last4 ? ` · ${sms.bank_code ?? ""} •${sms.card_last4}` : ""}`}
      amount={sms.amount !== null ? <Money value={sms.amount} currency={sms.currency ?? "AED"} /> : undefined}
    >
      <button type="button" onClick={() => setOpen((o) => !o)} aria-expanded={open} className="mt-1.5 inline-flex items-center gap-1 text-[12px] text-accent hover:underline">
        <ChevronDown className={cn("size-3 transition-transform", open && "rotate-180")} /> {open ? "Hide message" : "Show message"}
      </button>
      {open && <p className="mt-1.5 rounded-sm bg-surface-2 px-2 py-1.5 text-[12px] whitespace-pre-wrap text-ink-2">{body.isLoading ? "Loading…" : body.isError ? "Couldn't load the message." : body.data}</p>}
    </Subject>
  );
}

function TxnSubject({ t }: { t: TxnRow }) {
  return (
    <Subject
      title={<Link to="/activity" search={{ txn: t.txn_code ?? undefined }} className="hover:text-accent">{t.merchant_name ?? t.description}</Link>}
      meta={
        <span className="inline-flex flex-wrap items-center gap-2">
          {t.txn_at ? formatDateTime(t.txn_at) : formatDate(t.txn_date)} · {t.bank_code} •{t.card_last4}
          {t.category_name && <span className="inline-flex items-center gap-1"><Dot token={t.category_color} />{t.category_name}</span>}
          <StatusBadge status={t.status} />
        </span>
      }
      amount={<Money value={t.amount_aed} direction={t.direction} />}
    />
  );
}

function UnknownCardAction({ review, bank, last4, onRegister, busy }: { review: Review; bank: string | null | undefined; last4: string | null | undefined; onRegister: (account: string) => void; busy: boolean }) {
  const { profile_code } = useActiveProfile();
  const accounts = useAccounts(profile_code);
  const options = (accounts.data ?? []).filter((a) => !bank || a.bank_code === bank);
  const [account, setAccount] = useState<string | undefined>(undefined);
  return (
    <div className="flex flex-col gap-2 rounded-md border border-border bg-bg p-3">
      <p className="text-[13px] text-ink">
        Which account does <span className="tabular font-medium">{bank} •{last4 ?? "????"}</span> belong to?
      </p>
      {accounts.isLoading ? (
        <p className="text-[12px] text-muted">Loading accounts…</p>
      ) : options.length === 0 ? (
        <p className="text-[12px] text-muted">No {bank} account exists yet. Upload a {bank} statement first, then come back.</p>
      ) : (
        <div className="flex flex-wrap items-center gap-2">
          <Select
            key={review.review_code}
            size="sm"
            ariaLabel="Account"
            placeholder="Choose an account"
            value={account}
            onValueChange={setAccount}
            options={options.map((a) => ({ value: a.account_code, label: `${accountLabel(a)} (${(a.cards ?? []).map((c) => `•${c.last4}`).join(" ")})` }))}
            className="min-w-56"
          />
          <Button size="sm" variant="primary" disabled={!account || busy} onClick={() => account && onRegister(account)}>
            Add card as supplementary
          </Button>
        </div>
      )}
    </div>
  );
}

function TemplateProposal({ review, template }: { review: Review; template: NonNullable<NonNullable<ReturnType<typeof useReviewContext>["data"]>["template"]> }) {
  const { profile_code, isOwner } = useActiveProfile();
  const decide = useDecideTemplate(profile_code);
  const toast = useToast();
  const groups = Object.entries((template.field_groups ?? {}) as Record<string, number>);
  return (
    <div className="flex flex-col gap-3 rounded-md border border-border bg-bg p-3" data-review={review.review_code}>
      <div className="flex flex-wrap items-center gap-2">
        <p className="text-[13px] font-medium text-ink">Proposed format: {template.name}</p>
        <Badge tone="info">{template.bank_code}</Badge>
        <Badge>{template.msg_kind}</Badge>
        {template.source === "llm" && <Badge tone="accent">suggested by AI</Badge>}
      </div>
      <pre className="overflow-x-auto rounded-sm bg-surface-2 px-2 py-1.5 font-mono text-[11.5px] whitespace-pre-wrap text-ink-2">{template.body_pattern}</pre>
      {groups.length > 0 && (
        <p className="text-[12px] text-muted">
          Reads {groups.map(([k, g]) => `${k} (group ${g})`).join(", ")}
          {template.date_format ? ` · dates as ${template.date_format}` : ""}
        </p>
      )}
      {isOwner && (
        <div className="flex flex-wrap justify-end gap-2">
          <Button
            size="sm"
            variant="ghost"
            disabled={decide.isPending}
            onClick={() =>
              decide.mutate(
                { templateCode: template.template_code, active: false },
                { onSuccess: () => toast({ title: "Format rejected" }), onError: (e) => toast({ title: "Couldn't reject", description: errorMessage(e), tone: "danger" }) },
              )
            }
          >
            Reject
          </Button>
          <Button
            size="sm"
            variant="primary"
            icon={<Check className="size-3.5" />}
            loading={decide.isPending}
            onClick={() =>
              decide.mutate(
                { templateCode: template.template_code, active: true },
                {
                  onSuccess: () => toast({ title: "Format accepted", description: "Waiting messages are being parsed again.", tone: "positive" }),
                  onError: (e) => toast({ title: "Couldn't accept", description: errorMessage(e), tone: "danger" }),
                },
              )
            }
          >
            Accept format
          </Button>
        </div>
      )}
    </div>
  );
}


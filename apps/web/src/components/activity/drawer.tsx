import { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { ArrowLeftRight, ChevronDown, FileText, Lock, MessageSquareText } from "lucide-react";
import {
  EVIDENCE_LABEL,
  METHOD_LABEL,
  elsewhereLedger,
  ROLE_LABEL,
  evidenceBadge,
  evidenceTime,
  useEvidence,
  useRelatedTransactions,
  useSetCategory,
  useSmsBody,
  useTransaction,
  useTransactionLedger,
  useUpdateTransaction,
  type EvidenceItem,
  type TxnRow,
} from "@/data/transactions";
import { useActiveProfile, useProfileContext } from "@/data/profile";
import type { FilterMeta } from "@/data/overview";
import { errorMessage } from "@/data/api";
import { formatDate, formatDateTime } from "@/lib/dates";
import { displayAmount, formatMoney, formatRate } from "@/lib/money";
import { cn } from "@/lib/cn";
import { transferPeer } from "@/lib/transfers";
import { Sheet } from "@/components/ui/dialog";
import { Textarea } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/primitives";
import { Badge } from "@/components/ui/display";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { CategoryPicker, EvidenceBadge, Money, StatusBadge, TxnAmount } from "@/components/ledger";
import { CardRef } from "@/components/bank-logo";

const SOURCE_LABEL: Record<string, string> = {
  manual: "Your choice",
  merchant: "Applies to merchant",
  rule: "Rule",
  suggested: "Suggested",
};

export function TransactionDrawer({ txnCode, onClose, meta }: { txnCode: string | undefined; onClose: () => void; meta: FilterMeta | undefined }) {
  const { profile_code } = useActiveProfile();
  const q = useTransaction(profile_code, txnCode ?? null);
  const t = q.data;
  // The drawer is URL-driven, so Radix never saw a trigger: remember which row
  // opened it and hand focus back to that row on close (WEB-19).
  const lastCode = useRef(txnCode);
  useEffect(() => {
    if (txnCode) lastCode.current = txnCode;
  }, [txnCode]);
  return (
    <Sheet
      open={!!txnCode}
      onOpenChange={(o) => !o && onClose()}
      onCloseAutoFocus={(e) => {
        const opener = lastCode.current ? document.querySelector<HTMLElement>(`[data-txn-open="${CSS.escape(lastCode.current)}"]`) : null;
        if (opener) {
          e.preventDefault();
          opener.focus({ preventScroll: false });
        }
      }}
      title={t ? (t.merchant_name ?? t.description ?? "Transaction") : "Transaction"}
      description={t ? t.description ?? undefined : undefined}
    >
      {q.isLoading ? (
        <LoadingRows rows={4} className="p-0" />
      ) : q.isError ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : !t ? (
        <NotInLedger txnCode={txnCode ?? null} />
      ) : (
        <DrawerBody key={t.txn_code} t={t} meta={meta} />
      )}
    </Sheet>
  );
}

/** A txn= outside the active ledger: name its ledger and offer to switch (WEB-46). */
function NotInLedger({ txnCode }: { txnCode: string | null }) {
  const { profile, profiles, setActive } = useProfileContext();
  const active = profile?.profile_code ?? "";
  const q = useTransactionLedger(active, txnCode, true);
  const navigate = useNavigate();
  if (q.isLoading) return <LoadingRows rows={2} className="p-0" />;
  if (q.isError) return <ErrorState error={q.error} onRetry={() => void q.refetch()} />;
  const other = elsewhereLedger(q.data, active, profiles);
  if (!other) return <ErrorState title="Transaction not found" error={new Error("It isn't in this ledger, or it was removed.")} />;
  return (
    <EmptyState
      icon={<ArrowLeftRight />}
      title="This transaction belongs to another ledger"
      action={
        <Button
          variant="primary"
          size="sm"
          onClick={() => {
            setActive(other.profile_code);
            // The old ledger's filters (and a statement page) don't apply there.
            void navigate({ to: "/activity", search: { txn: txnCode ?? undefined } });
          }}
        >
          Switch to {other.name}
        </Button>
      }
    >
      It's in {other.name}. Switch ledgers to see it.
    </EmptyState>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-[96px_minmax(0,1fr)] gap-3 py-2 text-[13px] sm:grid-cols-[120px_minmax(0,1fr)]">
      <dt className="text-subtle">{label}</dt>
      <dd className="min-w-0 text-ink">{children}</dd>
    </div>
  );
}

function DrawerBody({ t, meta }: { t: TxnRow; meta: FilterMeta | undefined }) {
  const { profile_code, isOwner } = useActiveProfile();
  const toast = useToast();
  const setCat = useSetCategory(profile_code);
  const update = useUpdateTransaction(profile_code);
  const [notes, setNotes] = useState(t.notes ?? "");
  const fx = t.currency_original && t.currency_original !== "AED";
  const amount = displayAmount(t);

  return (
    <div className="flex flex-col gap-6">
      <div>
        <Money value={amount.value} currency={amount.currency} direction={t.direction} className="display-num text-[32px] leading-none sm:text-[36px]" />
        {amount.original && <p className="tabular mt-1.5 text-[13px] text-muted">{formatMoney(amount.original.value, { currency: amount.original.currency })}</p>}
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <StatusBadge status={t.status} />
          {t.status === "posted" && <Badge>posted</Badge>}
          <Badge tone="neutral">{t.kind}</Badge>
          <EvidenceBadge kind={evidenceBadge(t)} />
          {amount.awaitingFx && <Badge tone="warn">Awaiting FX rate</Badge>}
          {t.amount_aed_is_estimate && <Badge tone="warn">AED estimated</Badge>}
          {t.exclude_from_spend && <Badge tone="info">excluded from spend</Badge>}
        </div>
      </div>

      <dl className="divide-y divide-border border-y border-border">
        <Row label="Date">{t.txn_at ? formatDateTime(t.txn_at) : formatDate(t.txn_date)}</Row>
        {t.posting_date && <Row label="Posted">{formatDate(t.posting_date)}</Row>}
        <Row label="Card">
          <span className="inline-flex flex-wrap items-center gap-x-1.5">
            <CardRef bankCode={t.bank_code} last4={t.card_last4} size="sm" />
            {t.account_nickname && <span className="text-muted">· {t.account_nickname}</span>}
          </span>
        </Row>
        <Row label="Category">
          <div className="-ml-2 flex flex-wrap items-center gap-2">
            <CategoryPicker
              categories={meta?.categories ?? []}
              value={t.category_code}
              label={t.category_name}
              colorToken={t.category_color}
              source={t.category_source}
              disabled={!isOwner || setCat.isPending}
              allowApplyToMerchant={!!t.merchant_code}
              onSelect={(code, toMerchant) =>
                setCat.mutate(
                  { txnCode: t.txn_code!, categoryCode: code, applyToMerchant: toMerchant },
                  {
                    onSuccess: () => toast({ title: toMerchant ? "Category applied to merchant" : "Category updated", tone: "positive" }),
                    onError: (e) => toast({ title: "Couldn't change the category", description: errorMessage(e), tone: "danger" }),
                  },
                )
              }
            />
            {t.category_source && <span className="text-[11px] text-subtle">{SOURCE_LABEL[t.category_source] ?? t.category_source}</span>}
          </div>
        </Row>
        {fx && (
          <Row label="Foreign amount">
            <span className="tabular">{formatMoney(t.amount_original, { currency: t.currency_original ?? "AED" })}</span>
            {t.fx_rate && <span className="tabular ml-2 text-subtle">@ {formatRate(t.fx_rate)}</span>}
          </Row>
        )}
        {t.auth_amount !== null && t.auth_amount !== undefined && (
          <Row label="Authorised">
            <span className="tabular">{formatMoney(t.auth_amount, { currency: t.currency_original ?? "AED" })}</span>
            <span className="ml-2 text-subtle">at the time of the SMS</span>
          </Row>
        )}
      </dl>

      <CardTransfer t={t} />
      <RelatedReversal t={t} />

      <section className="flex flex-col gap-3">
        <div className="flex items-center justify-between gap-3">
          <label htmlFor="exclude" className="text-[13px] text-ink">
            Exclude from spending
            <span className="block text-[12px] text-subtle">For transfers or reimbursed purchases.</span>
          </label>
          <Switch
            id="exclude"
            checked={!!t.exclude_from_spend}
            disabled={!isOwner || update.isPending}
            onCheckedChange={(v) =>
              update.mutate(
                { txnCode: t.txn_code!, patch: { exclude_from_spend: v } },
                { onError: (e) => toast({ title: "Couldn't update", description: errorMessage(e), tone: "danger" }) },
              )
            }
          />
        </div>
        <div className="flex flex-col gap-1.5">
          <label htmlFor="notes" className="text-[13px] text-ink">Notes</label>
          <Textarea id="notes" value={notes} disabled={!isOwner} onChange={(e) => setNotes(e.target.value)} placeholder="Add a note for yourself" maxLength={1000} />
          {isOwner && notes !== (t.notes ?? "") && (
            <div className="flex justify-end gap-2">
              <Button size="sm" variant="ghost" onClick={() => setNotes(t.notes ?? "")}>Cancel</Button>
              <Button
                size="sm"
                variant="primary"
                loading={update.isPending}
                onClick={() =>
                  update.mutate(
                    { txnCode: t.txn_code!, patch: { notes: notes.trim() || null } },
                    {
                      onSuccess: () => toast({ title: "Note saved", tone: "positive" }),
                      onError: (e) => toast({ title: "Couldn't save the note", description: errorMessage(e), tone: "danger" }),
                    },
                  )
                }
              >
                Save note
              </Button>
            </div>
          )}
        </div>
      </section>

      <EvidenceTimeline txnCode={t.txn_code!} />
    </div>
  );
}

/** The other card of a card transfer (public.card_transfers), linked to its row. */
function CardTransfer({ t }: { t: TxnRow }) {
  const peer = transferPeer(t);
  if (!peer) return null;
  return (
    <section className="rounded-md border border-border bg-bg p-3">
      <p className="mb-2 flex items-center gap-1.5 text-[12px] font-medium text-ink-2">
        <ArrowLeftRight className="size-3.5" /> Card transfer
      </p>
      <Link to="/activity" replace search={(s) => ({ ...s, txn: peer.txnCode })} className="flex items-center gap-1.5 text-[13px] hover:text-accent">
        {peer.prefix} <CardRef bankCode={peer.bankCode} last4={peer.last4} size="sm" />
      </Link>
    </section>
  );
}

function RelatedReversal({ t }: { t: TxnRow }) {
  const { profile_code } = useActiveProfile();
  const q = useRelatedTransactions(profile_code, t);
  const related = (q.data ?? []).filter((r) => r.txn_code !== t.txn_code);
  if (!related.length) return null;
  return (
    <section className="rounded-md border border-border bg-bg p-3">
      <p className="mb-2 flex items-center gap-1.5 text-[12px] font-medium text-ink-2">
        <ArrowLeftRight className="size-3.5" /> {t.related_txn_code ? "Reverses" : "Reversed by"}
      </p>
      {related.map((r) => (
        <Link key={r.txn_code} to="/activity" replace search={(s) => ({ ...s, txn: r.txn_code ?? undefined })} className="flex items-center justify-between gap-3 text-[13px] hover:text-accent">
          <span className="min-w-0 truncate">{r.merchant_name ?? r.description} · {formatDate(r.txn_date, "short")}</span>
          <TxnAmount t={r} showOriginal={false} />
        </Link>
      ))}
    </section>
  );
}

function EvidenceTimeline({ txnCode }: { txnCode: string }) {
  const { profile_code } = useActiveProfile();
  const q = useEvidence(profile_code, txnCode);
  return (
    <section aria-labelledby="evidence-title">
      <h3 id="evidence-title" className="mb-3 text-[13px] font-semibold text-ink">Evidence</h3>
      {q.isLoading ? (
        <LoadingRows rows={2} className="p-0" />
      ) : q.isError ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : (q.data ?? []).length === 0 ? (
        <p className="text-[13px] text-muted">No evidence is attached. This transaction is orphaned and will show in Review.</p>
      ) : (
        <ol className="relative flex flex-col gap-4 border-l border-border pl-5">
          {q.data!.map((e) => (
            <EvidenceEntry key={e.evidence_code} e={e} />
          ))}
        </ol>
      )}
    </section>
  );
}

function EvidenceEntry({ e }: { e: EvidenceItem }) {
  const isSms = e.evidence_type === "sms";
  return (
    <li className={cn("relative", !e.is_active && "opacity-55")}>
      <span className="absolute top-0.5 -left-[29px] flex size-[17px] items-center justify-center rounded-pill border border-border bg-surface text-subtle">
        {isSms ? <MessageSquareText className="size-2.5" /> : <FileText className="size-2.5" />}
      </span>
      <p className="flex flex-wrap items-center gap-x-2 text-[13px] text-ink">
        <span className="font-medium">{EVIDENCE_LABEL[e.evidence_type]}</span>
        <span className="text-subtle">{ROLE_LABEL[e.role] ?? e.role}</span>
        {e.is_locked && <Lock className="size-3 text-subtle" aria-label="Locked by review" />}
        {!e.is_active && <Badge>detached</Badge>}
      </p>
      <p className="mt-0.5 text-[12px] text-muted">
        {isSms ? formatDateTime(evidenceTime(e)) : formatDate(evidenceTime(e))}
        {" · "}
        {METHOD_LABEL[e.method] ?? e.method}
        {e.score !== null && e.method !== "new" ? ` (${Math.round(Number(e.score))})` : ""}
      </p>
      {e.sms_messages && <SmsEvidence sms={e.sms_messages} />}
      {e.statement_lines && (
        <div className="mt-2 rounded-md border border-border bg-bg px-3 py-2 text-[12px]">
          <p className="font-mono text-[11.5px] text-ink-2 [overflow-wrap:anywhere]">{e.statement_lines.description_raw}</p>
          <p className="tabular mt-1 text-muted">
            {formatMoney(e.statement_lines.amount_original, { currency: e.statement_lines.currency_original })}
            {e.statement_lines.currency_original !== "AED" && e.statement_lines.amount_aed !== null && ` → ${formatMoney(e.statement_lines.amount_aed)}`}
            {e.statement_lines.statements && (
              <>
                {" · "}
                <Link to="/statements/$stmtCode" params={{ stmtCode: e.statement_lines.stmt_code }} className="text-accent hover:underline">
                  {e.statement_lines.statements.kind === "statement" ? "statement" : "history export"} of {formatDate(e.statement_lines.statements.statement_date)}
                </Link>
              </>
            )}
          </p>
        </div>
      )}
    </li>
  );
}

function SmsEvidence({ sms }: { sms: NonNullable<EvidenceItem["sms_messages"]> }) {
  const { profile_code } = useActiveProfile();
  const [open, setOpen] = useState(false);
  const body = useSmsBody(profile_code, open ? sms.sms_code : null);
  return (
    <div className="mt-2 rounded-md border border-border bg-bg px-3 py-2 text-[12px]">
      <p className="text-muted">
        From <span className="text-ink-2">{sms.sender}</span> · received {formatDateTime(sms.received_at)}
      </p>
      {sms.amount !== null && (
        <p className="tabular mt-0.5 text-muted">
          {formatMoney(sms.amount, { currency: sms.currency ?? "AED" })} {sms.msg_kind && `· ${sms.msg_kind}`} {sms.card_last4 && `· •${sms.card_last4}`}
        </p>
      )}
      <button type="button" onClick={() => setOpen((o) => !o)} aria-expanded={open} className="tap mt-1.5 inline-flex items-center gap-1 text-accent hover:underline">
        <ChevronDown className={cn("size-3 transition-transform", open && "rotate-180")} /> {open ? "Hide message" : "Show message"}
      </button>
      {open && (
        <p className="mt-1.5 rounded-sm bg-surface-2 px-2 py-1.5 whitespace-pre-wrap text-ink-2">
          {body.isLoading ? "Loading…" : body.isError ? "Couldn't load the message." : body.data}
        </p>
      )}
    </div>
  );
}

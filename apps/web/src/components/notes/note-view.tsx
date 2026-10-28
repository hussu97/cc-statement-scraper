import { useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronLeft, MoreHorizontal, RefreshCw, ScrollText, Trash2 } from "lucide-react";
import { useCancelNote, useNoteDetail, useRefreshNotePrices, type NoteDetail } from "@/data/notes";
import { errorMessage } from "@/data/api";
import { calledNext, isEnded, noteStatus, pct } from "@/lib/notes";
import { couponLine, gapText, nextCheckLine, verdictDate, verdictLine, VERDICT_TEXT } from "@/lib/note-verdict";
import { annualisedText, creditVerdict, isCreditLinked } from "@/lib/credit-notes";
import { signTone } from "@/lib/holdings";
import { formatDate } from "@/lib/dates";
import { formatMoney, formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Menu, MenuContent, MenuItem, MenuTrigger } from "@/components/ui/primitives";
import { ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { FormError } from "@/components/cash/bank-account-dialogs";
import { StockBars } from "./stock-bars";
import { PriceHistorySection, ScenariosSection, ScheduleSection, TermsSection } from "./note-sections";
import { CallDatesSection, CouponScheduleSection, ReferenceEntityCard } from "./credit-sections";

const TONE_TEXT = { positive: "text-positive", danger: "text-danger", neutral: "text-ink" } as const;

/**
 * One structured note (Wealth → Investments), answering one question first: will it be called,
 * and what does it need? Then its stocks, its money, and the detail collapsed below. A
 * credit-linked note answers what it pays instead, and its reference entity takes the stocks' place.
 */
export function NoteView({ profileCode, holdingCode, isOwner }: { profileCode: string; holdingCode: string; isOwner: boolean }) {
  const q = useNoteDetail(profileCode, holdingCode);
  const [cancelling, setCancelling] = useState(false);
  const n = q.data;

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <div>
        <Link to="/wealth/investments" className="tap -ml-1 inline-flex items-center gap-1 text-[13px] text-muted hover:text-accent">
          <ChevronLeft className="size-3.5" /> Investments
        </Link>
        <header className="mt-3 flex items-start justify-between gap-3">
          <div className="min-w-0">
            <h1 className="font-display text-[24px] leading-tight text-ink md:text-[30px]">{n ? n.name : <Skeleton className="h-8 w-64" />}</h1>
            {n && (
              <p className="mt-1 flex flex-wrap items-center gap-2 text-[13px] text-muted">
                <Badge tone={noteStatus(n.status).tone}>{noteStatus(n.status).label}</Badge>
                <span className="min-w-0 [overflow-wrap:anywhere]">{[n.issuer, n.isin].filter(Boolean).join(" · ")}</span>
              </p>
            )}
          </div>
          {n && isOwner && <NoteActions profileCode={profileCode} n={n} onRemove={() => setCancelling(true)} />}
        </header>
      </div>

      {q.isLoading ? (
        <Card>
          <LoadingRows rows={3} />
        </Card>
      ) : q.isError || !n ? (
        <Card>
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        </Card>
      ) : (
        <>
          <Verdict n={n} />
          {isCreditLinked(n) ? (
            <ReferenceEntityCard n={n} />
          ) : (
            !isEnded(n.status) &&
            n.underlyings.some((u) => u.close !== null) && (
              <Card>
                <CardHeader title="The stocks" />
                <StockBars shares={n.underlyings} className="max-w-3xl px-5 pb-4" />
              </Card>
            )
          )}
          <MoneyCard n={n} />
          {isCreditLinked(n) ? (
            <div className="flex flex-col gap-3">
              <CouponScheduleSection n={n} />
              <CallDatesSection n={n} />
              <TermsSection profileCode={profileCode} n={n} />
            </div>
          ) : (
            <div className="flex flex-col gap-3">
              {n.scenarios && !isEnded(n.status) && <ScenariosSection n={n} />}
              <ScheduleSection n={n} />
              <PriceHistorySection n={n} />
              <TermsSection profileCode={profileCode} n={n} />
            </div>
          )}
          {isOwner && <CancelDialog profileCode={profileCode} n={cancelling ? n : null} onClose={() => setCancelling(false)} />}
        </>
      )}
    </div>
  );
}

/** Update prices and Remove note, out of the way in a "…" menu. */
function NoteActions({ profileCode, n, onRemove }: { profileCode: string; n: NoteDetail; onRemove: () => void }) {
  const refresh = useRefreshNotePrices(profileCode);
  const toast = useToast();
  const canRefresh = !isEnded(n.status);
  const canRemove = n.status !== "cancelled";
  if (!canRefresh && !canRemove) return null;
  return (
    <Menu>
      <MenuTrigger asChild>
        <Button size="icon-sm" variant="ghost" aria-label="Note actions" loading={refresh.isPending}>
          <MoreHorizontal className="size-4" />
        </Button>
      </MenuTrigger>
      <MenuContent>
        {canRefresh && (
          <MenuItem
            onSelect={() =>
              refresh.mutate(undefined, {
                onSuccess: (r) => toast({ title: "Prices updated", description: r.failed.length ? `No prices for: ${r.failed.join(", ")}` : `${r.stored} closes stored.`, tone: r.failed.length ? "neutral" : "positive" }),
                onError: (e) => toast({ title: "Couldn't update prices", description: errorMessage(e), tone: "danger" }),
              })
            }
          >
            <RefreshCw className="size-3.5" /> Update prices
          </MenuItem>
        )}
        {canRemove && (
          <MenuItem tone="danger" onSelect={onRemove}>
            <Trash2 className="size-3.5" /> Remove note…
          </MenuItem>
        )}
      </MenuContent>
    </Menu>
  );
}

/** The verdict in big words, and when the next check is and what it takes. */
function Verdict({ n }: { n: NoteDetail }) {
  const money = (v: string) => formatMoney(v, { currency: n.currency });
  if (isEnded(n.status)) {
    return (
      <Card className="px-5 py-4">
        <p className="text-[20px] leading-snug font-medium text-ink md:text-[22px]">
          {noteStatus(n.status).label}
          {n.ended_on ? ` on ${formatDate(n.ended_on)}` : ""}
        </p>
      </Card>
    );
  }
  const credit = isCreditLinked(n) ? creditVerdict(n.verdict, n.credit, n.currency) : null;
  if (credit) {
    return (
      <Card className="px-5 py-4">
        <p className={cn("text-[20px] leading-snug font-medium md:text-[22px]", VERDICT_TEXT[credit.headline.tone])}>{credit.headline.text}</p>
        {credit.lines.map((l, i) => (
          <p key={l} className={cn("text-[13px] text-ink-2", i === 0 ? "mt-1.5" : "mt-0.5")}>
            {l}
          </p>
        ))}
      </Card>
    );
  }
  // A credit-linked note's verdict this build doesn't know: no share-check line (it has no shares).
  if (isCreditLinked(n)) return null;
  const line = verdictLine(n.verdict);
  const coupon = n.verdict?.kind === "coupon_at_risk" ? couponLine(n.next, money) : null;
  // With the coupon at stake spelled out, the check line only says when.
  const next = nextCheckLine(n.next, !coupon);
  if (!line && !next) return null;
  return (
    <Card className="px-5 py-4">
      {line && <p className={cn("text-[20px] leading-snug font-medium md:text-[22px]", VERDICT_TEXT[line.tone])}>{line.text}</p>}
      {next && <p className="mt-1.5 text-[13px] text-ink-2">{next}</p>}
      {coupon && <p className="mt-0.5 text-[13px] text-ink-2">{coupon}</p>}
      {n.verdict?.kind === "coupon_at_risk" && n.verdict.call_date && n.verdict.call_gap_pct && (
        <p className="mt-0.5 text-[13px] text-muted">
          To be called on {verdictDate(n.verdict.call_date)}: {Number(n.verdict.call_gap_pct) > 0 ? `${n.verdict.symbol ?? "the lowest stock"} needs +${gapText(n.verdict.call_gap_pct)}` : "every stock is there already"}.
        </p>
      )}
    </Card>
  );
}

function Figure({ label, children, sub }: { label: string; children: ReactNode; sub?: ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-[12px] text-subtle">{label}</dt>
      <dd className="tabular mt-0.5 text-[20px] leading-tight font-medium text-ink">{children}</dd>
      {sub && <dd className="tabular mt-0.5 text-[12px]">{sub}</dd>}
    </div>
  );
}

/**
 * The money in three numbers: paid, worth today, if called (live); paid, got back, profit (ended).
 * A live credit-linked note shows held to maturity instead of if called.
 */
function MoneyCard({ n }: { n: NoteDetail }) {
  const c = n.currency;
  const t = (v: string | null | undefined, signed = false) => formatTotal(v, { currency: c, signed });
  const called = calledNext(n.if_called_next);
  const r = n.result;
  const credit = isCreditLinked(n) ? n.credit : null;
  return (
    <Card className="px-5 py-4">
      <dl className="grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-3">
        <Figure label="Paid" sub={<span className="text-muted">{formatDate(n.trade_date)}</span>}>
          {t(n.invested)}
        </Figure>
        {isEnded(n.status) ? (
          <>
            <Figure label="Got back">{r ? t(r.total) : t(n.received.total)}</Figure>
            {r && (
              <Figure label="Profit" sub={<span className="text-muted">{pct(r.return_pct, 1)} return</span>}>
                <span className={TONE_TEXT[signTone(r.profit)]}>{t(r.profit, true)}</span>
              </Figure>
            )}
          </>
        ) : credit ? (
          <>
            <Figure
              label="Worth today"
              sub={n.market ? <span className={TONE_TEXT[signTone(n.market.profit)]}>{t(n.market.profit, true)} if sold today</span> : <span className="text-muted">No broker price yet</span>}
            >
              {n.market ? t(n.market.value) : "—"}
            </Figure>
            {credit.to_maturity && (
              <Figure
                label="Held to maturity"
                sub={
                  <>
                    <span className={TONE_TEXT[signTone(credit.to_maturity.profit)]}>{t(credit.to_maturity.profit, true)}</span>
                    {annualisedText(credit.to_maturity.annualised_pct) && <span className="text-muted"> · {annualisedText(credit.to_maturity.annualised_pct)}</span>}
                  </>
                }
              >
                {t(credit.to_maturity.total)}
              </Figure>
            )}
          </>
        ) : (
          <>
            <Figure label="Worth today" sub={n.market ? <span className={TONE_TEXT[signTone(n.market.profit)]}>{t(n.market.profit, true)}</span> : undefined}>
              {n.market ? t(n.market.value) : "—"}
            </Figure>
            {called && (
              <Figure
                label={`If called on ${verdictDate(called.obsDate)}`}
                sub={
                  <>
                    <span className={TONE_TEXT[signTone(called.profit)]}>{t(called.profit, true)}</span>
                    {called.annualisedPct && <span className="text-muted"> · {pct(called.annualisedPct, 0)} a year</span>}
                  </>
                }
              >
                {t(called.total)}
              </Figure>
            )}
          </>
        )}
      </dl>
      {Number(n.received.total) > 0 && !isEnded(n.status) && <p className="mt-3 text-[12px] text-muted">Coupons received so far: {formatMoney(n.received.coupons, { currency: c })}</p>}
    </Card>
  );
}

function CancelDialog({ profileCode, n, onClose }: { profileCode: string; n: NoteDetail | null; onClose: () => void }) {
  const cancel = useCancelNote(profileCode);
  const toast = useToast();
  return (
    <Dialog open={!!n} onOpenChange={(o) => !o && onClose()} title="Remove this note?" description="For a note added by mistake. Its purchase, coupons and redemptions leave the account's ledger; the terms are kept.">
      {n && (
        <div className="flex flex-col gap-4">
          <p className="flex items-center gap-2 text-sm text-ink-2">
            <ScrollText className="size-4" /> {n.name}
          </p>
          <FormError error={cancel.isError ? errorMessage(cancel.error) : null} />
          <div className="flex justify-end gap-2">
            <Button onClick={onClose}>Keep it</Button>
            <Button
              variant="danger"
              loading={cancel.isPending}
              onClick={() =>
                cancel.mutate(n.holding_code, {
                  onSuccess: () => {
                    toast({ title: "Note removed", description: n.name, tone: "positive" });
                    onClose();
                  },
                })
              }
            >
              Remove
            </Button>
          </div>
        </div>
      )}
    </Dialog>
  );
}

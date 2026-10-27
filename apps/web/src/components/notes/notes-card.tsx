import { Link } from "@tanstack/react-router";
import { ChevronRight, Plus, ScrollText } from "lucide-react";
import { useNotesSummary, type NoteSummary } from "@/data/notes";
import { isEnded, noteStatus, pct } from "@/lib/notes";
import { formatDate } from "@/lib/dates";
import { formatMoney } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";

/**
 * Structured notes: live first, then ended. On Investments every note; on an account page
 * (`fundingAccount`) only the notes paid from it.
 */
export function NotesCard({
  profileCode,
  isOwner,
  onAdd,
  fundingAccount,
  hideWhenEmpty,
}: {
  profileCode: string;
  isOwner: boolean;
  onAdd: () => void;
  fundingAccount?: string;
  /** On an account page: render nothing until a note is paid from it. */
  hideWhenEmpty?: boolean;
}) {
  const q = useNotesSummary(profileCode);
  const notes = (q.data ?? []).filter((n) => !fundingAccount || n.funding_account_code === fundingAccount);
  const live = notes.filter((n) => !isEnded(n.status));
  const ended = notes.filter((n) => isEnded(n.status));
  if (fundingAccount && q.data && notes.length === 0 && (!isOwner || hideWhenEmpty)) return null;

  return (
    <Card>
      <CardHeader
        eyebrow={fundingAccount ? "Invested from this account" : "Autocallables and other notes"}
        title="Structured notes"
        action={
          isOwner && (
            <Button size="sm" icon={<Plus className="size-3.5" />} onClick={onAdd}>
              <span className="sm:hidden">Add</span>
              <span className="hidden sm:inline">Add from term sheet</span>
            </Button>
          )
        }
      />
      {q.isLoading ? (
        <LoadingRows rows={2} />
      ) : q.isError ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : notes.length === 0 ? (
        <EmptyState icon={<ScrollText />} title="No notes yet">
          {isOwner
            ? "Upload a note's term sheet: Bank Ledger reads its coupons, autocalls and payout, follows the shares every day and shows how close each barrier is."
            : "The ledger's owner can add structured notes here."}
        </EmptyState>
      ) : (
        <div className="border-t border-border">
          {live.length > 0 && <NoteRows notes={live} />}
          {ended.length > 0 && (
            <section aria-labelledby="notes-ended">
              <h3 id="notes-ended" className="border-y border-border bg-surface-2/50 px-5 py-1.5 text-[11px] font-medium tracking-[0.06em] text-subtle uppercase">
                Ended
              </h3>
              <NoteRows notes={ended} />
            </section>
          )}
        </div>
      )}
    </Card>
  );
}

function NoteRows({ notes }: { notes: NoteSummary[] }) {
  return (
    <ul className="divide-y divide-border">
      {notes.map((n) => (
        <li key={n.note_code}>
          <NoteRow n={n} />
        </li>
      ))}
    </ul>
  );
}

function NoteRow({ n }: { n: NoteSummary }) {
  const status = noteStatus(n.status);
  const ended = isEnded(n.status);
  const coupon = n.next?.coupon;
  const call = n.next?.autocall;
  return (
    <Link
      to="/wealth/investments/$holdingCode"
      params={{ holdingCode: n.holding_code }}
      className="tap group flex items-center gap-3 px-5 py-3 hover:bg-surface-2/60 focus-visible:bg-surface-2/60"
    >
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="truncate text-sm font-medium text-ink">{n.name}</span>
          <Badge tone={status.tone}>{status.label}</Badge>
          {n.awaiting_prices && <Badge tone="warn">Awaiting prices</Badge>}
        </div>
        <p className="mt-0.5 text-[12px] text-muted">
          {n.symbols.join(" · ")}
          {!ended && n.worst_now && (
            <>
              {" · "}worst <span className="font-medium text-ink-2">{n.worst_now.symbol}</span> at {pct(n.worst_now.pct, 2)}
            </>
          )}
          {!ended && n.next && (
            <>
              {" · "}next {formatDate(n.next.obs_date, "short")}
              {call && <span className={cn(call.would_call ? "text-positive" : undefined)}>{call.would_call ? " (would call)" : ""}</span>}
              {!call && coupon && <span className={cn(coupon.would_pay ? "text-positive" : "text-warn")}>{coupon.would_pay ? " (coupon on track)" : " (coupon at risk)"}</span>}
            </>
          )}
          {ended && n.ended_on && ` · ended ${formatDate(n.ended_on)}`}
        </p>
      </div>
      <div className="text-right">
        <p className="tabular text-sm font-medium text-ink">{formatMoney(n.invested, { currency: n.currency })}</p>
        <p className="tabular text-[12px] text-muted">
          {ended && n.result ? (
            <span className={Number(n.result.profit) < 0 ? "text-danger" : "text-positive"}>
              {Number(n.result.profit) >= 0 ? "+" : ""}
              {formatMoney(n.result.profit, { currency: n.currency, bare: true })} ({pct(n.result.return_pct)})
            </span>
          ) : Number(n.received.total) > 0 ? (
            `${formatMoney(n.received.total, { currency: n.currency })} received`
          ) : (
            "invested"
          )}
        </p>
      </div>
      <ChevronRight className="size-4 shrink-0 text-subtle group-hover:text-ink-2" />
    </Link>
  );
}

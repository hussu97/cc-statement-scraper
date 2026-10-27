import { shareBars, verdictLine, VERDICT_TEXT, type BarTone, type NoteShare, type NoteVerdict } from "@/lib/note-verdict";
import { cn } from "@/lib/cn";

const DOT: Record<BarTone, string> = { positive: "bg-positive", warn: "bg-warn", danger: "bg-danger" };

/** The note in one line, coloured by how it reads; nothing for a verdict this build doesn't know. */
export function VerdictText({ verdict, className }: { verdict: NoteVerdict | null | undefined; className?: string }) {
  const line = verdictLine(verdict);
  if (!line) return null;
  return <p className={cn("font-medium", VERDICT_TEXT[line.tone], className)}>{line.text}</p>;
}

/**
 * One bar per stock of a live note, the stock holding it back first: a tick at the call level, a
 * dashed tick at the barrier (coupon or break-even), a dot at today's close coloured by where it
 * stands, and on the right what it still needs. Drawing only: the levels and distances are the server's.
 */
export function StockBars({ shares, className }: { shares: readonly NoteShare[] | null | undefined; className?: string }) {
  const bars = shareBars(shares);
  if (bars.length === 0) return null;
  const hasBarrier = bars.some((b) => b.barrierAt !== null);
  const hasCall = bars.some((b) => b.callAt !== null);
  return (
    <div className={className}>
      <ul className="flex flex-col gap-2.5">
        {bars.map((b) => (
          <li key={b.symbol} className="grid grid-cols-[3.25rem_1fr_auto] items-center gap-x-3 sm:grid-cols-[4rem_1fr_7.5rem]">
            <div className="min-w-0">
              <p className={cn("truncate text-[13px] font-medium", b.worst ? "text-ink" : "text-ink-2")} title={b.name ?? undefined}>
                {b.symbol}
              </p>
            </div>
            <div className="min-w-0">
              <Bar callAt={b.callAt} barrierAt={b.barrierAt} dotAt={b.dotAt} startAt={b.startAt} tone={b.dotTone} label={`${b.symbol}: ${b.close}, start ${b.start}, ${b.status}`} />
              <p className="tabular mt-0.5 truncate text-[11px] text-muted">
                {b.close} · start {b.start}
              </p>
            </div>
            <p className={cn("tabular text-right text-[12px] whitespace-nowrap", b.statusMet ? "text-positive" : "text-ink-2")}>{b.status}</p>
          </li>
        ))}
      </ul>
      <p className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-subtle">
        {hasCall && (
          <span className="inline-flex items-center gap-1">
            <span aria-hidden className="inline-block h-2.5 w-0.5 bg-ink-2" /> call level
          </span>
        )}
        {hasBarrier && (
          <span className="inline-flex items-center gap-1">
            <span aria-hidden className="inline-block h-2.5 border-l border-dashed border-muted" /> barrier
          </span>
        )}
        <span className="inline-flex items-center gap-1">
          <span aria-hidden className="inline-block size-2 rounded-pill bg-muted" /> today
        </span>
      </p>
    </div>
  );
}

function Bar({ callAt, barrierAt, dotAt, startAt, tone, label }: { callAt: number | null; barrierAt: number | null; dotAt: number; startAt: number; tone: BarTone; label: string }) {
  return (
    <div role="img" aria-label={label} className="relative h-4">
      <div className="absolute inset-x-0 top-1/2 h-1 -translate-y-1/2 rounded-pill bg-surface-3" />
      {/* the start, faint, so a fall from it shows */}
      <span aria-hidden className="absolute top-1/2 h-2 w-px -translate-y-1/2 bg-border-strong" style={{ left: `${startAt}%` }} />
      {barrierAt !== null && <span aria-hidden className="absolute top-0 h-4 border-l border-dashed border-muted" style={{ left: `${barrierAt}%` }} />}
      {callAt !== null && <span aria-hidden className="absolute top-0 h-4 w-0.5 -translate-x-1/2 rounded-pill bg-ink-2" style={{ left: `${callAt}%` }} />}
      <span aria-hidden className={cn("absolute top-1/2 size-2.5 -translate-x-1/2 -translate-y-1/2 rounded-pill ring-2 ring-surface", DOT[tone])} style={{ left: `${dotAt}%` }} />
    </div>
  );
}

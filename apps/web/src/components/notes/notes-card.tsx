import { Link } from "@tanstack/react-router";
import { ChevronRight } from "lucide-react";
import { useNotesSummary, type NoteSummary } from "@/data/notes";
import { liveNotesOutsideBrokers } from "@/lib/broker-accounts";
import { formatTotal } from "@/lib/money";
import { Card, CardHeader } from "@/components/ui/display";
import { ErrorState, LoadingRows } from "@/components/ui/states";
import { VerdictText } from "./stock-bars";

/**
 * Live structured notes not held at a synced broker account (that account's row covers its own),
 * one line each: name, verdict, worth today. Nothing at all when there are none; ended notes never list here.
 */
export function NotesCard({ profileCode, covered, coveredLoading }: { profileCode: string; covered: ReadonlySet<string>; coveredLoading?: boolean }) {
  const q = useNotesSummary(profileCode);
  if (q.isLoading || coveredLoading) {
    return (
      <Card>
        <CardHeader title="Structured notes" />
        <LoadingRows rows={2} />
      </Card>
    );
  }
  if (q.isError) {
    return (
      <Card>
        <CardHeader title="Structured notes" />
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      </Card>
    );
  }
  const notes = liveNotesOutsideBrokers(q.data ?? [], covered);
  if (notes.length === 0) return null;
  return (
    <Card>
      <CardHeader eyebrow={`${notes.length} live`} title="Structured notes" />
      <ul className="divide-y divide-border border-t border-border">
        {notes.map((n) => (
          <li key={n.note_code}>
            <NoteRow n={n} />
          </li>
        ))}
      </ul>
    </Card>
  );
}

function NoteRow({ n }: { n: NoteSummary }) {
  return (
    <Link
      to="/wealth/investments/$holdingCode"
      params={{ holdingCode: n.holding_code }}
      className="tap group flex items-center gap-3 px-5 py-3 hover:bg-surface-2/60 focus-visible:bg-surface-2/60"
    >
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium text-ink">{n.name}</p>
        <VerdictText verdict={n.verdict} className="mt-0.5 text-[12px]" />
      </div>
      <div className="tabular text-right">
        <p className="text-sm font-medium text-ink">{n.market ? formatTotal(n.market.value, { currency: n.currency }) : formatTotal(n.invested, { currency: n.currency })}</p>
        <p className="text-[11px] text-muted">{n.market ? "worth today" : "paid"}</p>
      </div>
      <ChevronRight className="size-4 shrink-0 text-subtle group-hover:text-ink-2" />
    </Link>
  );
}

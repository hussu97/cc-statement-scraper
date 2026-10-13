import { Link } from "@tanstack/react-router";
import { ChevronRight, FileText } from "lucide-react";
import { STATEMENT_CYCLES_MAX, useInfiniteStatementCycles, useStatementCycles, type StatementCycle } from "@/data/cards";
import { utilisationTone } from "@/data/statements";
import { formatDate } from "@/lib/dates";
import { formatPercent, formatTotal, toAmount } from "@/lib/money";
import { pageCount, type PageSize } from "@/lib/pagination";
import { INFINITE_QUERY } from "@/lib/infinite";
import { useClampPage, useMediaQuery } from "@/lib/hooks";
import { reconBadge } from "@/lib/recon";
import { cn } from "@/lib/cn";
import { Badge, Card, Meter } from "@/components/ui/display";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { Pagination } from "@/components/pagination";
import { InfiniteFooter } from "@/components/infinite-footer";

export interface ListPaging {
  page: number;
  size: PageSize;
  onPage: (page: number) => void;
  onSize: (size: PageSize) => void;
}

const empty = (
  <Card>
    <EmptyState icon={<FileText />} title="No statements yet" action={<Link to="/cards" search={{ tab: "upload" }} className="text-sm text-accent hover:underline">Upload a statement</Link>}>
      Statements arrive from the scraper, email, or an upload here.
    </EmptyState>
  </Card>
);

/** Every statement, newest first. Each row opens the statement page. Phones scroll forever; wider screens page. */
export function StatementsTab({ profileCode, paging }: { profileCode: string; paging: ListPaging }) {
  const phone = useMediaQuery(INFINITE_QUERY);
  return phone ? <StatementsInfinite profileCode={profileCode} /> : <StatementsPaged profileCode={profileCode} paging={paging} />;
}

function StatementsPaged({ profileCode, paging }: { profileCode: string; paging: ListPaging }) {
  const q = useStatementCycles(profileCode, paging.page, paging.size);
  useClampPage(paging.page, paging.size, q.data?.total, paging.onPage);
  if (q.isLoading) return <Card><LoadingRows rows={6} /></Card>;
  if (q.isError) return <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>;
  const { rows, total } = q.data!;
  if (total === 0) return empty;
  return (
    <>
      <Card className={cn("overflow-hidden", q.isFetching && !q.isLoading && "opacity-80 transition-opacity")}>
        {paging.page > pageCount(total, paging.size) ? (
          <LoadingRows rows={4} />
        ) : (
          <ul className="divide-y divide-border">
            {rows.map((s) => (
              <StatementRow key={s.stmt_code} s={s} />
            ))}
          </ul>
        )}
      </Card>
      <Pagination page={paging.page} size={paging.size} total={total} onPage={paging.onPage} onSize={paging.onSize} />
      {total >= STATEMENT_CYCLES_MAX && <CapNote />}
    </>
  );
}

function StatementsInfinite({ profileCode }: { profileCode: string }) {
  const q = useInfiniteStatementCycles(profileCode);
  if (q.isLoading) return <Card><LoadingRows rows={6} /></Card>;
  if (q.isError && !q.isFetchNextPageError) return <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>;
  if (q.items.length === 0) return empty;
  return (
    <>
      <Card className="overflow-hidden">
        <ul className="divide-y divide-border">
          {q.items.map((s) => (
            <StatementRow key={s.stmt_code} s={s} />
          ))}
        </ul>
        <InfiniteFooter
          hasNextPage={q.hasNextPage}
          isFetchingNextPage={q.isFetchingNextPage}
          isFetchNextPageError={q.isFetchNextPageError}
          error={q.error}
          fetchNextPage={q.fetchNextPage}
          loaded={q.items.length}
          noun="statements"
        />
      </Card>
      {(q.total ?? 0) >= STATEMENT_CYCLES_MAX && <CapNote />}
    </>
  );
}

function CapNote() {
  return <p className="px-1 pt-2 text-[12px] text-muted">Showing your newest {STATEMENT_CYCLES_MAX} statements. Older ones are still in your ledger and in Activity.</p>;
}

function StatementRow({ s }: { s: StatementCycle }) {
  const badge = reconBadge(s.recon_status);
  const util = toAmount(s.utilisation);
  return (
    <li>
      <Link
        to="/statements/$stmtCode"
        params={{ stmtCode: s.stmt_code }}
        className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 gap-y-2 px-4 py-3.5 transition-colors hover:bg-surface-2/50 md:grid-cols-[minmax(0,1.3fr)_repeat(3,minmax(0,1fr))_8.5rem] md:gap-x-4 md:px-5"
      >
        <span className="flex min-w-0 items-center gap-3">
          <BankLogo bankCode={s.bank_code} className="size-7" />
          <span className="min-w-0">
            <span className="block truncate text-sm text-ink">
              {formatDate(s.statement_date)} {s.kind !== "statement" && <span className="text-subtle">· history export</span>}
            </span>
            <span className="block truncate text-[12px] text-muted">
              {s.card_last4 ? `•${s.card_last4}` : "Card unknown"} · {s.period_start ? `${formatDate(s.period_start, "short")} – ${formatDate(s.period_end, "short")}` : "period unknown"}
            </span>
            <span className="tabular mt-0.5 block truncate text-[12px] text-ink-2 md:hidden">
              {formatTotal(s.closing_balance)}
              {s.due_date && <span className="text-muted"> · due {formatDate(s.due_date, "short")}</span>}
            </span>
          </span>
        </span>
        <span className="hidden text-[13px] md:block">
          <span className="block text-[11px] text-subtle">Closing</span>
          <span className="tabular block text-ink">{formatTotal(s.closing_balance)}</span>
        </span>
        <span className="hidden text-[13px] md:block">
          <span className="block text-[11px] text-subtle">Due</span>
          <span className="block text-ink">{s.due_date ? formatDate(s.due_date, "short") : "—"}</span>
          {s.min_due !== null && <span className="tabular block text-[11px] text-subtle">min {formatTotal(s.min_due)}</span>}
        </span>
        <span className="hidden text-[13px] md:block">
          <span className="block text-[11px] text-subtle">Utilisation</span>
          <span className="tabular block text-ink">{util !== null ? formatPercent(util) : "—"}</span>
          {util !== null && <Meter value={util} className="mt-1 h-1 w-20" tone={utilisationTone(util)} label="Utilisation" />}
        </span>
        <span className="flex items-center justify-end gap-1.5">
          <Badge tone={badge.tone}>{badge.label}</Badge>
          <ChevronRight className="size-4 text-subtle" aria-hidden />
        </span>
      </Link>
    </li>
  );
}

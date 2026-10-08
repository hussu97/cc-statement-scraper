import { useState } from "react";
import { ChevronDown, CircleAlert, FileText, RotateCw } from "lucide-react";
import { docWarnings, useDocumentHealth, useDocuments, useInfiniteDocuments, useRequeueDocuments, type DocumentRow } from "@/data/cards";
import { errorMessage } from "@/data/api";
import { formatRelative } from "@/lib/dates";
import { INFINITE_QUERY } from "@/lib/infinite";
import { pageCount } from "@/lib/pagination";
import { useClampPage, useMediaQuery } from "@/lib/hooks";
import { cn } from "@/lib/cn";
import { Badge, Card } from "@/components/ui/display";
import { Tooltip } from "@/components/ui/primitives";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { BankLogo } from "@/components/bank-logo";
import { Pagination } from "@/components/pagination";
import { InfiniteFooter } from "@/components/infinite-footer";
import { DocumentLog } from "@/components/documents/document-log";
import { usePdfOpener } from "@/components/documents/use-pdf-opener";
import type { ListPaging } from "./statements-tab";

const PARSE_TONE: Record<string, "neutral" | "info" | "positive" | "danger"> = { queued: "neutral", parsing: "info", parsed: "positive", failed: "danger" };

const empty = (
  <Card>
    <EmptyState icon={<FileText />} title="No documents yet">Uploaded and scraped PDFs appear here with their parse status.</EmptyState>
  </Card>
);

/** Every stored PDF with its parse status and processing log. Phones scroll forever; wider screens page. */
export function DocumentsTab({ profileCode, isOwner, paging }: { profileCode: string; isOwner: boolean; paging: ListPaging }) {
  const phone = useMediaQuery(INFINITE_QUERY);
  const health = useDocumentHealth(profileCode);
  const requeue = useRequeueDocuments(profileCode);
  const toast = useToast();
  const failed = health.data?.failedCodes ?? [];
  const failedCount = health.data?.counts.failed ?? 0;
  const parseAgain = (codes: string[]) =>
    requeue.mutate(codes, {
      onSuccess: (n) => toast({ title: `${n} document${n === 1 ? "" : "s"} queued for parsing`, tone: "positive" }),
      onError: (e) => toast({ title: "Couldn't queue", description: errorMessage(e), tone: "danger" }),
    });
  const row = (d: DocumentRow) => <DocumentItem key={d.doc_code} d={d} profileCode={profileCode} isOwner={isOwner} onParseAgain={() => parseAgain([d.doc_code])} />;
  return (
    <>
      {isOwner && failedCount > 0 && (
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-danger bg-danger-soft px-4 py-3 text-[13px]">
          <span className="flex items-center gap-2 text-danger"><CircleAlert className="size-4" />{failedCount} document{failedCount === 1 ? "" : "s"} failed to parse.</span>
          <Button size="sm" icon={<RotateCw className="size-3.5" />} loading={requeue.isPending} disabled={failed.length === 0} onClick={() => parseAgain(failed)}>Retry failed</Button>
        </div>
      )}
      {phone ? <DocumentsInfinite profileCode={profileCode} row={row} /> : <DocumentsPaged profileCode={profileCode} paging={paging} row={row} />}
    </>
  );
}

function DocumentsPaged({ profileCode, paging, row }: { profileCode: string; paging: ListPaging; row: (d: DocumentRow) => React.ReactNode }) {
  const q = useDocuments(profileCode, paging.page, paging.size);
  useClampPage(paging.page, paging.size, q.data?.total, paging.onPage);
  if (q.isLoading) return <Card><LoadingRows rows={6} /></Card>;
  if (q.isError) return <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>;
  const { rows, total } = q.data!;
  if (total === 0) return empty;
  return (
    <>
      <Card className={cn("overflow-hidden", q.isFetching && !q.isLoading && "opacity-80 transition-opacity")}>
        {paging.page > pageCount(total, paging.size) ? <LoadingRows rows={4} /> : <ul className="divide-y divide-border">{rows.map(row)}</ul>}
      </Card>
      <Pagination page={paging.page} size={paging.size} total={total} onPage={paging.onPage} onSize={paging.onSize} />
    </>
  );
}

function DocumentsInfinite({ profileCode, row }: { profileCode: string; row: (d: DocumentRow) => React.ReactNode }) {
  const q = useInfiniteDocuments(profileCode);
  if (q.isLoading) return <Card><LoadingRows rows={6} /></Card>;
  if (q.isError && !q.isFetchNextPageError) return <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>;
  if (q.items.length === 0) return empty;
  return (
    <Card className="overflow-hidden">
      <ul className="divide-y divide-border">{q.items.map(row)}</ul>
      <InfiniteFooter
        hasNextPage={q.hasNextPage}
        isFetchingNextPage={q.isFetchingNextPage}
        isFetchNextPageError={q.isFetchNextPageError}
        error={q.error}
        fetchNextPage={q.fetchNextPage}
        loaded={q.items.length}
        noun="documents"
      />
    </Card>
  );
}

function DocumentItem({ d, profileCode, isOwner, onParseAgain }: { d: DocumentRow; profileCode: string; isOwner: boolean; onParseAgain: () => void }) {
  const openPdf = usePdfOpener();
  const [logOpen, setLogOpen] = useState(false);
  const logId = `log-${d.doc_code}`;
  return (
    <li>
      <div className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 px-4 py-3 md:px-5">
        <div className="min-w-0">
          <button type="button" onClick={() => void openPdf(d.doc_code)} className="-my-2.5 block max-w-full truncate py-2.5 text-left text-sm text-ink hover:text-accent lg:my-0 lg:py-0">
            {d.original_filename}
          </button>
          <p className="mt-0.5 flex flex-wrap gap-x-2 text-[12px] text-muted">
            <span className="inline-flex items-center gap-1">{d.bank_code ? <><BankLogo bankCode={d.bank_code} size="xs" decorative />{d.bank_code}</> : "Bank unknown"}</span>
            <span>· {d.source}</span>
            <span>· added {formatRelative(d.created_at)}</span>
            {d.parsed_at && <span>· parsed {formatRelative(d.parsed_at)}</span>}
            {d.parser_version && <span>· parser {d.parser_version}</span>}
          </p>
          {d.parse_status === "failed" && d.parse_error && <p className="mt-1 text-[12px] text-danger">{d.parse_error}</p>}
          <button type="button" aria-expanded={logOpen} aria-controls={logId} onClick={() => setLogOpen((o) => !o)} className="tap mt-1 inline-flex items-center gap-1 text-[12px] text-accent hover:underline">
            <ChevronDown className={cn("size-3 transition-transform", logOpen && "rotate-180")} aria-hidden />
            {logOpen ? "Hide processing log" : "Processing log"}
          </button>
        </div>
        <div className="flex items-center gap-2">
          <WarningsChip warnings={docWarnings(d.parse_warnings)} />
          <Badge tone={PARSE_TONE[d.parse_status] ?? "neutral"} className={d.parse_status === "parsing" ? "animate-pulse" : undefined}>{d.parse_status}</Badge>
          {isOwner && (d.parse_status === "failed" || d.parse_status === "parsed") && (
            <Button size="icon-sm" variant="ghost" aria-label={`Parse ${d.original_filename} again`} onClick={onParseAgain}>
              <RotateCw className="size-3.5" />
            </Button>
          )}
        </div>
      </div>
      {logOpen && (
        <div id={logId} className="border-t border-border bg-bg px-4 py-3 md:px-5">
          <DocumentLog profileCode={profileCode} docCode={d.doc_code} bare />
        </div>
      )}
    </li>
  );
}

/** "2 warnings" next to a parsed document; the parser's notes in a tooltip (digit runs masked by docWarnings). */
function WarningsChip({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null;
  const shown = warnings.slice(0, 6);
  const label = `${warnings.length} warning${warnings.length === 1 ? "" : "s"}`;
  return (
    <Tooltip
      content={
        <ul className="flex flex-col gap-1">
          {shown.map((w, i) => (
            <li key={i}>{w}</li>
          ))}
          {warnings.length > shown.length && <li>+{warnings.length - shown.length} more</li>}
        </ul>
      }
    >
      <button type="button" aria-label={`${label}: ${shown.join("; ")}`} className="tap inline-flex items-center gap-1 rounded-pill text-[12px] text-muted hover:text-ink">
        <CircleAlert className="size-3.5" aria-hidden />
        <span className="tabular">{label}</span>
      </button>
    </Tooltip>
  );
}

import { useState } from "react";
import { Download, Eye, EyeOff, X } from "lucide-react";
import { errorMessage } from "@/data/api";
import { fetchActivityExport, useBulkUpdate, useSelectionSummary, type BulkPatch, type TxnSelection } from "@/data/transactions";
import { activityCsv, activityCsvFilename } from "@/lib/csv";
import { downloadText } from "@/lib/download";
import { todayDubai } from "@/lib/dates";
import { formatCount, formatTotal } from "@/lib/money";
import { Button } from "@/components/ui/button";
import { Badge, Skeleton } from "@/components/ui/display";
import { Tooltip } from "@/components/ui/primitives";
import { useToast } from "@/components/ui/toast";
import { CategoryPicker } from "@/components/ledger";

type Categories = Parameters<typeof CategoryPicker>[0]["categories"];

/**
 * The Activity bulk bar (WEB-24): the selection's count and net AED from the server
 * (activity_selection_summary), Categorise and Exclude / Include for owners, and Export CSV
 * for every member. A selection is the ticked rows or "all matching" the filters.
 */
export function BulkBar({
  profileCode,
  selection,
  isOwner,
  categories,
  selectAllLoaded,
  selectAllMatching,
  onClear,
}: {
  profileCode: string;
  selection: TxnSelection;
  isOwner: boolean;
  categories: Categories;
  /** Phones: tick every loaded row (shown when some are unticked). */
  selectAllLoaded?: () => void;
  /** Every loaded row is ticked but more match: offer the whole result set. */
  selectAllMatching?: { total: number; onSelect: () => void };
  onClear: () => void;
}) {
  const toast = useToast();
  const summary = useSelectionSummary(profileCode, selection);
  const bulk = useBulkUpdate(profileCode);
  const [exporting, setExporting] = useState(false);
  const s = summary.data;
  const matching = selection.kind === "filter";
  const count = matching ? s?.txn_count : selection.codes.length;
  const allExcluded = !!s && s.txn_count > 0 && s.excluded_count === s.txn_count;
  const busy = bulk.isPending || exporting;

  const apply = (patch: BulkPatch, done: (n: number) => string, failed: string) =>
    bulk.mutate(
      { selection, patch },
      {
        onSuccess: (n) => {
          toast({ title: n === 0 ? "Nothing to change" : done(n), tone: n === 0 ? "neutral" : "positive" });
          onClear();
        },
        onError: (e) => toast({ title: failed, description: errorMessage(e), tone: "danger" }),
      },
    );

  const exportCsv = async () => {
    setExporting(true);
    try {
      const rows = await fetchActivityExport(profileCode, selection);
      downloadText(activityCsvFilename(todayDubai()), activityCsv(rows));
      toast({ title: `Exported ${formatCount(rows.length)} ${rows.length === 1 ? "transaction" : "transactions"}`, tone: "positive" });
    } catch (e) {
      toast({ title: "Couldn't export", description: errorMessage(e), tone: "danger" });
    } finally {
      setExporting(false);
    }
  };

  return (
    // Sits above the phone tab bar and the home indicator.
    <div className="fixed inset-x-0 bottom-[calc(4.5rem+env(safe-area-inset-bottom))] z-30 flex justify-center px-4 lg:bottom-6 lg:pl-60">
      <div
        role="region"
        aria-label="Bulk actions"
        className="flex max-w-full min-w-0 flex-wrap items-center gap-x-2 gap-y-1.5 rounded-lg border border-border-strong bg-surface py-2 pr-2 pl-4 shadow-[0_16px_40px_-20px_var(--color-ink)] animate-rise sm:flex-nowrap sm:gap-3"
      >
        <div aria-live="polite" className="flex min-w-0 shrink-0 items-baseline gap-1.5 text-sm">
          <span className="tabular text-ink">
            {count === undefined ? "…" : matching ? `All ${formatCount(count)}` : formatCount(count)} selected
          </span>
          <span aria-hidden className="text-subtle">
            ·
          </span>
          {summary.isError ? (
            <span className="text-muted">total unavailable</span>
          ) : !s ? (
            <Skeleton className="h-3.5 w-20" />
          ) : (
            <span className={summary.isFetching ? "opacity-60 transition-opacity" : undefined}>
              <span className="tabular font-medium text-ink">{formatTotal(s.net_aed)}</span> <span className="text-muted">net</span>
            </span>
          )}
          {s?.has_estimate && (
            <Tooltip content="Some AED amounts use an estimated exchange rate.">
              <Badge tone="warn">est.</Badge>
            </Tooltip>
          )}
        </div>
        <div className="flex min-w-0 items-center gap-1.5 sm:gap-2">
          {selectAllLoaded && (
            <Button size="sm" variant="ghost" className="md:hidden" onClick={selectAllLoaded}>
              All
            </Button>
          )}
          {selectAllMatching && (
            <Button size="sm" variant="ghost" onClick={selectAllMatching.onSelect}>
              Select all {formatCount(selectAllMatching.total)}
            </Button>
          )}
          {isOwner && (
            <>
              <CategoryPicker
                categories={categories}
                value={null}
                emptyLabel="Categorise…"
                triggerClassName="h-8 min-w-0 border-border bg-surface-2 not-italic text-ink"
                disabled={busy}
                onSelect={(code) =>
                  apply({ manual_category_code: code }, (n) => `${formatCount(n)} ${n === 1 ? "transaction" : "transactions"} categorised`, "Couldn't categorise")
                }
              />
              <Button
                size="sm"
                variant="secondary"
                disabled={busy || !s}
                icon={allExcluded ? <Eye className="size-4" aria-hidden /> : <EyeOff className="size-4" aria-hidden />}
                aria-label={allExcluded ? "Include in spending" : "Exclude from spending"}
                onClick={() =>
                  apply(
                    { exclude_from_spend: !allExcluded },
                    (n) => `${formatCount(n)} ${n === 1 ? "transaction" : "transactions"} ${allExcluded ? "included in" : "excluded from"} spending`,
                    allExcluded ? "Couldn't include" : "Couldn't exclude",
                  )
                }
              >
                <span className="hidden sm:inline">{allExcluded ? "Include" : "Exclude"}</span>
              </Button>
            </>
          )}
          <Button size="sm" variant="secondary" loading={exporting} disabled={busy} icon={<Download className="size-4" aria-hidden />} aria-label="Export CSV" onClick={() => void exportCsv()}>
            <span className="hidden sm:inline">Export CSV</span>
          </Button>
          <Button size="icon-sm" variant="ghost" aria-label="Clear selection" onClick={onClear}>
            <X className="size-4" />
          </Button>
        </div>
      </div>
    </div>
  );
}

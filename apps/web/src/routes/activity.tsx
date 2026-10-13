import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useRouter } from "@tanstack/react-router";
import { NotebookPen, ReceiptText } from "lucide-react";
import { activityRoute } from "@/router";
import { listSearch, withFilter, type ActivitySearch } from "@/lib/activity-filters";
import { DEFAULT_PAGE_SIZE, pageCount } from "@/lib/pagination";
import { useClampPage, useMediaQuery } from "@/lib/hooks";
import { INFINITE_QUERY } from "@/lib/infinite";
import { formatDate, formatTime } from "@/lib/dates";
import { cn } from "@/lib/cn";
import { useActiveProfile } from "@/data/profile";
import { useFilterMeta } from "@/data/overview";
import {
  dayTotalLabel,
  evidenceBadge,
  groupByDay,
  listDays,
  useDayTotals,
  useInfiniteTransactions,
  useActivitySummary,
  useSetCategory,
  useTransactions,
  type DayTotal,
  type TxnRow,
  type TxnSelection,
} from "@/data/transactions";
import { errorMessage } from "@/data/api";
import { PageHeader, Card } from "@/components/ui/display";
import { Checkbox } from "@/components/ui/primitives";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { CategoryPicker, EvidenceBadge, StatusBadge, TxnAmount } from "@/components/ledger";
import { Pagination } from "@/components/pagination";
import { InfiniteFooter } from "@/components/infinite-footer";
import { ActivityFilters } from "@/components/activity/filters";
import { ActivitySummaryStrip } from "@/components/activity/summary";
import { TransactionDrawer } from "@/components/activity/drawer";
import { BulkBar } from "@/components/activity/bulk-bar";
import { CardRef } from "@/components/bank-logo";
import { transferPeer } from "@/lib/transfers";

export function ActivityPage() {
  const { profile_code, isOwner } = useActiveProfile();
  const search = activityRoute.useSearch();
  const navigate = useNavigate({ from: "/activity" });
  const list = useMemo(() => listSearch(search), [search]);
  // Phones scroll forever (100 at a time); wider screens keep numbered pages in the URL.
  const phone = useMediaQuery(INFINITE_QUERY);
  const paged = useTransactions(profile_code, list, !phone);
  const infinite = useInfiniteTransactions(profile_code, list, phone);
  const q = phone
    ? { ...infinite, data: infinite.data ? { rows: infinite.items, total: infinite.total ?? infinite.items.length } : undefined, isError: infinite.isError && !infinite.isFetchNextPageError }
    : paged;
  const meta = useFilterMeta(profile_code);
  const summary = useActivitySummary(profile_code, list);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  // Phones have no checkbox column: "Select" turns it on (WEB-24).
  const [selecting, setSelecting] = useState(false);
  const router = useRouter();
  // True while the open drawer was pushed from this list, so closing it can
  // pop that entry instead of pushing another (Back no longer reopens it, WEB-43).
  const pushedDrawer = useRef(false);
  useEffect(() => {
    if (!search.txn) pushedDrawer.current = false;
  }, [search.txn]);
  const toast = useToast();
  const setCat = useSetCategory(profile_code);
  // "Select all N matching": the selection is the filter, not the ticked rows (WEB-24).
  const [allMatching, setAllMatching] = useState(false);
  const clearSelection = () => {
    setSelected(new Set());
    setAllMatching(false);
  };

  const go = (next: ActivitySearch) => {
    clearSelection();
    void navigate({ search: next, replace: true });
  };
  const patch = (p: Partial<ActivitySearch>) => go(withFilter(search, p));
  const size = search.size ?? DEFAULT_PAGE_SIZE;
  // A page past the end (stale URL, or a bulk action that emptied the last page) moves to the last page.
  useClampPage(search.page ?? 1, size, phone ? undefined : q.data?.total, (p) => go({ ...search, page: p > 1 ? p : undefined }));
  const outOfRange = !phone && !!q.data && (search.page ?? 1) > pageCount(q.data.total, size);
  const rows = useMemo(() => q.data?.rows ?? [], [q.data]);
  const groups = useMemo(() => groupByDay(rows), [rows]);
  // Each date header's net over the whole filtered set, one call per page (MA-3).
  const days = useMemo(() => listDays(groups), [groups]);
  const dayTotals = useDayTotals(profile_code, list, days);
  const isSelected = (code: string) => allMatching || selected.has(code);
  const allSelected = rows.length > 0 && (allMatching || rows.every((r) => selected.has(r.txn_code!)));
  const selectRows = () => {
    setAllMatching(false);
    setSelected(new Set(rows.map((r) => r.txn_code!)));
  };
  const toggle = (code: string) => {
    // Unticking one row of "all matching" falls back to the loaded rows minus that one.
    const base = allMatching ? new Set(rows.map((r) => r.txn_code!)) : selected;
    setAllMatching(false);
    const n = new Set(base);
    if (n.has(code)) n.delete(code);
    else n.add(code);
    setSelected(n);
  };
  const selection = useMemo<TxnSelection | null>(
    () => (allMatching ? { kind: "filter", search: list } : selected.size ? { kind: "codes", codes: [...selected] } : null),
    [allMatching, list, selected],
  );
  const matchingTotal = q.data?.total ?? 0;

  return (
    <div>
      <PageHeader
        title="Activity"
        description="Every card transaction from SMS alerts and statements, matched into one ledger."
        actions={
          rows.length > 0 ? (
            <Button
              size="sm"
              variant={selecting ? "primary" : "secondary"}
              className="md:hidden"
              aria-pressed={selecting}
              onClick={() => {
                setSelecting((s) => !s);
                clearSelection();
              }}
            >
              {selecting ? "Done" : "Select"}
            </Button>
          ) : null
        }
      />
      <ActivityFilters search={search} patch={patch} meta={meta.data} onClear={() => go({})} />
      <ActivitySummaryStrip data={summary.data} isLoading={summary.isLoading} isError={summary.isError} isFetching={summary.isFetching && !summary.isLoading} />

      <Card className={cn("mt-4", q.isFetching && !q.isLoading && "opacity-80 transition-opacity")}>
        {q.isLoading || outOfRange ? (
          <LoadingRows rows={10} />
        ) : q.isError ? (
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        ) : rows.length === 0 ? (
          <EmptyState
            icon={<ReceiptText />}
            title={Object.keys(list).length ? "No transactions match these filters" : "No transactions yet"}
            action={Object.keys(list).length ? <Button onClick={() => go({})}>Clear filters</Button> : undefined}
          >
            {Object.keys(list).length ? "Try a wider date range or a different category." : "Upload a statement or set up SMS capture to start your ledger."}
          </EmptyState>
        ) : (
          <div role="table" aria-label="Transactions">
            <div role="row" className="hidden grid-cols-[28px_minmax(0,1fr)_200px_120px_130px] items-center gap-3 rounded-t-lg border-b border-border px-4 py-2 text-[11px] font-medium tracking-wide text-subtle uppercase md:grid">
              <span role="columnheader">
                <Checkbox
                  aria-label={phone ? "Select all loaded" : "Select all on this page"}
                  checked={allSelected ? true : selected.size ? "indeterminate" : false}
                  onCheckedChange={() => (allSelected ? clearSelection() : selectRows())}
                />
              </span>
              <span role="columnheader">Description</span>
              <span role="columnheader">Category</span>
              <span role="columnheader">Card</span>
              <span role="columnheader" className="text-right">Amount</span>
            </div>
            {groups.map((g) => (
              <div key={g.day} role="rowgroup">
                <div className="sticky top-[calc(3.5rem+env(safe-area-inset-top))] z-[1] flex items-baseline justify-between gap-3 border-b border-border bg-surface-2/95 px-4 py-1.5 text-[12px] font-medium text-ink-2 backdrop-blur lg:top-0">
                  <span>{formatDate(g.day, "day")}</span>
                  <DayTotalFigure total={dayTotals.data?.get(g.day)} />
                </div>
                {g.rows.map((t) => (
                  <TxnLine
                    key={t.txn_code}
                    t={t}
                    selected={isSelected(t.txn_code!)}
                    selecting={selecting}
                    onToggle={() => toggle(t.txn_code!)}
                    onOpen={() => {
                      pushedDrawer.current = true;
                      void navigate({ search: { ...search, txn: t.txn_code! } });
                    }}
                    categories={meta.data?.categories ?? []}
                    canEdit={isOwner}
                    onCategory={(code, toMerchant) =>
                      setCat.mutate(
                        { txnCode: t.txn_code!, categoryCode: code, applyToMerchant: toMerchant },
                        {
                          onSuccess: () => toast({ title: toMerchant ? "Category applied to merchant" : "Category updated", tone: "positive" }),
                          onError: (e) => toast({ title: "Couldn't change the category", description: errorMessage(e), tone: "danger" }),
                        },
                      )
                    }
                  />
                ))}
              </div>
            ))}
            {phone && (
              <InfiniteFooter
                hasNextPage={infinite.hasNextPage}
                isFetchingNextPage={infinite.isFetchingNextPage}
                isFetchNextPageError={infinite.isFetchNextPageError}
                error={infinite.error}
                fetchNextPage={infinite.fetchNextPage}
                loaded={rows.length}
                noun="transactions"
              />
            )}
          </div>
        )}
      </Card>

      {!phone && q.data && q.data.total > 0 && (
        <Pagination
          page={search.page ?? 1}
          size={size}
          total={q.data.total}
          onPage={(p) => go({ ...search, page: p > 1 ? p : undefined })}
          onSize={(s) => go(withFilter(search, { size: s === DEFAULT_PAGE_SIZE ? undefined : s }))}
        />
      )}

      {selection && (
        <BulkBar
          profileCode={profile_code}
          selection={selection}
          isOwner={isOwner}
          categories={meta.data?.categories ?? []}
          selectAllLoaded={!allSelected ? selectRows : undefined}
          selectAllMatching={
            !allMatching && allSelected && matchingTotal > selected.size ? { total: matchingTotal, onSelect: () => setAllMatching(true) } : undefined
          }
          onClear={clearSelection}
        />
      )}

      <TransactionDrawer
        txnCode={search.txn}
        meta={meta.data}
        onClose={() => {
          if (pushedDrawer.current) {
            pushedDrawer.current = false;
            router.history.back();
          } else {
            void navigate({ search: { ...search, txn: undefined }, replace: true });
          }
        }}
      />
    </div>
  );
}

function TxnLine({
  t,
  selected,
  selecting,
  onToggle,
  onOpen,
  categories,
  canEdit,
  onCategory,
}: {
  t: TxnRow;
  selected: boolean;
  /** Phone select mode: the checkbox column shows and tapping a row toggles it. */
  selecting: boolean;
  onToggle?: () => void;
  onOpen: () => void;
  categories: NonNullable<ReturnType<typeof useFilterMeta>["data"]>["categories"];
  canEdit: boolean;
  onCategory: (code: string | null, toMerchant: boolean) => void;
}) {
  const picking = selecting && !!onToggle;
  return (
    <div
      role="row"
      className={cn(
        "group grid items-center gap-x-3 gap-y-1 border-b border-border px-4 py-2.5 last:border-b-0 last:rounded-b-lg md:grid-cols-[28px_minmax(0,1fr)_200px_120px_130px]",
        picking ? "grid-cols-[20px_minmax(0,1fr)_auto]" : "grid-cols-[minmax(0,1fr)_auto]",
        selected ? "bg-accent-soft/50" : "hover:bg-surface-2/50",
        (t.status === "void" || t.exclude_from_spend) && "text-muted",
      )}
    >
      <span role="cell" className={picking ? "flex" : "hidden md:block"}>
        {onToggle && <Checkbox aria-label={`Select ${t.merchant_name ?? t.description}`} checked={selected} onCheckedChange={onToggle} />}
      </span>
      {/* A real button inside the cell keeps button semantics (WEB-20); data-txn-open lets the drawer return focus here (WEB-19). */}
      <span role="cell" className="min-w-0">
        <button type="button" data-txn-open={t.txn_code} onClick={picking ? onToggle : onOpen} aria-pressed={picking ? selected : undefined} className="block w-full min-w-0 text-left">
          <span className={cn("flex items-center gap-1.5 truncate text-sm text-ink", t.status === "void" && "line-through decoration-subtle")}>
            <span className="truncate">{t.merchant_name ?? t.description}</span>
            {t.notes && <NotebookPen className="size-3 shrink-0 text-subtle" aria-label="Has a note" />}
          </span>
          <span className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[12px] text-muted">
            {t.txn_at && <span className="tabular">{formatTime(t.txn_at)}</span>}
            <CardRef bankCode={t.bank_code} last4={t.card_last4} className="md:hidden" />
            <EvidenceBadge kind={evidenceBadge(t)} />
            <TransferRef t={t} />
            <StatusBadge status={t.status} />
            {t.exclude_from_spend && <span>excluded</span>}
          </span>
        </button>
      </span>
      <span role="cell" className={cn("order-last col-span-2 -ml-2 min-w-0 md:order-none md:col-span-1 md:col-start-auto", picking && "col-start-2")}>
        <CategoryPicker
          categories={categories}
          value={t.category_code}
          label={t.category_name}
          colorToken={t.category_color}
          source={t.category_source}
          disabled={!canEdit}
          allowApplyToMerchant={!!t.merchant_code}
          onSelect={onCategory}
        />
      </span>
      <span role="cell" className="hidden truncate text-[12px] text-muted md:block">
        <CardRef bankCode={t.bank_code} last4={t.card_last4} size="sm" />
      </span>
      <span role="cell" className="text-right">
        <TxnAmount t={t} className="text-sm" />
      </span>
    </div>
  );
}

/** A date header's net, from the server; nothing while it loads or for a day it did not return. */
function DayTotalFigure({ total }: { total: DayTotal | undefined }) {
  const label = dayTotalLabel(total);
  if (!label || !total) return null;
  const noun = total.txn_count === 1 ? "transaction" : "transactions";
  return (
    <span className="tabular font-normal text-muted" title={`Net of ${total.txn_count} ${noun} that day`}>
      {label}
    </span>
  );
}

/** "Paid to EIB •6177" / "From WIO •2010" under a card-transfer row. */
function TransferRef({ t }: { t: TxnRow }) {
  const peer = transferPeer(t);
  if (!peer) return null;
  return (
    <span className="inline-flex min-w-0 items-center gap-1">
      {peer.prefix} <CardRef bankCode={peer.bankCode} last4={peer.last4} />
    </span>
  );
}

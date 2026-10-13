import { useMemo, useState } from "react";
import { Check, Search, Sparkles, Store, Wand2, X } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import {
  emptyRuleDraft,
  filterMerchants,
  mergeSearchRows,
  merchantState,
  sampleDescription,
  slicePage,
  suggestPattern,
  useCategories,
  useMerchantSearch,
  useMerchants,
  useSetMerchantCategory,
  type MerchantRow,
  type RuleDraft,
} from "@/data/rules";
import { errorMessage } from "@/data/api";
import { formatCount, formatPercent } from "@/lib/money";
import { formatDate } from "@/lib/dates";
import { Card, Dot } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Segmented } from "@/components/ui/primitives";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { CategoryPicker, Money } from "@/components/ledger";
import { Pager, SearchPager, ViewerNote, usePager } from "./shared";
import { useDebouncedValue } from "@/lib/hooks";
import { cn } from "@/lib/cn";
import { RuleEditor } from "./rule-editor";

type View = "all" | "suggested";

export function MerchantsTab() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const merchants = useMerchants(profileCode);
  const categories = useCategories(profileCode);
  const setCategory = useSetMerchantCategory(profileCode);
  const toast = useToast();
  const [q, setQ] = useState("");
  const query = useDebouncedValue(q.trim(), 300);
  const [view, setView] = useState<View>("all");
  const [ruleDraft, setRuleDraft] = useState<RuleDraft | null>(null);
  const [making, setMaking] = useState<string | null>(null);
  const pager = usePager(`${view === "all" ? query : q}|${view}`);
  // "All": every merchant of the ledger, searched and paged on the server.
  const search = useMerchantSearch(profileCode, query, pager.page, pager.size, view === "all");

  const catByCode = useMemo(() => new Map((categories.data ?? []).map((c) => [c.category_code, c])), [categories.data]);
  const pickerCats = useMemo(
    () => (categories.data ?? []).map((c) => ({ ...c, archived: !!c.archived_at })),
    [categories.data],
  );
  const suggestedCount = useMemo(() => (merchants.data?.rows ?? []).filter((m) => merchantState(m) === "suggested").length, [merchants.data]);

  const assign = (m: MerchantRow, code: string | null, title: string, reject = false) =>
    setCategory.mutate(
      { merchantCode: m.merchant_code, categoryCode: code, reject },
      {
        onSuccess: () => toast({ title, tone: "positive" }),
        onError: (e) => toast({ title: "Couldn't update the merchant", description: errorMessage(e), tone: "danger" }),
      },
    );

  const makeRule = async (m: MerchantRow) => {
    setMaking(m.merchant_code);
    try {
      const desc = await sampleDescription(profileCode, m.merchant_code);
      setRuleDraft(
        emptyRuleDraft({
          name: m.merchant_name,
          pattern: suggestPattern(desc, m.merchant_name),
          category_code: m.assignment?.category_code ?? m.category_code ?? "",
          source: "llm_promoted",
        }),
      );
    } finally {
      setMaking(null);
    }
  };

  const renderMerchant = (m: MerchantRow) => {
    const state = merchantState(m);
    const code = m.assignment?.category_code ?? m.category_code;
    const cat = code ? catByCode.get(code) : undefined;
    return (
      <li
        key={m.merchant_code}
        className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-1.5 px-5 py-3 sm:grid-cols-[minmax(0,1fr)_13rem_7.5rem]"
      >
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium text-ink">{m.merchant_name}</p>
          <p className="mt-0.5 text-[12px] text-muted tabular">
            {m.txn_count === null || !m.last_date
              ? "No spend in the last 12 months"
              : `${formatCount(m.txn_count)} ${m.txn_count === 1 ? "transaction" : "transactions"} · last ${formatDate(m.last_date, "short")}`}
          </p>
        </div>
        {m.amount === null ? (
          <span className="text-right text-sm text-muted sm:col-start-3 sm:row-start-1">—</span>
        ) : (
          <Money value={m.amount} total className="text-right text-sm text-ink sm:col-start-3 sm:row-start-1" />
        )}
        <div className="col-span-2 -ml-2 flex min-w-0 flex-col items-start sm:col-span-1 sm:col-start-2 sm:row-start-1">
            {state === "suggested" ? (
              <span className="inline-flex items-center gap-1.5 px-2 py-0.5 text-[12px] text-ink-2">
                <Dot token={cat?.color_token} />
                <span className="truncate">{cat?.name ?? m.category_name ?? "Unknown"}</span>
              </span>
            ) : (
              <CategoryPicker
                categories={pickerCats}
                value={code}
                label={cat?.name ?? m.category_name}
                colorToken={cat?.color_token}
                disabled={!isOwner || setCategory.isPending}
                onSelect={(c) => assign(m, c, c ? `${m.merchant_name} → ${catByCode.get(c)?.name ?? "category"}` : `Cleared ${m.merchant_name}`)}
              />
            )}
            <span className="px-2 text-[11px] text-subtle">
              {state === "manual" && "Applies to merchant"}
              {state === "suggested" && (
                <>
                  <Sparkles className="mr-0.5 inline size-3 text-accent" aria-hidden />
                  Suggested{m.assignment?.confidence != null && ` · ${formatPercent(m.assignment.confidence)} sure`}
                </>
              )}
              {state === "rules" && (code ? "From rules" : "Not set")}
            </span>
        </div>
        {state === "suggested" && isOwner && (
          <div className="col-span-full -ml-1 flex flex-wrap gap-1.5 sm:col-start-2 sm:-ml-2">
            <Button size="sm" variant="secondary" icon={<Check className="size-3.5" />} disabled={setCategory.isPending} onClick={() => assign(m, m.assignment!.category_code, `Accepted ${cat?.name ?? "category"} for ${m.merchant_name}`)}>
              Accept
            </Button>
            <Button size="sm" variant="ghost" icon={<X className="size-3.5" />} disabled={setCategory.isPending} onClick={() => assign(m, null, `Suggestion rejected for ${m.merchant_name}`, true)}>
              Reject
            </Button>
            <Button size="sm" variant="ghost" icon={<Wand2 className="size-3.5" />} loading={making === m.merchant_code} onClick={() => void makeRule(m)}>
              Make a rule
            </Button>
          </div>
        )}
      </li>
    );
  };

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="max-w-xl text-sm text-muted">
          Every merchant in this ledger, busiest first; search finds any of them. Amounts are the last 12 months' spend. A category set here applies to every transaction from that merchant, unless you picked one yourself.
        </p>
        {!isOwner && <ViewerNote />}
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <div className="relative min-w-0 flex-1 basis-56">
          <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-subtle" aria-hidden />
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Find a merchant" aria-label="Find a merchant" className="pl-9" />
        </div>
        <Segmented<View>
          ariaLabel="Show"
          value={view}
          onChange={setView}
          options={[
            { value: "all", label: "All" },
            { value: "suggested", label: <>Suggestions{suggestedCount > 0 && <span className="ml-1 text-accent tabular">{suggestedCount}</span>}</> },
          ]}
        />
      </div>

      <Card className={cn(view === "all" && search.isFetching && !search.isLoading && "opacity-80 transition-opacity")}>
        {view === "all" ? (
          search.isLoading || (merchants.isLoading && !merchants.data) ? (
            <LoadingRows rows={6} />
          ) : search.isError ? (
            <ErrorState error={search.error} onRetry={() => void search.refetch()} />
          ) : (search.data?.rows.length ?? 0) === 0 ? (
            query ? (
              <EmptyState icon={<Search />} title="No merchants match" action={<Button size="sm" onClick={() => setQ("")}>Clear search</Button>}>
                Nothing matches “{query}”.
              </EmptyState>
            ) : pager.page > 1 ? (
              <EmptyState icon={<Store />} title="No more merchants" action={<Button size="sm" onClick={() => pager.setPage(1)}>Back to the first page</Button>} />
            ) : (
              <EmptyState icon={<Store />} title="No merchants yet">
                Merchants appear once transactions are in.
              </EmptyState>
            )
          ) : (
            <>
              <ul className="divide-y divide-border">
                {mergeSearchRows(search.data!.rows, merchants.data?.rows ?? []).map(renderMerchant)}
              </ul>
              <SearchPager page={pager.page} size={pager.size} shown={search.data!.rows.length} hasMore={search.data!.hasMore} onPage={pager.setPage} onSize={pager.setSize} noun="merchants" />
            </>
          )
        ) : merchants.isLoading ? (
          <LoadingRows rows={6} />
        ) : merchants.isError ? (
          <ErrorState error={merchants.error} onRetry={() => void merchants.refetch()} />
        ) : (
          (() => {
            const filtered = filterMerchants(merchants.data?.rows ?? [], { q, suggestionsOnly: true });
            if (filtered.length === 0) {
              return !q ? (
                <EmptyState icon={<Sparkles />} title="No suggestions to review">
                  When Bank Ledger suggests a category for a merchant, it shows up here for you to accept or reject.
                </EmptyState>
              ) : (
                <EmptyState icon={<Search />} title="No suggestions match" action={<Button size="sm" onClick={() => setQ("")}>Clear search</Button>}>
                  Nothing matches “{q}”.
                </EmptyState>
              );
            }
            return (
              <>
                <ul className="divide-y divide-border">
                  {slicePage(filtered, pager.page, pager.size).map(renderMerchant)}
                </ul>
                <Pager total={filtered.length} page={pager.page} size={pager.size} onPage={pager.setPage} onSize={pager.setSize} noun="merchants" />
              </>
            );
          })()
        )}
      </Card>

      {ruleDraft && <RuleEditor initial={ruleDraft} onClose={() => setRuleDraft(null)} />}
    </div>
  );
}

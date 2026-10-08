import { useMemo } from "react";
import { Link, useNavigate, useSearch } from "@tanstack/react-router";
import { ArrowRight, ChevronLeft, ChevronRight, Inbox, Lightbulb, MessageSquareText, X } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { accountLabel, insightTarget, sortInsights, useDismissInsight, useInsights, useOverview, type Insight, type Overview, type OverviewAccount } from "@/data/overview";
import { evidenceBadge, useTransactions } from "@/data/transactions";
import { addMonths, daysBetween, formatDate, formatDateTime, formatMonth, formatRelative, formatTime, monthEnd, monthStart, todayDubai } from "@/lib/dates";
import { formatChange, formatMoney, formatPercent, toAmount } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Card, CardHeader, Badge, Dot, Meter, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { BankMark, EvidenceBadge, HeroAmount, StatusBadge, TxnAmount } from "@/components/ledger";
import { PaceRule } from "@/components/overview/pace-rule";
import { CategoryRing } from "@/components/overview/category-ring";

export function OverviewPage() {
  const { profile_code } = useActiveProfile();
  const today = todayDubai();
  const search = useSearch({ from: "/app/" });
  const navigate = useNavigate();
  const thisMonth = monthStart(today);
  const month = search.month && search.month <= thisMonth ? search.month : thisMonth;
  const isCurrent = month === thisMonth;
  const q = useOverview(profile_code, month);
  const setMonth = (m: string) => void navigate({ to: "/", search: m === thisMonth ? {} : { month: m } });

  return (
    <div className="flex flex-col gap-6">
      <section aria-labelledby="hero-title" className="animate-rise">
        <div className="flex items-center justify-between gap-3">
          <p id="hero-title" className="text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">
            {formatMonth(month)} {isCurrent ? "· so far" : ""}
          </p>
          <div className="flex items-center gap-1">
            <Button size="icon-sm" variant="ghost" aria-label="Previous month" onClick={() => setMonth(addMonths(month, -1))}>
              <ChevronLeft className="size-4" />
            </Button>
            <Button size="icon-sm" variant="ghost" aria-label="Next month" disabled={isCurrent} onClick={() => setMonth(addMonths(month, 1))}>
              <ChevronRight className="size-4" />
            </Button>
          </div>
        </div>
        {q.isLoading ? (
          <HeroSkeleton />
        ) : q.isError || !q.data ? (
          <Card className="mt-3"><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>
        ) : (
          <Hero data={q.data} isCurrent={isCurrent} today={today} />
        )}
      </section>

      {isCurrent && <PendingStrip profileCode={profile_code} overview={q.data} />}

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <Card>
          <CardHeader
            eyebrow="Where it went"
            title={`Top categories in ${formatMonth(month, "short")}`}
            action={<Link to="/insights" search={{ tab: "categories" }} className="tap text-[13px] text-accent hover:underline">All categories</Link>}
          />
          <div className="px-5 pb-5">
            {q.isLoading ? (
              <Skeleton className="h-44 w-full" />
            ) : q.isError || !q.data ? (
              <ErrorState error={q.error} onRetry={() => void q.refetch()} />
            ) : q.data.top_categories.length === 0 ? (
              <EmptyState title="No spending this month yet">Purchases appear here as SMS alerts and statements arrive.</EmptyState>
            ) : (
              <CategoryRing categories={q.data.top_categories} total={q.data.spend} from={month} to={monthEnd(month)} />
            )}
          </div>
        </Card>
        <InsightsPanel profileCode={profile_code} />
      </div>

      <AccountsPanel overview={q.data} loading={q.isLoading} error={q.isError ? q.error : null} retry={() => void q.refetch()} />

      <Card>
        <CardHeader title="Recent activity" action={<Link to="/activity" className="inline-flex items-center gap-1 text-[13px] text-accent hover:underline">All activity <ArrowRight className="size-3.5" /></Link>} />
        {q.isLoading ? (
          <LoadingRows rows={6} />
        ) : q.isError || !q.data ? (
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        ) : q.data.recent.length === 0 ? (
          <EmptyState title="No transactions yet">Upload a statement or set up SMS capture to start your ledger.</EmptyState>
        ) : (
          <ul className="divide-y divide-border border-t border-border">
            {q.data.recent.map((t) => (
              <li key={t.txn_code}>
                <Link to="/activity" search={{ txn: t.txn_code }} className="grid grid-cols-[1fr_auto] items-center gap-3 px-5 py-3 hover:bg-surface-2/60">
                  <div className="min-w-0">
                    <p className="truncate text-sm text-ink">{t.merchant_name ?? t.description}</p>
                    <p className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-muted">
                      <span>{t.txn_at ? formatDateTime(t.txn_at) : formatDate(t.txn_date, "short")}</span>
                      {t.category_name && (
                        <span className="inline-flex items-center gap-1"><Dot token={t.category_color} />{t.category_name}</span>
                      )}
                      <EvidenceBadge kind={evidenceBadge(t)} compact />
                      <StatusBadge status={t.status} />
                    </p>
                  </div>
                  <div className="text-right">
                    <TxnAmount t={t} className="text-sm" />
                  </div>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

function HeroSkeleton() {
  return (
    <div className="mt-3 flex flex-col gap-4" role="status" aria-label="Loading">
      <Skeleton className="h-14 w-64" />
      <Skeleton className="h-4 w-80" />
      <Skeleton className="mt-6 h-10 w-full" />
    </div>
  );
}

function Hero({ data, isCurrent, today }: { data: Overview; isCurrent: boolean; today: string }) {
  // Server fractions: vs last month by the same day (the whole month for a past month), and vs the 3-month average.
  const delta = formatChange(data.change_vs_prev_month_to_date);
  const deltaUp = (toAmount(data.change_vs_prev_month_to_date) ?? 0) > 0;
  const avgDelta = isCurrent ? null : formatChange(data.change_vs_avg_3m);
  const dayLabel = `the ${ordinal(Number(today.slice(8, 10)))}`;
  return (
    <div className="mt-2">
      <div className="flex flex-wrap items-end justify-between gap-x-8 gap-y-3">
        <div>
          <h1 className="sr-only">Spending in {formatMonth(data.month)}</h1>
          <HeroAmount value={data.spend} />
          <p className="mt-3 text-sm text-muted">
            {delta ? (
              <>
                <span className={cn("font-medium", deltaUp ? "text-warn" : "text-positive")}>{delta}</span>{" "}
                {isCurrent ? `vs last month by ${dayLabel}` : "vs the month before"}
              </>
            ) : (
              "Nothing to compare with last month yet"
            )}
            <span className="mx-2 text-border-strong">/</span>
            3-month average {formatMoney(data.spend_avg_3m, { whole: true })}
            {avgDelta && <span className="tabular"> ({avgDelta})</span>}
          </p>
        </div>
        <dl className="flex gap-8 text-sm">
          <div>
            <dt className="text-[12px] text-subtle">Payments in</dt>
            <dd className="tabular mt-0.5 text-positive">{formatMoney(data.payments, { signed: true })}</dd>
          </div>
          <Link to="/activity" search={{ category: "none", from: data.month, to: monthEnd(data.month) }} className="group">
            <dt className="text-[12px] text-subtle">Uncategorised</dt>
            <dd className="tabular mt-0.5 text-ink group-hover:text-accent">{data.uncategorized_count}</dd>
          </Link>
          <Link to="/review" className="group">
            <dt className="text-[12px] text-subtle">To review</dt>
            <dd className={cn("tabular mt-0.5 group-hover:text-accent", data.open_reviews ? "text-accent" : "text-ink")}>{data.open_reviews}</dd>
          </Link>
        </dl>
      </div>
      {isCurrent && (
        <div className="mt-6">
          <PaceRule spend={data.spend} prevToDate={data.spend_prev_month_to_date} avg3m={data.spend_avg_3m} dayLabel={dayLabel} />
        </div>
      )}
    </div>
  );
}

function ordinal(n: number): string {
  const s = ["th", "st", "nd", "rd"];
  const v = n % 100;
  return `${n}${s[(v - 20) % 10] ?? s[v] ?? s[0]}`;
}

function PendingStrip({ profileCode, overview }: { profileCode: string; overview: Overview | undefined }) {
  const q = useTransactions(profileCode, { status: "pending" });
  const rows = q.data?.rows ?? [];
  const now = q.dataUpdatedAt;
  return (
    <section aria-labelledby="pending-title" className="rounded-lg border border-border bg-surface">
      <header className="flex flex-wrap items-center justify-between gap-2 px-5 pt-4 pb-3">
        <div className="flex items-center gap-2">
          <span className="relative flex size-2">
            <span className="absolute inline-flex size-full animate-ping rounded-pill bg-accent opacity-50" />
            <span className="relative inline-flex size-2 rounded-pill bg-accent" />
          </span>
          <h2 id="pending-title" className="text-[15px] font-semibold text-ink">Pending from SMS</h2>
          {overview && (
            <span className="tabular text-[13px] text-muted">
              {overview.pending_count} · {formatMoney(overview.pending_amount)}
            </span>
          )}
        </div>
        <span className="text-[12px] text-subtle">
          {overview?.last_sms_at ? `Last SMS ${formatRelative(overview.last_sms_at)}` : "No SMS received yet"}
        </span>
      </header>
      {q.isLoading ? (
        <div className="flex gap-3 overflow-hidden px-5 pb-4">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-[76px] w-52 shrink-0 rounded-md" />)}</div>
      ) : q.isError ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} className="py-6" />
      ) : rows.length === 0 ? (
        <p className="px-5 pb-4 text-[13px] text-muted">
          Nothing pending. New card alerts land here within seconds. <Link to="/settings" search={{ tab: "sms" }} className="text-accent hover:underline">Set up SMS capture</Link>
        </p>
      ) : (
        <ul className="flex snap-x gap-3 overflow-x-auto px-5 pb-4 [scrollbar-width:thin]">
          {rows.slice(0, 20).map((t) => {
            const fresh = t.created_at ? now - new Date(t.created_at).getTime() < 60_000 : false;
            return (
              <li key={t.txn_code} className="snap-start">
                <Link
                  to="/activity"
                  search={{ txn: t.txn_code ?? undefined }}
                  className={cn(
                    "flex h-full w-52 flex-col gap-1 rounded-md border bg-bg px-3 py-2.5 transition-colors hover:border-border-strong",
                    fresh ? "border-accent animate-rise" : "border-border",
                  )}
                >
                  <span className="flex items-center justify-between text-[11px] text-subtle">
                    <span className="inline-flex items-center gap-1"><MessageSquareText className="size-3" />{t.bank_code} •{t.card_last4}</span>
                    <span>{t.txn_at ? `${formatDate(t.txn_date, "short")} ${formatTime(t.txn_at)}` : formatDate(t.txn_date, "short")}</span>
                  </span>
                  <span className="truncate text-[13px] text-ink">{t.merchant_name ?? t.description}</span>
                  <TxnAmount t={t} align="start" showOriginal={false} className="text-[15px] font-medium" />
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

function InsightsPanel({ profileCode }: { profileCode: string }) {
  const { isOwner } = useActiveProfile();
  const q = useInsights(profileCode);
  const dismiss = useDismissInsight(profileCode);
  const list = useMemo(() => sortInsights(q.data ?? []), [q.data]);
  return (
    <Card>
      <CardHeader eyebrow="Worth a look" title="Insights" />
      {q.isLoading ? (
        <LoadingRows rows={3} />
      ) : q.isError ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : list.length === 0 ? (
        <EmptyState icon={<Lightbulb />} title="All quiet">Ledger checks your spending every night and notes anything unusual here.</EmptyState>
      ) : (
        <ul className="flex flex-col gap-2 px-5 pb-5">
          {list.slice(0, 5).map((i) => (
            <InsightCard key={i.insight_code} insight={i} onDismiss={isOwner ? () => dismiss.mutate(i.insight_code) : undefined} />
          ))}
        </ul>
      )}
    </Card>
  );
}

function InsightCard({ insight: i, onDismiss }: { insight: Insight; onDismiss?: () => void }) {
  const target = insightTarget(i);
  const body = (
    <>
      <div className="flex items-center gap-2">
        <span aria-hidden className={cn("size-1.5 shrink-0 rounded-pill", i.severity === "alert" ? "bg-danger" : i.severity === "warn" ? "bg-warn" : "bg-info")} />
        <p className="text-[13.5px] font-medium text-ink">{i.title}</p>
      </div>
      <p className="mt-1 text-[13px] leading-relaxed text-muted">{i.body}</p>
      {target && (
        <span className="mt-1.5 inline-flex items-center gap-1 text-[12.5px] font-medium text-accent">
          {target.label} <ArrowRight className="size-3.5" aria-hidden />
        </span>
      )}
    </>
  );
  return (
    <li className="group relative rounded-md border border-border bg-bg transition-colors hover:border-border-strong">
      {target ? (
        <Link to={target.to} search={"search" in target ? target.search : undefined} className="block rounded-md px-4 py-3 pr-12">
          {body}
        </Link>
      ) : (
        <div className="px-4 py-3 pr-12">{body}</div>
      )}
      {onDismiss && (
        <button
          type="button"
          onClick={onDismiss}
          aria-label={`Dismiss: ${i.title}`}
          className="absolute top-0 right-0 flex size-11 items-center justify-center rounded-md text-muted hover:bg-surface-2 hover:text-ink md:top-1 md:right-1 md:size-8"
        >
          <X className="size-3.5" />
        </button>
      )}
    </li>
  );
}

function AccountsPanel({ overview, loading, error, retry }: { overview: Overview | undefined; loading: boolean; error: unknown; retry: () => void }) {
  return (
    <section aria-labelledby="cards-title">
      <div className="mb-3 flex items-center justify-between">
        <h2 id="cards-title" className="text-[15px] font-semibold text-ink">Cards</h2>
        <Link to="/cards" className="tap text-[13px] text-accent hover:underline">Cards & statements</Link>
      </div>
      {loading ? (
        <div className="grid gap-4 md:grid-cols-2"><Skeleton className="h-40 rounded-lg" /><Skeleton className="h-40 rounded-lg" /></div>
      ) : error || !overview ? (
        <Card><ErrorState error={error} onRetry={retry} /></Card>
      ) : overview.accounts.length === 0 ? (
        <Card>
          <EmptyState icon={<Inbox />} title="No cards yet" action={<Link to="/cards" search={{ tab: "upload" }} className="text-sm text-accent hover:underline">Upload a statement</Link>}>
            Cards are created automatically from your first statement or SMS.
          </EmptyState>
        </Card>
      ) : (
        <div className="grid gap-4 md:grid-cols-2">
          {overview.accounts.map((a) => (
            <AccountCard key={a.account_code} account={a} />
          ))}
        </div>
      )}
    </section>
  );
}

function AccountCard({ account: a }: { account: OverviewAccount }) {
  const st = a.latest_statement;
  const today = todayDubai();
  const dueIn = st?.due_date ? daysBetween(today, st.due_date) : null;
  const util = toAmount(a.utilisation);
  return (
    <Card className="flex flex-col gap-4 p-5">
      <div className="flex items-start gap-3">
        <BankMark bank={a.bank_code} />
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium text-ink">{accountLabel(a)}</p>
          <p className="text-[12px] text-subtle">{a.last4 ? a.last4.split(",").map((l) => `•${l}`).join("  ") : "No card yet"}</p>
        </div>
        {dueIn !== null && dueIn >= 0 && dueIn <= 7 && <Badge tone={dueIn <= 2 ? "danger" : "warn"}>Due in {dueIn} d</Badge>}
      </div>
      <dl className="grid grid-cols-3 gap-3 text-[12px]">
        <div>
          <dt className="text-subtle">Statement</dt>
          <dd className="tabular mt-0.5 text-sm text-ink">{st ? formatMoney(st.closing_balance, { whole: true }) : "—"}</dd>
        </div>
        <div>
          <dt className="text-subtle">Due</dt>
          <dd className="mt-0.5 text-sm text-ink">{st?.due_date ? formatDate(st.due_date, "short") : "—"}</dd>
          {st?.min_due && <dd className="tabular text-[11px] text-subtle">min {formatMoney(st.min_due, { whole: true })}</dd>}
        </div>
        <div>
          <dt className="text-subtle">Since statement</dt>
          <dd className="tabular mt-0.5 text-sm text-ink">{formatMoney(a.unbilled_aed, { whole: true })}</dd>
        </div>
      </dl>
      <div>
        <div className="mb-1.5 flex justify-between text-[12px]">
          <span className="text-subtle">Utilisation at last statement</span>
          <span className="tabular text-ink-2">
            {util !== null ? formatPercent(util) : "—"}
            {a.credit_limit && <span className="text-subtle"> of {formatMoney(a.credit_limit, { whole: true })}</span>}
          </span>
        </div>
        <Meter value={util} tone={util !== null && util > 0.7 ? "danger" : util !== null && util > 0.3 ? "warn" : "positive"} label="Utilisation" />
      </div>
    </Card>
  );
}

import { useMemo } from "react";
import { Link, useNavigate, useSearch } from "@tanstack/react-router";
import { ArrowRight, ChevronLeft, ChevronRight, Inbox, Lightbulb, X } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { accountLabel, insightTarget, pendingSummary, sortInsights, useDismissInsight, useInsights, useOverview, type Insight, type Overview, type OverviewAccount } from "@/data/overview";
import { evidenceBadge } from "@/data/transactions";
import { addMonths, daysBetween, formatDate, formatDateTime, formatMonth, formatRelative, monthEnd, monthStart, todayDubai } from "@/lib/dates";
import { formatChange, formatPercent, formatTotal, toAmount } from "@/lib/money";
import { balanceAnchorNote, formatOutstanding, outstandingCaveat } from "@/lib/balances";
import { dueBadge, paidNote } from "@/lib/dues";
import { pacePins, projectionLabel } from "@/lib/pace";
import { cn } from "@/lib/cn";
import { Card, CardHeader, Badge, Dot, Meter, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { EvidenceBadge, HeroAmount, StatusBadge, TxnAmount } from "@/components/ledger";
import { PaceRule } from "@/components/overview/pace-rule";
import { CategoryRing } from "@/components/overview/category-ring";
import { MonthlySpendCard } from "@/components/overview/monthly-spend";
import { SetupChecklistCard } from "@/components/overview/setup-checklist";
import { isEmptyLedger } from "@/lib/setup-checklist";
import { BankLogo } from "@/components/bank-logo";

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

  // No transaction and no card: AED 0.00, an empty pace rule and empty panels
  // would claim things the ledger can't know yet. Show its first steps (WEB-27).
  if (q.data && isEmptyLedger(q.data)) {
    return (
      <div className="max-w-2xl">
        <h1 className="sr-only">Overview</h1>
        <SetupChecklistCard lastSmsAt={q.data.last_sms_at} />
      </div>
    );
  }

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

      {isCurrent && <PendingStrip overview={q.data} />}

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

      <MonthlySpendCard profileCode={profile_code} month={month} />

      <AccountsPanel overview={q.data} loading={q.isLoading} error={q.isError ? q.error : null} retry={() => void q.refetch()} />

      <Card>
        <CardHeader title="Recent activity" action={<Link to="/activity" className="tap inline-flex items-center gap-1 text-[13px] text-accent hover:underline">All activity <ArrowRight className="size-3.5" /></Link>} />
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
            3-month average {formatTotal(data.spend_avg_3m)}
            {avgDelta && <span className="tabular"> ({avgDelta})</span>}
          </p>
        </div>
        <dl className="flex gap-8 text-sm">
          <div>
            <dt className="text-[12px] text-subtle">Payments in</dt>
            <dd className="tabular mt-0.5 text-positive">{formatTotal(data.payments, { signed: true })}</dd>
          </div>
          {/* A <dl> holds only dt/dd groups (in a <div>), so the link sits in the dd and stretches over its group (WEB-52). */}
          <div className="relative">
            <dt className="text-[12px] text-subtle">Uncategorised</dt>
            <dd className="tabular mt-0.5">
              <Link
                to="/activity"
                search={{ category: "none", from: data.month, to: monthEnd(data.month) }}
                aria-label={`${data.uncategorized_count} uncategorised`}
                className="text-ink after:absolute after:inset-0 hover:text-accent"
              >
                {data.uncategorized_count}
              </Link>
            </dd>
          </div>
          <div className="relative">
            <dt className="text-[12px] text-subtle">To review</dt>
            <dd className="tabular mt-0.5">
              <Link to="/review" aria-label={`${data.open_reviews} to review`} className={cn("after:absolute after:inset-0 hover:text-accent", data.open_reviews ? "text-accent" : "text-ink")}>
                {data.open_reviews}
              </Link>
            </dd>
          </div>
        </dl>
      </div>
      {isCurrent && (
        <div className="mt-6">
          <PaceRule spend={data.spend} pins={pacePins(data, dayLabel)} projection={projectionLabel(data.projected_month_end, monthEnd(data.month))} />
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

/**
 * Pending SMS charges in one line (WEB-35): the count and sum from the server, and when the last
 * SMS arrived. The rows themselves are at the top of Recent activity with a Pending badge, so the
 * two panels no longer list the same transactions.
 */
function PendingStrip({ overview }: { overview: Overview | undefined }) {
  const summary = overview ? pendingSummary(overview.pending_count, overview.pending_amount) : null;
  return (
    <section aria-labelledby="pending-title" className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 rounded-lg border border-border bg-surface px-5 py-3.5">
      <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
        <span aria-hidden className="relative flex size-2">
          <span className="absolute inline-flex size-full animate-ping rounded-pill bg-accent opacity-50" />
          <span className="relative inline-flex size-2 rounded-pill bg-accent" />
        </span>
        <h2 id="pending-title" className="text-[15px] font-semibold text-ink">Pending from SMS</h2>
        {summary ? (
          <Link to="/activity" search={{ status: "pending" }} className="tap tabular text-[13px] text-muted hover:text-accent hover:underline">
            {summary}
          </Link>
        ) : (
          overview && (
            <span className="text-[13px] text-muted">
              Nothing pending. New card alerts show in Recent activity within seconds.{" "}
              <Link to="/settings" search={{ tab: "sms" }} className="text-accent hover:underline">Set up SMS capture</Link>
            </span>
          )
        )}
      </div>
      {/* Only a loaded overview may claim there has been no SMS (CLAUDE.md §4.3). */}
      {overview && (
        <span className="text-[12px] text-subtle">
          {overview.last_sms_at ? `Last SMS ${formatRelative(overview.last_sms_at)}` : "No SMS received yet"}
        </span>
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
        <EmptyState icon={<Lightbulb />} title="All quiet">Bank Ledger checks your spending every night and notes anything unusual here.</EmptyState>
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
      {overview && overview.accounts.length > 0 && <OwedNow overview={overview} />}
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

function OwedNow({ overview: o }: { overview: Overview }) {
  const caveat = outstandingCaveat(o.outstanding_complete, o.accounts.reduce((n, a) => n + a.balance_unpriced_count, 0));
  return (
    <p className="mb-3 flex flex-wrap items-baseline gap-x-2 gap-y-1 text-sm text-muted">
      <span>Owed now</span>
      <span className="tabular font-medium text-ink">{formatOutstanding(o.outstanding, o.outstanding_has_estimate)}</span>
      {caveat && <span className="text-[12px] text-subtle">{caveat}</span>}
    </p>
  );
}

function AccountCard({ account: a }: { account: OverviewAccount }) {
  const st = a.latest_statement;
  const today = todayDubai();
  const dueIn = st?.due_date ? daysBetween(today, st.due_date) : null;
  // Paid / Part paid / Overdue come from the server (WEB-36); the countdown only from the date.
  const due = st ? dueBadge(st.payment_status, dueIn) : null;
  const paid = st ? paidNote(st.payment_status, st.amount_paid) : null;
  const util = toAmount(a.utilisation);
  return (
    <Card className="flex flex-col gap-4 p-5">
      <div className="flex items-start gap-3">
        <BankLogo bankCode={a.bank_code} />
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium text-ink">{accountLabel(a)}</p>
          <p className="text-[12px] text-subtle">{a.last4 ? a.last4.split(",").map((l) => `•${l}`).join("  ") : "No card yet"}</p>
        </div>
        {due && <Badge tone={due.tone}>{due.label}</Badge>}
      </div>
      <div>
        <p className="text-[12px] text-subtle">Owed now</p>
        <p className="tabular mt-0.5 text-lg font-medium text-ink">{formatOutstanding(a.outstanding_aed, a.balance_has_estimate)}</p>
        <p className="text-[11px] text-subtle">{balanceAnchorNote(a.balance_anchor, a.balance_anchor_date)}</p>
      </div>
      <dl className="grid grid-cols-3 gap-3 text-[12px]">
        <div>
          <dt className="text-subtle">Statement</dt>
          <dd className="tabular mt-0.5 text-sm text-ink">
            {st ? (
              <Link to="/statements/$stmtCode" params={{ stmtCode: st.stmt_code }} className="tap hover:text-accent hover:underline" aria-label={`Statement of ${formatDate(st.statement_date)}: ${formatTotal(st.closing_balance)}`}>
                {formatTotal(st.closing_balance)}
              </Link>
            ) : (
              "—"
            )}
          </dd>
        </div>
        <div>
          <dt className="text-subtle">Due</dt>
          <dd className="mt-0.5 text-sm text-ink">{st?.due_date ? formatDate(st.due_date, "short") : "—"}</dd>
          {st?.min_due && <dd className="tabular text-[11px] text-subtle">min {formatTotal(st.min_due)}</dd>}
          {paid && <dd className="tabular text-[11px] text-subtle">{paid}</dd>}
        </div>
        <div>
          <dt className="text-subtle">Since statement</dt>
          <dd className="tabular mt-0.5 text-sm text-ink">{formatTotal(a.unbilled_aed)}</dd>
        </div>
      </dl>
      <div>
        <div className="mb-1.5 flex justify-between text-[12px]">
          <span className="text-subtle">Utilisation at last statement</span>
          <span className="tabular text-ink-2">
            {util !== null ? formatPercent(util) : "—"}
            {a.credit_limit && <span className="text-subtle"> of {formatTotal(a.credit_limit)}</span>}
          </span>
        </div>
        <Meter value={util} tone={util !== null && util > 0.7 ? "danger" : util !== null && util > 0.3 ? "warn" : "positive"} label="Utilisation" />
      </div>
    </Card>
  );
}

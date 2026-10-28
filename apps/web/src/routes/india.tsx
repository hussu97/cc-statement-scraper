import { Link, useNavigate } from "@tanstack/react-router";
import { IndianRupee } from "lucide-react";
import { indiaRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useIndiaOverview } from "@/data/india";
import { INDIA_PERIODS, indiaPeriodParam } from "@/lib/india";
import { investmentPeriod, type InvestmentPeriod } from "@/lib/investments";
import { Card, PageHeader, Skeleton } from "@/components/ui/display";
import { Segmented } from "@/components/ui/segmented";
import { EmptyState, ErrorState, LoadingBlock } from "@/components/ui/states";
import { IndiaAccountsCard, IndiaChartCard, IndiaReturnsCard, IndiaSummary } from "@/components/india/india-overview";

/** On a ledger without Kite or Coin: India has nothing to show. */
export function NoIndia() {
  return (
    <Card>
      <EmptyState
        icon={<IndianRupee />}
        title="No India accounts in this ledger"
        action={
          <Link to="/wealth" className="text-sm text-accent hover:underline">
            Back to Wealth
          </Link>
        }
      >
        India shows Zerodha Kite and Zerodha Coin. Connect one to this ledger and it appears here, apart from Wealth.
      </EmptyState>
    </Card>
  );
}

/** India mode's overview: Kite and Coin together in INR (AED under it), a period's chart and returns, a row per account. */
export function IndiaOverviewPage() {
  const { profile_code: profileCode } = useActiveProfile();
  // One period for the value chart and the period returns, in the URL (?period=, 90 days when absent).
  const period = investmentPeriod(indiaRoute.useSearch().period);
  const navigate = useNavigate({ from: "/india" });
  const setPeriod = (p: InvestmentPeriod) => void navigate({ search: (s) => ({ ...s, period: indiaPeriodParam(p) }), replace: true, resetScroll: false });
  const q = useIndiaOverview(profileCode, period);
  const o = q.data;

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <PageHeader title="India" description="Zerodha Kite (stocks, ETFs and the Funds cash) and Zerodha Coin (mutual funds), in rupees, apart from Wealth." />
      {q.isLoading ? (
        <div className="flex flex-col gap-6" role="status" aria-label="Loading">
          <div className="flex flex-col gap-3">
            <Skeleton className="h-14 w-64 max-w-full" />
            <Skeleton className="h-4 w-80 max-w-full" />
          </div>
          <Card>
            <LoadingBlock className="h-72" />
          </Card>
        </div>
      ) : q.isError || !o ? (
        <Card>
          <ErrorState title="Couldn't load India" error={q.error} onRetry={() => void q.refetch()} />
        </Card>
      ) : !o.available ? (
        <NoIndia />
      ) : (
        <>
          <IndiaSummary o={o} />
          <section aria-labelledby="india-performance" className="flex flex-col gap-4">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <h2 id="india-performance" className="text-[15px] font-semibold text-ink">
                How they've done
              </h2>
              <Segmented ariaLabel="Period" value={period} onChange={setPeriod} options={[...INDIA_PERIODS]} />
            </div>
            <IndiaChartCard o={o} period={period} stale={q.isPlaceholderData} />
            <IndiaReturnsCard o={o} stale={q.isPlaceholderData} />
          </section>
          {o.accounts.length > 0 && <IndiaAccountsCard o={o} />}
        </>
      )}
    </div>
  );
}

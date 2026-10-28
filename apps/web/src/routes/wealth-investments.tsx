import { useMemo, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { wealthInvestmentsRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useHoldingsValuation, type Holding } from "@/data/holdings";
import { useBrokerAccounts } from "@/data/broker";
import { brokerHoldingCodes } from "@/lib/broker-accounts";
import { INVESTMENT_PERIODS, investmentPeriod, investmentPeriodParam } from "@/lib/investments";
import { PageHeader } from "@/components/ui/display";
import { Segmented } from "@/components/ui/segmented";
import { InvestmentsChartCard, InvestmentsSummary } from "@/components/wealth/investments";
import { HoldingsListCard } from "@/components/wealth/holdings-list";
import { CloseHoldingDialog, HoldingDialog } from "@/components/wealth/holding-dialogs";
import { UpdateValueDialog } from "@/components/wealth/holding-value-dialogs";
import { ReturnsCard } from "@/components/wealth/returns";
import { NotesCard } from "@/components/notes/notes-card";

/** Investments (Wealth mode): metals, plans, broker accounts, shares and funds, deposits; values, gains and returns. */
export function InvestmentsPage() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const q = useHoldingsValuation(profileCode);
  // A synced broker account (Swissquote) is one row; its notes and shares are on its own page.
  const brokers = useBrokerAccounts(profileCode);
  const accounts = useMemo(() => brokers.data ?? [], [brokers.data]);
  const covered = useMemo(() => brokerHoldingCodes(accounts), [accounts]);
  const [editing, setEditing] = useState<{ holding: Holding | null } | null>(null);
  const [closing, setClosing] = useState<Holding | null>(null);
  const [updating, setUpdating] = useState<Holding | null>(null);
  // One period for the value chart and the returns, in the URL (?period=, 90 days when absent).
  const period = investmentPeriod(wealthInvestmentsRoute.useSearch().period);
  const navigate = useNavigate({ from: "/wealth/investments" });
  const setPeriod = (p: typeof period) => void navigate({ search: (s) => ({ ...s, period: investmentPeriodParam(p) }), replace: true, resetScroll: false });

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <PageHeader
        title="Investments"
        description="Gold and silver at Dubai's retail rates, plans, broker accounts, shares, deposits, structured notes and savings accounts: what you put in, how it grew, and the yearly return."
      />
      <InvestmentsSummary q={q} />
      <HoldingsListCard
        q={q}
        isOwner={isOwner}
        onAdd={() => setEditing({ holding: null })}
        actions={{ onEdit: (h) => setEditing({ holding: h }), onClose: setClosing, onUpdateValue: setUpdating }}
        brokers={{ accounts, covered, loading: brokers.isLoading }}
      />
      <NotesCard profileCode={profileCode} covered={covered} coveredLoading={brokers.isLoading} />
      <section aria-labelledby="investments-performance" className="flex flex-col gap-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h2 id="investments-performance" className="text-[15px] font-semibold text-ink">
            How they've done
          </h2>
          <Segmented ariaLabel="Period" value={period} onChange={setPeriod} options={[...INVESTMENT_PERIODS]} />
        </div>
        <InvestmentsChartCard profileCode={profileCode} period={period} />
        <ReturnsCard profileCode={profileCode} period={period} />
      </section>
      {isOwner && <HoldingDialog profileCode={profileCode} open={!!editing} holding={editing?.holding ?? null} onClose={() => setEditing(null)} />}
      {isOwner && <CloseHoldingDialog profileCode={profileCode} holding={closing} onClose={() => setClosing(null)} />}
      {isOwner && <UpdateValueDialog profileCode={profileCode} holding={updating} onClose={() => setUpdating(null)} />}
    </div>
  );
}

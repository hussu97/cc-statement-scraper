import { useState } from "react";
import { useActiveProfile } from "@/data/profile";
import { useHoldingsValuation, type Holding } from "@/data/holdings";
import { PageHeader } from "@/components/ui/display";
import { InvestmentsChartCard, InvestmentsSummary, PriceStrip } from "@/components/wealth/investments";
import { HoldingsListCard } from "@/components/wealth/holdings-list";
import { CloseHoldingDialog, HoldingDialog } from "@/components/wealth/holding-dialogs";

/** Investments (Wealth mode): gold and silver for now, valued at Dubai retail rates, with gains. */
export function InvestmentsPage() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const q = useHoldingsValuation(profileCode);
  const [editing, setEditing] = useState<{ holding: Holding | null } | null>(null);
  const [closing, setClosing] = useState<Holding | null>(null);

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <PageHeader title="Investments" description="Your gold and silver, valued at Dubai's retail rates, with the gain on what you paid." />
      <InvestmentsSummary q={q} />
      <PriceStrip q={q} />
      <InvestmentsChartCard profileCode={profileCode} />
      <HoldingsListCard
        q={q}
        isOwner={isOwner}
        onAdd={() => setEditing({ holding: null })}
        onEdit={(h) => setEditing({ holding: h })}
        onClose={setClosing}
      />
      {isOwner && <HoldingDialog profileCode={profileCode} open={!!editing} holding={editing?.holding ?? null} onClose={() => setEditing(null)} />}
      {isOwner && <CloseHoldingDialog profileCode={profileCode} holding={closing} onClose={() => setClosing(null)} />}
    </div>
  );
}

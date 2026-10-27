import { useState } from "react";
import { useActiveProfile } from "@/data/profile";
import { useHoldingsValuation, type Holding } from "@/data/holdings";
import { kindOf } from "@/lib/investments";
import { PageHeader } from "@/components/ui/display";
import { InvestmentsChartCard, InvestmentsSummary, PriceStrip } from "@/components/wealth/investments";
import { HoldingsListCard } from "@/components/wealth/holdings-list";
import { CloseHoldingDialog, HoldingDialog } from "@/components/wealth/holding-dialogs";
import { UpdateValueDialog } from "@/components/wealth/holding-value-dialogs";
import { ReturnsCard } from "@/components/wealth/returns";
import { NotesCard } from "@/components/notes/notes-card";
import { AddNoteDialog } from "@/components/notes/add-note-dialog";

/** Investments (Wealth mode): metals, plans, broker accounts, shares and funds, deposits; values, gains and returns. */
export function InvestmentsPage() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const q = useHoldingsValuation(profileCode);
  const [editing, setEditing] = useState<{ holding: Holding | null } | null>(null);
  const [closing, setClosing] = useState<Holding | null>(null);
  const [updating, setUpdating] = useState<Holding | null>(null);
  const [addingNote, setAddingNote] = useState(false);
  // Metal prices matter once there is gold or silver (or nothing yet, to show what's offered).
  const showPrices = !q.data || q.data.holdings.length === 0 || q.data.holdings.some((h) => kindOf(h) === "metal");

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <PageHeader
        title="Investments"
        description="Gold and silver at Dubai's retail rates, plans, broker accounts, shares, deposits and structured notes: what you put in, how it grew, and the yearly return."
      />
      <InvestmentsSummary q={q} />
      <HoldingsListCard
        q={q}
        isOwner={isOwner}
        onAdd={() => setEditing({ holding: null })}
        actions={{ onEdit: (h) => setEditing({ holding: h }), onClose: setClosing, onUpdateValue: setUpdating }}
      />
      <NotesCard profileCode={profileCode} isOwner={isOwner} onAdd={() => setAddingNote(true)} />
      <ReturnsCard profileCode={profileCode} />
      <InvestmentsChartCard profileCode={profileCode} />
      {showPrices && <PriceStrip q={q} />}
      {isOwner && <HoldingDialog profileCode={profileCode} open={!!editing} holding={editing?.holding ?? null} onClose={() => setEditing(null)} />}
      {isOwner && <CloseHoldingDialog profileCode={profileCode} holding={closing} onClose={() => setClosing(null)} />}
      {isOwner && <UpdateValueDialog profileCode={profileCode} holding={updating} onClose={() => setUpdating(null)} />}
      {isOwner && <AddNoteDialog profileCode={profileCode} open={addingNote} onClose={() => setAddingNote(false)} />}
    </div>
  );
}

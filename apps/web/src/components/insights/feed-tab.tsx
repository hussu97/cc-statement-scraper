import { useMemo } from "react";
import { Lightbulb } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { groupInsights, INSIGHTS_LIMIT, isWealthInsight, useDismissInsight, useInsights } from "@/data/overview";
import { formatCount } from "@/lib/money";
import { Card, CardHeader } from "@/components/ui/display";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { InsightCard } from "./insight-card";

/**
 * "Worth a look" (MA-5): every open server insight, in sections by the screen that answers it,
 * each linking there. Owners can dismiss one; it leaves the feed and the Overview panel at once.
 */
export function FeedTab({ profileCode }: { profileCode: string }) {
  const { isOwner } = useActiveProfile();
  const q = useInsights(profileCode);
  const dismiss = useDismissInsight(profileCode);
  // Bank balance and income insights live on the Wealth overview.
  const groups = useMemo(() => groupInsights((q.data ?? []).filter((i) => !isWealthInsight(i))), [q.data]);

  if (q.isLoading) return <Card><LoadingRows rows={4} /></Card>;
  if (q.isError) return <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>;
  if (groups.length === 0) {
    return (
      <Card>
        <EmptyState icon={<Lightbulb />} title="All quiet">
          Bank Ledger checks your spending every night: pace, category spikes, large charges, budgets, price changes, statements due and anything left to tidy up. Whatever needs a look appears here.
        </EmptyState>
      </Card>
    );
  }
  const total = q.data?.length ?? 0;
  return (
    <div className="flex flex-col gap-6">
      {groups.map((g) => (
        <Card key={g.key} aria-labelledby={`feed-${g.key}`}>
          <CardHeader title={<span id={`feed-${g.key}`}>{g.label}</span>} eyebrow={`${formatCount(g.items.length)} to look at`} />
          <ul className="grid gap-2 px-5 pb-5 lg:grid-cols-2">
            {g.items.map((i) => (
              <InsightCard key={i.insight_code} insight={i} showAge onDismiss={isOwner ? () => dismiss.mutate(i.insight_code) : undefined} />
            ))}
          </ul>
        </Card>
      ))}
      {total >= INSIGHTS_LIMIT && <p className="text-[12px] text-subtle">Showing the newest {formatCount(INSIGHTS_LIMIT)} insights.</p>}
    </div>
  );
}

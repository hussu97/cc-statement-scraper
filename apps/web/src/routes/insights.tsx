import { useNavigate } from "@tanstack/react-router";
import { insightsRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { insightsRange, withInsightsRange } from "@/lib/search";
import { PageHeader } from "@/components/ui/display";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/primitives";
import { RangeControl } from "@/components/insights/range-control";
import { INSIGHT_TABS, resolveTab, type InsightTab } from "@/components/insights/labels";
import { TrendsTab } from "@/components/insights/trends-tab";
import { CategoriesTab } from "@/components/insights/categories-tab";
import { MerchantsTab } from "@/components/insights/merchants-tab";
import { SubscriptionsTab } from "@/components/insights/subscriptions-tab";
import { FxTab } from "@/components/insights/fx-tab";
import { CalendarTab } from "@/components/insights/calendar-tab";
import { TimeOfDayTab } from "@/components/insights/time-tab";
import { YoyTab } from "@/components/insights/yoy-tab";
import { AnomaliesTab } from "@/components/insights/anomalies-tab";
import { FeedTab } from "@/components/insights/feed-tab";
import { isWealthInsight, useInsights } from "@/data/overview";
import { formatBadgeCount } from "@/lib/money";

/** Tabs that ignore the date range (they have their own period, or none). */
const RANGELESS: InsightTab[] = ["feed", "subscriptions", "yoy"];

export function InsightsPage() {
  const { profile_code: profileCode } = useActiveProfile();
  const search = insightsRoute.useSearch();
  const navigate = useNavigate({ from: "/insights" });
  const tab = resolveTab(search.tab);
  const { from, to } = insightsRange(search);
  const range = { from, to };
  const props = { profileCode, range };
  // The feed tab's count; the same cached query as Overview's insights panel.
  const insights = useInsights(profileCode);
  const open = insights.data?.filter((i) => !isWealthInsight(i)).length ?? 0;

  return (
    <div className="animate-fade-in">
      <PageHeader
        title="Insights"
        description="Where your money goes, and how that changes over time."
        actions={
          RANGELESS.includes(tab) ? undefined : (
            <RangeControl search={search} onChange={(r) => void navigate({ search: (s) => withInsightsRange(s, r), replace: true })} />
          )
        }
      />
      <Tabs
        value={tab}
        onValueChange={(v) => void navigate({ search: (s) => ({ ...s, tab: v === "trends" ? undefined : v }), replace: true })}
      >
        <TabsList aria-label="Insights">
          {INSIGHT_TABS.map((t) => (
            <TabsTrigger key={t.value} value={t.value}>
              {t.label}
              {t.value === "feed" && open > 0 && (
                <>
                  <span aria-hidden className="tabular ml-1.5 rounded-pill bg-accent-soft px-1.5 text-[11px] leading-[18px] font-medium text-accent">
                    {formatBadgeCount(open)}
                  </span>
                  <span className="sr-only">, {open} open</span>
                </>
              )}
            </TabsTrigger>
          ))}
        </TabsList>
        {/* Radix unmounts inactive tabs, so only the active tab's queries run. */}
        <div className="pt-5">
          <TabsContent value="trends">
            <TrendsTab {...props} />
          </TabsContent>
          <TabsContent value="feed">
            <FeedTab profileCode={profileCode} />
          </TabsContent>
          <TabsContent value="categories">
            <CategoriesTab {...props} />
          </TabsContent>
          <TabsContent value="merchants">
            <MerchantsTab {...props} />
          </TabsContent>
          <TabsContent value="subscriptions">
            <SubscriptionsTab profileCode={profileCode} />
          </TabsContent>
          <TabsContent value="fx">
            <FxTab {...props} />
          </TabsContent>
          <TabsContent value="calendar">
            <CalendarTab {...props} />
          </TabsContent>
          <TabsContent value="time">
            <TimeOfDayTab {...props} />
          </TabsContent>
          <TabsContent value="yoy">
            <YoyTab profileCode={profileCode} />
          </TabsContent>
          <TabsContent value="anomalies">
            <AnomaliesTab {...props} />
          </TabsContent>
        </div>
      </Tabs>
    </div>
  );
}

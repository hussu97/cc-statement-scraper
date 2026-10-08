import { useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { insightsRoute } from "@/router";
import { RANGE_PRESETS, isISODate, type RangePreset } from "@/lib/dates";
import { insightsRange, withInsightsRange } from "@/lib/search";
import { Select } from "@/components/ui/select";
import { Input } from "@/components/ui/input";

const CUSTOM = "custom";

/** Date-range picker for Insights: presets, or a custom from/to in the URL. */
export function RangeControl() {
  const search = insightsRoute.useSearch();
  const navigate = useNavigate({ from: "/insights" });
  const range = insightsRange(search);
  const [customOpen, setCustomOpen] = useState(false);
  const showCustom = customOpen || (!!search.from && range.preset === null);
  const value = showCustom ? CUSTOM : (range.preset ?? CUSTOM);

  const setCustom = (from: string, to: string) => {
    if (!isISODate(from) || !isISODate(to) || from > to) return;
    void navigate({ search: (s) => withInsightsRange(s, { from, to }), replace: true });
  };

  return (
    <div className="flex flex-wrap items-center gap-2">
      {showCustom && (
        <div className="flex items-center gap-1.5">
          <Input
            type="date"
            aria-label="From"
            className="h-8 w-[9.5rem] text-[13px]"
            value={range.from}
            max={range.to}
            onChange={(e) => setCustom(e.target.value, range.to)}
          />
          <span className="text-[13px] text-subtle" aria-hidden>
            –
          </span>
          <Input
            type="date"
            aria-label="To"
            className="h-8 w-[9.5rem] text-[13px]"
            value={range.to}
            min={range.from}
            onChange={(e) => setCustom(range.from, e.target.value)}
          />
        </div>
      )}
      <Select
        size="sm"
        ariaLabel="Date range"
        className="min-w-40"
        value={value}
        onValueChange={(v) => {
          if (v === CUSTOM) {
            setCustomOpen(true);
            return;
          }
          setCustomOpen(false);
          void navigate({ search: (s) => withInsightsRange(s, { range: v as RangePreset }), replace: true });
        }}
        options={[...RANGE_PRESETS, { value: CUSTOM, label: "Custom range" }]}
      />
    </div>
  );
}

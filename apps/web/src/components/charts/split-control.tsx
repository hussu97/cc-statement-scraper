import { Segmented } from "@/components/ui/primitives";
import { SPLIT_LABEL, SPLITS, type SpendSplit } from "./spend-split";

/** The split control: none / category / bank / merchant. Its own module, so it doesn't load the chart library (WEB-53). */
export function SplitControl({ value, onChange, className }: { value: SpendSplit; onChange: (s: SpendSplit) => void; className?: string }) {
  return <Segmented ariaLabel="Split bars by" value={value} onChange={onChange} options={SPLITS.map((s) => ({ value: s, label: SPLIT_LABEL[s] }))} className={className} />;
}

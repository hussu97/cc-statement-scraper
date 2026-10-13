import type { ReactNode } from "react";
import type { TooltipContentProps } from "recharts";
import type { NameType, ValueType } from "recharts/types/component/DefaultTooltipContent";
import { formatMoney, formatTotal } from "@/lib/money";

/** Shared axis/grid styling: token colours only. */
export const AXIS_TICK = { fill: "var(--chart-axis)", fontSize: 11 } as const;
export const GRID_STROKE = "var(--chart-grid)";
/** Hover band behind the active bar group. */
export const CURSOR_FILL = { fill: "var(--color-surface-2)", opacity: 0.6 } as const;

/** Axis tick: compact money, without the currency code. */
export function axisMoney(v: number): string {
  return formatMoney(v, { compact: true, bare: true });
}

interface Row {
  key: string;
  label: ReactNode;
  color: string;
  value: number | string | null | undefined;
}

/** The tooltip card itself, usable outside Recharts too. */
export function TooltipCard({ title, rows, footer }: { title: ReactNode; rows: Row[]; footer?: ReactNode }) {
  return (
    <div className="min-w-44 rounded-md border border-border bg-surface px-3 py-2 text-[12px] shadow-[0_8px_24px_-12px_var(--color-border-strong)]">
      <p className="mb-1.5 font-medium text-ink">{title}</p>
      <ul className="flex flex-col gap-1">
        {rows.map((r) => (
          <li key={r.key} className="flex items-center gap-2">
            <span aria-hidden className="inline-block size-2 shrink-0 rounded-pill" style={{ background: r.color }} />
            <span className="flex-1 truncate text-ink-2">{r.label}</span>
            <span className="tabular text-ink">{formatTotal(r.value)}</span>
          </li>
        ))}
      </ul>
      {footer && <div className="mt-1.5 border-t border-border pt-1.5 text-muted">{footer}</div>}
    </div>
  );
}

/**
 * Recharts tooltip content in Bank Ledger's style. Series with no value in the
 * hovered bucket are skipped; the order follows the stack (top first).
 */
export function MoneyTooltip({
  active,
  payload,
  label,
  formatLabel,
  nameOf,
}: Partial<TooltipContentProps<ValueType, NameType>> & {
  formatLabel?: (label: string) => ReactNode;
  nameOf?: (dataKey: string) => ReactNode;
}) {
  if (!active || !payload || payload.length === 0) return null;
  const rows: Row[] = payload
    .filter((p) => p.value !== undefined && p.value !== null && Number(p.value) !== 0)
    .map((p) => {
      const key = String(p.dataKey ?? p.name ?? "");
      return {
        key,
        label: nameOf ? nameOf(key) : String(p.name ?? key),
        color: String(p.color ?? p.fill ?? "var(--chart-uncategorized)"),
        value: p.value as number,
      };
    })
    .reverse();
  if (rows.length === 0) return null;
  return <TooltipCard title={formatLabel ? formatLabel(String(label ?? "")) : String(label ?? "")} rows={rows} />;
}

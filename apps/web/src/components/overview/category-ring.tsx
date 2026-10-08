import { Cell, Pie, PieChart, ResponsiveContainer } from "recharts";
import { Link } from "@tanstack/react-router";
import { categoryVar } from "@ledger/tokens/chart";
import { displayRatio, formatMoney, formatPercent, toAmount, type MoneyInput } from "@/lib/money";
import { Dot } from "@/components/ui/display";
import type { OverviewCategory } from "@/data/overview";

export function CategoryRing({ categories, total, from, to }: { categories: OverviewCategory[]; total: MoneyInput; from: string; to: string }) {
  const data = categories
    .map((c) => ({ ...c, value: toAmount(c.amount) ?? 0 }))
    .filter((c) => c.value > 0);
  return (
    <div className="grid grid-cols-1 items-center gap-6 sm:grid-cols-[180px_1fr]">
      <div className="relative mx-auto size-[180px]">
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie data={data} dataKey="value" nameKey="name" innerRadius={62} outerRadius={86} paddingAngle={1.5} stroke="none" isAnimationActive={false}>
              {data.map((c) => (
                <Cell key={c.category_code ?? "none"} fill={categoryVar(c.color_token)} />
              ))}
            </Pie>
          </PieChart>
        </ResponsiveContainer>
        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-[11px] text-subtle">Top {data.length}</span>
          <span className="display-num text-lg text-ink">{formatMoney(total, { compact: true })}</span>
        </div>
      </div>
      <ul className="flex flex-col">
        {data.map((c) => (
          <li key={c.category_code ?? "none"}>
            <Link
              to="/activity"
              search={{ category: c.category_code ?? "none", from, to }}
              className="-mx-2 grid grid-cols-[auto_1fr_auto_auto] items-center gap-3 rounded-sm px-2 py-1.5 text-[13px] hover:bg-surface-2"
            >
              <Dot token={c.color_token} />
              <span className="truncate text-ink">{c.name ?? "Uncategorised"}</span>
              <span className="tabular text-subtle">{formatPercent(displayRatio(c.amount, total))}</span>
              <span className="tabular w-24 text-right text-ink">{formatMoney(c.amount, { whole: true })}</span>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}

import { MoreHorizontal, Pencil, Trash2 } from "lucide-react";
import { budgetTone, type BudgetStatusRow } from "@/data/budgets";
import { formatMoney, formatPercent, toAmount } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Money } from "@/components/ledger";
import { Badge, Card, Dot, Meter } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Menu, MenuContent, MenuItem, MenuTrigger } from "@/components/ui/primitives";

const TONE_TEXT = { positive: "text-positive", warn: "text-warn", danger: "text-danger" } as const;

export function BudgetCard({
  row,
  phase,
  canEdit,
  onEdit,
  onDelete,
  hero,
}: {
  row: BudgetStatusRow;
  phase: "past" | "current" | "future";
  canEdit: boolean;
  onEdit: () => void;
  onDelete: () => void;
  hero?: boolean;
}) {
  const tone = budgetTone(row, phase === "current");
  const share = toAmount(row.share_used) ?? 0;
  const projected = toAmount(row.projected_aed);
  const budget = toAmount(row.budget_aed);
  const overPace = phase === "current" && projected !== null && budget !== null && projected > budget;
  const isTotal = row.category_code === null;

  return (
    <Card className={cn("flex flex-col gap-4 p-5", hero && "md:p-6")}>
      <header className="flex items-start justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2">
          {isTotal ? <span aria-hidden className="inline-block size-2 shrink-0 rounded-pill bg-ink" /> : <Dot token={row.color_token} className="size-2.5" />}
          <h2 className={cn("truncate font-medium text-ink", hero ? "text-[15px]" : "text-sm")}>{row.category_name}</h2>
          {share > 1 && <Badge tone="danger">Over</Badge>}
        </div>
        {canEdit && (
          <Menu modal={false}>
            <MenuTrigger asChild>
              <Button variant="ghost" size="icon-sm" aria-label={`Actions for ${row.category_name}`} icon={<MoreHorizontal className="size-4" />} />
            </MenuTrigger>
            <MenuContent>
              <MenuItem onSelect={onEdit}>
                <Pencil className="size-3.5" aria-hidden /> Edit
              </MenuItem>
              <MenuItem tone="danger" onSelect={onDelete}>
                <Trash2 className="size-3.5" aria-hidden /> Delete
              </MenuItem>
            </MenuContent>
          </Menu>
        )}
      </header>

      <div>
        <p className="flex flex-wrap items-baseline gap-x-2">
          {hero ? (
            <span className="inline-flex items-baseline gap-1.5">
              <span className="text-[13px] font-medium tracking-wide text-muted">AED</span>
              <span className="display-num text-[34px] leading-none text-ink md:text-[40px]">{formatMoney(row.spent_aed, { bare: true })}</span>
            </span>
          ) : (
            <Money value={row.spent_aed} className="text-xl font-medium text-ink" />
          )}
          <span className="text-[13px] text-muted">
            of <Money value={row.budget_aed} />
          </span>
        </p>
        <Meter value={share} tone={tone} className={cn("mt-3", hero && "h-2")} label={`${formatPercent(share)} of ${row.category_name} budget used`} />
      </div>

      <footer className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-[12px]">
        <span className={cn("tabular font-medium", TONE_TEXT[tone])}>{formatPercent(share)} used</span>
        {phase === "current" ? (
          <span className={cn("text-muted", overPace && "text-warn")}>
            On pace for <span className="tabular">{formatMoney(row.projected_aed)}</span>
          </span>
        ) : phase === "past" ? (
          <span className="text-muted">Month closed</span>
        ) : (
          <span className="text-muted">Month not started</span>
        )}
      </footer>
    </Card>
  );
}

import { ArrowDownLeft, ArrowUpRight, ChevronRight } from "lucide-react";
import type { FilterMeta } from "@/data/overview";
import { lineAmount, lineTitle, type StatementLine, type StatementSide } from "@/data/statements";
import { formatDate } from "@/lib/dates";
import { formatCount, formatMoney } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, Dot } from "@/components/ui/display";
import { EmptyState } from "@/components/ui/states";
import { TxnAmount } from "@/components/ledger";

type Category = FilterMeta["categories"][number];

const COPY = {
  debit: { title: "Debits", icon: <ArrowUpRight />, empty: "No purchases, fees or interest on this statement." },
  credit: { title: "Credits", icon: <ArrowDownLeft />, empty: "No payments or refunds on this statement." },
} as const;

/** One side of a statement (debits or credits): count, total, then each line. */
export function StatementLines({
  side,
  data,
  categories,
  showCard,
  onOpen,
}: {
  side: "debit" | "credit";
  data: StatementSide;
  categories: Map<string, Category>;
  /** Show each line's card when the statement covers more than one. */
  showCard: boolean;
  onOpen: (txnCode: string) => void;
}) {
  const copy = COPY[side];
  const id = `stmt-${side}s`;
  return (
    <Card aria-labelledby={id} className="overflow-hidden">
      <header className="flex items-end justify-between gap-3 border-b border-border px-4 pt-4 pb-3 md:px-5">
        <div className="min-w-0">
          <h2 id={id} className="flex items-center gap-2 text-[15px] font-semibold text-ink">
            <span aria-hidden className={cn("flex size-6 items-center justify-center rounded-pill [&_svg]:size-3.5", side === "credit" ? "bg-positive-soft text-positive" : "bg-surface-2 text-ink-2")}>
              {copy.icon}
            </span>
            {copy.title}
          </h2>
          <p className="mt-0.5 text-[12px] text-muted">
            {formatCount(data.count)} {data.count === 1 ? "line" : "lines"}
          </p>
        </div>
        <p className={cn("tabular text-[17px] font-medium", side === "credit" ? "text-positive" : "text-ink")}>
          {side === "credit" ? formatMoney(data.total, { signed: true }) : formatMoney(data.total)}
        </p>
      </header>
      {data.lines.length === 0 ? (
        <EmptyState title={`No ${copy.title.toLowerCase()}`} className="py-8">
          {copy.empty}
        </EmptyState>
      ) : (
        <ul className="divide-y divide-border">
          {data.lines.map((l) => (
            <LineRow key={l.line_code} line={l} side={side} category={l.category_code ? categories.get(l.category_code) : undefined} showCard={showCard} onOpen={onOpen} />
          ))}
        </ul>
      )}
    </Card>
  );
}

function LineRow({ line, side, category, showCard, onOpen }: { line: StatementLine; side: "debit" | "credit"; category: Category | undefined; showCard: boolean; onOpen: (txnCode: string) => void }) {
  const title = lineTitle(line);
  const body = (
    <>
      <span className="tabular w-11 shrink-0 pt-0.5 text-[12px] leading-tight text-muted">
        {formatDate(line.txn_date, "short")}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-sm text-ink">{title}</span>
        {line.merchant_name && line.merchant_name !== line.description && (
          <span className="block truncate font-mono text-[11px] text-subtle">{line.description}</span>
        )}
        <span className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[12px] text-muted">
          {category ? (
            <span className="inline-flex min-w-0 items-center gap-1">
              <Dot token={category.color_token} />
              <span className="truncate">{category.name}</span>
            </span>
          ) : line.txn_code ? (
            <span className="inline-flex items-center gap-1 italic text-subtle">
              <Dot token={null} />
              Uncategorised
            </span>
          ) : null}
          {line.kind && line.kind !== "purchase" && line.kind !== "payment" && <span>{line.kind.replace(/_/g, " ")}</span>}
          {showCard && line.card_last4 && <span className="tabular">•{line.card_last4}</span>}
          {!line.txn_code && <Badge tone="warn">In Review</Badge>}
        </span>
      </span>
      <span className="flex shrink-0 items-start gap-1">
        <TxnAmount t={lineAmount(line, side)} className="text-sm" />
        {line.txn_code && <ChevronRight aria-hidden className="mt-0.5 size-4 text-subtle" />}
      </span>
    </>
  );
  return (
    <li>
      {line.txn_code ? (
        <button
          type="button"
          data-txn-open={line.txn_code}
          onClick={() => onOpen(line.txn_code!)}
          className="flex w-full items-start gap-3 px-4 py-2.5 text-left transition-colors hover:bg-surface-2/60 md:px-5"
        >
          {body}
        </button>
      ) : (
        <div className="flex items-start gap-3 px-4 py-2.5 md:px-5">{body}</div>
      )}
    </li>
  );
}

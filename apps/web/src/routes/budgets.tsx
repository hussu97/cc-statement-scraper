import { useMemo, useState } from "react";
import { ChevronLeft, ChevronRight, Plus, Target } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { budgetAppliesTo, monthPhase, useBudgetStatus, useBudgets, useDeleteBudget, type BudgetInput } from "@/data/budgets";
import { useCategories } from "@/data/rules";
import { errorMessage } from "@/data/api";
import { addMonths, formatMonth, monthStart, todayDubai } from "@/lib/dates";
import { PageHeader, Card, Dot, Badge } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { EmptyState, LoadingBlock, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { Money } from "@/components/ledger";
import { BudgetCard } from "@/components/budgets/budget-card";
import { BudgetDialog } from "@/components/budgets/budget-dialog";

type Budget = NonNullable<ReturnType<typeof useBudgets>["data"]>[number];

function toDraft(b: Budget): BudgetInput {
  return {
    budget_code: b.budget_code,
    category_code: b.category_code,
    amount_aed: String(b.amount_aed),
    effective_from: b.effective_from,
    effective_to: b.effective_to,
  };
}

export function BudgetsPage() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const today = todayDubai();
  const thisMonth = monthStart(today);
  const [month, setMonth] = useState(thisMonth);
  const phase = monthPhase(month, today);

  const status = useBudgetStatus(profileCode, month);
  const budgets = useBudgets(profileCode);
  const cats = useCategories(profileCode);
  const del = useDeleteBudget(profileCode);
  const toast = useToast();

  const [editing, setEditing] = useState<BudgetInput | null>(null);
  const [deleting, setDeleting] = useState<{ code: string; name: string } | null>(null);

  const byCode = useMemo(() => new Map((budgets.data ?? []).map((b) => [b.budget_code, b])), [budgets.data]);
  const catOf = useMemo(() => new Map((cats.data ?? []).map((c) => [c.category_code, c])), [cats.data]);
  const shown = useMemo(() => new Set((status.data ?? []).map((r) => r.budget_code)), [status.data]);
  const others = useMemo(() => (budgets.data ?? []).filter((b) => !shown.has(b.budget_code)), [budgets.data, shown]);

  const newDraft = (): BudgetInput => ({ category_code: null, amount_aed: "", effective_from: phase === "past" ? thisMonth : month, effective_to: null });
  const edit = (code: string) => {
    const b = byCode.get(code);
    if (b) setEditing(toDraft(b));
  };
  const nameOf = (b: Budget) => (b.category_code ? (catOf.get(b.category_code)?.name ?? "Category") : "All spending");

  return (
    <div className="animate-fade-in">
      <PageHeader
        title="Budgets"
        description="Monthly limits, and how each month is tracking against them."
        actions={
          isOwner && (
            <Button variant="primary" icon={<Plus className="size-4" />} onClick={() => setEditing(newDraft())}>
              New budget
            </Button>
          )
        }
      />

      <div className="mb-5 flex flex-wrap items-center gap-2">
        <Button variant="secondary" size="icon-sm" aria-label="Previous month" icon={<ChevronLeft className="size-4" />} onClick={() => setMonth(addMonths(month, -1))} />
        <h2 className="min-w-36 text-center text-[15px] font-medium text-ink tabular" aria-live="polite">
          {formatMonth(month)}
        </h2>
        <Button variant="secondary" size="icon-sm" aria-label="Next month" icon={<ChevronRight className="size-4" />} onClick={() => setMonth(addMonths(month, 1))} />
        {month !== thisMonth && (
          <Button variant="ghost" size="sm" onClick={() => setMonth(thisMonth)}>
            This month
          </Button>
        )}
      </div>

      <QueryView
        query={status}
        loading={
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            <LoadingBlock className="h-44 p-0 md:col-span-2 xl:col-span-3" />
            <LoadingBlock className="h-40 p-0" />
            <LoadingBlock className="h-40 p-0" />
          </div>
        }
        isEmpty={(rows) => rows.length === 0}
        empty={
          <Card>
            {budgets.data && budgets.data.length === 0 ? (
              <EmptyState
                icon={<Target />}
                title="No budgets yet"
                action={
                  isOwner && (
                    <Button variant="primary" icon={<Plus className="size-4" />} onClick={() => setEditing(newDraft())}>
                      Create a budget
                    </Button>
                  )
                }
              >
                Set a monthly limit for all spending or for a category, and Bank Ledger will track it as the month goes.
              </EmptyState>
            ) : (
              <EmptyState icon={<Target />} title={`No budgets apply to ${formatMonth(month)}`}>
                {budgets.isLoading ? "Checking your budgets…" : "Your budgets start later or ended earlier. They're listed below."}
              </EmptyState>
            )}
          </Card>
        }
      >
        {(rows) => (
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            {rows.map((r) => (
              <div key={r.budget_code} className={r.category_code === null ? "md:col-span-2 xl:col-span-3" : undefined}>
                <BudgetCard
                  row={r}
                  phase={phase}
                  hero={r.category_code === null}
                  canEdit={isOwner && byCode.has(r.budget_code)}
                  onEdit={() => edit(r.budget_code)}
                  onDelete={() => setDeleting({ code: r.budget_code, name: r.category_name })}
                />
              </div>
            ))}
          </div>
        )}
      </QueryView>

      {others.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-2 text-[11px] font-medium tracking-[0.08em] text-subtle uppercase">Not active in {formatMonth(month)}</h2>
          <Card>
            <ul className="divide-y divide-border">
              {others.map((b) => {
                const cat = b.category_code ? catOf.get(b.category_code) : null;
                const when =
                  b.effective_from > month
                    ? `Starts ${formatMonth(b.effective_from)}`
                    : b.effective_to && b.effective_to < month
                      ? `Ended ${formatMonth(b.effective_to)}`
                      : budgetAppliesTo(b, month)
                        ? "Replaced by a newer budget"
                        : "";
                return (
                  <li key={b.budget_code} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-5 py-3">
                    {b.category_code ? <Dot token={cat?.color_token} /> : <span aria-hidden className="inline-block size-2 rounded-pill bg-ink" />}
                    <span className="min-w-0 flex-1 truncate text-sm text-ink">{nameOf(b)}</span>
                    <Badge>{when}</Badge>
                    <Money value={b.amount_aed} className="text-sm text-ink-2" />
                    {isOwner && (
                      <span className="flex gap-1">
                        <Button variant="ghost" size="sm" onClick={() => setEditing(toDraft(b))}>
                          Edit
                        </Button>
                        <Button variant="ghost" size="sm" className="text-danger" onClick={() => setDeleting({ code: b.budget_code, name: nameOf(b) })}>
                          Delete
                        </Button>
                      </span>
                    )}
                  </li>
                );
              })}
            </ul>
          </Card>
        </section>
      )}

      {isOwner && (
        <BudgetDialog
          open={editing !== null}
          onOpenChange={(o) => !o && setEditing(null)}
          profileCode={profileCode}
          initial={editing ?? newDraft()}
        />
      )}

      <Dialog
        open={deleting !== null}
        onOpenChange={(o) => !o && setDeleting(null)}
        title="Delete this budget?"
        description={deleting ? `The ${deleting.name} budget goes away for every month it covered. Your transactions aren't affected.` : undefined}
        footer={
          <>
            <Button variant="ghost" onClick={() => setDeleting(null)}>
              Keep it
            </Button>
            <Button
              variant="danger"
              loading={del.isPending}
              onClick={() =>
                deleting &&
                del.mutate(deleting.code, {
                  onSuccess: () => {
                    toast({ title: "Budget deleted" });
                    setDeleting(null);
                  },
                  onError: (e) => toast({ title: "Couldn't delete the budget", description: errorMessage(e), tone: "danger" }),
                })
              }
            >
              Delete budget
            </Button>
          </>
        }
      >
        <p className="text-sm text-ink-2">This can't be undone, but you can create it again at any time.</p>
      </Dialog>
    </div>
  );
}

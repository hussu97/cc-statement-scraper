import { useMemo, useState } from "react";
import { ChevronLeft, ChevronRight, Plus, Target } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import {
  budgetDraft,
  budgetTitle,
  inactiveBudgetLabel,
  monthPhase,
  splitByEffective,
  useBudgetStatus,
  useDeleteBudget,
  type BudgetInput,
  type BudgetStatusRow,
} from "@/data/budgets";
import { BankLogo } from "@/components/bank-logo";
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

export function BudgetsPage() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const today = todayDubai();
  const thisMonth = monthStart(today);
  const [month, setMonth] = useState(thisMonth);
  const phase = monthPhase(month, today);

  // One request: every budget of the ledger, with the server's word on which ones count this
  // month. Names, colours and card logos come on the rows, so nothing else has to load.
  const status = useBudgetStatus(profileCode, month);
  const del = useDeleteBudget(profileCode);
  const toast = useToast();

  const [editing, setEditing] = useState<BudgetInput | null>(null);
  const [deleting, setDeleting] = useState<{ code: string; name: string } | null>(null);

  const split = useMemo(() => splitByEffective(status.data ?? []), [status.data]);

  const newDraft = (): BudgetInput => ({ account_code: null, category_code: null, amount_aed: "", effective_from: phase === "past" ? thisMonth : month, effective_to: null });
  const edit = (r: BudgetStatusRow) => setEditing(budgetDraft(r));

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

      {/* A failed load shows QueryView's error state with a retry, never an empty state. */}
      <QueryView
        query={status}
        loading={
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            <LoadingBlock className="h-44 p-0 md:col-span-2 xl:col-span-3" />
            <LoadingBlock className="h-40 p-0" />
            <LoadingBlock className="h-40 p-0" />
          </div>
        }
        isEmpty={(rows) => splitByEffective(rows).effective.length === 0}
        empty={
          <Card>
            {split.inactive.length === 0 ? (
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
                Set a monthly limit for all spending or for a category, on every card or just one, and Bank Ledger will track it as the month goes.
              </EmptyState>
            ) : (
              <EmptyState icon={<Target />} title={`No budgets apply to ${formatMonth(month)}`}>
                Your budgets start later or ended earlier. They're listed below.
              </EmptyState>
            )}
          </Card>
        }
      >
        {(rows) => (
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            {splitByEffective(rows).effective.map((r) => (
              <div key={r.budget_code} className={r.category_code === null && r.account_code === null ? "md:col-span-2 xl:col-span-3" : undefined}>
                <BudgetCard
                  row={r}
                  phase={phase}
                  hero={r.category_code === null && r.account_code === null}
                  canEdit={isOwner}
                  onEdit={() => edit(r)}
                  onDelete={() => setDeleting({ code: r.budget_code, name: budgetTitle(r) })}
                />
              </div>
            ))}
          </div>
        )}
      </QueryView>

      {status.isSuccess && split.inactive.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-2 text-[11px] font-medium tracking-[0.08em] text-subtle uppercase">Not active in {formatMonth(month)}</h2>
          <Card>
            <ul className="divide-y divide-border">
              {split.inactive.map((b) => (
                <li key={b.budget_code} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-5 py-3">
                  {b.category_code ? <Dot token={b.color_token} /> : <span aria-hidden className="inline-block size-2 rounded-pill bg-ink" />}
                  {b.account_code && <BankLogo bankCode={b.bank_code} size="xs" decorative />}
                  <span className="min-w-0 flex-1 truncate text-sm text-ink">{budgetTitle(b)}</span>
                  <Badge>{inactiveBudgetLabel(b, month)}</Badge>
                  <Money value={b.budget_aed} className="text-sm text-ink-2" />
                  {isOwner && (
                    <span className="flex gap-1">
                      <Button variant="ghost" size="sm" onClick={() => edit(b)}>
                        Edit
                      </Button>
                      <Button variant="ghost" size="sm" className="text-danger" onClick={() => setDeleting({ code: b.budget_code, name: budgetTitle(b) })}>
                        Delete
                      </Button>
                    </span>
                  )}
                </li>
              ))}
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

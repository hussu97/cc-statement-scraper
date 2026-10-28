import { useState, type FormEvent } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronRight, Landmark, TrendingUp } from "lucide-react";
import type { CashAccount, useCashPosition } from "@/data/cash";
import { holdingErrorMessage, useTrackAccountAsInvestment } from "@/data/holdings";
import { trimDecimal } from "@/lib/holdings";
import { balanceSourceLabel, bankAccountLabel } from "@/lib/cash-flow";
import { canTrackAsInvestment, rateAYear, validateTrackRate } from "@/lib/investments";
import { formatRelative } from "@/lib/dates";
import { formatMoney } from "@/lib/money";
import { Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { FormError, FormFooter } from "@/components/cash/bank-account-dialogs";

// A bank savings account under Investments (20261028082732_savings_account_investments.sql):
// the bank account page's "Show under Investments" and the dialog it opens.

/**
 * On a bank account's page: shown under Investments, a line saying so with a link to the holding;
 * else, for the owner of a current or savings account, the action that shows it there.
 */
export function AccountInvestmentBar({ profileCode, account, isOwner }: { profileCode: string; account: CashAccount | null; isOwner: boolean }) {
  const [target, setTarget] = useState<TrackTarget | null>(null);
  if (!account) return null;
  const holdingCode = account.investment_holding_code;
  if (holdingCode) {
    return (
      <Card className="flex items-center gap-3 px-5 py-3.5">
        <TrendingUp aria-hidden className="size-5 shrink-0 text-ink-2" />
        <p className="min-w-0 flex-1 text-[13px] text-ink-2">
          <span className="font-medium text-ink">Shown under Investments.</span> Its balance counts there, not in your cash total.
        </p>
        <Link
          to="/wealth/investments/$holdingCode"
          params={{ holdingCode }}
          className="tap inline-flex shrink-0 items-center gap-0.5 text-[13px] text-accent hover:underline"
        >
          Open <span className="hidden sm:inline">in Investments</span>
          <ChevronRight aria-hidden className="size-3.5" />
        </Link>
      </Card>
    );
  }
  if (!isOwner || !canTrackAsInvestment(account)) return null;
  return (
    <Card className="flex flex-wrap items-center gap-3 px-5 py-3.5">
      <TrendingUp aria-hidden className="size-5 shrink-0 text-ink-2" />
      <p className="min-w-0 flex-1 text-[13px] text-muted">
        Does it pay interest? Show it under Investments to follow its returns. Its balance then counts there instead of in cash.
      </p>
      <Button size="sm" onClick={() => setTarget({ accountCode: account.account_code, label: bankAccountLabel(account) })}>
        Show under Investments
      </Button>
      <TrackAccountDialog profileCode={profileCode} target={target} onClose={() => setTarget(null)} />
    </Card>
  );
}

/**
 * On a savings account holding's page, in place of its value history: the bank account whose
 * balance values it, as of when, with a link to the account's page.
 */
export function BackingAccountCard({ cash, account }: { cash: ReturnType<typeof useCashPosition>; account: CashAccount | null }) {
  const source = balanceSourceLabel(account?.anchor_source);
  return (
    <Card>
      <CardHeader eyebrow="Valued at its balance" title="Bank account" />
      {cash.isLoading ? (
        <LoadingRows rows={2} />
      ) : cash.isError ? (
        <ErrorState error={cash.error} onRetry={() => void cash.refetch()} />
      ) : !account ? (
        <EmptyState icon={<Landmark />} title="Its bank account isn't listed">
          The account behind it isn't under Accounts any more, so its balance can't value it.
        </EmptyState>
      ) : (
        <div className="px-5 pb-5">
          <Link
            to="/wealth/accounts/$accountCode"
            params={{ accountCode: account.account_code }}
            className="tap group -mx-2 flex items-center gap-3 rounded-md px-2 py-2 hover:bg-surface-2/60"
          >
            <BankLogo bankCode={account.bank_code} decorative />
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-medium text-ink group-hover:text-accent">{bankAccountLabel(account)}</span>
              <span className="block text-[12px] text-subtle">
                {account.bank_code}
                {account.nickname && account.account_ref ? ` ··· ${account.account_ref}` : ""}
                {account.as_of ? ` · as of ${formatRelative(account.as_of)}${source ? `, ${source}` : ""}` : ""}
              </span>
            </span>
            <span className="tabular shrink-0 text-sm font-medium text-ink">
              {account.balance === null ? <span className="text-muted">No balance yet</span> : formatMoney(account.balance, { currency: account.currency })}
            </span>
            <ChevronRight aria-hidden className="size-4 shrink-0 text-subtle group-hover:text-ink-2" />
          </Link>
          <p className="mt-3 text-[13px] text-muted">
            Its value is always this account's balance, so it matches Accounts. Transfers into and out of the account are money in and out, and interest the bank pays is income that stays in the account. Open the account for its statements and transactions.
          </p>
        </div>
      )}
    </Card>
  );
}

/** The bank account being shown under Investments, or whose stated rate is being changed. */
export interface TrackTarget {
  accountCode: string;
  label: string;
  /** Set when it is already shown there: the dialog then changes its rate. */
  ratePct?: string | null;
  shown?: boolean;
}

/**
 * "Show under Investments" (track_account_as_investment): the account becomes a savings account
 * holding valued at its balance, with an optional stated interest rate. Shown already, the same
 * dialog changes that rate. `onDone` gets the holding's code. Owner only; the caller decides.
 */
export function TrackAccountDialog({
  profileCode,
  target,
  onClose,
  onDone,
}: {
  profileCode: string;
  target: TrackTarget | null;
  onClose: () => void;
  onDone?: (holdingCode: string) => void;
}) {
  return (
    <Dialog
      open={!!target}
      onOpenChange={(o) => !o && onClose()}
      title={target?.shown ? "Interest rate" : "Show under Investments"}
      description={
        target?.shown
          ? `${target.label}: the rate the bank states, shown beside it under Investments.`
          : target
            ? `${target.label} moves from cash to Investments, valued at its balance. Transfers in and out count as money in and out, and interest as income. It stays under Accounts with its transactions.`
            : undefined
      }
    >
      {target && <TrackForm key={target.accountCode} profileCode={profileCode} target={target} onClose={onClose} onDone={onDone} />}
    </Dialog>
  );
}

function TrackForm({ profileCode, target, onClose, onDone }: { profileCode: string; target: TrackTarget; onClose: () => void; onDone?: (holdingCode: string) => void }) {
  const track = useTrackAccountAsInvestment(profileCode);
  const toast = useToast();
  const [rate, setRate] = useState(trimDecimal(target.ratePct));
  const [error, setError] = useState<string | null>(null);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const v = validateTrackRate(rate);
    if (!v.ok) {
      setError(v.error);
      return;
    }
    // track_account_as_investment keeps a stated rate when given none: it can change, not clear.
    if (target.shown && v.rate === null) {
      setError("Enter the rate a year in percent, e.g. 5.");
      return;
    }
    setError(null);
    track.mutate(
      { accountCode: target.accountCode, ratePct: v.rate },
      {
        onSuccess: (holdingCode) => {
          const stated = rateAYear(v.rate);
          toast(
            target.shown
              ? { title: "Rate saved", description: `${target.label}: ${stated}.`, tone: "positive" }
              : { title: "Shown under Investments", description: `${target.label} now counts there${stated ? `, at ${stated}` : ""}, not as cash.`, tone: "positive" },
          );
          onClose();
          onDone?.(holdingCode);
        },
        onError: (err) => setError(holdingErrorMessage(err)),
      },
    );
  };

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <Field label={target.shown ? "Interest rate (% a year)" : "Interest rate (% a year, optional)"} hint="As the bank states it, e.g. 5. It is shown beside the account; returns come from the interest it actually pays.">
        {(id, desc) => (
          <Input
            id={id}
            aria-describedby={desc}
            inputMode="decimal"
            autoComplete="off"
            placeholder="e.g. 5"
            className="tabular w-36"
            value={rate}
            onChange={(e) => setRate(e.target.value)}
            autoFocus
          />
        )}
      </Field>
      <FormError error={error} />
      <FormFooter onCancel={onClose} pending={track.isPending} submit={target.shown ? "Save rate" : "Show under Investments"} />
    </form>
  );
}

import { lazy, Suspense, useMemo, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight, Landmark, ReceiptText } from "lucide-react";
import { wealthAccountRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useCashPosition, type CashAccount } from "@/data/cash";
import { useFilterMeta } from "@/data/overview";
import { isNotFound, useAccountLedger, useBankBalanceSeries, type AccountLedger, type LedgerRow } from "@/data/wealth";
import { useSetCategory } from "@/data/transactions";
import { errorMessage } from "@/data/api";
import { balanceSourceLabel, bankAccountLabel } from "@/lib/cash-flow";
import {
  accountKindLabel,
  accountMonthStart,
  availableLedgerFilters,
  balancePoints,
  balanceRange,
  BALANCE_DAYS,
  formatInOut,
  hasBalances,
  matchesLedgerFilter,
  shiftAccountMonth,
  type LedgerFilter,
} from "@/lib/wealth";
import { formatMonth, formatRelative, monthEnd, monthStart, todayDubai } from "@/lib/dates";
import { formatTotal } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Segmented } from "@/components/ui/primitives";
import { EmptyState, ErrorState, LoadingBlock, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { BankLogo } from "@/components/bank-logo";
import { UpdateBalanceDialog } from "@/components/cash/bank-account-dialogs";
import { AccountLedgerTable } from "@/components/wealth/account-ledger";
import { TransactionDrawer } from "@/components/activity/drawer";
import { NotesCard } from "@/components/notes/notes-card";
import { AddNoteDialog } from "@/components/notes/add-note-dialog";
import { AccountEntryDialog } from "@/components/notes/account-entry-dialog";

// The chart library loads after the page renders (as on Overview, WEB-53).
const BalanceChart = lazy(() => import("@/components/wealth/balance-chart").then((m) => ({ default: m.BalanceChart })));

const ACC_RE = /^acc_[0-9a-z]{26}$/;

/** One bank account (Wealth mode): its balance, balance over time, and the month as a statement. */
export function AccountPage() {
  const { accountCode } = wealthAccountRoute.useParams();
  if (!ACC_RE.test(accountCode)) return <AccountNotFound />;
  return <AccountView key={accountCode} accountCode={accountCode} />;
}

function AccountNotFound() {
  return (
    <Card>
      <EmptyState
        icon={<Landmark />}
        title="Account not found"
        action={
          <Link to="/wealth/accounts" className="text-sm text-accent hover:underline">
            See your accounts
          </Link>
        }
      >
        It isn't a bank account in this ledger, or it was removed.
      </EmptyState>
    </Card>
  );
}

function AccountView({ accountCode }: { accountCode: string }) {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const search = wealthAccountRoute.useSearch();
  const navigate = useNavigate({ from: "/wealth/accounts/$accountCode" });
  const today = todayDubai();
  const start = accountMonthStart(search.month, today);
  const isCurrent = start === monthStart(today);
  const ledger = useAccountLedger(profileCode, accountCode, { from: start, to: monthEnd(start) });
  const cash = useCashPosition(profileCode);
  const position = cash.data?.accounts.find((a) => a.account_code === accountCode) ?? null;
  const [updating, setUpdating] = useState<CashAccount | null>(null);
  const [entering, setEntering] = useState<CashAccount | null>(null);
  const [addingNote, setAddingNote] = useState(false);
  const setMonth = (by: number) => void navigate({ search: { month: shiftAccountMonth(start, by, today) }, replace: true });

  if (ledger.isError && isNotFound(ledger.error)) return <AccountNotFound />;
  const account = ledger.data?.account ?? position;

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <div>
        <Link to="/wealth/accounts" className="tap -ml-1 inline-flex items-center gap-1 text-[13px] text-muted hover:text-accent">
          <ChevronLeft className="size-3.5" /> Accounts
        </Link>
        <header className="mt-3 flex items-center gap-3">
          {account ? <BankLogo bankCode={account.bank_code} size="lg" /> : <Skeleton className="size-10 rounded-md" />}
          <div className="min-w-0">
            <h1 className="truncate font-display text-[26px] leading-tight text-ink md:text-[30px]">{account ? bankAccountLabel(account) : <Skeleton className="h-8 w-48" />}</h1>
            {account && (
              <p className="text-[13px] text-muted">
                {accountKindLabel(account.kind)} · {account.bank_code}
                {account.account_ref ? ` ··· ${account.account_ref}` : ""}
                {account.currency.toUpperCase() !== "AED" ? ` · ${account.currency.toUpperCase()}` : ""}
              </p>
            )}
          </div>
        </header>
      </div>

      <BalanceCard
        profileCode={profileCode}
        accountCode={accountCode}
        position={position}
        loading={cash.isLoading}
        error={cash.isError ? cash.error : null}
        retry={() => void cash.refetch()}
        onUpdate={isOwner && position ? () => setUpdating(position) : undefined}
      />
      {isOwner && position && (
        <div className="-mt-3 flex justify-end">
          <Button size="sm" variant="link" className="text-[13px]" onClick={() => setEntering(position)}>
            Add a deposit or withdrawal
          </Button>
        </div>
      )}

      {/* A broker's cash (Swissquote) pays for notes; any account that funds one lists it. */}
      <NotesCard profileCode={profileCode} isOwner={isOwner} onAdd={() => setAddingNote(true)} fundingAccount={accountCode} hideWhenEmpty={account?.bank_code !== "SWQ"} />

      <Card>
        <CardHeader
          eyebrow="Statement"
          title={`${formatMonth(start)}${isCurrent ? " so far" : ""}`}
          action={
            <div className="flex items-center gap-1">
              <Button size="icon-sm" variant="ghost" aria-label="Previous month" onClick={() => setMonth(-1)}>
                <ChevronLeft className="size-4" />
              </Button>
              <Button size="icon-sm" variant="ghost" aria-label="Next month" disabled={isCurrent} onClick={() => setMonth(1)}>
                <ChevronRight className="size-4" />
              </Button>
            </div>
          }
        />
        {ledger.isLoading ? (
          <LoadingRows rows={6} />
        ) : ledger.isError || !ledger.data ? (
          <ErrorState error={ledger.error} onRetry={() => void ledger.refetch()} />
        ) : (
          <div className={cn(ledger.isPlaceholderData && "opacity-60 transition-opacity")}>
            <MonthSummary data={ledger.data} />
            <LedgerSection profileCode={profileCode} data={ledger.data} isOwner={isOwner} month={start} />
          </div>
        )}
      </Card>

      {isOwner && <UpdateBalanceDialog profileCode={profileCode} account={updating} onClose={() => setUpdating(null)} />}
      {isOwner && <AccountEntryDialog profileCode={profileCode} account={entering} onClose={() => setEntering(null)} />}
      {isOwner && <AddNoteDialog profileCode={profileCode} open={addingNote} onClose={() => setAddingNote(false)} fundingAccount={accountCode} />}
    </div>
  );
}

function BalanceCard({
  profileCode,
  accountCode,
  position: a,
  loading,
  error,
  retry,
  onUpdate,
}: {
  profileCode: string;
  accountCode: string;
  position: CashAccount | null;
  loading: boolean;
  error: unknown;
  retry: () => void;
  onUpdate?: () => void;
}) {
  const range = useMemo(() => balanceRange(), []);
  const series = useBankBalanceSeries(profileCode, accountCode, range);
  const points = useMemo(() => balancePoints(series.data ?? []), [series.data]);
  const source = balanceSourceLabel(a?.anchor_source);
  const currency = a?.currency ?? "AED";
  return (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-4 px-5 pt-5">
        <div>
          <p className="text-[12px] text-subtle">Balance</p>
          {loading ? (
            <Skeleton className="mt-1 h-9 w-48" />
          ) : error ? (
            <ErrorState error={error} onRetry={retry} className="p-0" />
          ) : !a || a.balance === null ? (
            <p className="mt-1 text-lg text-muted">No balance yet</p>
          ) : (
            <>
              <p className="tabular mt-0.5 text-[32px] leading-tight font-medium text-ink">{formatTotal(a.balance, { currency })}</p>
              {currency.toUpperCase() !== "AED" && <p className="tabular text-[12px] text-subtle">{a.balance_aed ? `≈ ${formatTotal(a.balance_aed)}` : "No AED rate yet"}</p>}
            </>
          )}
          {a && (
            <p className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-subtle">
              {a.as_of ? <span>as of {formatRelative(a.as_of)}{source ? `, ${source}` : ""}</span> : <span>Enter today's balance once; alerts keep it current after that.</span>}
              {a.is_stale && <Badge tone="warn">Over a week old</Badge>}
              {a.unpriced_count > 0 && <span>Excludes {a.unpriced_count} without an amount in {currency}</span>}
            </p>
          )}
        </div>
        {onUpdate && (
          <Button size="sm" onClick={onUpdate}>
            Update balance
          </Button>
        )}
      </div>
      <div className="px-3 pt-3 pb-4 md:px-4">
        <p className="mb-1 px-2 text-[11px] font-medium tracking-[0.06em] text-subtle uppercase">Last {BALANCE_DAYS} days</p>
        {series.isLoading ? (
          <LoadingBlock className="h-44" />
        ) : series.isError ? (
          <ErrorState error={series.error} onRetry={() => void series.refetch()} />
        ) : !hasBalances(points) ? (
          <EmptyState title="No balance history yet" className="h-44">
            The line starts once the account has a balance: enter one, or let an alert with a balance arrive.
          </EmptyState>
        ) : (
          <Suspense fallback={<LoadingBlock className="h-44" />}>
            <BalanceChart points={points} currency={currency} />
          </Suspense>
        )}
      </div>
    </Card>
  );
}

function MonthSummary({ data }: { data: AccountLedger }) {
  const currency = data.account.currency;
  const item = (label: string, text: string | null, tone = "text-ink") => (
    <div>
      <dt className="text-[12px] text-subtle">{label}</dt>
      <dd className={cn("tabular mt-0.5 text-[15px] font-medium", text === null ? "text-muted" : tone)}>{text ?? "Unknown"}</dd>
    </div>
  );
  const balance = (v: string | null) => (v === null ? null : formatTotal(v, { currency }));
  return (
    <div className="border-b border-border px-5 pb-4">
      <dl className="grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-4">
        {item("Opening balance", balance(data.opening_balance))}
        {item("Money in", formatInOut(data.money_in, "in", currency), "text-positive")}
        {item("Money out", formatInOut(data.money_out, "out", currency))}
        {item("Closing balance", balance(data.closing_balance))}
      </dl>
      {data.unpriced_count > 0 && (
        <p className="mt-2 text-[11px] text-subtle">
          {data.unpriced_count} {data.unpriced_count === 1 ? "transaction has" : "transactions have"} no amount in {currency} and {data.unpriced_count === 1 ? "is" : "are"} left out of these figures.
        </p>
      )}
    </div>
  );
}

function LedgerSection({ profileCode, data, isOwner, month }: { profileCode: string; data: AccountLedger; isOwner: boolean; month: string }) {
  const meta = useFilterMeta(profileCode);
  const setCat = useSetCategory(profileCode);
  const toast = useToast();
  const [filter, setFilter] = useState<LedgerFilter>("all");
  const [open, setOpen] = useState<string | undefined>();
  const filters = useMemo(() => availableLedgerFilters(data.rows), [data.rows]);
  const active = filters.some((f) => f.value === filter) ? filter : "all";
  const rows = useMemo(() => data.rows.filter((r) => matchesLedgerFilter(r.flow, active)), [data.rows, active]);
  const onCategory = (r: LedgerRow, code: string | null, toMerchant: boolean) =>
    setCat.mutate(
      { txnCode: r.txn_code, categoryCode: code, applyToMerchant: toMerchant },
      {
        onSuccess: () => toast({ title: toMerchant ? "Category applied to merchant" : "Category updated", tone: "positive" }),
        onError: (e) => toast({ title: "Couldn't change the category", description: errorMessage(e), tone: "danger" }),
      },
    );

  if (data.rows.length === 0) {
    return (
      <EmptyState icon={<ReceiptText />} title={`Nothing on this account in ${formatMonth(month)}`}>
        Salary, transfers and debit-card purchases appear here as the bank's alerts arrive.
      </EmptyState>
    );
  }
  return (
    <>
      {filters.length > 2 && (
        <div className="-mx-1 overflow-x-auto px-5 pt-3 pb-3 [scrollbar-width:none]">
          <Segmented ariaLabel="Show" value={active} onChange={setFilter} options={filters.map((f) => ({ value: f.value, label: f.label }))} />
        </div>
      )}
      <AccountLedgerTable
        rows={rows}
        currency={data.account.currency}
        categories={meta.data?.categories ?? []}
        canEdit={isOwner}
        onCategory={onCategory}
        onOpen={(r) => setOpen(r.txn_code)}
      />
      <TransactionDrawer txnCode={open} meta={meta.data} onClose={() => setOpen(undefined)} />
    </>
  );
}

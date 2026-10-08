import { useEffect, useMemo, useRef, type ReactNode } from "react";
import { Link, useNavigate, useRouter } from "@tanstack/react-router";
import { ArrowLeft, CheckCircle2, CircleMinus, ExternalLink, FileText, ListTree, XCircle } from "lucide-react";
import { statementRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useFilterMeta } from "@/data/overview";
import { dueInDays, isStatementCode, useStatementDetail, utilisationOf, utilisationTone, type StatementDetail } from "@/data/statements";
import { useBanks } from "@/data/banks";
import { formatDate, todayDubai } from "@/lib/dates";
import { formatMoney, formatPercent } from "@/lib/money";
import { reconBadge, reconChecks, reconNote } from "@/lib/recon";
import { cn } from "@/lib/cn";
import { Badge, Card, Meter, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { BankLogo } from "@/components/bank-logo";
import { StatementLines } from "@/components/statements/statement-lines";
import { DocumentLog } from "@/components/documents/document-log";
import { usePdfOpener } from "@/components/documents/use-pdf-opener";
import { TransactionDrawer } from "@/components/activity/drawer";

export function StatementPage() {
  const { profile_code } = useActiveProfile();
  const { stmtCode } = statementRoute.useParams();
  const search = statementRoute.useSearch();
  const navigate = useNavigate({ from: "/statements/$stmtCode" });
  const router = useRouter();
  const q = useStatementDetail(profile_code, stmtCode);
  const meta = useFilterMeta(profile_code);
  const categories = useMemo(() => new Map((meta.data?.categories ?? []).map((c) => [c.category_code, c])), [meta.data]);
  // Like Activity: a drawer opened from this page pops its own history entry on close.
  const pushedDrawer = useRef(false);
  useEffect(() => {
    if (!search.txn) pushedDrawer.current = false;
  }, [search.txn]);

  const back = (
    <Link to="/cards" search={{ tab: "statements" }} className="tap inline-flex items-center gap-1.5 text-[13px] text-muted hover:text-ink">
      <ArrowLeft className="size-3.5" aria-hidden /> Statements
    </Link>
  );

  if (!isStatementCode(stmtCode) || (q.isError && (q.error as { code?: string }).code === "P0002")) {
    return (
      <div className="flex flex-col gap-4">
        {back}
        <Card>
          <EmptyState icon={<FileText />} title="This statement isn't in this ledger" action={<Link to="/cards" search={{ tab: "statements" }} className="text-sm text-accent hover:underline">See all statements</Link>}>
            It may belong to another ledger, or it was replaced by a newer upload.
          </EmptyState>
        </Card>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-5">
      {back}
      {q.isLoading ? (
        <DetailSkeleton />
      ) : q.isError || !q.data ? (
        <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>
      ) : (
        <Detail
          data={q.data}
          categories={categories}
          onOpen={(txn) => {
            pushedDrawer.current = true;
            void navigate({ search: { txn }, resetScroll: false });
          }}
        />
      )}
      <TransactionDrawer
        txnCode={search.txn}
        meta={meta.data}
        onClose={() => {
          if (pushedDrawer.current) {
            pushedDrawer.current = false;
            router.history.back();
          } else {
            void navigate({ search: {}, replace: true, resetScroll: false });
          }
        }}
      />
    </div>
  );
}

function Detail({ data, categories, onOpen }: { data: StatementDetail; categories: Parameters<typeof StatementLines>[0]["categories"]; onOpen: (txn: string) => void }) {
  const { profile_code } = useActiveProfile();
  const s = data.statement;
  const banks = useBanks();
  const bankName = banks.data?.find((b) => b.bank_code === s.bank_code)?.name ?? s.bank_code;
  const openPdf = usePdfOpener();
  const isHistory = s.kind !== "statement";
  const multiCard = s.card_last4s.length > 1;
  return (
    <>
      <header className="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
        <div className="flex min-w-0 items-start gap-3">
          <BankLogo bankCode={s.bank_code} size="lg" decorative />
          <div className="min-w-0">
            <p className="text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">{bankName}</p>
            <h1 className="font-display text-[26px] leading-tight text-ink md:text-[30px]">
              {isHistory ? "History export" : "Statement"} · {formatDate(s.statement_date)}
            </h1>
            <p className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-[13px] text-muted">
              {s.card_last4s.length > 0 ? (
                <span className="tabular">{s.card_last4s.map((l) => `•${l}`).join("  ")}</span>
              ) : (
                <span>Card unknown</span>
              )}
              <span aria-hidden>·</span>
              <span>{s.period_start ? `${formatDate(s.period_start, "short")} – ${formatDate(s.period_end)}` : "Period unknown"}</span>
            </p>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button size="sm" icon={<ExternalLink className="size-3.5" />} onClick={() => void openPdf(s.doc_code)} disabled={!s.doc_code}>
            Open PDF
          </Button>
          <Link
            to="/activity"
            search={{ account: s.account_code, from: s.period_start ?? undefined, to: s.period_end ?? s.statement_date }}
            className="tap inline-flex h-8 items-center gap-1.5 rounded-sm border border-border bg-surface px-3 text-[13px] font-medium text-ink hover:border-border-strong hover:bg-surface-2"
          >
            <ListTree className="size-3.5" aria-hidden /> In Activity
          </Link>
        </div>
      </header>

      <Summary data={data} />

      <div className="grid gap-5 xl:grid-cols-2">
        <StatementLines side="debit" data={data.debits} categories={categories} showCard={multiCard} onOpen={onOpen} />
        <StatementLines side="credit" data={data.credits} categories={categories} showCard={multiCard} onOpen={onOpen} />
      </div>

      <Recon status={s.recon_status} checks={s.recon_checks} />

      {s.doc_code && <DocumentLog profileCode={profile_code} docCode={s.doc_code} collapsible />}
    </>
  );
}

function Tile({ label, children, sub, className }: { label: string; children: ReactNode; sub?: ReactNode; className?: string }) {
  return (
    <div className={cn("min-w-0 rounded-md border border-border bg-surface px-3.5 py-3", className)}>
      <dt className="text-[11.5px] text-subtle">{label}</dt>
      <dd className="tabular mt-1 truncate text-[17px] leading-tight text-ink">{children}</dd>
      {sub && <dd className="mt-1 text-[11.5px] text-muted">{sub}</dd>}
    </div>
  );
}

function Summary({ data }: { data: StatementDetail }) {
  const s = data.statement;
  const util = utilisationOf(s);
  const due = dueInDays(s.due_date, todayDubai());
  const badge = reconBadge(s.recon_status);
  return (
    <section aria-label="Statement summary">
      <dl className="grid grid-cols-2 gap-2.5 md:grid-cols-4">
        <Tile label="Opening balance">{formatMoney(s.opening_balance)}</Tile>
        <Tile label="Total debits" sub={`${data.debits.count} ${data.debits.count === 1 ? "line" : "lines"}`}>{formatMoney(s.total_debits)}</Tile>
        <Tile label="Total credits" sub={`${data.credits.count} ${data.credits.count === 1 ? "line" : "lines"}`}>
          <span className="text-positive">{formatMoney(s.total_credits, { signed: true })}</span>
        </Tile>
        <Tile label="Closing balance">{formatMoney(s.closing_balance)}</Tile>
        <Tile
          label="Minimum due"
          sub={
            s.due_date ? (
              <span className="inline-flex flex-wrap items-center gap-1.5">
                Due {formatDate(s.due_date, "short")}
                {due !== null && due >= 0 && due <= 7 && <Badge tone={due <= 2 ? "danger" : "warn"}>in {due} d</Badge>}
              </span>
            ) : (
              "No due date"
            )
          }
        >
          {formatMoney(s.min_due)}
        </Tile>
        <Tile label="Utilisation" sub={s.credit_limit ? `of ${formatMoney(s.credit_limit, { whole: true })}` : "No credit limit"}>
          <span>{util !== null ? formatPercent(util) : "—"}</span>
          {util !== null && <Meter value={util} tone={utilisationTone(util)} className="mt-1.5 h-1" label="Utilisation" />}
        </Tile>
        <div className="col-span-2 flex min-w-0 items-center justify-between gap-3 rounded-md border border-border bg-surface px-3.5 py-3">
          <div className="min-w-0">
            <dt className="text-[11.5px] text-subtle">Reconciliation</dt>
            <dd className="mt-1 text-[13px] text-muted">{reconSummary(s.recon_status)}</dd>
          </div>
          <dd>
            <a href="#statement-recon" className="tap rounded-pill">
              <Badge tone={badge.tone}>{badge.label}</Badge>
            </a>
          </dd>
        </div>
      </dl>
    </section>
  );
}

function reconSummary(status: string | null): string {
  switch (status) {
    case "ok":
      return "Lines add up to the statement's totals.";
    case "warn":
      return "Mostly adds up; a check needs a look.";
    case "fail":
      return "The lines don't add up to the totals.";
    case "n/a":
      return "History exports have no totals to check.";
    default:
      return "Not checked yet.";
  }
}

function Recon({ status, checks }: { status: string | null; checks: Record<string, unknown> | null }) {
  const rows = reconChecks(checks);
  const note = reconNote(status);
  const badge = reconBadge(status);
  return (
    <Card id="statement-recon" aria-labelledby="statement-recon-title" className="scroll-mt-20 px-4 py-4 md:px-5">
      <div className="mb-3 flex items-center justify-between gap-3">
        <h2 id="statement-recon-title" className="text-[15px] font-semibold text-ink">Reconciliation checks</h2>
        <Badge tone={badge.tone}>{badge.label}</Badge>
      </div>
      {note && <p className="mb-2 text-[13px] text-muted">{note}</p>}
      {rows.length === 0 && !note ? (
        <p className="text-[13px] text-muted">No reconciliation has run for this statement.</p>
      ) : (
        <ul className="flex flex-col gap-2">
          {rows.map((c) => (
            <li key={c.key} className="flex items-start gap-2 text-[13px]">
              {c.ok === true ? (
                <CheckCircle2 className="mt-0.5 size-3.5 shrink-0 text-positive" aria-label="Passed" />
              ) : c.ok === false ? (
                <XCircle className="mt-0.5 size-3.5 shrink-0 text-danger" aria-label="Failed" />
              ) : (
                <CircleMinus className="mt-0.5 size-3.5 shrink-0 text-subtle" aria-label="For information" />
              )}
              <span className="min-w-0">
                <span className="text-ink">{c.label}</span>
                {c.detail && <span className="tabular text-muted"> · {c.detail}</span>}
              </span>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

function DetailSkeleton() {
  return (
    <div role="status" aria-label="Loading" className="flex flex-col gap-5">
      <div className="flex items-start gap-3">
        <Skeleton className="size-10 rounded-md" />
        <div className="flex flex-1 flex-col gap-2">
          <Skeleton className="h-3 w-24" />
          <Skeleton className="h-7 w-64 max-w-full" />
          <Skeleton className="h-3 w-48" />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2.5 md:grid-cols-4">
        {Array.from({ length: 8 }, (_, i) => (
          <Skeleton key={i} className="h-[74px] rounded-md" />
        ))}
      </div>
      <Card><LoadingRows rows={6} /></Card>
    </div>
  );
}

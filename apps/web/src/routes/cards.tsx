import { useState } from "react";
import { Link, useNavigate, useSearch } from "@tanstack/react-router";
import { CheckCircle2, ChevronDown, CircleAlert, CircleMinus, ExternalLink, FileText, Pencil, RotateCw, XCircle } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { accountLabel } from "@/data/overview";
import { docWarnings, documentStoragePath, signedDocumentUrl, STATEMENT_CYCLES_MAX, useAccounts, useDocumentHealth, useDocuments, useRequeueDocuments, useStatementCycles, useUpdateAccount, type StatementCycle } from "@/data/cards";
import { errorMessage } from "@/data/api";
import { formatDate, formatRelative } from "@/lib/dates";
import { formatMoney, formatPercent } from "@/lib/money";
import { pageCount } from "@/lib/pagination";
import { useClampPage, usePageState } from "@/lib/hooks";
import { reconBadge, reconChecks, reconNote } from "@/lib/recon";
import { cn } from "@/lib/cn";
import { Badge, Card, Meter, PageHeader } from "@/components/ui/display";
import { Tabs, TabsContent, TabsList, TabsTrigger, Tooltip } from "@/components/ui/primitives";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { Pagination } from "@/components/pagination";
import { UploadDropzone } from "@/components/cards/upload";
import { BankLogo } from "@/components/bank-logo";

const TABS = ["cards", "statements", "upload", "documents"] as const;

export function CardsPage() {
  const search = useSearch({ from: "/app/cards" });
  const navigate = useNavigate({ from: "/cards" });
  const tab = TABS.includes(search.tab as (typeof TABS)[number]) ? search.tab! : "cards";
  const { profile_code, isOwner } = useActiveProfile();
  return (
    <div>
      <PageHeader title="Cards & statements" description="Your card accounts, every statement with its reconciliation, and the PDFs behind them." />
      <Tabs value={tab} onValueChange={(t) => void navigate({ search: { tab: t === "cards" ? undefined : t }, replace: true })}>
        <TabsList>
          <TabsTrigger value="cards">Cards</TabsTrigger>
          <TabsTrigger value="statements">Statements</TabsTrigger>
          <TabsTrigger value="upload">Upload</TabsTrigger>
          <TabsTrigger value="documents">Documents</TabsTrigger>
        </TabsList>
        <TabsContent value="cards" className="pt-6"><AccountsTab profileCode={profile_code} isOwner={isOwner} /></TabsContent>
        <TabsContent value="statements" className="pt-6"><StatementsTab profileCode={profile_code} /></TabsContent>
        <TabsContent value="upload" className="pt-6"><UploadDropzone profileCode={profile_code} disabled={!isOwner} /></TabsContent>
        <TabsContent value="documents" className="pt-6"><DocumentsTab profileCode={profile_code} isOwner={isOwner} /></TabsContent>
      </Tabs>
    </div>
  );
}

type AccountRow = NonNullable<ReturnType<typeof useAccounts>["data"]>[number];

function AccountsTab({ profileCode, isOwner }: { profileCode: string; isOwner: boolean }) {
  const q = useAccounts(profileCode);
  const [editing, setEditing] = useState<AccountRow | null>(null);
  if (q.isLoading) return <Card><LoadingRows rows={3} /></Card>;
  if (q.isError) return <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>;
  if (!q.data?.length)
    return (
      <Card>
        <EmptyState title="No cards yet" action={<Link to="/cards" search={{ tab: "upload" }} className="text-sm text-accent hover:underline">Upload a statement</Link>}>
          Bank Ledger creates a card account from your first statement or SMS alert.
        </EmptyState>
      </Card>
    );
  return (
    <div className="grid gap-4 md:grid-cols-2">
      {q.data.map((a) => (
        <Card key={a.account_code} className="p-5">
          <div className="flex items-start gap-3">
            <BankLogo bankCode={a.bank_code} />
            <div className="min-w-0 flex-1">
              <p className="truncate text-[15px] font-medium text-ink">{accountLabel(a)}</p>
              <p className="text-[12px] text-subtle">{[a.bank_code, a.product_name].filter(Boolean).join(" · ")}</p>
            </div>
            {a.status !== "active" && <Badge>{a.status}</Badge>}
            {isOwner && (
              <Button size="icon-sm" variant="ghost" aria-label={`Edit ${accountLabel(a)}`} onClick={() => setEditing(a)}>
                <Pencil className="size-3.5" />
              </Button>
            )}
          </div>
          <dl className="mt-5 grid grid-cols-2 gap-4 text-[13px]">
            <div>
              <dt className="text-[12px] text-subtle">Credit limit</dt>
              <dd className="tabular mt-0.5 text-ink">{formatMoney(a.credit_limit, { whole: true })}</dd>
            </div>
            <div>
              <dt className="text-[12px] text-subtle">Cycle closes</dt>
              <dd className="mt-0.5 text-ink">{a.cycle_close_day ? `Day ${a.cycle_close_day}` : "From statements"}</dd>
            </div>
          </dl>
          <ul className="mt-4 flex flex-col gap-1.5 border-t border-border pt-3">
            {(a.cards ?? []).map((c) => (
              <li key={c.card_code} className="flex items-center justify-between text-[13px]">
                <span className="tabular text-ink">•{c.last4}</span>
                <span className="text-muted">
                  {c.is_supplementary ? "Supplementary" : "Primary"}
                  {c.status !== "active" && ` · ${c.status}`}
                </span>
              </li>
            ))}
            {(a.cards ?? []).length === 0 && <li className="text-[13px] text-muted">No cards seen yet.</li>}
          </ul>
        </Card>
      ))}
      {editing && <EditAccountDialog profileCode={profileCode} account={editing} onClose={() => setEditing(null)} />}
    </div>
  );
}

function EditAccountDialog({ profileCode, account, onClose }: { profileCode: string; account: AccountRow; onClose: () => void }) {
  const [nickname, setNickname] = useState(account.nickname ?? "");
  const [limit, setLimit] = useState(account.credit_limit !== null ? String(account.credit_limit) : "");
  const update = useUpdateAccount(profileCode);
  const toast = useToast();
  const limitValid = limit.trim() === "" || /^\d+(\.\d{1,2})?$/.test(limit.trim());
  return (
    <Dialog
      open
      onOpenChange={(o) => !o && onClose()}
      title="Edit card account"
      description={`${account.bank_code}${account.product_name ? ` · ${account.product_name}` : ""}`}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          <Button
            variant="primary"
            disabled={!limitValid}
            loading={update.isPending}
            onClick={() =>
              update.mutate(
                { accountCode: account.account_code, nickname, creditLimit: limit },
                {
                  onSuccess: () => {
                    toast({ title: "Card account saved", tone: "positive" });
                    onClose();
                  },
                  onError: (e) => toast({ title: "Couldn't save", description: errorMessage(e), tone: "danger" }),
                },
              )
            }
          >
            Save
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <Field label="Nickname" hint="Shown instead of the bank and product name.">
          {(id, d) => <Input id={id} aria-describedby={d} value={nickname} maxLength={60} onChange={(e) => setNickname(e.target.value)} placeholder="e.g. Travel card" />}
        </Field>
        <Field label="Credit limit (AED)" hint="Updated automatically from each statement." error={!limitValid ? "Enter a number like 30000 or 30000.00." : undefined}>
          {(id, d) => <Input id={id} aria-describedby={d} aria-invalid={!limitValid} inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value)} className="tabular" />}
        </Field>
      </div>
    </Dialog>
  );
}

function usePdfOpener() {
  const toast = useToast();
  return async (docCode: string | null) => {
    if (!docCode) {
      toast({ title: "No PDF for this statement", tone: "danger" });
      return;
    }
    const win = window.open("about:blank", "_blank");
    try {
      const path = await documentStoragePath(docCode);
      if (!path) throw new Error("The PDF for this statement isn't available.");
      const url = await signedDocumentUrl(path);
      if (win) win.location.href = url;
      else window.location.assign(url);
    } catch (e) {
      win?.close();
      toast({ title: "Couldn't open the PDF", description: errorMessage(e), tone: "danger" });
    }
  };
}

function StatementsTab({ profileCode }: { profileCode: string }) {
  const pager = usePageState();
  const q = useStatementCycles(profileCode, pager.page, pager.size);
  useClampPage(pager.page, pager.size, q.data?.total, pager.setPage);
  const openPdf = usePdfOpener();
  if (q.isLoading) return <Card><LoadingRows rows={6} /></Card>;
  if (q.isError) return <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>;
  const { rows, total } = q.data!;
  if (total === 0)
    return (
      <Card>
        <EmptyState icon={<FileText />} title="No statements yet" action={<Link to="/cards" search={{ tab: "upload" }} className="text-sm text-accent hover:underline">Upload a statement</Link>}>
          Statements arrive from the scraper, email, or an upload here.
        </EmptyState>
      </Card>
    );
  return (
    <>
      <Card className={cn("overflow-hidden", q.isFetching && !q.isLoading && "opacity-80 transition-opacity")}>
        {pager.page > pageCount(total, pager.size) ? (
          <LoadingRows rows={4} />
        ) : (
          <ul className="divide-y divide-border">
            {rows.map((s) => (
              <StatementRow key={s.stmt_code} s={s} onOpenPdf={() => void openPdf(s.doc_code)} />
            ))}
          </ul>
        )}
      </Card>
      <Pagination page={pager.page} size={pager.size} total={total} onPage={pager.setPage} onSize={pager.setSize} />
      {total >= STATEMENT_CYCLES_MAX && (
        <p className="px-1 text-[12px] text-muted">Showing your newest {STATEMENT_CYCLES_MAX} statements. Older ones are still in your ledger and in Activity.</p>
      )}
    </>
  );
}

function StatementRow({ s, onOpenPdf }: { s: StatementCycle; onOpenPdf: () => void }) {
  const [open, setOpen] = useState(false);
  const checks = reconChecks(s.recon_checks as Record<string, unknown> | null);
  const badge = reconBadge(s.recon_status);
  const note = reconNote(s.recon_status);
  return (
    <li>
      <div className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-2 px-5 py-3.5 md:grid-cols-[minmax(0,1.3fr)_repeat(3,minmax(0,1fr))_8.5rem]">
        <button type="button" onClick={() => setOpen((o) => !o)} aria-expanded={open} className="flex min-w-0 items-center gap-3 text-left">
          <ChevronDown className={cn("size-4 shrink-0 text-subtle transition-transform", open && "rotate-180")} aria-hidden />
          <BankLogo bankCode={s.bank_code} className="size-7" />
          <span className="min-w-0">
            <span className="block truncate text-sm text-ink">
              {formatDate(s.statement_date)} {s.kind !== "statement" && <span className="text-subtle">· history export</span>}
            </span>
            <span className="block text-[12px] text-muted md:truncate">
              {s.bank_code} {s.card_last4 ? `•${s.card_last4}` : ""} · {s.period_start ? `${formatDate(s.period_start, "short")} – ${formatDate(s.period_end, "short")}` : "period unknown"}
            </span>
          </span>
        </button>
        <div className="hidden text-[13px] md:block">
          <p className="text-[11px] text-subtle">Closing</p>
          <p className="tabular text-ink">{formatMoney(s.closing_balance)}</p>
        </div>
        <div className="hidden text-[13px] md:block">
          <p className="text-[11px] text-subtle">Due</p>
          <p className="text-ink">{s.due_date ? formatDate(s.due_date, "short") : "—"}</p>
          {s.min_due !== null && <p className="tabular text-[11px] text-subtle">min {formatMoney(s.min_due)}</p>}
        </div>
        <div className="hidden text-[13px] md:block">
          <p className="text-[11px] text-subtle">Utilisation</p>
          <p className="tabular text-ink">{s.utilisation !== null ? formatPercent(s.utilisation) : "—"}</p>
          {s.utilisation !== null && <Meter value={s.utilisation} className="mt-1 h-1 w-20" tone={s.utilisation > 0.7 ? "danger" : s.utilisation > 0.3 ? "warn" : "positive"} />}
        </div>
        <div className="flex items-center justify-end gap-2">
          <Badge tone={badge.tone}>{badge.label}</Badge>
        </div>
      </div>
      {open && (
        <div className="grid gap-5 border-t border-border bg-bg px-5 py-4 md:grid-cols-[1fr_auto]">
          <div>
            <dl className="mb-4 grid grid-cols-2 gap-3 text-[13px] md:hidden">
              <div><dt className="text-[11px] text-subtle">Closing</dt><dd className="tabular">{formatMoney(s.closing_balance)}</dd></div>
              <div><dt className="text-[11px] text-subtle">Due</dt><dd>{s.due_date ? formatDate(s.due_date) : "—"}</dd></div>
            </dl>
            {note && <p className="mb-2 text-[13px] text-muted">{note}</p>}
            <ul className="flex flex-col gap-1.5">
              {checks.map((c) => (
                <li key={c.key} className="flex items-start gap-2 text-[13px]">
                  {c.ok === true ? <CheckCircle2 className="mt-0.5 size-3.5 shrink-0 text-positive" /> : c.ok === false ? <XCircle className="mt-0.5 size-3.5 shrink-0 text-danger" /> : <CircleMinus className="mt-0.5 size-3.5 shrink-0 text-subtle" />}
                  <span className="text-ink">{c.label}</span>
                  {c.detail && <span className="tabular text-muted">· {c.detail}</span>}
                </li>
              ))}
              {checks.length === 0 && !note && <li className="text-[13px] text-muted">No reconciliation has run for this statement.</li>}
            </ul>
            <p className="tabular mt-3 text-[12px] text-muted">
              {s.line_count} lines · debits {formatMoney(s.debits)} · credits {formatMoney(s.credits)}
            </p>
          </div>
          <div className="flex flex-wrap items-start gap-2 md:flex-col md:items-end">
            <Button size="sm" icon={<ExternalLink className="size-3.5" />} onClick={onOpenPdf} disabled={!s.doc_code}>
              Open PDF
            </Button>
            <Link
              to="/activity"
              search={{ account: s.account_code, from: s.period_start ?? undefined, to: s.period_end ?? s.statement_date, source: undefined }}
              className="text-[13px] text-accent hover:underline"
            >
              Transactions in this period
            </Link>
          </div>
        </div>
      )}
    </li>
  );
}

const PARSE_TONE: Record<string, "neutral" | "info" | "positive" | "danger"> = { queued: "neutral", parsing: "info", parsed: "positive", failed: "danger" };

function DocumentsTab({ profileCode, isOwner }: { profileCode: string; isOwner: boolean }) {
  const pager = usePageState();
  const q = useDocuments(profileCode, pager.page, pager.size);
  useClampPage(pager.page, pager.size, q.data?.total, pager.setPage);
  const health = useDocumentHealth(profileCode);
  const requeue = useRequeueDocuments(profileCode);
  const openPdf = usePdfOpener();
  const toast = useToast();
  const failed = health.data?.failedCodes ?? [];
  const failedCount = health.data?.counts.failed ?? 0;
  const parseAgain = (codes: string[]) =>
    requeue.mutate(codes, {
      onSuccess: (n) => toast({ title: `${n} document${n === 1 ? "" : "s"} queued for parsing`, tone: "positive" }),
      onError: (e) => toast({ title: "Couldn't queue", description: errorMessage(e), tone: "danger" }),
    });
  if (q.isLoading) return <Card><LoadingRows rows={6} /></Card>;
  if (q.isError) return <Card><ErrorState error={q.error} onRetry={() => void q.refetch()} /></Card>;
  const { rows, total } = q.data!;
  if (total === 0) return <Card><EmptyState icon={<FileText />} title="No documents yet">Uploaded and scraped PDFs appear here with their parse status.</EmptyState></Card>;
  return (
    <>
      {isOwner && failedCount > 0 && (
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-danger bg-danger-soft px-4 py-3 text-[13px]">
          <span className="flex items-center gap-2 text-danger"><CircleAlert className="size-4" />{failedCount} document{failedCount === 1 ? "" : "s"} failed to parse.</span>
          <Button size="sm" icon={<RotateCw className="size-3.5" />} loading={requeue.isPending} disabled={failed.length === 0} onClick={() => parseAgain(failed)}>Retry failed</Button>
        </div>
      )}
      <Card className="overflow-hidden">
        <ul className="divide-y divide-border">
          {rows.map((d) => (
            <li key={d.doc_code} className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 px-5 py-3">
              <div className="min-w-0">
                <button type="button" onClick={() => void openPdf(d.doc_code)} className="-my-2.5 block max-w-full truncate py-2.5 text-left text-sm text-ink hover:text-accent lg:my-0 lg:py-0">
                  {d.original_filename}
                </button>
                <p className="mt-0.5 flex flex-wrap gap-x-2 text-[12px] text-muted">
                  <span className="inline-flex items-center gap-1">{d.bank_code ? <><BankLogo bankCode={d.bank_code} size="xs" decorative />{d.bank_code}</> : "Bank unknown"}</span>
                  <span>· {d.source}</span>
                  <span>· added {formatRelative(d.created_at)}</span>
                  {d.parsed_at && <span>· parsed {formatRelative(d.parsed_at)}</span>}
                  {d.parser_version && <span>· parser {d.parser_version}</span>}
                </p>
                {d.parse_status === "failed" && d.parse_error && <p className="mt-1 text-[12px] text-danger">{d.parse_error}</p>}
              </div>
              <div className="flex items-center gap-2">
                <WarningsChip warnings={docWarnings(d.parse_warnings)} />
                <Badge tone={PARSE_TONE[d.parse_status] ?? "neutral"} className={d.parse_status === "parsing" ? "animate-pulse" : undefined}>{d.parse_status}</Badge>
                {isOwner && (d.parse_status === "failed" || d.parse_status === "parsed") && (
                  <Button size="icon-sm" variant="ghost" aria-label={`Parse ${d.original_filename} again`} onClick={() => parseAgain([d.doc_code])}>
                    <RotateCw className="size-3.5" />
                  </Button>
                )}
              </div>
            </li>
          ))}
        </ul>
      </Card>
      <Pagination page={pager.page} size={pager.size} total={total} onPage={pager.setPage} onSize={pager.setSize} />
    </>
  );
}

/** "2 warnings" next to a parsed document; the parser's notes in a tooltip (digit runs masked by docWarnings). */
function WarningsChip({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null;
  const shown = warnings.slice(0, 6);
  const label = `${warnings.length} warning${warnings.length === 1 ? "" : "s"}`;
  return (
    <Tooltip
      content={
        <ul className="flex flex-col gap-1">
          {shown.map((w, i) => (
            <li key={i}>{w}</li>
          ))}
          {warnings.length > shown.length && <li>+{warnings.length - shown.length} more</li>}
        </ul>
      }
    >
      <button type="button" aria-label={`${label}: ${shown.join("; ")}`} className="tap inline-flex items-center gap-1 rounded-pill text-[12px] text-muted hover:text-ink">
        <CircleAlert className="size-3.5" aria-hidden />
        <span className="tabular">{label}</span>
      </button>
    </Tooltip>
  );
}

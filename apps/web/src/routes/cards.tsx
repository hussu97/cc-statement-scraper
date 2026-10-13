import { useState } from "react";
import { Link, useNavigate, useSearch } from "@tanstack/react-router";
import { Pencil } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { accountLabel } from "@/data/overview";
import { normalizeWalletName, useAccounts, useUpdateAccount, useUpdateCard, WALLET_NAME_MAX } from "@/data/cards";
import { errorMessage } from "@/data/api";
import { formatTotal } from "@/lib/money";
import { DEFAULT_PAGE_SIZE } from "@/lib/pagination";
import { pagePatch, sizePatch, type PageSearch } from "@/lib/infinite";
import { Badge, Card, PageHeader } from "@/components/ui/display";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/primitives";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { UploadDropzone } from "@/components/cards/upload";
import { StatementsTab, type ListPaging } from "@/components/cards/statements-tab";
import { DocumentsTab } from "@/components/cards/documents-tab";
import { BankLogo } from "@/components/bank-logo";
import { AccountComparison } from "@/components/cards/account-comparison";

const TABS = ["cards", "statements", "upload", "documents"] as const;

export function CardsPage() {
  const search = useSearch({ from: "/app/cards" });
  const navigate = useNavigate({ from: "/cards" });
  const tab = TABS.includes(search.tab as (typeof TABS)[number]) ? search.tab! : "cards";
  const { profile_code, isOwner } = useActiveProfile();
  // ?page=&size= belong to the open tab's list; switching tabs drops them (back to page 1).
  const setPaging = (p: PageSearch) => void navigate({ search: (s) => ({ ...s, ...p }), replace: true });
  const paging: ListPaging = {
    page: search.page ?? 1,
    size: search.size ?? DEFAULT_PAGE_SIZE,
    onPage: (page) => setPaging(pagePatch(page)),
    onSize: (size) => setPaging(sizePatch(size)),
  };
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
        <TabsContent value="cards" className="pt-6"><AccountsTab profileCode={profile_code} isOwner={isOwner} /><AccountComparison profileCode={profile_code} /></TabsContent>
        <TabsContent value="statements" className="pt-6"><StatementsTab profileCode={profile_code} paging={paging} /></TabsContent>
        <TabsContent value="upload" className="pt-6"><UploadDropzone profileCode={profile_code} disabled={!isOwner} /></TabsContent>
        <TabsContent value="documents" className="pt-6"><DocumentsTab profileCode={profile_code} isOwner={isOwner} paging={paging} /></TabsContent>
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
              <dd className="tabular mt-0.5 text-ink">{formatTotal(a.credit_limit)}</dd>
            </div>
            <div>
              <dt className="text-[12px] text-subtle">Cycle closes</dt>
              <dd className="mt-0.5 text-ink">{a.cycle_close_day ? `Day ${a.cycle_close_day}` : "From statements"}</dd>
            </div>
          </dl>
          <ul className="mt-4 flex flex-col gap-1.5 border-t border-border pt-3">
            {(a.cards ?? []).map((c) => (
              <li key={c.card_code} className="flex items-center justify-between gap-3 text-[13px]">
                <span className="min-w-0 truncate text-ink">
                  <span className="tabular">•{c.last4}</span>
                  {c.wallet_name && <span className="ml-2 text-muted" title="Wallet name">{c.wallet_name}</span>}
                </span>
                <span className="shrink-0 text-muted">
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
  const cards = account.cards ?? [];
  const [wallet, setWallet] = useState<Record<string, string>>(() => Object.fromEntries(cards.map((c) => [c.card_code, c.wallet_name ?? ""])));
  const update = useUpdateAccount(profileCode);
  const updateCard = useUpdateCard(profileCode);
  const toast = useToast();
  const limitValid = limit.trim() === "" || /^\d+(\.\d{1,2})?$/.test(limit.trim());
  const save = async () => {
    try {
      await update.mutateAsync({ accountCode: account.account_code, nickname, creditLimit: limit });
      // Only the cards whose Wallet name changed: each one re-processes waiting Wallet payments.
      for (const c of cards) {
        const next = normalizeWalletName(wallet[c.card_code]);
        if (next !== (c.wallet_name ?? null)) await updateCard.mutateAsync({ cardCode: c.card_code, walletName: next });
      }
      toast({ title: "Card account saved", tone: "positive" });
      onClose();
    } catch (e) {
      toast({ title: "Couldn't save", description: errorMessage(e), tone: "danger" });
    }
  };
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
            loading={update.isPending || updateCard.isPending}
            onClick={() => void save()}
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
        {cards.map((c) => (
          <Field key={c.card_code} label={<>Wallet name <span className="tabular font-normal text-muted">•{c.last4}</span></>} hint="This card's name as the Wallet app shows it. The payment shortcut uses it to find the card.">
            {(id, d) => (
              <Input
                id={id}
                aria-describedby={d}
                value={wallet[c.card_code] ?? ""}
                maxLength={WALLET_NAME_MAX}
                autoComplete="off"
                onChange={(e) => setWallet((w) => ({ ...w, [c.card_code]: e.target.value }))}
                placeholder="e.g. Wio Credit"
              />
            )}
          </Field>
        ))}
      </div>
    </Dialog>
  );
}

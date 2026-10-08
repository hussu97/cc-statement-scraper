import { useMemo, useState } from "react";
import { KeyRound, Mail, MoreHorizontal, Pencil, Plus, Trash2 } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useFilterMeta } from "@/data/overview";
import {
  EMAIL_EVENT_TONE,
  isEmail,
  joinList,
  regexError,
  routedBanks,
  splitList,
  useAddMailbox,
  useDeleteMailbox,
  useDeleteRoute,
  useMailboxes,
  useSaveRoute,
  useSetMailboxSecret,
  useToggleMailbox,
  watchState,
  type RouteDraft,
} from "@/data/settings";
import type { Tables } from "@/lib/supabase";
import { errorMessage } from "@/data/api";
import { formatDateTime, formatRelative } from "@/lib/dates";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Textarea } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Menu, MenuContent, MenuItem, MenuTrigger, Segmented, Switch } from "@/components/ui/primitives";
import { EmptyState, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ConfirmDialog } from "@/components/rules/shared";

type Mailbox = Tables<"email_mailboxes">;
type Route = Tables<"email_routes">;
const PROVIDER: Record<string, string> = { gmail: "Gmail", outlook: "Outlook" };

export function EmailSection() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const mail = useMailboxes(profileCode);
  const meta = useFilterMeta(profileCode);
  const toggle = useToggleMailbox(profileCode);
  const delMailbox = useDeleteMailbox(profileCode);
  const delRoute = useDeleteRoute(profileCode);
  const toast = useToast();
  const [adding, setAdding] = useState(false);
  const [tokenFor, setTokenFor] = useState<Mailbox | null>(null);
  const [routeEdit, setRouteEdit] = useState<{ mailbox: Mailbox; route: Route | null } | null>(null);
  const [deleting, setDeleting] = useState<{ kind: "mailbox"; item: Mailbox } | { kind: "route"; item: Route } | null>(null);

  const bankName = useMemo(() => {
    const m = new Map((meta.data?.banks ?? []).map((b) => [b.bank_code, b.name]));
    return (code: string) => m.get(code) ?? code;
  }, [meta.data]);
  const routeByCode = useMemo(() => new Map((mail.data?.routes ?? []).map((r) => [r.route_code, r])), [mail.data]);

  return (
    <Card>
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            <Mail className="size-4 text-muted" aria-hidden /> Email
          </span>
        }
        action={
          isOwner && (
            <Button size="sm" icon={<Plus className="size-3.5" />} onClick={() => setAdding(true)}>
              Add mailbox
            </Button>
          )
        }
      />
      <p className="-mt-1 px-5 pb-3 text-[13px] text-muted">
        Bank Ledger reads statement PDFs from bank emails. Each mailbox has routes that say which bank's emails to pick up.
      </p>
      <QueryView
        query={mail}
        isEmpty={(d) => d.mailboxes.length === 0}
        empty={
          <EmptyState icon={<Mail />} title="No mailboxes connected" className="border-t border-border">
            {isOwner ? "Add the Gmail or Outlook address your banks send statements to." : "An owner of this ledger can connect one."}
          </EmptyState>
        }
      >
        {(d) => (
          <>
            <ul className="divide-y divide-border border-t border-border">
              {d.mailboxes.map((m) => {
                const routes = d.routes.filter((r) => r.mailbox_code === m.mailbox_code);
                const watch = watchState(m.watch_expires_at);
                return (
                  <li key={m.mailbox_code} className="px-5 py-4">
                    <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
                      <Badge>{PROVIDER[m.provider] ?? m.provider}</Badge>
                      <span className="min-w-0 flex-1 truncate text-sm font-medium text-ink">{m.mailbox_email}</span>
                      <Switch
                        checked={m.enabled}
                        disabled={!isOwner}
                        aria-label={m.enabled ? "Pause this mailbox" : "Resume this mailbox"}
                        onCheckedChange={(v) =>
                          toggle.mutate(
                            { mailboxCode: m.mailbox_code, enabled: v },
                            {
                              onSuccess: () => toast({ title: v ? "Mailbox resumed" : "Mailbox paused" }),
                              onError: (e) => toast({ title: "Couldn't change the mailbox", description: errorMessage(e), tone: "danger" }),
                            },
                          )
                        }
                      />
                      {isOwner && (
                        <Menu>
                          <MenuTrigger asChild>
                            <Button size="icon-sm" variant="ghost" aria-label={`Actions for ${m.mailbox_email}`}>
                              <MoreHorizontal className="size-4" />
                            </Button>
                          </MenuTrigger>
                          <MenuContent>
                            <MenuItem onSelect={() => setRouteEdit({ mailbox: m, route: null })}>
                              <Plus className="size-3.5" /> Add bank route
                            </MenuItem>
                            <MenuItem onSelect={() => setTokenFor(m)}>
                              <KeyRound className="size-3.5" /> Set refresh token
                            </MenuItem>
                            <MenuItem tone="danger" onSelect={() => setDeleting({ kind: "mailbox", item: m })}>
                              <Trash2 className="size-3.5" /> Remove mailbox
                            </MenuItem>
                          </MenuContent>
                        </Menu>
                      )}
                    </div>
                    <p className="mt-1.5 flex flex-wrap gap-x-4 gap-y-1 text-[12px] text-muted">
                      <span>Synced {formatRelative(m.last_synced_at)}</span>
                      {watch !== "none" && (
                        <span className={watch === "expired" ? "text-danger" : watch === "soon" ? "text-warn" : undefined}>
                          {watch === "expired" ? "Push watch expired" : `Push watch until ${formatDateTime(m.watch_expires_at)}`}
                        </span>
                      )}
                      {!m.enabled && <span className="text-warn">Paused</span>}
                    </p>
                    <div className="mt-3 rounded-md border border-border">
                      {routes.length === 0 ? (
                        <p className="px-3 py-2.5 text-[13px] text-muted">
                          No bank routes yet, so nothing is picked up.{" "}
                          {isOwner && (
                            <Button variant="link" className="text-[13px]" onClick={() => setRouteEdit({ mailbox: m, route: null })}>
                              Add one
                            </Button>
                          )}
                        </p>
                      ) : (
                        <ul className="divide-y divide-border">
                          {routes.map((r) => (
                            <li key={r.route_code} className="flex items-start gap-3 px-3 py-2.5">
                              <div className="min-w-0 flex-1">
                                <p className="text-[13px] font-medium text-ink">
                                  {bankName(r.bank_code)}
                                  {!r.enabled && <span className="ml-2 font-normal text-subtle">off</span>}
                                </p>
                                <p className="mt-0.5 text-[12px] break-words text-muted">
                                  {[
                                    r.sender_allowlist.length ? `From ${r.sender_allowlist.join(", ")}` : "From any sender",
                                    r.subject_keywords.length ? `subject has ${r.subject_keywords.join(" or ")}` : null,
                                    r.attachment_filename_regex ? `file matches ${r.attachment_filename_regex}` : null,
                                  ]
                                    .filter(Boolean)
                                    .join(" · ")}
                                </p>
                              </div>
                              {isOwner && (
                                <div className="flex shrink-0 gap-1">
                                  <Button size="icon-sm" variant="ghost" aria-label={`Edit ${bankName(r.bank_code)} route`} onClick={() => setRouteEdit({ mailbox: m, route: r })}>
                                    <Pencil className="size-3.5" />
                                  </Button>
                                  <Button size="icon-sm" variant="ghost" aria-label={`Delete ${bankName(r.bank_code)} route`} onClick={() => setDeleting({ kind: "route", item: r })}>
                                    <Trash2 className="size-3.5" />
                                  </Button>
                                </div>
                              )}
                            </li>
                          ))}
                        </ul>
                      )}
                    </div>
                  </li>
                );
              })}
            </ul>
            <div className="border-t border-border px-5 py-4">
              <h3 className="mb-2 text-[11px] font-medium tracking-[0.08em] text-subtle uppercase">Recent emails</h3>
              {d.events.length === 0 ? (
                <p className="text-[13px] text-muted">No statement emails processed yet.</p>
              ) : (
                <ul className="flex flex-col gap-2">
                  {d.events.map((e) => {
                    const r = e.route_code ? routeByCode.get(e.route_code) : undefined;
                    return (
                      <li key={e.event_code} className="flex items-center gap-3 text-[13px]">
                        <Badge tone={EMAIL_EVENT_TONE[e.status] ?? "neutral"} className="w-16 justify-center">
                          {e.status}
                        </Badge>
                        <span className="min-w-0 flex-1 truncate text-ink-2" title={e.detail ?? undefined}>
                          {e.attachment_filename ?? "Attachment"}
                          {r && <span className="text-subtle"> · {bankName(r.bank_code)}</span>}
                          {e.status === "failed" && e.detail && <span className="block truncate text-[12px] text-danger">{e.detail}</span>}
                        </span>
                        <span className="shrink-0 text-[12px] text-muted">{formatRelative(e.created_at)}</span>
                      </li>
                    );
                  })}
                </ul>
              )}
            </div>
          </>
        )}
      </QueryView>

      {adding && <AddMailboxDialog onClose={() => setAdding(false)} />}
      {tokenFor && <RefreshTokenDialog mailbox={tokenFor} onClose={() => setTokenFor(null)} />}
      {routeEdit && (
        <RouteDialog
          mailbox={routeEdit.mailbox}
          route={routeEdit.route}
          banks={meta.data?.banks ?? []}
          taken={routedBanks(mail.data?.routes ?? [], routeEdit.route?.route_code)}
          onClose={() => setRouteEdit(null)}
        />
      )}
      <ConfirmDialog
        open={!!deleting}
        onOpenChange={(o) => {
          if (!o) {
            setDeleting(null);
            delMailbox.reset();
            delRoute.reset();
          }
        }}
        title={deleting?.kind === "mailbox" ? "Remove this mailbox?" : "Delete this route?"}
        confirmLabel={deleting?.kind === "mailbox" ? "Remove mailbox" : "Delete route"}
        pending={delMailbox.isPending || delRoute.isPending}
        error={delMailbox.error ?? delRoute.error}
        onConfirm={() => {
          if (!deleting) return;
          const done = { onSuccess: () => (toast({ title: deleting.kind === "mailbox" ? "Mailbox removed" : "Route deleted", tone: "positive" }), setDeleting(null)) };
          if (deleting.kind === "mailbox") delMailbox.mutate(deleting.item.mailbox_code, done);
          else delRoute.mutate(deleting.item.route_code, done);
        }}
      >
        {deleting?.kind === "mailbox"
          ? `Bank Ledger will stop reading ${deleting.item.mailbox_email}. Statements already imported stay.`
          : deleting
            ? `Emails from ${bankName(deleting.item.bank_code)} will no longer be picked up. Statements already imported stay.`
            : null}
      </ConfirmDialog>
    </Card>
  );
}

function AddMailboxDialog({ onClose }: { onClose: () => void }) {
  const { profile_code: profileCode } = useActiveProfile();
  const add = useAddMailbox(profileCode);
  const toast = useToast();
  const [provider, setProvider] = useState<"gmail" | "outlook">("gmail");
  const [email, setEmail] = useState("");
  const [touched, setTouched] = useState(false);
  const invalid = !isEmail(email);
  const submit = () => {
    setTouched(true);
    if (invalid) return;
    add.mutate(
      { provider, email },
      {
        onSuccess: () => {
          toast({ title: "Mailbox added", description: "Set its refresh token so Bank Ledger can read it.", tone: "positive" });
          onClose();
        },
      },
    );
  };
  return (
    <Dialog
      open
      onOpenChange={(o) => !o && onClose()}
      title="Add a mailbox"
      className="max-w-md"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" loading={add.isPending} onClick={submit}>
            Add mailbox
          </Button>
        </>
      }
    >
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <div className="flex flex-col gap-1.5">
          <span className="text-[13px] font-medium text-ink-2">Provider</span>
          <Segmented<"gmail" | "outlook">
            ariaLabel="Provider"
            value={provider}
            onChange={setProvider}
            options={[
              { value: "gmail", label: "Gmail" },
              { value: "outlook", label: "Outlook" },
            ]}
            className="self-start"
          />
        </div>
        <Field label="Address" error={touched && invalid ? "Enter an email address like you@example.com." : add.error ? errorMessage(add.error) : null}>
          {(id, d) => <Input id={id} aria-describedby={d} aria-invalid={touched && invalid} type="email" autoComplete="off" value={email} onChange={(e) => setEmail(e.target.value)} autoFocus />}
        </Field>
        <button type="submit" hidden />
      </form>
    </Dialog>
  );
}

function RefreshTokenDialog({ mailbox, onClose }: { mailbox: Mailbox; onClose: () => void }) {
  const set = useSetMailboxSecret();
  const toast = useToast();
  const [value, setValue] = useState("");
  const submit = () => {
    if (!value.trim()) return;
    set.mutate(
      { mailboxCode: mailbox.mailbox_code, value: value.trim() },
      {
        onSuccess: () => {
          setValue("");
          toast({ title: "Refresh token saved", tone: "positive" });
          onClose();
        },
      },
    );
  };
  return (
    <Dialog
      open
      onOpenChange={(o) => !o && onClose()}
      title="Set refresh token"
      description={mailbox.mailbox_email}
      className="max-w-md"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" loading={set.isPending} disabled={!value.trim()} onClick={submit}>
            Save token
          </Button>
        </>
      }
    >
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <Field
          label="OAuth refresh token"
          hint="Stored encrypted. It's never shown again; paste a new one to replace it."
          error={set.error ? errorMessage(set.error) : null}
        >
          {(id, d) => (
            <Input id={id} aria-describedby={d} type="password" autoComplete="off" spellCheck={false} value={value} onChange={(e) => setValue(e.target.value)} autoFocus className="font-mono" />
          )}
        </Field>
      </form>
    </Dialog>
  );
}

function RouteDialog({
  mailbox,
  route,
  banks,
  taken,
  onClose,
}: {
  mailbox: Mailbox;
  route: Route | null;
  banks: { bank_code: string; name: string }[];
  taken: Set<string>;
  onClose: () => void;
}) {
  const { profile_code: profileCode } = useActiveProfile();
  const save = useSaveRoute(profileCode);
  const toast = useToast();
  const free = banks.filter((b) => !taken.has(b.bank_code));
  const [bank, setBank] = useState(route?.bank_code ?? free[0]?.bank_code ?? "");
  const [senders, setSenders] = useState(joinList(route?.sender_allowlist));
  const [keywords, setKeywords] = useState(joinList(route?.subject_keywords));
  const [regex, setRegex] = useState(route?.attachment_filename_regex ?? "");
  const [enabled, setEnabled] = useState(route?.enabled ?? true);
  const reErr = regexError(regex);

  const submit = () => {
    if (!bank || reErr) return;
    const draft: RouteDraft = {
      route_code: route?.route_code,
      mailbox_code: mailbox.mailbox_code,
      bank_code: bank,
      enabled,
      sender_allowlist: splitList(senders),
      subject_keywords: splitList(keywords),
      attachment_filename_regex: regex,
    };
    save.mutate(draft, {
      onSuccess: () => {
        toast({ title: route ? "Route saved" : "Route added", tone: "positive" });
        onClose();
      },
    });
  };

  return (
    <Dialog
      open
      onOpenChange={(o) => !o && onClose()}
      title={route ? "Edit bank route" : "Add a bank route"}
      description={mailbox.mailbox_email}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" loading={save.isPending} disabled={!bank || !!reErr} onClick={submit}>
            {route ? "Save route" : "Add route"}
          </Button>
        </>
      }
    >
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <Field label="Bank" hint={route ? "To change the bank, delete this route and add a new one." : free.length === 0 ? "Every bank already has a route." : "One route per bank."}>
          {() => (
            <Select
              ariaLabel="Bank"
              value={bank || undefined}
              onValueChange={setBank}
              disabled={!!route}
              placeholder="Choose a bank"
              options={(route ? banks : free).map((b) => ({ value: b.bank_code, label: b.name }))}
              className="w-full"
            />
          )}
        </Field>
        <Field label="Only from these senders" hint="Comma-separated full email addresses. Leave empty for any sender.">
          {(id, d) => <Textarea id={id} aria-describedby={d} value={senders} onChange={(e) => setSenders(e.target.value)} placeholder="statements@bank.ae" className="min-h-16 font-mono text-[13px]" spellCheck={false} />}
        </Field>
        <Field label="Subject contains" hint="Comma-separated; any one is enough. Leave empty to skip this check.">
          {(id, d) => <Input id={id} aria-describedby={d} value={keywords} onChange={(e) => setKeywords(e.target.value)} placeholder="e-statement, credit card statement" />}
        </Field>
        <Field label="Attachment name pattern" hint="Optional regular expression for the PDF file name. Case doesn't matter." error={reErr}>
          {(id, d) => (
            <Input id={id} aria-describedby={d} aria-invalid={!!reErr} value={regex} onChange={(e) => setRegex(e.target.value)} placeholder="statement.*\.pdf$" className="font-mono text-[13px]" spellCheck={false} />
          )}
        </Field>
        <label className="flex items-center justify-between gap-3 text-sm text-ink">
          Route enabled
          <Switch checked={enabled} onCheckedChange={setEnabled} aria-label="Route enabled" />
        </label>
        {save.error ? <p className="text-[13px] text-danger">{errorMessage(save.error)}</p> : null}
        <button type="submit" hidden />
      </form>
    </Dialog>
  );
}

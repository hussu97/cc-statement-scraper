import { useState } from "react";
import { AlertTriangle, Check, Copy, KeySquare, Plus } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { TOKEN_SCOPES, tokenScopeLabel, useCreateServiceToken, useRevokeServiceToken, useServiceTokens } from "@/data/settings";
import { errorMessage } from "@/data/api";
import { formatDate, formatRelative } from "@/lib/dates";
import { cn } from "@/lib/cn";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/primitives";
import { EmptyState, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ConfirmDialog } from "@/components/rules/shared";

interface TokenRow {
  token_code: string;
  name: string;
  token_prefix: string;
  scopes: string[];
  created_at: string;
  last_used_at: string | null;
  revoked_at: string | null;
}

export function TokensSection() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const tokens = useServiceTokens(profileCode);
  const revoke = useRevokeServiceToken(profileCode);
  const toast = useToast();
  const [creating, setCreating] = useState(false);
  const [revoking, setRevoking] = useState<TokenRow | null>(null);

  return (
    <Card>
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            <KeySquare className="size-4 text-muted" aria-hidden /> Scraper & automation tokens
          </span>
        }
        action={
          isOwner && (
            <Button size="sm" icon={<Plus className="size-3.5" />} onClick={() => setCreating(true)}>
              New token
            </Button>
          )
        }
      />
      <p className="-mt-1 px-5 pb-3 text-[13px] text-muted">Tokens let the local scraper and other tools send data to this ledger without your password.</p>
      <QueryView
        query={tokens}
        isEmpty={(d) => d.length === 0}
        empty={
          <EmptyState title="No tokens yet" className="border-t border-border">
            {isOwner ? "Create one for the scraper, then put it in the scraper's settings." : "An owner of this ledger can create one."}
          </EmptyState>
        }
      >
        {(list) => (
          <ul className="divide-y divide-border border-t border-border">
            {list.map((t) => (
              <li key={t.token_code} className={cn("flex flex-col gap-2 px-5 py-3 sm:flex-row sm:items-center sm:gap-4", t.revoked_at && "opacity-60")}>
                <div className="min-w-0 flex-1">
                  <p className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-ink">
                    <span className="font-medium break-words">{t.name}</span>
                    <code className="font-mono text-[12px] text-muted">{t.token_prefix}…</code>
                    {t.revoked_at && <Badge tone="danger">revoked</Badge>}
                  </p>
                  <p className="mt-1 flex flex-wrap gap-1">
                    {t.scopes.map((s) => (
                      <Badge key={s}>{tokenScopeLabel(s)}</Badge>
                    ))}
                  </p>
                </div>
                <div className="flex items-center justify-between gap-3 sm:justify-end">
                  <p className="text-[12px] text-muted sm:text-right">
                    Created {formatDate(t.created_at.slice(0, 10))}
                    <br />
                    {t.revoked_at ? `Revoked ${formatRelative(t.revoked_at)}` : `Last used ${formatRelative(t.last_used_at)}`}
                  </p>
                  {isOwner && !t.revoked_at && (
                    <Button size="sm" variant="danger" onClick={() => setRevoking(t)}>
                      Revoke
                    </Button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </QueryView>

      {creating && <CreateTokenDialog onClose={() => setCreating(false)} />}
      <ConfirmDialog
        open={!!revoking}
        onOpenChange={(o) => {
          if (!o) {
            setRevoking(null);
            revoke.reset();
          }
        }}
        title="Revoke this token?"
        confirmLabel="Revoke token"
        pending={revoke.isPending}
        error={revoke.error}
        onConfirm={() =>
          revoking &&
          revoke.mutate(revoking.token_code, {
            onSuccess: () => {
              toast({ title: "Token revoked", tone: "positive" });
              setRevoking(null);
            },
          })
        }
      >
        Anything using “{revoking?.name}” will stop working straight away. This can't be undone; create a new token if you need one.
      </ConfirmDialog>
    </Card>
  );
}

function CreateTokenDialog({ onClose }: { onClose: () => void }) {
  const { profile_code: profileCode } = useActiveProfile();
  const create = useCreateServiceToken(profileCode);
  const toast = useToast();
  const [name, setName] = useState("");
  const [scopes, setScopes] = useState<string[]>([TOKEN_SCOPES[0].value]);
  const [touched, setTouched] = useState(false);
  // The plaintext lives only in this component's state, never in the query cache.
  const [secret, setSecret] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const nameErr = !name.trim() ? "Name it after where it's used, e.g. “Laptop scraper”." : null;
  const scopeErr = scopes.length === 0 ? "Choose at least one permission." : null;

  const submit = () => {
    setTouched(true);
    if (nameErr || scopeErr) return;
    create.mutate(
      { name, scopes },
      {
        onSuccess: (res) => {
          setSecret(res.token);
          create.reset();
          toast({ title: "Token created", tone: "positive" });
        },
      },
    );
  };

  const close = () => {
    setSecret(null);
    onClose();
  };

  if (secret) {
    return (
      <Dialog
        open
        onOpenChange={(o) => !o && close()}
        title="Copy your token"
        className="max-w-md"
        footer={
          <Button variant="primary" onClick={close}>
            I've saved it
          </Button>
        }
      >
        <div className="flex flex-col gap-3">
          <p className="flex items-start gap-2 rounded-md bg-warn-soft px-3 py-2 text-[13px] text-ink-2">
            <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warn" aria-hidden />
            This is the only time you'll see it. Store it somewhere safe, like the scraper's .env file or a password manager.
          </p>
          <div className="flex items-stretch gap-2">
            <code className="min-w-0 flex-1 rounded-md border border-border bg-surface-2 px-3 py-2 font-mono text-[12px] break-all text-ink select-all">{secret}</code>
            <Button
              variant="secondary"
              size="icon"
              aria-label="Copy token"
              onClick={() =>
                void navigator.clipboard.writeText(secret).then(
                  () => {
                    setCopied(true);
                    toast({ title: "Token copied" });
                  },
                  () => toast({ title: "Couldn't copy", description: "Select the token and copy it by hand.", tone: "danger" }),
                )
              }
            >
              {copied ? <Check className="size-4 text-positive" /> : <Copy className="size-4" />}
            </Button>
          </div>
        </div>
      </Dialog>
    );
  }

  return (
    <Dialog
      open
      onOpenChange={(o) => !o && close()}
      title="New token"
      className="max-w-md"
      footer={
        <>
          <Button variant="ghost" onClick={close}>
            Cancel
          </Button>
          <Button variant="primary" loading={create.isPending} onClick={submit}>
            Create token
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
        <Field label="Name" error={touched ? nameErr : null}>
          {(id, d) => <Input id={id} aria-describedby={d} aria-invalid={touched && !!nameErr} value={name} onChange={(e) => setName(e.target.value)} placeholder="Laptop scraper" maxLength={80} autoFocus />}
        </Field>
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1.5 text-[13px] font-medium text-ink-2">Allowed to</legend>
          {TOKEN_SCOPES.map((s) => (
            <label key={s.value} className="flex cursor-pointer items-center gap-2.5 text-sm text-ink">
              <Checkbox
                checked={scopes.includes(s.value)}
                onCheckedChange={(v) => setScopes((l) => (v === true ? [...l, s.value] : l.filter((x) => x !== s.value)))}
              />
              {s.label}
            </label>
          ))}
          {touched && scopeErr && <p className="text-xs text-danger">{scopeErr}</p>}
        </fieldset>
        {create.error ? <p className="text-[13px] text-danger">{errorMessage(create.error)}</p> : null}
        <button type="submit" hidden />
      </form>
    </Dialog>
  );
}

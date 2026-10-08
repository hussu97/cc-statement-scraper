import { useState } from "react";
import { Fingerprint, LogOut, Pencil, Plus } from "lucide-react";
import { signOut, useAuth } from "@/data/auth";
import { passkeysSupported, setPasskeyOfferDeclined, useDeletePasskey, usePasskeys, useRegisterPasskey, useRenamePasskey, type Passkey } from "@/data/passkeys";
import { errorMessage } from "@/data/api";
import { formatDate, formatRelative } from "@/lib/dates";
import { Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { EmptyState, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ConfirmDialog } from "@/components/rules/shared";

export function AccountTab() {
  const { email } = useAuth();
  return (
    <div className="flex flex-col gap-4">
      <Card>
        <CardHeader title="Signed in" />
        <div className="flex flex-wrap items-center justify-between gap-4 px-5 pb-5">
          <p className="text-[13px] text-muted">
            <span className="font-medium text-ink">{email}</span>
            <br />
            You sign in with a one-time code sent to this email, or with a passkey.
          </p>
          <Button icon={<LogOut className="size-3.5" />} onClick={() => void signOut()}>
            Sign out
          </Button>
        </div>
      </Card>
      <PasskeysSection />
    </div>
  );
}

function PasskeysSection() {
  const { userId } = useAuth();
  const passkeys = usePasskeys(userId);
  const add = useRegisterPasskey(userId);
  const remove = useDeletePasskey(userId);
  const toast = useToast();
  const [renaming, setRenaming] = useState<Passkey | null>(null);
  const [removing, setRemoving] = useState<Passkey | null>(null);
  const supported = passkeysSupported();

  const onAdd = () =>
    add.mutate(undefined, {
      onSuccess: (pk) => {
        if (!pk) return; // cancelled in the browser prompt
        if (userId) setPasskeyOfferDeclined(userId, false);
        toast({ title: "Passkey added", description: "Use it next time you sign in.", tone: "positive" });
      },
      onError: (e) => toast({ title: "Couldn't add a passkey", description: errorMessage(e), tone: "danger" }),
    });

  return (
    <Card>
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            <Fingerprint className="size-4 text-muted" aria-hidden /> Passkeys
          </span>
        }
        action={
          supported && (
            <Button size="sm" icon={<Plus className="size-3.5" />} loading={add.isPending} onClick={onAdd}>
              Add a passkey
            </Button>
          )
        }
      />
      <p className="-mt-1 px-5 pb-3 text-[13px] text-muted">
        Sign in with Face ID, Touch ID or your device's screen lock instead of an email code. Passkeys sync through your password manager (for example iCloud Keychain), so one passkey usually covers all your Apple devices.
        {!supported && " This browser doesn't support passkeys."}
      </p>
      <QueryView
        query={passkeys}
        isEmpty={(d) => d.length === 0}
        empty={
          <EmptyState title="No passkeys yet" className="border-t border-border">
            {supported ? "Add one to skip the email code next time." : "Open Bank Ledger in a browser that supports passkeys to add one."}
          </EmptyState>
        }
      >
        {(list) => (
          <ul className="divide-y divide-border border-t border-border">
            {list.map((pk) => (
              <li key={pk.id} className="flex flex-col gap-2 px-5 py-3 sm:flex-row sm:items-center sm:gap-4">
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium break-words text-ink">{pk.friendly_name || "Passkey"}</p>
                  <p className="mt-0.5 text-[12px] text-muted">
                    Added {formatDate(pk.created_at.slice(0, 10))} · {pk.last_used_at ? `last used ${formatRelative(pk.last_used_at)}` : "not used yet"}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <Button size="sm" variant="ghost" icon={<Pencil className="size-3.5" />} onClick={() => setRenaming(pk)}>
                    Rename
                  </Button>
                  <Button size="sm" variant="danger" onClick={() => setRemoving(pk)}>
                    Remove
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </QueryView>

      {renaming && <RenamePasskeyDialog passkey={renaming} onClose={() => setRenaming(null)} />}
      <ConfirmDialog
        open={!!removing}
        onOpenChange={(o) => {
          if (!o) {
            setRemoving(null);
            remove.reset();
          }
        }}
        title="Remove this passkey?"
        confirmLabel="Remove passkey"
        pending={remove.isPending}
        error={remove.error}
        onConfirm={() =>
          removing &&
          remove.mutate(removing.id, {
            onSuccess: () => {
              toast({ title: "Passkey removed", tone: "positive" });
              setRemoving(null);
            },
          })
        }
      >
        “{removing?.friendly_name || "Passkey"}” will no longer sign you in to Bank Ledger. You can still sign in with an email code. Also delete it from your password manager so it isn't offered again.
      </ConfirmDialog>
    </Card>
  );
}

function RenamePasskeyDialog({ passkey, onClose }: { passkey: Passkey; onClose: () => void }) {
  const { userId } = useAuth();
  const rename = useRenamePasskey(userId);
  const toast = useToast();
  const [name, setName] = useState(passkey.friendly_name ?? "");
  const err = !name.trim() ? "Give it a name, e.g. “Work laptop”." : name.trim().length > 120 ? "Keep it under 120 characters." : null;
  const submit = () => {
    if (err) return;
    rename.mutate(
      { id: passkey.id, name },
      {
        onSuccess: () => {
          toast({ title: "Passkey renamed", tone: "positive" });
          onClose();
        },
      },
    );
  };
  return (
    <Dialog
      open
      onOpenChange={(o) => !o && onClose()}
      title="Rename passkey"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" loading={rename.isPending} disabled={!!err} onClick={submit}>
            Save
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
        <Field label="Name" error={name ? (err ?? undefined) : undefined}>
          {(id) => <Input id={id} value={name} maxLength={120} onChange={(e) => setName(e.target.value)} autoFocus />}
        </Field>
        {rename.error && (
          <p role="alert" className="mt-3 text-sm text-danger">
            {errorMessage(rename.error)}
          </p>
        )}
      </form>
    </Dialog>
  );
}

import { useState } from "react";
import { LockKeyhole } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { SECRET_KEYS, secretStatus, useProfileSecrets, useSetProfileSecret } from "@/data/settings";
import { errorMessage } from "@/data/api";
import { formatDate } from "@/lib/dates";
import { Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ConfirmDialog } from "@/components/rules/shared";

type SecretKey = (typeof SECRET_KEYS)[number];

export function SecretsSection() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const secrets = useProfileSecrets(profileCode);
  const setSecret = useSetProfileSecret(profileCode);
  const toast = useToast();
  const [editing, setEditing] = useState<SecretKey | null>(null);
  const [clearing, setClearing] = useState<SecretKey | null>(null);

  return (
    <Card id="statement-passwords" className="scroll-mt-20">
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            <LockKeyhole className="size-4 text-muted" aria-hidden /> Statement passwords
          </span>
        }
      />
      <p className="-mt-1 px-5 pb-3 text-[13px] text-muted">
        Banks lock statement PDFs with a password. Bank Ledger stores them encrypted and uses them only to open your statements. They're never shown back.
      </p>
      <QueryView query={secrets} loading={<div className="h-40" />}>
        {(list) => (
          <ul className="divide-y divide-border border-t border-border">
            {SECRET_KEYS.map((k) => {
              const st = secretStatus(list, k.key);
              return (
                <li key={k.key} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-5 py-3">
                  <span className="min-w-0 flex-1 text-sm text-ink">{k.label}</span>
                  <span className={st.set ? "text-[12px] text-positive" : "text-[12px] text-subtle"}>
                    {st.set ? `Set · updated ${formatDate(st.updatedAt, "short")}` : "Not set"}
                  </span>
                  {isOwner && (
                    <div className="flex gap-1">
                      <Button size="sm" variant="secondary" onClick={() => setEditing(k)}>
                        {st.set ? "Replace" : "Set"}
                      </Button>
                      {st.set && (
                        <Button size="sm" variant="ghost" onClick={() => setClearing(k)}>
                          Clear
                        </Button>
                      )}
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </QueryView>

      {editing && <SecretDialog secret={editing} onClose={() => setEditing(null)} />}
      <ConfirmDialog
        open={!!clearing}
        onOpenChange={(o) => {
          if (!o) {
            setClearing(null);
            setSecret.reset();
          }
        }}
        title="Clear this password?"
        confirmLabel="Clear password"
        pending={setSecret.isPending}
        error={setSecret.error}
        onConfirm={() =>
          clearing &&
          setSecret.mutate(
            { key: clearing.key, value: "" },
            {
              onSuccess: () => {
                toast({ title: `${clearing.label} cleared`, tone: "positive" });
                setClearing(null);
              },
            },
          )
        }
      >
        New {clearing?.label.replace(/ password$/, "")} statements that need it won't open until you set it again.
      </ConfirmDialog>
    </Card>
  );
}

function SecretDialog({ secret, onClose }: { secret: SecretKey; onClose: () => void }) {
  const { profile_code: profileCode } = useActiveProfile();
  const set = useSetProfileSecret(profileCode);
  const toast = useToast();
  const [value, setValue] = useState("");
  const submit = () => {
    if (!value) return;
    set.mutate(
      { key: secret.key, value },
      {
        onSuccess: () => {
          setValue("");
          toast({ title: `${secret.label} saved`, tone: "positive" });
          onClose();
        },
      },
    );
  };
  return (
    <Dialog
      open
      onOpenChange={(o) => !o && onClose()}
      title={secret.label}
      className="max-w-md"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" loading={set.isPending} disabled={!value} onClick={submit}>
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
        <Field label={secret.key === "ADCB_CID" ? "Customer ID" : "Password"} hint="Write-only: you can replace it later, but not see it." error={set.error ? errorMessage(set.error) : null}>
          {(id, d) => <Input id={id} aria-describedby={d} type="password" autoComplete="new-password" value={value} onChange={(e) => setValue(e.target.value)} autoFocus />}
        </Field>
      </form>
    </Dialog>
  );
}

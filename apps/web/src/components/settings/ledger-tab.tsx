import { useState } from "react";
import { Check, Copy } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useRenameProfile } from "@/data/settings";
import { errorMessage } from "@/data/api";
import { Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { ThemeToggle } from "@/components/chrome";
import { ViewerNote } from "@/components/rules/shared";

export function AppearanceTab() {
  return (
    <Card>
      <CardHeader title="Theme" />
      <div className="flex flex-wrap items-center justify-between gap-4 px-5 pb-5">
        <p className="max-w-md text-[13px] text-muted">
          Light, follow your device, or dark. The choice is saved in this browser only.
        </p>
        <div className="flex items-center gap-3">
          <span className="text-[12px] text-subtle">Light · System · Dark</span>
          <ThemeToggle />
        </div>
      </div>
    </Card>
  );
}

export function LedgerTab() {
  const profile = useActiveProfile();
  const rename = useRenameProfile(profile.profile_code);
  const toast = useToast();
  const [name, setName] = useState(profile.name);
  const [copied, setCopied] = useState(false);
  const trimmed = name.trim();
  const err = !trimmed ? "Give the ledger a name." : trimmed.length > 80 ? "Keep it under 80 characters." : null;
  const dirty = trimmed !== profile.name;

  return (
    <div className="flex flex-col gap-4">
      <Card>
        <CardHeader title="This ledger" />
        <form
          className="flex flex-col gap-4 px-5 pb-5"
          onSubmit={(e) => {
            e.preventDefault();
            if (err || !dirty) return;
            rename.mutate(trimmed, {
              onSuccess: () => toast({ title: "Ledger renamed", tone: "positive" }),
              onError: (e2) => toast({ title: "Couldn't rename", description: errorMessage(e2), tone: "danger" }),
            });
          }}
        >
          <div className="flex flex-col gap-3 sm:flex-row sm:items-end">
            <Field label="Name" error={dirty ? err : null} className="flex-1">
              {(id, d) => <Input id={id} aria-describedby={d} aria-invalid={dirty && !!err} value={name} onChange={(e) => setName(e.target.value)} disabled={!profile.isOwner} maxLength={80} />}
            </Field>
            {profile.isOwner && (
              <Button type="submit" variant="primary" disabled={!dirty || !!err} loading={rename.isPending}>
                Save name
              </Button>
            )}
          </div>
          {!profile.isOwner && <ViewerNote>Only owners can rename this ledger.</ViewerNote>}
        </form>
        <dl className="grid gap-4 border-t border-border px-5 py-4 sm:grid-cols-2">
          <div>
            <dt className="text-[12px] text-muted">Profile key</dt>
            <dd className="mt-1 flex items-center gap-2">
              <code className="font-mono text-sm text-ink">{profile.key}</code>
              <Button
                size="icon-sm"
                variant="ghost"
                aria-label="Copy profile key"
                onClick={() =>
                  void navigator.clipboard.writeText(profile.key).then(() => {
                    setCopied(true);
                    toast({ title: "Profile key copied" });
                  })
                }
              >
                {copied ? <Check className="size-3.5 text-positive" /> : <Copy className="size-3.5" />}
              </Button>
            </dd>
            <p className="mt-1 text-[12px] text-subtle">The scraper uses this with a token to know where to send statements.</p>
          </div>
          <div>
            <dt className="text-[12px] text-muted">Base currency</dt>
            <dd className="mt-1 font-mono text-sm text-ink">{profile.base_currency}</dd>
            <p className="mt-1 text-[12px] text-subtle">Totals and budgets are shown in this currency.</p>
          </div>
        </dl>
      </Card>
    </div>
  );
}

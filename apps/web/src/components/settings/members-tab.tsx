import { useState } from "react";
import { UserPlus, Users } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useAuth } from "@/data/auth";
import { addMemberError, isEmail, shortUserId, useAddMember, useMembers } from "@/data/settings";
import { formatDate } from "@/lib/dates";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { EmptyState, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ViewerNote } from "@/components/rules/shared";

const ROLES = [
  { value: "viewer", label: "Viewer · can look, not change" },
  { value: "owner", label: "Owner · can change everything" },
];

export function MembersTab() {
  const { profile_code: profileCode, name, isOwner } = useActiveProfile();
  const { userId } = useAuth();
  const members = useMembers(profileCode);

  return (
    <div className="flex flex-col gap-4">
      <Card>
        <CardHeader title="People with access" />
        <QueryView
          query={members}
          isEmpty={(d) => d.length === 0}
          empty={<EmptyState icon={<Users />} title="No members found" />}
        >
          {(list) => (
            <ul className="divide-y divide-border border-t border-border">
              {list.map((m) => {
                const me = m.user_id === userId;
                return (
                  <li key={m.user_id} className="flex items-center gap-3 px-5 py-3">
                    <span className="flex size-8 shrink-0 items-center justify-center rounded-pill bg-surface-2 text-[12px] font-medium text-ink-2">
                      {me ? "You" : shortUserId(m.user_id).slice(0, 2).toUpperCase()}
                    </span>
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm text-ink">{me ? "You" : <span className="font-mono text-[13px]">Member {shortUserId(m.user_id)}</span>}</p>
                      <p className="text-[12px] text-muted">Joined {formatDate(m.created_at.slice(0, 10))}</p>
                    </div>
                    <Badge tone={m.role === "owner" ? "accent" : "neutral"}>{m.role === "owner" ? "Owner" : "Viewer"}</Badge>
                  </li>
                );
              })}
            </ul>
          )}
        </QueryView>
      </Card>

      {isOwner ? <AddMember ledgerName={name} /> : <ViewerNote>Only owners can invite people to this ledger.</ViewerNote>}
    </div>
  );
}

function AddMember({ ledgerName }: { ledgerName: string }) {
  const { profile_code: profileCode } = useActiveProfile();
  const add = useAddMember(profileCode);
  const toast = useToast();
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<"owner" | "viewer">("viewer");
  const [touched, setTouched] = useState(false);
  const invalid = !isEmail(email);

  const submit = () => {
    setTouched(true);
    if (invalid) return;
    add.mutate(
      { email, role },
      {
        onSuccess: (result) => {
          toast(
            result === "invited"
              ? { title: "Invite saved", description: `${email.trim()} will get access to ${ledgerName} the first time they sign in to Ledger.`, tone: "positive" }
              : { title: "Member added", description: `${email.trim()} can now open ${ledgerName}.`, tone: "positive" },
          );
          setEmail("");
          setTouched(false);
        },
      },
    );
  };

  return (
    <Card>
      <CardHeader title="Add someone" />
      <form
        className="flex flex-col gap-3 px-5 pb-5"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <p className="text-[13px] text-muted">If they haven't used Ledger yet, they get access the first time they sign in with this email. Adding someone who's already a member changes their role.</p>
        <div className="grid gap-3 sm:grid-cols-[minmax(0,1fr)_16rem_auto] sm:items-end">
          <Field label="Email" error={touched && invalid ? "Enter an email address like them@example.com." : null}>
            {(id, d) => (
              <Input
                id={id}
                aria-describedby={d}
                aria-invalid={touched && invalid}
                type="email"
                autoComplete="off"
                value={email}
                onChange={(e) => {
                  setEmail(e.target.value);
                  if (add.error) add.reset();
                }}
              />
            )}
          </Field>
          <Field label="Role">{() => <Select ariaLabel="Role" value={role} onValueChange={(v) => setRole(v as "owner" | "viewer")} options={ROLES} className="w-full" />}</Field>
          <Button type="submit" variant="primary" icon={<UserPlus className="size-4" />} loading={add.isPending}>
            Add
          </Button>
        </div>
        {add.error ? <p className="text-[13px] text-danger" role="alert">{addMemberError(add.error)}</p> : null}
      </form>
    </Card>
  );
}

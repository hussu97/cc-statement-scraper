import { useState } from "react";
import { MailQuestionMark, UserPlus, Users } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useAuth } from "@/data/auth";
import {
  canRemoveMember,
  inviteMemberError,
  inviteNotice,
  isEmail,
  memberActionError,
  memberInitials,
  memberKey,
  memberName,
  resendInviteError,
  resendNotice,
  useCancelInvite,
  useInviteMember,
  useMembers,
  useRemoveMember,
  useResendInvite,
  type ProfileMember,
} from "@/data/settings";
import { formatDate } from "@/lib/dates";
import { Badge, Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { EmptyState, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ConfirmDialog, ViewerNote } from "@/components/rules/shared";

const ROLES = [
  { value: "viewer", label: "Viewer · can look, not change" },
  { value: "owner", label: "Owner · can change everything" },
];

export function MembersTab() {
  const { profile_code: profileCode, name, isOwner } = useActiveProfile();
  const { userId } = useAuth();
  const members = useMembers(profileCode);
  const remove = useRemoveMember(profileCode);
  const cancel = useCancelInvite(profileCode);
  const resend = useResendInvite(profileCode);
  const toast = useToast();
  const [removing, setRemoving] = useState<ProfileMember | null>(null);
  const [cancelling, setCancelling] = useState<ProfileMember | null>(null);

  const resendTo = (email: string) =>
    resend.mutate(email, {
      onSuccess: () => toast(resendNotice(email)),
      onError: (e) => toast({ title: "Invite not sent", description: resendInviteError(e), tone: "danger" }),
    });

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
                const me = !!m.user_id && m.user_id === userId;
                return (
                  <li key={memberKey(m)} className="flex flex-wrap items-center gap-3 px-5 py-3">
                    <span
                      aria-hidden
                      className="flex size-8 shrink-0 items-center justify-center rounded-pill bg-surface-2 text-[12px] font-medium text-ink-2"
                    >
                      {m.pending ? <MailQuestionMark className="size-4 text-subtle" /> : memberInitials(m)}
                    </span>
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm text-ink">
                        {memberName(m)}
                        {me && <span className="text-muted"> (you)</span>}
                      </p>
                      <p className="text-[12px] text-muted">
                        {m.pending
                          ? `Invited ${formatDate(m.created_at.slice(0, 10))} · gets access when they accept`
                          : `Joined ${formatDate(m.created_at.slice(0, 10))}`}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      {m.pending && <Badge tone="warn">Pending</Badge>}
                      <Badge tone={m.role === "owner" ? "accent" : "neutral"}>{m.role === "owner" ? "Owner" : "Viewer"}</Badge>
                      {isOwner && m.pending && m.email && (
                        <Button
                          size="sm"
                          variant="ghost"
                          loading={resend.isPending && resend.variables === m.email}
                          disabled={resend.isPending}
                          onClick={() => m.email && resendTo(m.email)}
                        >
                          Resend invite
                        </Button>
                      )}
                      {isOwner && m.pending && (
                        <Button size="sm" variant="ghost" onClick={() => setCancelling(m)}>
                          Cancel invite
                        </Button>
                      )}
                      {isOwner && canRemoveMember(m, list, userId) && (
                        <Button size="sm" variant="danger" onClick={() => setRemoving(m)}>
                          Remove
                        </Button>
                      )}
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </QueryView>
      </Card>

      {isOwner ? <AddMember ledgerName={name} /> : <ViewerNote>Only owners can invite or remove people.</ViewerNote>}

      <ConfirmDialog
        open={!!removing}
        onOpenChange={(o) => {
          if (!o) {
            setRemoving(null);
            remove.reset();
          }
        }}
        title="Remove access?"
        confirmLabel="Remove"
        pending={remove.isPending}
        error={remove.error ? new Error(memberActionError(remove.error)) : null}
        onConfirm={() =>
          removing?.user_id &&
          remove.mutate(removing.user_id, {
            onSuccess: () => {
              toast({ title: "Access removed", description: `${memberName(removing)} can no longer open ${name}.`, tone: "positive" });
              setRemoving(null);
            },
          })
        }
      >
        {removing ? memberName(removing) : "They"} will lose access to {name} straight away. You can add them again later.
      </ConfirmDialog>

      <ConfirmDialog
        open={!!cancelling}
        onOpenChange={(o) => {
          if (!o) {
            setCancelling(null);
            cancel.reset();
          }
        }}
        title="Cancel this invite?"
        confirmLabel="Cancel invite"
        pending={cancel.isPending}
        error={cancel.error ? new Error(memberActionError(cancel.error)) : null}
        onConfirm={() =>
          cancelling?.email &&
          cancel.mutate(cancelling.email, {
            onSuccess: () => {
              toast({ title: "Invite cancelled", tone: "positive" });
              setCancelling(null);
            },
          })
        }
      >
        {cancelling?.email ?? "They"} won't get access to {name} when they sign in.
      </ConfirmDialog>
    </div>
  );
}

function AddMember({ ledgerName }: { ledgerName: string }) {
  const { profile_code: profileCode } = useActiveProfile();
  const add = useInviteMember(profileCode);
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
          toast(inviteNotice(result, email, ledgerName));
          setEmail("");
          setTouched(false);
        },
      },
    );
  };

  return (
    <Card>
      <CardHeader title="Invite someone" />
      <form
        className="flex flex-col gap-3 px-5 pb-5"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <p className="text-[13px] text-muted">If they don't have a Bank Ledger account yet, we email them an invite. Inviting someone who's already a member changes their role.</p>
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
            Invite
          </Button>
        </div>
        {add.error ? <p className="text-[13px] text-danger" role="alert">{inviteMemberError(add.error)}</p> : null}
      </form>
    </Card>
  );
}

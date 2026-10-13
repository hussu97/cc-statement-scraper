import { Link } from "@tanstack/react-router";
import { ArrowRight, Circle, CircleCheck, CircleHelp } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useSetupChecklist } from "@/data/setup";
import { SETUP_INTRO, SETUP_TITLE, SETUP_VIEWER_NOTE, setupTarget, spokenStatus, type SetupStep } from "@/lib/setup-checklist";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { LoadingRows } from "@/components/ui/states";

/**
 * An empty ledger's first steps (WEB-27), in place of the hero, the pace rule
 * and the empty cards, ring and activity. Owners get a link per open step.
 */
export function SetupChecklistCard({ lastSmsAt }: { lastSmsAt: string | null }) {
  const { profile_code, isOwner } = useActiveProfile();
  const { checklist, loading } = useSetupChecklist(profile_code, lastSmsAt);
  return (
    <Card aria-labelledby="setup-title" className="animate-rise">
      <CardHeader
        eyebrow="New ledger"
        title={<span id="setup-title">{SETUP_TITLE}</span>}
        action={!loading && <span className="tabular text-[13px] text-muted">{checklist.progress}</span>}
      />
      <p className="-mt-1 px-5 pb-3 text-[13px] text-muted">{SETUP_INTRO}</p>
      {loading ? (
        <LoadingRows rows={5} />
      ) : (
        <ol className="divide-y divide-border border-t border-border">
          {checklist.steps.map((s) => (
            <StepRow key={s.kind} step={s} linked={isOwner && s.status !== "done"} />
          ))}
        </ol>
      )}
      {!isOwner && <p className="border-t border-border px-5 py-3 text-[12px] text-subtle">{SETUP_VIEWER_NOTE}</p>}
    </Card>
  );
}

function StepRow({ step: s, linked }: { step: SetupStep; linked: boolean }) {
  const target = setupTarget(s.kind);
  return (
    <li className="flex flex-wrap items-start gap-x-3 gap-y-2 px-5 py-3.5">
      <StatusIcon status={s.status} />
      <div className="min-w-0 flex-1">
        <p className={cn("text-sm font-medium", s.status === "done" ? "text-muted" : "text-ink")}>
          {s.title}
          <span className="sr-only">: {spokenStatus(s.status)}</span>
        </p>
        <p className="mt-0.5 text-[13px] text-muted">{s.detail}</p>
        {s.status === "unknown" && <p className="mt-0.5 text-[12px] text-subtle">Couldn't check this just now.</p>}
      </div>
      {linked && (
        <Link
          to={target.to}
          search={target.search}
          hash={"hash" in target ? target.hash : undefined}
          className="tap ml-8 inline-flex items-center gap-1 text-[13px] font-medium text-accent hover:underline sm:ml-0"
        >
          {target.label} <ArrowRight className="size-3.5" aria-hidden />
        </Link>
      )}
    </li>
  );
}

function StatusIcon({ status }: { status: SetupStep["status"] }) {
  const cls = "mt-0.5 size-5 shrink-0";
  if (status === "done") return <CircleCheck className={cn(cls, "text-positive")} aria-hidden />;
  if (status === "unknown") return <CircleHelp className={cn(cls, "text-subtle")} aria-hidden />;
  return <Circle className={cn(cls, "text-subtle")} aria-hidden />;
}

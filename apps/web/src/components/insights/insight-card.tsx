import type { ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowRight, X } from "lucide-react";
import { insightTarget, type Insight, type InsightTarget } from "@/data/overview";
import { formatRelative } from "@/lib/dates";
import { cn } from "@/lib/cn";

const SEVERITY_LABEL: Record<string, string> = { alert: "Alert", warn: "Heads-up", info: "Info" };

/**
 * One server insight: severity dot, title, body and a link to the screen that answers it
 * (insightTarget). Owners get a dismiss button. Shared by the Overview panel and the Insights
 * feed; `showAge` adds when it was noticed.
 */
export function InsightCard({ insight: i, onDismiss, showAge }: { insight: Insight; onDismiss?: () => void; showAge?: boolean }) {
  const target = insightTarget(i);
  const body = (
    <>
      <div className="flex items-start gap-2">
        <span
          role="img"
          aria-label={SEVERITY_LABEL[i.severity] ?? "Info"}
          className={cn("mt-[7px] size-1.5 shrink-0 rounded-pill", i.severity === "alert" ? "bg-danger" : i.severity === "warn" ? "bg-warn" : "bg-info")}
        />
        <p className="text-[13.5px] font-medium text-ink">{i.title}</p>
      </div>
      <p className="mt-1 text-[13px] leading-relaxed text-muted">{i.body}</p>
      {(target || showAge) && (
        <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1">
          {target && (
            <span className="inline-flex items-center gap-1 text-[12.5px] font-medium text-accent">
              {target.label} <ArrowRight className="size-3.5" aria-hidden />
            </span>
          )}
          {showAge && <span className="text-[12px] text-subtle">Noticed {formatRelative(i.created_at)}</span>}
        </div>
      )}
    </>
  );
  return (
    <li className="group relative rounded-md border border-border bg-bg transition-colors hover:border-border-strong">
      {target ? (
        <TargetLink target={target} className="block rounded-md px-4 py-3 pr-12">
          {body}
        </TargetLink>
      ) : (
        <div className="px-4 py-3 pr-12">{body}</div>
      )}
      {onDismiss && (
        <button
          type="button"
          onClick={onDismiss}
          aria-label={`Dismiss: ${i.title}`}
          className="absolute top-0 right-0 flex size-11 items-center justify-center rounded-md text-muted hover:bg-surface-2 hover:text-ink md:top-1 md:right-1 md:size-8"
        >
          <X className="size-3.5" />
        </button>
      )}
    </li>
  );
}

function TargetLink({ target, className, children }: { target: InsightTarget; className?: string; children: ReactNode }) {
  if (target.to === "/insights/category/$categoryCode") {
    return (
      <Link to={target.to} params={target.params} search={target.search} className={className}>
        {children}
      </Link>
    );
  }
  if (target.to === "/wealth/accounts/$accountCode") {
    return (
      <Link to={target.to} params={target.params} search={target.search} className={className}>
        {children}
      </Link>
    );
  }
  return (
    <Link to={target.to} search={"search" in target ? target.search : undefined} className={className}>
      {children}
    </Link>
  );
}

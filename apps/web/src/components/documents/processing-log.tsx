import type { ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { CheckCircle2, Clock, CopyCheck, FileCheck2, FileInput, HardDrive, Loader2, RotateCw, XCircle } from "lucide-react";
import { eventAdvice, eventTone, stageLabel, type DocumentEvent, type EventTone } from "@/data/document-events";
import { formatDateTime, formatTime } from "@/lib/dates";
import { cn } from "@/lib/cn";
import { Button } from "@/components/ui/button";

const ICON: Record<string, ReactNode> = {
  received: <FileInput />,
  stored: <HardDrive />,
  duplicate: <CopyCheck />,
  queued: <Clock />,
  parsing: <Loader2 />,
  parsed: <FileCheck2 />,
  ingested: <CheckCircle2 />,
  failed: <XCircle />,
  retry: <RotateCw />,
};

const TONE_TEXT: Record<EventTone, string> = {
  neutral: "text-subtle",
  info: "text-info",
  positive: "text-positive",
  warn: "text-warn",
  danger: "text-danger",
};

/**
 * One document's processing log: each document_events row with its stage
 * icon, time and message. Failures are highlighted with what to do next.
 * `active` animates the newest "reading" step while work is in flight.
 */
export function ProcessingLog({
  events,
  active,
  onRetry,
  retrying,
  dense,
  className,
}: {
  events: DocumentEvent[];
  active?: boolean;
  /** Offered on failures that a re-read can fix (owners only). */
  onRetry?: () => void;
  retrying?: boolean;
  dense?: boolean;
  className?: string;
}) {
  const lastIndex = events.length - 1;
  return (
    <ol aria-label="Processing log" className={cn("flex flex-col", dense ? "gap-1" : "gap-1.5", className)}>
      {events.map((e, i) => {
        const tone = eventTone(e);
        const advice = eventAdvice(e);
        const spinning = active && i === lastIndex && (e.stage === "parsing" || e.stage === "queued" || e.stage === "retry");
        const highlighted = tone === "danger" || tone === "warn";
        return (
          <li
            key={e.event_code}
            className={cn(
              "grid grid-cols-[16px_minmax(0,1fr)] gap-x-2 text-[12.5px]",
              highlighted && "rounded-md px-2 py-1.5",
              tone === "danger" && "bg-danger-soft",
              tone === "warn" && "bg-warn-soft",
            )}
          >
            <span aria-hidden className={cn("mt-px flex size-4 items-center justify-center [&_svg]:size-3.5", TONE_TEXT[tone], spinning && "[&_svg]:animate-spin")}>
              {ICON[e.stage] ?? <Clock />}
            </span>
            <div className="min-w-0">
              <p className="flex flex-wrap items-baseline gap-x-2">
                <span className={cn("font-medium", highlighted ? TONE_TEXT[tone] : "text-ink")}>{stageLabel(e.stage)}</span>
                <time dateTime={e.created_at} title={formatDateTime(e.created_at)} className="tabular text-[11.5px] text-subtle">
                  {formatTime(e.created_at)}
                </time>
              </p>
              <p className={cn("break-words", highlighted ? "text-ink-2" : "text-muted")}>{e.message}</p>
              {advice && <Advice advice={advice} onRetry={onRetry} retrying={retrying} />}
            </div>
          </li>
        );
      })}
    </ol>
  );
}

function Advice({ advice, onRetry, retrying }: { advice: NonNullable<ReturnType<typeof eventAdvice>>; onRetry?: () => void; retrying?: boolean }) {
  const action =
    advice.kind === "passwords" ? (
      <Link to="/settings" search={{ tab: "sources" }} hash="statement-passwords" className="tap font-medium text-accent hover:underline">
        Open Settings → Statement passwords
      </Link>
    ) : advice.kind === "retry" && onRetry ? (
      <Button size="sm" variant="secondary" icon={<RotateCw className="size-3.5" />} loading={retrying} onClick={onRetry}>
        Read again
      </Button>
    ) : null;
  if (!advice.text && !action) return null;
  return (
    <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1">
      {advice.text && <span className="text-ink-2">{advice.text}</span>}
      {action}
    </div>
  );
}

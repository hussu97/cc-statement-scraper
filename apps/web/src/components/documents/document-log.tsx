import { ChevronDown, ScrollText } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useRequeueDocuments } from "@/data/cards";
import { docState, useDocumentEvents } from "@/data/document-events";
import { errorMessage } from "@/data/api";
import { cn } from "@/lib/cn";
import { Card } from "@/components/ui/display";
import { ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ProcessingLog } from "./processing-log";

/**
 * "Processing log" for one stored document (statement detail, Documents tab):
 * its document_events, live while it is still being processed. Events are
 * kept for 90 days, so older uploads say so instead of showing an empty log.
 */
export function DocumentLog({ profileCode, docCode, collapsible, bare }: { profileCode: string; docCode: string; collapsible?: boolean; bare?: boolean }) {
  const q = useDocumentEvents(profileCode, [docCode]);
  const { isOwner } = useActiveProfile();
  const requeue = useRequeueDocuments(profileCode);
  const toast = useToast();
  const events = q.data ?? [];
  const state = docState(events);
  const body = q.isLoading ? (
    <LoadingRows rows={3} className="p-0" />
  ) : q.isError ? (
    <ErrorState error={q.error} onRetry={() => void q.refetch()} className="py-4" />
  ) : events.length === 0 ? (
    <p className="text-[13px] text-muted">No processing log for this document. Logs are kept for 90 days after an upload.</p>
  ) : (
    <ProcessingLog
      events={events}
      active={state === "working" || state === "retrying"}
      retrying={requeue.isPending}
      onRetry={
        isOwner && state === "failed"
          ? () =>
              requeue.mutate([docCode], {
                onSuccess: () => toast({ title: "Queued to be read again", tone: "positive" }),
                onError: (e) => toast({ title: "Couldn't queue", description: errorMessage(e), tone: "danger" }),
              })
          : undefined
      }
    />
  );

  if (bare) return body;
  const title = (
    <span className="flex items-center gap-2 text-[15px] font-semibold text-ink">
      <ScrollText className="size-4 text-muted" aria-hidden /> Processing log
      {events.length > 0 && <span className="tabular rounded-pill bg-surface-2 px-2 text-[12px] font-normal text-muted">{events.length}</span>}
    </span>
  );
  if (!collapsible) {
    return (
      <Card className="px-4 py-4 md:px-5">
        <h2 className="mb-3">{title}</h2>
        {body}
      </Card>
    );
  }
  return (
    <Card className="group/log overflow-hidden">
      <details className="[&[open]_.log-chevron]:rotate-180">
        <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3.5 md:px-5 [&::-webkit-details-marker]:hidden">
          {title}
          <ChevronDown className={cn("log-chevron size-4 text-subtle transition-transform")} aria-hidden />
        </summary>
        <div className="border-t border-border px-4 py-3.5 md:px-5">{body}</div>
      </details>
    </Card>
  );
}

import { Link } from "@tanstack/react-router";
import { ArrowRight, FileText, MessageSquareText, RotateCw } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useDocumentHealth, useRequeueDocuments } from "@/data/cards";
import { useSmsHealth } from "@/data/settings";
import { errorMessage } from "@/data/api";
import { formatCount } from "@/lib/money";
import { formatRelative } from "@/lib/dates";
import { cn } from "@/lib/cn";
import { Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { LoadingRows, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";

const DOC_STATUSES: { key: string; label: string; tone?: string }[] = [
  { key: "parsed", label: "Read" },
  { key: "queued", label: "Waiting" },
  { key: "parsing", label: "Reading" },
  { key: "failed", label: "Failed", tone: "text-danger" },
];

function Stat({ label, value, className }: { label: string; value: string; className?: string }) {
  return (
    <div className="min-w-0">
      <p className={cn("text-xl text-ink tabular", className)}>{value}</p>
      <p className="text-[12px] text-muted">{label}</p>
    </div>
  );
}

export function HealthSection() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const docs = useDocumentHealth(profileCode);
  const sms = useSmsHealth(profileCode);
  const requeue = useRequeueDocuments(profileCode);
  const toast = useToast();

  return (
    <div className="grid gap-4 md:grid-cols-2">
      <Card>
        <CardHeader
          title={
            <span className="flex items-center gap-2">
              <FileText className="size-4 text-muted" aria-hidden /> Statements
            </span>
          }
          action={
            <Link to="/cards" search={{ tab: "documents" }} className="tap inline-flex items-center gap-1 text-[13px] text-accent hover:underline">
              Documents <ArrowRight className="size-3.5" aria-hidden />
            </Link>
          }
        />
        <div className="px-5 pb-5">
          <QueryView query={docs} loading={<LoadingRows rows={1} className="p-0" />}>
            {({ counts, total, failedCodes: failed }) => {
              const failedCount = counts.failed ?? 0;
              return (
                <>
                  {total === 0 ? (
                    <p className="text-[13px] text-muted">No statements yet. Upload PDFs on Cards & statements, or let the scraper or email send them.</p>
                  ) : (
                    <div className="grid grid-cols-4 gap-3">
                      {DOC_STATUSES.map((s) => (
                        <Stat key={s.key} label={s.label} value={formatCount(counts[s.key] ?? 0)} className={(counts[s.key] ?? 0) > 0 ? s.tone : undefined} />
                      ))}
                    </div>
                  )}
                  {failedCount > 0 && (
                    <div className="mt-4 flex flex-wrap items-center justify-between gap-2 rounded-md bg-danger-soft px-3 py-2">
                      <p className="text-[13px] text-ink-2">
                        {failedCount === 1 ? "One statement couldn't be read. Check its password, then retry." : `${formatCount(failedCount)} statements couldn't be read. Check their passwords, then retry.`}
                      </p>
                      {isOwner && (
                        <Button
                          size="sm"
                          icon={<RotateCw className="size-3.5" />}
                          loading={requeue.isPending}
                          onClick={() =>
                            requeue.mutate(failed, {
                              onSuccess: (n) => toast({ title: `Retrying ${formatCount(n ?? failed.length)} ${n === 1 ? "statement" : "statements"}`, tone: "positive" }),
                              onError: (e) => toast({ title: "Couldn't retry", description: errorMessage(e), tone: "danger" }),
                            })
                          }
                        >
                          Retry failed
                        </Button>
                      )}
                    </div>
                  )}
                </>
              );
            }}
          </QueryView>
        </div>
      </Card>

      <Card>
        <CardHeader
          title={
            <span className="flex items-center gap-2">
              <MessageSquareText className="size-4 text-muted" aria-hidden /> Bank SMS
            </span>
          }
          action={
            <Link to="/settings" search={{ tab: "sms" }} className="tap inline-flex items-center gap-1 text-[13px] text-accent hover:underline">
              Set up <ArrowRight className="size-3.5" aria-hidden />
            </Link>
          }
        />
        <div className="px-5 pb-5">
          <QueryView query={sms} loading={<LoadingRows rows={1} className="p-0" />}>
            {(h) =>
              h.total === 0 ? (
                <p className="text-[13px] text-muted">No SMS received yet. Follow the iPhone setup guide to forward bank messages.</p>
              ) : (
                <>
                  <div className="grid grid-cols-3 gap-3">
                    <Stat label="Last received" value={formatRelative(h.lastReceivedAt)} className="text-base leading-7" />
                    <Stat label="Read" value={`${formatCount(h.parsed)} / ${formatCount(h.total)}`} />
                    <Stat label="Not understood" value={formatCount(h.unparsed)} className={h.unparsed > 0 ? "text-warn" : undefined} />
                  </div>
                  {h.lastSender && <p className="mt-3 text-[12px] text-muted">Latest from {h.lastSender}.</p>}
                  {h.unparsed > 0 && (
                    <Link to="/review" className="tap mt-3 inline-flex items-center gap-1 text-[13px] text-accent hover:underline">
                      Review messages Ledger couldn't read <ArrowRight className="size-3.5" aria-hidden />
                    </Link>
                  )}
                </>
              )
            }
          </QueryView>
        </div>
      </Card>
    </div>
  );
}

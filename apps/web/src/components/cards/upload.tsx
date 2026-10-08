import { useRef, useState, type DragEvent } from "react";
import { Link } from "@tanstack/react-router";
import { FileUp, AlertCircle, Loader2, CheckCircle2, CopyCheck, XCircle, Clock, ChevronDown } from "lucide-react";
import { checkUploadFiles, useRequeueDocuments, useUploadStatements, type UploadResult } from "@/data/cards";
import { eventsByDoc, uploadStatus, useDocumentEvents, type DocumentEvent, type UploadStatus } from "@/data/document-events";
import { errorMessage } from "@/data/api";
import { cn } from "@/lib/cn";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";
import { ProcessingLog } from "@/components/documents/processing-log";

/**
 * Statement upload with a live per-file log: after the Edge Function answers
 * with a doc_code per file, each file's document_events stream in over
 * Realtime (received → stored → queued → reading → read → imported, or
 * duplicate / failed / retry). Failures say what to do next.
 */
export function UploadDropzone({ profileCode, disabled }: { profileCode: string; disabled?: boolean }) {
  const input = useRef<HTMLInputElement>(null);
  const [over, setOver] = useState(false);
  const [rejected, setRejected] = useState<{ name: string; reason: string }[]>([]);
  const [sending, setSending] = useState<string[]>([]);
  const [results, setResults] = useState<UploadResult[]>([]);
  const upload = useUploadStatements(profileCode);
  const events = useDocumentEvents(profileCode, results.map((r) => r.doc_code));
  const byDoc = eventsByDoc(events.data ?? []);

  const handle = (list: FileList | null) => {
    if (!list || disabled || upload.isPending) return;
    const { ok, rejected } = checkUploadFiles([...list]);
    setRejected(rejected);
    setResults([]);
    setSending(ok.map((f) => f.name));
    if (ok.length)
      upload.mutate(ok, {
        onSuccess: setResults,
        onSettled: () => setSending([]),
      });
    if (input.current) input.current.value = "";
  };
  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    setOver(false);
    handle(e.dataTransfer.files);
  };
  const anything = sending.length > 0 || results.length > 0 || rejected.length > 0 || upload.isError;

  return (
    <div className="flex flex-col gap-4">
      <div
        onDragOver={(e) => {
          e.preventDefault();
          setOver(true);
        }}
        onDragLeave={() => setOver(false)}
        onDrop={onDrop}
        className={cn(
          "flex flex-col items-center justify-center gap-3 rounded-lg border-2 border-dashed px-6 py-12 text-center transition-colors",
          over ? "border-accent bg-accent-soft" : "border-border-strong bg-surface",
          disabled && "opacity-60",
        )}
      >
        <FileUp className="size-7 text-accent" aria-hidden />
        <div>
          <p className="text-sm font-medium text-ink">Drop statement PDFs here</p>
          <p className="mt-1 text-[13px] text-muted">
            Up to 20 files, 25 MB each. Password-protected PDFs use the{" "}
            <Link to="/settings" search={{ tab: "sources" }} hash="statement-passwords" className="text-accent hover:underline">
              statement passwords
            </Link>{" "}
            saved in Settings.
          </p>
        </div>
        <input ref={input} type="file" accept="application/pdf,.pdf" multiple hidden onChange={(e) => handle(e.target.files)} />
        <Button variant="primary" onClick={() => input.current?.click()} loading={upload.isPending} disabled={disabled}>
          Choose files
        </Button>
        {disabled && <p className="text-[12px] text-subtle">Only owners can upload statements.</p>}
      </div>
      {anything && (
        <section aria-labelledby="upload-log-title" className="rounded-lg border border-border bg-surface">
          <h2 id="upload-log-title" className="border-b border-border px-4 py-3 text-[13px] font-semibold text-ink">
            Upload log
          </h2>
          <ul className="flex flex-col divide-y divide-border">
            {sending.map((name) => (
              <FileRow key={`sending-${name}`} name={name} status={{ state: "uploading", label: "Uploading…" }} />
            ))}
            {results.map((r) => (
              <UploadedFile key={r.doc_code} profileCode={profileCode} result={r} events={byDoc.get(r.doc_code) ?? []} loading={events.isLoading} />
            ))}
            {rejected.map((r) => (
              <FileRow key={`rejected-${r.name}`} name={r.name} status={{ state: "failed", label: r.reason }} />
            ))}
            {upload.isError && (
              <li role="alert" className="flex items-center gap-3 px-4 py-3 text-[13px] text-danger">
                <AlertCircle className="size-4 shrink-0" aria-hidden /> Upload failed: {errorMessage(upload.error)}
              </li>
            )}
          </ul>
        </section>
      )}
    </div>
  );
}

const STATE_ICON: Record<UploadStatus["state"], React.ReactNode> = {
  uploading: <Loader2 className="animate-spin" />,
  working: <Loader2 className="animate-spin" />,
  waiting: <Clock />,
  done: <CheckCircle2 />,
  duplicate: <CopyCheck />,
  failed: <XCircle />,
  retrying: <Loader2 className="animate-spin" />,
};
const STATE_TONE: Record<UploadStatus["state"], string> = {
  uploading: "text-info",
  working: "text-info",
  waiting: "text-subtle",
  done: "text-positive",
  duplicate: "text-subtle",
  failed: "text-danger",
  retrying: "text-warn",
};

function FileRow({ name, status, children, open, onToggle }: { name: string; status: UploadStatus; children?: React.ReactNode; open?: boolean; onToggle?: () => void }) {
  return (
    <li className="px-4 py-3">
      <div className="flex items-center gap-3 text-[13px]">
        <span aria-hidden className={cn("flex size-4 shrink-0 items-center justify-center [&_svg]:size-4", STATE_TONE[status.state])}>{STATE_ICON[status.state]}</span>
        <span className="min-w-0 flex-1 truncate text-ink" title={name}>{name}</span>
        <span className={cn("shrink-0", status.state === "failed" ? "text-danger" : "text-muted")}>{status.label}</span>
        {onToggle && (
          <button type="button" onClick={onToggle} aria-expanded={open} aria-label={`${open ? "Hide" : "Show"} the log for ${name}`} className="tap -mr-1 rounded-sm p-1 text-subtle hover:text-ink">
            <ChevronDown className={cn("size-4 transition-transform", open && "rotate-180")} aria-hidden />
          </button>
        )}
      </div>
      {open && children && <div className="mt-2.5 pl-7">{children}</div>}
    </li>
  );
}

function UploadedFile({ profileCode, result, events, loading }: { profileCode: string; result: UploadResult; events: DocumentEvent[]; loading: boolean }) {
  const status = uploadStatus(result.status, events);
  // Open by default; a finished import folds away only when the person closes it.
  const [open, setOpen] = useState(true);
  const requeue = useRequeueDocuments(profileCode);
  const toast = useToast();
  return (
    <FileRow name={result.filename} status={status} open={open} onToggle={() => setOpen((o) => !o)}>
      <div aria-live="polite">
        {events.length === 0 ? (
          <p className="text-[12.5px] text-muted">{loading ? "Loading the log…" : "Waiting for the first step…"}</p>
        ) : (
          <ProcessingLog
            events={events}
            dense
            active={status.state === "working" || status.state === "retrying"}
            retrying={requeue.isPending}
            onRetry={
              status.state === "failed"
                ? () =>
                    requeue.mutate([result.doc_code], {
                      onSuccess: () => toast({ title: "Queued to be read again", tone: "positive" }),
                      onError: (e) => toast({ title: "Couldn't queue", description: errorMessage(e), tone: "danger" }),
                    })
                : undefined
            }
          />
        )}
      </div>
    </FileRow>
  );
}

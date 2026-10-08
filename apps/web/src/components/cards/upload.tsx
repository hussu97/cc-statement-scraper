import { useRef, useState, type DragEvent } from "react";
import { FileUp, CheckCircle2, CopyCheck, AlertCircle } from "lucide-react";
import { checkUploadFiles, useUploadStatements, type UploadResult } from "@/data/cards";
import { errorMessage } from "@/data/api";
import { cn } from "@/lib/cn";
import { Button } from "@/components/ui/button";

export function UploadDropzone({ profileCode, disabled }: { profileCode: string; disabled?: boolean }) {
  const input = useRef<HTMLInputElement>(null);
  const [over, setOver] = useState(false);
  const [rejected, setRejected] = useState<{ name: string; reason: string }[]>([]);
  const [results, setResults] = useState<UploadResult[]>([]);
  const upload = useUploadStatements(profileCode);

  const handle = (list: FileList | null) => {
    if (!list || disabled) return;
    const { ok, rejected } = checkUploadFiles([...list]);
    setRejected(rejected);
    setResults([]);
    if (ok.length) upload.mutate(ok, { onSuccess: setResults });
  };
  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    setOver(false);
    handle(e.dataTransfer.files);
  };

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
          <p className="mt-1 text-[13px] text-muted">Up to 10 files, 25 MB each. Password-protected PDFs use the passwords saved in Settings.</p>
        </div>
        <input ref={input} type="file" accept="application/pdf,.pdf" multiple hidden onChange={(e) => handle(e.target.files)} />
        <Button variant="primary" onClick={() => input.current?.click()} loading={upload.isPending} disabled={disabled}>
          Choose files
        </Button>
        {disabled && <p className="text-[12px] text-subtle">Only owners can upload statements.</p>}
      </div>
      {(results.length > 0 || rejected.length > 0 || upload.isError) && (
        <ul className="flex flex-col divide-y divide-border rounded-lg border border-border bg-surface" aria-live="polite">
          {results.map((r) => (
            <li key={r.doc_code} className="flex items-center gap-3 px-4 py-2.5 text-[13px]">
              {r.status === "duplicate" ? <CopyCheck className="size-4 text-subtle" /> : <CheckCircle2 className="size-4 text-positive" />}
              <span className="min-w-0 flex-1 truncate text-ink">{r.filename}</span>
              <span className="text-muted">{r.status === "duplicate" ? "Already uploaded" : "Queued for parsing"}</span>
            </li>
          ))}
          {rejected.map((r) => (
            <li key={r.name} className="flex items-center gap-3 px-4 py-2.5 text-[13px]">
              <AlertCircle className="size-4 text-danger" />
              <span className="min-w-0 flex-1 truncate text-ink">{r.name}</span>
              <span className="text-danger">{r.reason}</span>
            </li>
          ))}
          {upload.isError && (
            <li className="flex items-center gap-3 px-4 py-2.5 text-[13px] text-danger">
              <AlertCircle className="size-4" /> Upload failed: {errorMessage(upload.error)}
            </li>
          )}
        </ul>
      )}
    </div>
  );
}

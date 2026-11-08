import { useEffect, useMemo, useRef, useState, type ChangeEvent } from "react";
import { Download, FileText, Paperclip, Trash2, Upload } from "lucide-react";
import {
  holdingErrorMessage,
  useHoldingAttachmentBlob,
  useRemoveHoldingAttachment,
  useUploadHoldingAttachments,
  type HoldingAttachment,
  type useHoldingDetail,
} from "@/data/holdings";
import { ATTACHMENT_ACCEPT, attachmentFacts, attachmentLabel, canPreview, checkAttachmentFiles, formatBytes } from "@/lib/holding-attachments";
import { formatDate } from "@/lib/dates";
import { Card, CardHeader, Skeleton } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { EmptyState, ErrorState, LoadingRows } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ConfirmDialog } from "@/components/rules/shared";

/** A blob's object URL for as long as the component shows it. */
function useObjectUrl(blob: Blob | undefined): string | null {
  const url = useMemo(() => (blob ? URL.createObjectURL(blob) : null), [blob]);
  useEffect(() => () => void (url && URL.revokeObjectURL(url)), [url]);
  return url;
}

/** Invoices, certificates and other proof kept with a holding. Members view; the owner adds and removes. */
export function AttachmentsCard({
  profileCode,
  holdingCode,
  detail,
  isOwner,
}: {
  profileCode: string;
  holdingCode: string;
  detail: ReturnType<typeof useHoldingDetail>;
  isOwner: boolean;
}) {
  const upload = useUploadHoldingAttachments(profileCode, holdingCode);
  const toast = useToast();
  const input = useRef<HTMLInputElement>(null);
  const [viewing, setViewing] = useState<HoldingAttachment | null>(null);
  const [removing, setRemoving] = useState<HoldingAttachment | null>(null);
  const attachments = detail.data?.attachments ?? [];

  const onFiles = (e: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files ?? []);
    e.target.value = "";
    if (files.length === 0) return;
    const { ok, rejected } = checkAttachmentFiles(files, attachments.length);
    for (const r of rejected) toast({ title: `${r.name} wasn't added`, description: r.reason, tone: "danger" });
    if (ok.length === 0) return;
    upload.mutate(
      ok.map((x) => ({ file: x.file as File, type: x.type })),
      {
        onSuccess: (codes) => toast({ title: codes.length === 1 ? "File added" : `${codes.length} files added`, tone: "positive" }),
        onError: (err) => toast({ title: "Couldn't add the file", description: holdingErrorMessage(err), tone: "danger" }),
      },
    );
  };

  return (
    <Card>
      <CardHeader
        eyebrow="Proof of purchase"
        title="Attachments"
        action={
          isOwner && (
            <>
              <input ref={input} type="file" accept={ATTACHMENT_ACCEPT} multiple className="hidden" onChange={onFiles} aria-label="Choose files to attach" />
              <Button size="sm" icon={<Upload className="size-3.5" />} onClick={() => input.current?.click()} disabled={upload.isPending}>
                {upload.isPending ? "Adding…" : "Add"}
              </Button>
            </>
          )
        }
      />
      {detail.isLoading ? (
        <LoadingRows rows={2} />
      ) : detail.isError || !detail.data ? (
        <ErrorState error={detail.error} onRetry={() => void detail.refetch()} />
      ) : attachments.length === 0 ? (
        <EmptyState icon={<Paperclip />} title="No attachments yet">
          {isOwner ? "Add a photo or PDF of the invoice, a certificate or anything else that proves the purchase." : "The ledger's owner can add invoices and certificates here."}
        </EmptyState>
      ) : (
        <ul className="grid grid-cols-2 gap-3 border-t border-border p-4 sm:grid-cols-3 lg:grid-cols-4">
          {attachments.map((a) => (
            <AttachmentTile key={a.attachment_code} profileCode={profileCode} a={a} onOpen={() => setViewing(a)} onRemove={isOwner ? () => setRemoving(a) : undefined} />
          ))}
        </ul>
      )}
      <AttachmentViewer profileCode={profileCode} attachment={viewing} onClose={() => setViewing(null)} />
      {isOwner && <RemoveAttachmentDialog profileCode={profileCode} holdingCode={holdingCode} attachment={removing} onClose={() => setRemoving(null)} />}
    </Card>
  );
}

function AttachmentTile({ profileCode, a, onOpen, onRemove }: { profileCode: string; a: HoldingAttachment; onOpen: () => void; onRemove?: () => void }) {
  const preview = canPreview(a.mime_type);
  const blob = useHoldingAttachmentBlob(profileCode, a.storage_path, preview);
  const url = useObjectUrl(blob.data);
  const label = attachmentLabel(a);
  return (
    <li className="group relative flex flex-col overflow-hidden rounded-md border border-border bg-surface">
      <button type="button" onClick={onOpen} className="tap relative flex aspect-[4/3] items-center justify-center overflow-hidden bg-surface-2 focus-visible:outline-2 focus-visible:outline-accent" aria-label={`Open ${label}`}>
        {preview && url ? (
          <img src={url} alt={label} className="absolute inset-0 size-full object-cover object-top" />
        ) : preview && blob.isLoading ? (
          <Skeleton className="size-full" />
        ) : (
          <FileText className="size-8 text-muted" aria-hidden />
        )}
      </button>
      <div className="flex items-start gap-1 px-2.5 py-2">
        <div className="min-w-0 flex-1">
          <p className="truncate text-[13px] text-ink" title={label}>
            {label}
          </p>
          <p className="text-[11px] text-subtle">
            {formatDate(a.created_at.slice(0, 10))} · {formatBytes(a.size_bytes)}
          </p>
        </div>
        {onRemove && (
          <Button size="sm" variant="ghost" className="-mr-1 shrink-0 text-muted" onClick={onRemove} aria-label={`Remove ${label}`}>
            <Trash2 className="size-3.5" />
          </Button>
        )}
      </div>
    </li>
  );
}

function AttachmentViewer({ profileCode, attachment, onClose }: { profileCode: string; attachment: HoldingAttachment | null; onClose: () => void }) {
  const blob = useHoldingAttachmentBlob(profileCode, attachment?.storage_path ?? null);
  const url = useObjectUrl(blob.data);
  const a = attachment;
  return (
    <Dialog
      open={!!a}
      onOpenChange={(o) => !o && onClose()}
      title={a ? attachmentLabel(a) : ""}
      description={a ? attachmentFacts(a) : undefined}
      size="lg"
      footer={
        url &&
        a && (
          <a href={url} download={a.file_name} className="inline-flex items-center gap-1.5 text-sm text-accent hover:underline">
            <Download className="size-3.5" /> Download
          </a>
        )
      }
    >
      {!a ? null : blob.isLoading ? (
        <LoadingRows rows={4} />
      ) : blob.isError || !url ? (
        <ErrorState error={blob.error} onRetry={() => void blob.refetch()} />
      ) : canPreview(a.mime_type) ? (
        <img src={url} alt={attachmentLabel(a)} className="mx-auto max-h-[70dvh] w-auto rounded-md object-contain" />
      ) : a.mime_type === "application/pdf" ? (
        <iframe src={url} title={attachmentLabel(a)} className="h-[70dvh] w-full rounded-md border border-border" />
      ) : (
        <p className="text-sm text-muted">This browser can't show this file. Download it to open it.</p>
      )}
    </Dialog>
  );
}

function RemoveAttachmentDialog({
  profileCode,
  holdingCode,
  attachment,
  onClose,
}: {
  profileCode: string;
  holdingCode: string;
  attachment: HoldingAttachment | null;
  onClose: () => void;
}) {
  const remove = useRemoveHoldingAttachment(profileCode, holdingCode);
  const toast = useToast();
  return (
    <ConfirmDialog
      open={!!attachment}
      onOpenChange={(o) => {
        if (!o) {
          onClose();
          remove.reset();
        }
      }}
      title="Remove this file?"
      confirmLabel="Remove"
      pending={remove.isPending}
      error={remove.error ? new Error(holdingErrorMessage(remove.error)) : null}
      onConfirm={() =>
        attachment &&
        remove.mutate(attachment.attachment_code, {
          onSuccess: () => {
            toast({ title: "File removed", tone: "positive" });
            onClose();
          },
        })
      }
    >
      {attachment && <>{attachmentLabel(attachment)} is deleted for everyone in this ledger. This can't be undone.</>}
    </ConfirmDialog>
  );
}

import { useMemo } from "react";
import { Download, ExternalLink, FileText, Share2 } from "lucide-react";
import { useTermSheet } from "@/data/notes";
import { errorMessage } from "@/data/api";
import { useObjectUrl } from "@/lib/hooks";
import { canShareFile, isShareCancel, termSheetFilename } from "@/lib/term-sheet";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { ErrorState, LoadingBlock } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";

/**
 * A structured note's term sheet, read from the private `term-sheets` bucket and shown in the app
 * (the browser's own PDF viewer in a frame), with Share (the system share sheet, where the browser
 * takes files), Download and Open in a new tab. The bytes stay in memory while it is open.
 */
export function TermSheetDialog({
  profileCode,
  path,
  filename,
  title,
  open,
  onOpenChange,
}: {
  profileCode: string;
  path: string;
  filename: string | null;
  title: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const q = useTermSheet(profileCode, path, open);
  const toast = useToast();
  const name = termSheetFilename(filename, title);
  const file = useMemo(() => (q.data ? new File([q.data], name, { type: "application/pdf" }) : null), [q.data, name]);
  const url = useObjectUrl(file);
  const shareable = !!file && canShareFile(typeof navigator === "undefined" ? undefined : navigator, file);

  const share = async () => {
    if (!file) return;
    try {
      await navigator.share({ files: [file], title: name });
    } catch (e) {
      if (!isShareCancel(e)) toast({ title: "Couldn't share the term sheet", description: errorMessage(e), tone: "danger" });
    }
  };
  const download = () => {
    if (!url) return;
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    a.rel = "noopener";
    document.body.appendChild(a);
    a.click();
    a.remove();
  };

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title={title}
      description={
        <span className="inline-flex items-center gap-1.5">
          <FileText className="size-3.5" aria-hidden /> {name}
        </span>
      }
      size="lg"
      footer={
        <>
          {url && (
            <Button variant="ghost" size="sm" icon={<ExternalLink className="size-4" aria-hidden />} onClick={() => window.open(url, "_blank", "noopener")}>
              Open in new tab
            </Button>
          )}
          <Button size="sm" disabled={!url} icon={<Download className="size-4" aria-hidden />} onClick={download}>
            Download
          </Button>
          {shareable && (
            <Button variant="primary" size="sm" icon={<Share2 className="size-4" aria-hidden />} onClick={() => void share()}>
              Share
            </Button>
          )}
        </>
      }
    >
      {q.isError ? (
        <ErrorState title="Couldn't open the term sheet" error={q.error} onRetry={() => void q.refetch()} />
      ) : !url ? (
        <LoadingBlock className="h-[70dvh]" />
      ) : (
        <iframe title={`Term sheet: ${name}`} src={url} className="block h-[70dvh] w-full rounded-md border border-border bg-surface-2" />
      )}
    </Dialog>
  );
}

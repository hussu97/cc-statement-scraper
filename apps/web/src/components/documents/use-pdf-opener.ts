import { documentStoragePath, signedDocumentUrl } from "@/data/cards";
import { errorMessage } from "@/data/api";
import { useToast } from "@/components/ui/toast";

/**
 * Open a stored statement PDF in a new tab through a short-lived signed URL.
 * The tab opens synchronously (inside the click) so pop-up blockers allow it.
 */
export function usePdfOpener() {
  const toast = useToast();
  return async (docCode: string | null) => {
    if (!docCode) {
      toast({ title: "No PDF for this statement", tone: "danger" });
      return;
    }
    const win = window.open("about:blank", "_blank");
    try {
      const path = await documentStoragePath(docCode);
      if (!path) throw new Error("The PDF for this statement isn't available.");
      const url = await signedDocumentUrl(path);
      if (win) win.location.href = url;
      else window.location.assign(url);
    } catch (e) {
      win?.close();
      toast({ title: "Couldn't open the PDF", description: errorMessage(e), tone: "danger" });
    }
  };
}

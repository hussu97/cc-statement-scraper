// A structured note's term sheet in the viewer: what a downloaded or shared copy is called, and
// whether the browser can hand the file to the system share sheet. Pure, unit-tested; the iOS
// twin is LedgerKit `TermSheetPDF.shareFilename`.

/** The stored file name (else the fallback) without path separators, always ending ".pdf". */
export function termSheetFilename(filename: string | null | undefined, fallback: string): string {
  const raw = filename?.trim() || fallback;
  const name = raw.replace(/[/:\\]/g, "-").replace(/\.pdf$/i, "").trim();
  return `${name || "Term sheet"}.pdf`;
}

type ShareNavigator = Pick<Navigator, "share" | "canShare">;

/** True when the browser's Web Share API takes files (Safari, Chrome on phones and macOS). */
export function canShareFile(nav: Partial<ShareNavigator> | undefined, file: File): boolean {
  if (!nav?.share || !nav.canShare) return false;
  try {
    return nav.canShare({ files: [file] });
  } catch {
    return false;
  }
}

/** A user cancelling the share sheet is not a failure. */
export function isShareCancel(e: unknown): boolean {
  return e instanceof DOMException && e.name === "AbortError";
}

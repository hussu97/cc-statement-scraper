/**
 * Save text as a file in the browser. A CSV starts with a UTF-8 byte order mark so Excel reads
 * Arabic merchant names and "•" correctly.
 */
export function downloadText(filename: string, text: string, type = "text/csv;charset=utf-8"): void {
  const blob = new Blob([type.startsWith("text/csv") ? "﻿" : "", text], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.rel = "noopener";
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Revoke after the click has been handled.
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// Holding attachments (20261108112842_holding_attachments): invoices and certificates kept with a
// holding in the private `holding-attachments` bucket at <profile>/<holding>/<file>.
// Pure helpers, unit-tested; the bucket and add_holding_attachment check everything again.
import { formatDate } from "@/lib/dates";

/** The bucket's limit (storage.buckets.file_size_limit). */
export const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;
/** add_holding_attachment refuses more than this per holding. */
export const MAX_ATTACHMENTS = 20;

/** The bucket's allowed types and the extension each is stored under. */
export const ATTACHMENT_TYPES: Readonly<Record<string, string>> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/heic": "heic",
  "application/pdf": "pdf",
};

/** The file input's `accept`. */
export const ATTACHMENT_ACCEPT = Object.keys(ATTACHMENT_TYPES).join(",");

const EXT_TYPES: Readonly<Record<string, string>> = {
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
  heic: "image/heic",
  pdf: "application/pdf",
};

/** A file's type: the browser's, or from its extension when the browser gives none (HEIC on most desktops). */
export function attachmentType(file: { name: string; type: string }): string | null {
  if (file.type && ATTACHMENT_TYPES[file.type]) return file.type;
  if (file.type && file.type !== "application/octet-stream") return null;
  const ext = /\.([a-z0-9]+)$/i.exec(file.name)?.[1]?.toLowerCase();
  return (ext && EXT_TYPES[ext]) || null;
}

/** Client-side pre-checks: type, size, and room left under the per-holding limit. */
export function checkAttachmentFiles(
  files: { name: string; type: string; size: number }[],
  existing: number,
): { ok: { file: (typeof files)[number]; type: string }[]; rejected: { name: string; reason: string }[] } {
  const ok: { file: (typeof files)[number]; type: string }[] = [];
  const rejected: { name: string; reason: string }[] = [];
  for (const f of files) {
    const type = attachmentType(f);
    if (!type) rejected.push({ name: f.name, reason: "Not a photo or PDF" });
    else if (f.size === 0) rejected.push({ name: f.name, reason: "Empty file" });
    else if (f.size > MAX_ATTACHMENT_BYTES) rejected.push({ name: f.name, reason: "Larger than 10 MB" });
    else if (existing + ok.length >= MAX_ATTACHMENTS) rejected.push({ name: f.name, reason: `A holding keeps at most ${MAX_ATTACHMENTS} files` });
    else ok.push({ file: f, type });
  }
  return { ok, rejected };
}

/** Where a new file goes: `<profile>/<holding>/<id>.<ext>`, the only shape add_holding_attachment accepts. */
export function attachmentPath(profileCode: string, holdingCode: string, id: string, type: string): string {
  const ext = ATTACHMENT_TYPES[type];
  if (!ext) throw new Error(`Unsupported attachment type ${type}`);
  return `${profileCode}/${holdingCode}/${id}.${ext}`;
}

/** What a row shows: its caption, else its file name. */
export function attachmentLabel(a: { caption: string | null; file_name: string }): string {
  return a.caption?.trim() || a.file_name;
}

/** The viewer's subtitle: the file name when a caption hides it, then size and the day it was added. */
export function attachmentFacts(a: { caption: string | null; file_name: string; size_bytes: number; created_at: string }): string {
  const parts = [a.caption?.trim() ? a.file_name : null, formatBytes(a.size_bytes), `added ${formatDate(a.created_at.slice(0, 10))}`];
  return parts.filter(Boolean).join(" · ");
}

export function isImageAttachment(mime: string): boolean {
  return mime.startsWith("image/");
}

/** Browsers other than Safari can't draw HEIC: shown as a file to download instead of a picture. */
export function canPreview(mime: string): boolean {
  return isImageAttachment(mime) && mime !== "image/heic";
}

/** 2400000 → "2.3 MB", 81920 → "80 KB". */
export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return "";
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

import { describe, expect, it } from "vitest";
import {
  MAX_ATTACHMENT_BYTES,
  MAX_ATTACHMENTS,
  attachmentFacts,
  attachmentLabel,
  attachmentPath,
  attachmentType,
  canPreview,
  checkAttachmentFiles,
  formatBytes,
} from "./holding-attachments";

const P = "prf_00000000000000000000000001";
const H = "hld_00000000000000000000000002";

describe("attachmentType", () => {
  it("takes the browser's type when the bucket allows it", () => {
    expect(attachmentType({ name: "a.jpg", type: "image/jpeg" })).toBe("image/jpeg");
    expect(attachmentType({ name: "a.pdf", type: "application/pdf" })).toBe("application/pdf");
  });
  it("falls back to the extension when the browser gives none", () => {
    expect(attachmentType({ name: "IMG_0001.HEIC", type: "" })).toBe("image/heic");
    expect(attachmentType({ name: "scan.jpeg", type: "application/octet-stream" })).toBe("image/jpeg");
  });
  it("refuses anything else", () => {
    expect(attachmentType({ name: "a.gif", type: "image/gif" })).toBeNull();
    expect(attachmentType({ name: "notes.txt", type: "" })).toBeNull();
    expect(attachmentType({ name: "a.pdf", type: "text/plain" })).toBeNull();
  });
});

describe("checkAttachmentFiles", () => {
  it("sorts files into accepted and rejected with a reason", () => {
    const { ok, rejected } = checkAttachmentFiles(
      [
        { name: "invoice.jpg", type: "image/jpeg", size: 2_000_000 },
        { name: "big.pdf", type: "application/pdf", size: MAX_ATTACHMENT_BYTES + 1 },
        { name: "empty.png", type: "image/png", size: 0 },
        { name: "clip.mov", type: "video/quicktime", size: 10 },
      ],
      0,
    );
    expect(ok.map((x) => [x.file.name, x.type])).toEqual([["invoice.jpg", "image/jpeg"]]);
    expect(rejected).toEqual([
      { name: "big.pdf", reason: "Larger than 10 MB" },
      { name: "empty.png", reason: "Empty file" },
      { name: "clip.mov", reason: "Not a photo or PDF" },
    ]);
  });
  it("keeps to the per-holding limit, counting what is already there", () => {
    const f = (n: number) => ({ name: `${n}.jpg`, type: "image/jpeg", size: 10 });
    const { ok, rejected } = checkAttachmentFiles([f(1), f(2), f(3)], MAX_ATTACHMENTS - 2);
    expect(ok).toHaveLength(2);
    expect(rejected).toEqual([{ name: "3.jpg", reason: `A holding keeps at most ${MAX_ATTACHMENTS} files` }]);
  });
});

describe("attachmentPath", () => {
  it("is <profile>/<holding>/<id>.<ext>", () => {
    expect(attachmentPath(P, H, "abc", "image/jpeg")).toBe(`${P}/${H}/abc.jpg`);
    expect(attachmentPath(P, H, "abc", "application/pdf")).toBe(`${P}/${H}/abc.pdf`);
  });
  it("refuses a type the bucket doesn't take", () => {
    expect(() => attachmentPath(P, H, "abc", "image/gif")).toThrow();
  });
});

describe("labels and previews", () => {
  it("shows the caption, else the file name", () => {
    expect(attachmentLabel({ caption: "Purchase invoice", file_name: "IMG_1.jpg" })).toBe("Purchase invoice");
    expect(attachmentLabel({ caption: "  ", file_name: "IMG_1.jpg" })).toBe("IMG_1.jpg");
    expect(attachmentLabel({ caption: null, file_name: "IMG_1.jpg" })).toBe("IMG_1.jpg");
  });
  it("names the file only when a caption hides it", () => {
    const base = { file_name: "IMG_1.jpg", size_bytes: 81_920, created_at: "2026-03-04T10:00:00Z" };
    expect(attachmentFacts({ ...base, caption: null })).toMatch(/^80 KB · added /);
    expect(attachmentFacts({ ...base, caption: "Invoice" })).toMatch(/^IMG_1\.jpg · 80 KB · added /);
  });
  it("previews images browsers can draw", () => {
    expect(canPreview("image/jpeg")).toBe(true);
    expect(canPreview("image/heic")).toBe(false);
    expect(canPreview("application/pdf")).toBe(false);
  });
  it("formats sizes", () => {
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(81_920)).toBe("80 KB");
    expect(formatBytes(2_400_000)).toBe("2.3 MB");
    expect(formatBytes(-1)).toBe("");
  });
});

import { describe, expect, it } from "vitest";
import { canShareFile, isShareCancel, termSheetFilename } from "./term-sheet";

describe("termSheetFilename", () => {
  it("keeps the original name and normalises the extension", () => {
    expect(termSheetFilename("Final TS GOOGL AMZN META 27% P.A.pdf", "x")).toBe("Final TS GOOGL AMZN META 27% P.A.pdf");
    expect(termSheetFilename("Step-Up Note.PDF", "x")).toBe("Step-Up Note.pdf");
  });
  it("drops path separators", () => {
    expect(termSheetFilename("a/b:c\\d", "x")).toBe("a-b-c-d.pdf");
  });
  it("falls back to the note's name, then to 'Term sheet'", () => {
    expect(termSheetFilename(null, "Example Bank B Athena 2029")).toBe("Example Bank B Athena 2029.pdf");
    expect(termSheetFilename("  ", "Example Bank B")).toBe("Example Bank B.pdf");
    expect(termSheetFilename(".pdf", "x")).toBe("Term sheet.pdf");
  });
});

describe("canShareFile", () => {
  const file = new File(["%PDF-"], "t.pdf", { type: "application/pdf" });
  it("needs both share and canShare, and canShare to accept files", () => {
    expect(canShareFile(undefined, file)).toBe(false);
    expect(canShareFile({ share: async () => {} }, file)).toBe(false);
    expect(canShareFile({ share: async () => {}, canShare: () => false }, file)).toBe(false);
    expect(canShareFile({ share: async () => {}, canShare: () => true }, file)).toBe(true);
  });
  it("a canShare that throws means no", () => {
    expect(canShareFile({ share: async () => {}, canShare: () => { throw new TypeError("x"); } }, file)).toBe(false);
  });
});

describe("isShareCancel", () => {
  it("is only the AbortError the share sheet raises when dismissed", () => {
    expect(isShareCancel(new DOMException("cancelled", "AbortError"))).toBe(true);
    expect(isShareCancel(new DOMException("denied", "NotAllowedError"))).toBe(false);
    expect(isShareCancel(new Error("x"))).toBe(false);
  });
});

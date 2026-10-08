import { describe, expect, it } from "vitest";
import { compareEvents, docState, eventAdvice, eventTone, eventsByDoc, mergeEvents, normalizeDocCodes, stageLabel, uploadStatus, type DocumentEvent } from "./document-events";

const DOC_A = "doc_01m4ea5xbab549jj8c98dtcj6v";
const DOC_B = "doc_01m4ea5xc2rph4za264wqq8cj2";

let n = 0;
const ev = (stage: string, at: string, over: Partial<DocumentEvent> = {}): DocumentEvent => ({
  event_code: `dev_${String(++n).padStart(26, "0")}`,
  profile_code: "prf_1",
  doc_code: DOC_A,
  created_at: `2026-10-08T10:00:${at}Z`,
  stage,
  level: "info",
  message: stage,
  detail: {},
  ...over,
});

describe("timeline order and merging", () => {
  it("orders by created_at, then event_code", () => {
    const a = ev("received", "01", { event_code: "dev_b" });
    const b = ev("stored", "01", { event_code: "dev_a" });
    const c = ev("queued", "00");
    expect([a, b, c].sort(compareEvents).map((e) => e.stage)).toEqual(["queued", "stored", "received"]);
  });

  it("adds realtime arrivals once, in order", () => {
    const r = ev("received", "01");
    const s = ev("stored", "02");
    const q = ev("queued", "03");
    const merged = mergeEvents([r, s], [q, s]);
    expect(merged.map((e) => e.stage)).toEqual(["received", "stored", "queued"]);
    expect(mergeEvents([], [q, r]).map((e) => e.stage)).toEqual(["received", "queued"]);
  });

  it("groups by document", () => {
    const m = eventsByDoc([ev("queued", "05", { doc_code: DOC_B }), ev("received", "01"), ev("received", "02", { doc_code: DOC_B })]);
    expect(m.get(DOC_A)!.map((e) => e.stage)).toEqual(["received"]);
    expect(m.get(DOC_B)!.map((e) => e.stage)).toEqual(["received", "queued"]);
  });

  it("keeps only real doc codes, once, sorted (a stable query key)", () => {
    expect(normalizeDocCodes([DOC_B, null, DOC_A, "junk", undefined, DOC_B])).toEqual([DOC_A, DOC_B]);
  });
});

describe("docState", () => {
  it("follows the latest event", () => {
    expect(docState([])).toBe("waiting");
    expect(docState([ev("received", "01"), ev("parsing", "02")])).toBe("working");
    expect(docState([ev("received", "01"), ev("ingested", "09")])).toBe("done");
    expect(docState([ev("received", "01"), ev("duplicate", "02")])).toBe("duplicate");
    expect(docState([ev("parsing", "01"), ev("failed", "02")])).toBe("failed");
    expect(docState([ev("failed", "01"), ev("retry", "02")])).toBe("retrying");
    // Out-of-order input still uses the newest event.
    expect(docState([ev("ingested", "09"), ev("received", "01")])).toBe("done");
  });
});

describe("uploadStatus", () => {
  it("uses the upload response until events arrive", () => {
    expect(uploadStatus("queued", [])).toEqual({ state: "waiting", label: "Queued" });
    expect(uploadStatus("duplicate", [])).toEqual({ state: "duplicate", label: "Already uploaded" });
  });

  it("then follows the timeline", () => {
    expect(uploadStatus("queued", [ev("received", "01"), ev("stored", "02"), ev("queued", "03")]).label).toBe("Queued");
    expect(uploadStatus("queued", [ev("queued", "03"), ev("parsing", "04")])).toEqual({ state: "working", label: "Reading…" });
    expect(uploadStatus("queued", [ev("parsed", "05")]).label).toBe("Read…");
    expect(uploadStatus("queued", [ev("ingested", "06")])).toEqual({ state: "done", label: "Imported" });
    expect(uploadStatus("queued", [ev("failed", "06")])).toEqual({ state: "failed", label: "Failed" });
    expect(uploadStatus("duplicate", [ev("received", "01"), ev("duplicate", "02")]).state).toBe("duplicate");
  });
});

describe("labels and tones", () => {
  it("names every stage and passes unknown ones through", () => {
    expect(stageLabel("parsing")).toBe("Reading");
    expect(stageLabel("ingested")).toBe("Imported");
    expect(stageLabel("someday")).toBe("someday");
  });

  it("highlights errors and warnings", () => {
    expect(eventTone({ stage: "failed", level: "error" })).toBe("danger");
    expect(eventTone({ stage: "retry", level: "warn" })).toBe("warn");
    expect(eventTone({ stage: "ingested", level: "info" })).toBe("positive");
    expect(eventTone({ stage: "parsing", level: "info" })).toBe("info");
    expect(eventTone({ stage: "queued", level: "info" })).toBe("neutral");
  });
});

describe("eventAdvice", () => {
  const failed = (code?: string) => ({ stage: "failed", level: "error", detail: code ? { error_code: code } : {} });

  it("sends a wrong or missing PDF password to Settings", () => {
    expect(eventAdvice(failed("PDF_DECRYPT_FAILED"))?.kind).toBe("passwords");
  });

  it("asks for a re-upload when the file itself is the problem", () => {
    expect(eventAdvice(failed("BANK_UNDETECTED"))?.kind).toBe("reupload");
    expect(eventAdvice(failed("DOCUMENT_MISSING"))?.kind).toBe("reupload");
  });

  it("offers a re-read for transient and ingest failures", () => {
    expect(eventAdvice(failed("PARSE_TIMEOUT"))?.kind).toBe("retry");
    expect(eventAdvice(failed("INGEST_23505"))?.kind).toBe("retry");
    expect(eventAdvice(failed())?.kind).toBe("retry");
  });

  it("offers nothing for unsupported statements, and a hint for big files", () => {
    expect(eventAdvice(failed("UNSUPPORTED_BANK"))).toEqual({ kind: "none" });
    expect(eventAdvice(failed("PDF_TOO_LARGE"))?.text).toMatch(/smaller PDF/);
  });

  it("is silent for normal steps", () => {
    expect(eventAdvice({ stage: "ingested", level: "info", detail: {} })).toBeNull();
    expect(eventAdvice({ stage: "retry", level: "warn", detail: { error_code: "PARSE_TIMEOUT" } })).toBeNull();
  });
});

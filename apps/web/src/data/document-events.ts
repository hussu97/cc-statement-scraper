import { useEffect, useId, useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase, type Tables } from "@/lib/supabase";
import { keys } from "./keys";
import { mustList } from "./api";

export const DOCUMENT_STAGES = ["received", "stored", "duplicate", "queued", "parsing", "parsed", "ingested", "failed", "retry"] as const;
export type DocumentStage = (typeof DOCUMENT_STAGES)[number];
export type EventLevel = "info" | "warn" | "error";

/** A document_events row (generated as plain text columns; these are its CHECK values). */
export interface DocumentEvent extends Omit<Tables<"document_events">, "stage" | "level" | "detail"> {
  stage: DocumentStage | string;
  level: EventLevel | string;
  detail: Record<string, unknown> | null;
}

const COLUMNS = "event_code, profile_code, doc_code, created_at, stage, level, message, detail";

/** Timeline order: created_at (clock_timestamp), then event_code. Pure. */
export function compareEvents(a: Pick<DocumentEvent, "created_at" | "event_code">, b: Pick<DocumentEvent, "created_at" | "event_code">): number {
  return a.created_at.localeCompare(b.created_at) || a.event_code.localeCompare(b.event_code);
}

/**
 * Add realtime arrivals to what was fetched: one row per event_code (an
 * insert can arrive both ways), in timeline order. Pure, unit-tested.
 */
export function mergeEvents(existing: readonly DocumentEvent[], incoming: readonly DocumentEvent[]): DocumentEvent[] {
  const byCode = new Map<string, DocumentEvent>();
  for (const e of existing) byCode.set(e.event_code, e);
  for (const e of incoming) byCode.set(e.event_code, e);
  return [...byCode.values()].sort(compareEvents);
}

/** Events per document, each list in timeline order. Pure. */
export function eventsByDoc(events: readonly DocumentEvent[]): Map<string, DocumentEvent[]> {
  const out = new Map<string, DocumentEvent[]>();
  for (const e of [...events].sort(compareEvents)) {
    const list = out.get(e.doc_code) ?? [];
    list.push(e);
    out.set(e.doc_code, list);
  }
  return out;
}

export type DocState = "waiting" | "working" | "done" | "duplicate" | "failed" | "retrying";

/** Where a document is, from its latest event. Pure, unit-tested. */
export function docState(events: readonly DocumentEvent[]): DocState {
  const last = events.length ? [...events].sort(compareEvents)[events.length - 1]! : null;
  if (!last) return "waiting";
  switch (last.stage) {
    case "ingested":
      return "done";
    case "duplicate":
      return "duplicate";
    case "failed":
      return "failed";
    case "retry":
      return "retrying";
    default:
      return "working";
  }
}

export const STAGE_LABEL: Record<DocumentStage, string> = {
  received: "Received",
  stored: "Saved",
  duplicate: "Already uploaded",
  queued: "Queued",
  parsing: "Reading",
  parsed: "Read",
  ingested: "Imported",
  failed: "Failed",
  retry: "Retrying",
};

export function stageLabel(stage: string): string {
  return STAGE_LABEL[stage as DocumentStage] ?? stage;
}

export type EventTone = "neutral" | "info" | "positive" | "warn" | "danger";

/** Tone of an event row: errors and warnings by level, the end states by stage. Pure. */
export function eventTone(e: Pick<DocumentEvent, "stage" | "level">): EventTone {
  if (e.level === "error" || e.stage === "failed") return "danger";
  if (e.level === "warn") return "warn";
  if (e.stage === "ingested") return "positive";
  if (e.stage === "parsing" || e.stage === "parsed") return "info";
  return "neutral";
}

export type EventAdvice =
  | { kind: "passwords"; text: string }
  | { kind: "reupload"; text: string }
  | { kind: "retry"; text: string }
  | { kind: "none"; text: string };

/**
 * What to do next after a failure, from detail.error_code (parse-v1 codes,
 * worker codes, INGEST_<sqlstate>). The event's own message says what went
 * wrong; this is the action. Null for events that need nothing. Pure, unit-tested.
 */
export function eventAdvice(e: Pick<DocumentEvent, "stage" | "level" | "detail">): EventAdvice | null {
  if (e.stage !== "failed" && e.level !== "error") return null;
  const code = typeof e.detail?.error_code === "string" ? e.detail.error_code : "";
  switch (true) {
    case code === "PDF_DECRYPT_FAILED":
      return { kind: "passwords", text: "Add or fix this bank's statement password, then upload the PDF again." };
    case code === "BANK_UNDETECTED" || code === "DOWNLOAD_FAILED" || code === "DOCUMENT_MISSING":
      return { kind: "reupload", text: "Upload the PDF again." };
    case code === "UNSUPPORTED_BANK" || code === "UNSUPPORTED_LAYOUT":
      return { kind: "none", text: "Nothing to do for now: this statement can't be imported yet." };
    case code === "PDF_TOO_LARGE":
      return { kind: "none", text: "Try a smaller PDF, such as one statement per file." };
    case code === "PARSE_TIMEOUT" || code === "MAX_ATTEMPTS" || code === "INTERNAL_ERROR" || code.startsWith("INGEST_") || code === "PARSE_OUTPUT_INVALID":
      return { kind: "retry", text: "Try reading it again. If it fails again, the statement may need a parser update." };
    default:
      return { kind: "retry", text: "Try reading it again." };
  }
}

/** Codes worth subscribing for, deduplicated and sorted (a stable query key). Pure. */
export function normalizeDocCodes(codes: readonly (string | null | undefined)[]): string[] {
  return [...new Set(codes.filter((c): c is string => typeof c === "string" && /^doc_[0-9a-z]{26}$/.test(c)))].sort();
}

/**
 * The processing log of some documents: an initial fetch, then live inserts
 * over Realtime (document_events is in the publication; RLS limits rows to
 * members). The list is kept in timeline order with no duplicates.
 */
export function useDocumentEvents(profileCode: string, docCodes: readonly (string | null | undefined)[], opts: { live?: boolean } = {}) {
  const live = opts.live ?? true;
  const codes = useMemo(() => normalizeDocCodes(docCodes), [docCodes]);
  const codesKey = codes.join(",");
  const qc = useQueryClient();
  const instance = useId();
  const queryKey = keys.documentEvents(profileCode, codes);
  const query = useQuery({
    queryKey,
    enabled: codes.length > 0,
    queryFn: async (): Promise<DocumentEvent[]> =>
      mustList(
        await supabase
          .from("document_events")
          .select(COLUMNS)
          .eq("profile_code", profileCode)
          .in("doc_code", codes)
          .order("created_at", { ascending: true })
          .order("event_code", { ascending: true })
          .limit(2000),
      ) as DocumentEvent[],
  });

  useEffect(() => {
    if (!live || !codesKey) return;
    const wanted = new Set(codesKey.split(","));
    const key = keys.documentEvents(profileCode, [...wanted]);
    const channel = supabase.channel(`doc-events:${profileCode}:${instance}`);
    channel.on(
      "postgres_changes",
      { event: "INSERT", schema: "public", table: "document_events", filter: `profile_code=eq.${profileCode}` },
      (payload) => {
        const row = payload.new as DocumentEvent;
        if (!wanted.has(row.doc_code)) return;
        qc.setQueryData<DocumentEvent[]>(key, (prev) => mergeEvents(prev ?? [], [row]));
      },
    );
    // Events written between the first fetch and the subscription: fetch once more when live.
    channel.subscribe((status) => {
      if (status === "SUBSCRIBED") void qc.invalidateQueries({ queryKey: key });
    });
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [live, codesKey, profileCode, qc, instance]);

  return query;
}

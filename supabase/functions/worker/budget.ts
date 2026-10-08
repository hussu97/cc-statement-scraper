// Worker time budget (audit SRV-04). Pure, so _tests/worker_test.ts can import it.

import { LLM_TIMEOUT_MS } from "../_shared/llm.ts";
import { parserTimeoutMs } from "./parse_document.ts";

/** Edge Functions wall-clock limit (150 s on the free plan, 400 s on paid). */
export const DEFAULT_WALL_CLOCK_MS = 150_000;
/** ingest_parsed_document + status writes after the parser answers. */
export const INGEST_MARGIN_MS = 20_000;
/** Kept free at the end for Sentry flush and the isolate shutting down. */
export const SAFETY_MARGIN_MS = 5_000;

export interface WorkerTiming {
  /** When the request started (the wall clock counts from here, not from runWorker). */
  startedAt: number;
  /** Stop starting new rounds after this many ms. */
  budgetMs: number;
  wallClockMs: number;
  parserTimeoutMs: number;
  llmTimeoutMs: number;
}

export function workerTiming(startedAt: number, budgetMs: number): WorkerTiming {
  const wall = Number(Deno.env.get("EDGE_WALL_CLOCK_MS"));
  return {
    startedAt,
    budgetMs,
    wallClockMs: Number.isFinite(wall) && wall > 0 ? wall : DEFAULT_WALL_CLOCK_MS,
    parserTimeoutMs: parserTimeoutMs(),
    llmTimeoutMs: LLM_TIMEOUT_MS,
  };
}

/** Can a round that may wait `needMs` start at `now` without outliving the isolate? */
export function canStart(t: WorkerTiming, now: number, needMs: number): boolean {
  if (now >= t.startedAt + t.budgetMs) return false;
  const wallDeadline = t.startedAt + t.wallClockMs - SAFETY_MARGIN_MS;
  return wallDeadline - now >= needMs;
}

export function parseRoundNeedMs(t: WorkerTiming): number {
  return t.parserTimeoutMs + INGEST_MARGIN_MS;
}

export function llmRoundNeedMs(t: WorkerTiming): number {
  return t.llmTimeoutMs + 5_000;
}

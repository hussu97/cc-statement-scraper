// storage_cleanup queue consumer (DB-21e). delete_profile can't delete Storage objects
// from SQL, so it queues the deleted profile's PDF paths as {bucket, paths[]} (≤100 per
// message); the worker removes them through the Storage API with the service client.
//
// Only the `statements` bucket and paths shaped like <profile_code>/<file> are accepted,
// so a malformed message can never delete anything else. Removing an object that is
// already gone succeeds, so redelivery is harmless. A failed removal is retried by the
// visibility timeout and dead-lettered after MAX_READS (storage_cleanup_dlq).

import { captureMessage } from "../_shared/sentry.ts";
import type { Db } from "../_shared/supabase.ts";
import { MAX_READS, queueDelete, type QueueMessage, toDlq } from "./queue.ts";

export const STORAGE_QUEUE = "storage_cleanup";
const BUCKETS: ReadonlySet<string> = new Set(["statements"]);
const PATH_RE = /^prf_[0-9a-z]{26}\/[A-Za-z0-9._-]{1,200}$/;
const MAX_PATHS = 100;

export interface CleanupResult {
  queue: string;
  outcome: "done" | "retry" | "dlq";
  code?: string;
  removed?: number;
}

export interface CleanupBatch {
  bucket: string;
  /** Paths safe to delete. */
  paths: string[];
  /** Entries that don't look like `<profile_code>/<file>`: never deleted, only counted. */
  skipped: number;
}

/** The message's bucket and paths, or null when it isn't a well-formed cleanup batch. */
export function cleanupBatch(message: Record<string, unknown>): CleanupBatch | null {
  const bucket = message.bucket;
  const paths = message.paths;
  if (typeof bucket !== "string" || !BUCKETS.has(bucket)) return null;
  if (!Array.isArray(paths) || paths.length > MAX_PATHS) return null;
  const ok = paths.filter((p): p is string => typeof p === "string" && PATH_RE.test(p) && !p.includes(".."));
  return { bucket, paths: ok, skipped: paths.length - ok.length };
}

export async function processStorageCleanup(svc: Db, msg: QueueMessage): Promise<CleanupResult> {
  const batch = cleanupBatch(msg.message);
  if (!batch) {
    await toDlq(svc, STORAGE_QUEUE, msg, "invalid message");
    captureMessage("storage_cleanup message rejected", {
      level: "error",
      tags: { queue: STORAGE_QUEUE },
      fingerprint: ["worker", "dlq", STORAGE_QUEUE, "INVALID_MESSAGE"],
    });
    return { queue: STORAGE_QUEUE, outcome: "dlq", code: "INVALID_MESSAGE" };
  }
  if (batch.skipped > 0) {
    captureMessage("storage_cleanup skipped paths that don't belong to a profile", {
      level: "warning",
      tags: { queue: STORAGE_QUEUE },
      extra: { skipped: batch.skipped, kept: batch.paths.length },
      fingerprint: ["worker", STORAGE_QUEUE, "skipped_paths"],
    });
  }
  if (batch.paths.length === 0) {
    await queueDelete(svc, STORAGE_QUEUE, msg.msg_id);
    return { queue: STORAGE_QUEUE, outcome: "done", removed: 0 };
  }
  const { data, error } = await svc.storage.from(batch.bucket).remove(batch.paths);
  if (error) {
    // deno-lint-ignore no-explicit-any
    const status = String((error as any).statusCode ?? (error as any).status ?? "ERROR");
    const code = `STORAGE_${status}`;
    if (msg.read_ct >= MAX_READS) {
      await toDlq(svc, STORAGE_QUEUE, msg, code);
      captureMessage(`storage_cleanup moved to DLQ: ${code}`, {
        level: "error",
        tags: { queue: STORAGE_QUEUE, error_code: code, read_ct: msg.read_ct },
        fingerprint: ["worker", "dlq", STORAGE_QUEUE, code],
      });
      return { queue: STORAGE_QUEUE, outcome: "dlq", code };
    }
    // Left on the queue: it comes back after its visibility timeout.
    return { queue: STORAGE_QUEUE, outcome: "retry", code };
  }
  await queueDelete(svc, STORAGE_QUEUE, msg.msg_id);
  return { queue: STORAGE_QUEUE, outcome: "done", removed: Array.isArray(data) ? data.length : 0 };
}

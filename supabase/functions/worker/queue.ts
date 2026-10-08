// Thin wrappers over the pgmq RPCs (public.queue_*), service role only.

import type { Db } from "../_shared/supabase.ts";

/** A message is attempted on reads 1..MAX_READS, then dead-lettered. */
export const MAX_READS = 5;

/** Delay before attempt n+1 after a transient failure on attempt n (1-based), in seconds. */
export const RETRY_BACKOFF_SECONDS = [60, 300, 900, 1800] as const;

export function backoffSeconds(attempt: number): number {
  const i = Math.min(Math.max(attempt, 1), RETRY_BACKOFF_SECONDS.length) - 1;
  return RETRY_BACKOFF_SECONDS[i];
}

/**
 * Attempts so far, including this read. A retried message is re-sent with
 * `attempt` = attempts already used (pgmq's read_ct restarts at 1 for the new message).
 */
export function attemptOf(msg: QueueMessage): number {
  const prior = Number((msg.message as { attempt?: unknown }).attempt ?? 0);
  return (Number.isFinite(prior) && prior > 0 ? Math.floor(prior) : 0) + msg.read_ct;
}

export interface QueueMessage {
  msg_id: number;
  read_ct: number;
  message: Record<string, unknown>;
}

export async function queueRead(svc: Db, queue: string, vt: number, qty: number): Promise<QueueMessage[]> {
  const { data, error } = await svc.rpc("queue_read", { p_queue: queue, p_vt: vt, p_qty: qty });
  if (error) throw new Error(`queue_read(${queue}) failed (${error.code})`);
  return (data ?? []) as QueueMessage[];
}

export async function queueDelete(svc: Db, queue: string, msgId: number): Promise<void> {
  const { error } = await svc.rpc("queue_delete", { p_queue: queue, p_msg_id: msgId });
  if (error) throw new Error(`queue_delete(${queue}) failed (${error.code})`);
}

/** Move to `<queue>_dlq`. `reason` must never contain message bodies or secrets. */
export async function toDlq(svc: Db, queue: string, msg: QueueMessage, reason: string): Promise<void> {
  const { error } = await svc.rpc("queue_to_dlq", {
    p_queue: queue,
    p_msg_id: msg.msg_id,
    p_message: msg.message,
    p_reason: reason,
  });
  if (error) throw new Error(`queue_to_dlq(${queue}) failed (${error.code})`);
}

/**
 * Retry later with backoff: re-send the message with a delay and the attempt count, then
 * delete this copy. Send first so a failure can never lose the message; if the send
 * fails, the message simply becomes visible again after its visibility timeout.
 */
export async function retryLater(svc: Db, queue: string, msg: QueueMessage, attempt: number): Promise<number | null> {
  const delay = backoffSeconds(attempt);
  const { error } = await svc.rpc("queue_send", {
    p_queue: queue,
    p_message: { ...msg.message, attempt },
    p_delay: delay,
  });
  if (error) return null;
  await queueDelete(svc, queue, msg.msg_id);
  return delay;
}

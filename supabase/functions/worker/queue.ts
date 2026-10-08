// Thin wrappers over the pgmq RPCs (public.queue_*), service role only.

import type { Db } from "../_shared/supabase.ts";

/** A message is attempted on reads 1..MAX_READS, then dead-lettered. */
export const MAX_READS = 5;

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

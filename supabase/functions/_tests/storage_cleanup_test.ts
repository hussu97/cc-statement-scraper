// storage_cleanup consumer (DB-21e) with a fake Db and Storage.

import { assertEquals } from "jsr:@std/assert@1.0.13";
import { cleanupBatch, processStorageCleanup } from "../worker/storage_cleanup.ts";
import { MAX_READS } from "../worker/queue.ts";
import { FakeDb } from "./fake_db.ts";

Deno.env.delete("SENTRY_DSN");

const PRF = "prf_01k6zz0000000000000000000e";
const p1 = `${PRF}/doc_01k6zz0000000000000000000a.pdf`;
const p2 = `${PRF}/doc_01k6zz0000000000000000000b.pdf`;

function setup() {
  const db = new FakeDb({
    rpcs: {
      queue_delete: () => ({ data: true, error: null }),
      queue_to_dlq: () => ({ data: null, error: null }),
    },
  });
  db.objects.set(p1, new Uint8Array(1));
  db.objects.set(p2, new Uint8Array(1));
  db.objects.set("prf_other/keep.pdf", new Uint8Array(1));
  return db;
}

Deno.test("cleanupBatch accepts only the statements bucket and profile-scoped paths", () => {
  assertEquals(cleanupBatch({ bucket: "statements", paths: [p1, p2] }), {
    bucket: "statements",
    paths: [p1, p2],
    skipped: 0,
  });
  assertEquals(cleanupBatch({ bucket: "avatars", paths: [p1] }), null);
  assertEquals(cleanupBatch({ bucket: "statements", paths: "x" }), null);
  assertEquals(cleanupBatch({ bucket: "statements", paths: Array(101).fill(p1) }), null);
  assertEquals(
    cleanupBatch({ bucket: "statements", paths: [p1, "../etc/passwd", `${PRF}/../x`, "", 7, "nested/a/b.pdf"] }),
    { bucket: "statements", paths: [p1], skipped: 5 },
  );
});

Deno.test("storage_cleanup removes the batch and deletes the message; redelivery is harmless", async () => {
  const db = setup();
  const msg = { msg_id: 4, read_ct: 1, message: { bucket: "statements", paths: [p1, p2] } };
  assertEquals(await processStorageCleanup(db.asDb(), msg), { queue: "storage_cleanup", outcome: "done", removed: 2 });
  assertEquals([db.objects.has(p1), db.objects.has(p2), db.objects.has("prf_other/keep.pdf")], [false, false, true]);
  assertEquals(db.rpcCalls("queue_delete"), [{ p_queue: "storage_cleanup", p_msg_id: 4 }]);
  // Already gone: still done.
  assertEquals((await processStorageCleanup(db.asDb(), msg)).outcome, "done");
});

Deno.test("storage_cleanup never deletes paths outside a profile prefix", async () => {
  const db = setup();
  const r = await processStorageCleanup(db.asDb(), {
    msg_id: 5,
    read_ct: 1,
    message: { bucket: "statements", paths: ["prf_other/keep.pdf", p1] },
  });
  assertEquals(r.outcome, "done");
  assertEquals(db.objects.has("prf_other/keep.pdf"), true);
  assertEquals(db.calls.filter((c) => c.kind === "remove").map((c) => c.args), [[p1]]);
});

Deno.test("storage_cleanup: a malformed message is dead-lettered without touching Storage", async () => {
  const db = setup();
  const r = await processStorageCleanup(db.asDb(), {
    msg_id: 6,
    read_ct: 1,
    message: { bucket: "other", paths: [p1] },
  });
  assertEquals(r, { queue: "storage_cleanup", outcome: "dlq", code: "INVALID_MESSAGE" });
  assertEquals(db.calls.filter((c) => c.kind === "remove").length, 0);
  assertEquals(db.rpcCalls("queue_to_dlq")[0].p_queue, "storage_cleanup");
});

Deno.test("storage_cleanup: a Storage error retries, then dead-letters after MAX_READS", async () => {
  const db = setup();
  db.removeError = { code: "500", message: "storage down", statusCode: "500" };
  const msg = (read_ct: number) => ({ msg_id: 7, read_ct, message: { bucket: "statements", paths: [p1] } });
  assertEquals(await processStorageCleanup(db.asDb(), msg(1)), {
    queue: "storage_cleanup",
    outcome: "retry",
    code: "STORAGE_500",
  });
  assertEquals(db.rpcCalls("queue_delete").length, 0, "left for the visibility timeout");
  assertEquals((await processStorageCleanup(db.asDb(), msg(MAX_READS))).outcome, "dlq");
  assertEquals(db.objects.has(p1), true);
});

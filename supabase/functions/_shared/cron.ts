// pg_cron calls functions through pg_net with a 5 s timeout (private.invoke_edge),
// so long jobs run in the background (EdgeRuntime.waitUntil) and answer 202 at once.
// `?sync=1` or a JSON body {"sync": true} waits and returns the result instead.

import { captureException, waitUntil } from "./sentry.ts";
import { json, readJson } from "./http.ts";

export async function wantsSync(req: Request): Promise<boolean> {
  if (new URL(req.url).searchParams.get("sync") === "1") return true;
  const body = (await readJson(req).catch(() => ({}))) as { sync?: unknown } | null;
  return body?.sync === true;
}

export async function runCronJob(req: Request, name: string, job: () => Promise<unknown>): Promise<Response> {
  if (await wantsSync(req)) return json(await job(), 200, req);
  const work = job().catch((e) => captureException(e, { tags: { function: name } }));
  if (!waitUntil(work)) await work;
  return json({ accepted: true }, 202, req);
}

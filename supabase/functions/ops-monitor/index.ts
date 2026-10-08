// ops-monitor: DB-side health → Sentry. pg_cron calls it every 15 min (x-cron-secret).
// Reads public.ops_health(), raises one Sentry issue per problem type (fingerprint
// ['ops', <issue>]), then sends a Sentry Cron check-in for monitor `ops-heartbeat`,
// so a paused project or dead pg_cron alerts through the missed check-in.

import { captureMessage, Sentry, sentryEnabled, withSentry } from "../_shared/sentry.ts";
import { requireCron } from "../_shared/auth.ts";
import { json, pgErrorToHttp, requireMethod } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { evaluateHealth, thresholdsFromEnv } from "./health.ts";

const MONITOR_SLUG = "ops-heartbeat";
const MONITOR_CONFIG = {
  schedule: { type: "crontab" as const, value: "*/15 * * * *" },
  checkinMargin: 5,
  maxRuntime: 2,
  timezone: "Etc/UTC",
};

function checkIn(status: "ok" | "error"): void {
  if (!sentryEnabled()) return;
  Sentry.captureCheckIn({ monitorSlug: MONITOR_SLUG, status }, MONITOR_CONFIG);
}

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);

  const { data, error } = await serviceClient().rpc("ops_health");
  if (error) {
    checkIn("error");
    throw pgErrorToHttp(error, "ops_health failed");
  }
  const issues = evaluateHealth(data ?? {}, thresholdsFromEnv());
  for (const i of issues) {
    captureMessage(i.message, {
      level: i.level,
      fingerprint: ["ops", i.issue],
      tags: { ops_issue: i.issue },
      extra: i.extra,
    });
  }
  checkIn("ok");
  return json(
    { checked_at: new Date().toISOString(), issues: issues.map((i) => ({ issue: i.issue, level: i.level })) },
    200,
    req,
  );
}

Deno.serve(withSentry("ops-monitor", handler));

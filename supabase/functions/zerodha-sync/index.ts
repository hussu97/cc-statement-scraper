// zerodha-sync: a Zerodha portfolio → its Kite and Coin holdings, Funds cash and value per day
// (tasks/todo.md §12). pg_cron calls it on weekdays with x-cron-secret (job `ledger-zerodha-sync`,
// 0 18 * * 1-5 UTC, 23:30 IST, after the close and most NAVs).
//
// For each login in ZERODHA_LOGINS ([{profile_code, user_id, password, totp_secret, api_key,
// api_secret}], an Edge secret): sign in to the user's own Kite Connect app (password + TOTP; the
// free Personal plan has no refresh token, so every run signs in), read the profile, Kite holdings,
// Coin holdings and Funds, and send them to import_zerodha_data, which keeps the ledger's account,
// holdings, marks, inferred flows and daily value (idempotent per day). Sign out. A segment whose
// read failed is left out (its marks carry over) and recorded on the connection; any failure is
// thrown after the other logins ran, so Sentry captures it. Messages never carry logins, codes,
// tokens or response bodies.

import { withSentry } from "../_shared/sentry.ts";
import { requireCron } from "../_shared/auth.ts";
import { pgErrorToHttp, requireMethod } from "../_shared/http.ts";
import { runCronJob } from "../_shared/cron.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { KiteSession, parseLogins, readPortfolio, why, type ZerodhaLogin } from "./kite.ts";

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);
  return await runCronJob(req, "zerodha-sync", syncAll);
}

interface ImportResult {
  account_code: string;
  positions_marked: number;
  positions_closed: number;
  value: string;
}

async function syncLogin(login: ZerodhaLogin) {
  const session = new KiteSession(login);
  await session.signIn();
  try {
    const { data, failed } = await readPortfolio(session, login.user_id);
    if (data.segments_read.length === 0) throw new Error(failed.join("; "));
    const db = serviceClient();
    const { data: result, error } = await db.rpc("import_zerodha_data", {
      p_profile_code: login.profile_code,
      p_data: data,
    });
    if (error) throw pgErrorToHttp(error, "import_zerodha_data failed");
    const r = result as ImportResult;
    // Part of it could not be read: the screen says so, and Sentry hears of it.
    if (failed.length > 0) throw new Error(`partly synced (${failed.join("; ")})`);
    return { account_code: r.account_code, positions: r.positions_marked, closed: r.positions_closed, value: r.value };
  } finally {
    await session.signOut();
  }
}

async function syncAll() {
  const logins = parseLogins(Deno.env.get("ZERODHA_LOGINS"));
  if (logins.length === 0) return { skipped: "ZERODHA_LOGINS is not set" };
  const results: Record<string, unknown> = {};
  const errors: string[] = [];
  for (const login of logins) {
    try {
      results[login.profile_code] = await syncLogin(login);
    } catch (e) {
      const msg = why(e);
      errors.push(`${login.profile_code}: ${msg}`);
      await serviceClient().rpc("record_broker_sync_error", {
        p_profile_code: login.profile_code,
        p_provider: "zerodha",
        p_error: msg,
      });
    }
  }
  if (errors.length > 0) throw new Error(`zerodha-sync: ${errors.join(" | ")} (done: ${JSON.stringify(results)})`);
  return results;
}

Deno.serve(withSentry("zerodha-sync", handler));

// rl360-sync: RL360 plan values, value history and premiums → the ledger's RL360 plans
// (tasks/todo.md §8). pg_cron calls it daily with x-cron-secret (job `ledger-rl360-sync`,
// 20 2 * * * UTC, 06:20 Dubai).
//
// For each login in RL360_LOGINS ([{profile_code, username, password}], an Edge secret): sign
// in, list the plans, and per plan send today's value and the full premium history to
// import_holding_data (which claims the holding, stores the value and reconciles premiums with
// linked card payments), then backfill up to BACKFILL_PER_RUN month-end values it reports
// missing, and sign out. Requests are spaced out (PAUSE_MS). Any failure throws after the other
// logins ran, so Sentry captures it; messages never carry logins or page text.

import { withSentry } from "../_shared/sentry.ts";
import { requireCron } from "../_shared/auth.ts";
import { pgErrorToHttp, requireMethod } from "../_shared/http.ts";
import { runCronJob } from "../_shared/cron.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { dubaiDate } from "../metal-prices/quotes.ts";
import {
  parseLogins,
  parsePlans,
  parsePremiums,
  parseValuation,
  parseWithdrawalTotal,
  premiumsUrl,
  RL360_BASE,
  type Rl360Login,
  Rl360Session,
  valuationUrl,
} from "./rl360.ts";

const BACKFILL_PER_RUN = 30;
const PAUSE_MS = 1_000;

const pause = () => new Promise((r) => setTimeout(r, PAUSE_MS));

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);
  return await runCronJob(req, "rl360-sync", syncAll);
}

interface ImportResult {
  holding_code: string | null;
  reason?: string;
  claimed?: boolean;
  values_added?: number;
  premiums?: unknown;
  missing_month_ends?: string[];
}

async function importData(
  login: Rl360Login,
  plan: string,
  currency: string,
  startedOn: string,
  valuations: { as_of: string; value: string }[],
  premiums: { ref: string; date: string; amount: string }[] | null,
): Promise<ImportResult> {
  const { data, error } = await serviceClient().rpc("import_holding_data", {
    p_profile_code: login.profile_code,
    p_institution: "RL360",
    p_external_ref: plan,
    p_currency: currency,
    p_started_on: startedOn,
    p_valuations: valuations,
    p_premiums: premiums,
  });
  if (error) throw pgErrorToHttp(error, "import_holding_data failed");
  return data as ImportResult;
}

const masked = (plan: string) => `…${plan.slice(-4)}`;

async function syncPlan(session: Rl360Session, login: Rl360Login, plan: string) {
  const today = dubaiDate();
  const now = parseValuation(await session.get(valuationUrl(plan)));
  await pause();
  const historyHtml = await session.get(premiumsUrl(plan, now.started_on, today));
  const premiums = parsePremiums(historyHtml);
  const withdrawn = parseWithdrawalTotal(historyHtml);
  const first = await importData(
    login,
    plan,
    now.currency,
    now.started_on,
    [{ as_of: today, value: now.value }],
    premiums,
  );
  if (!first.holding_code) return { plan: masked(plan), skipped: first.reason };

  const backfill: { as_of: string; value: string }[] = [];
  for (const day of (first.missing_month_ends ?? []).slice(0, BACKFILL_PER_RUN)) {
    await pause();
    const past = parseValuation(await session.get(valuationUrl(plan, day)));
    if (past.plan !== plan || past.as_of !== day) {
      throw new Error(`RL360 ${masked(plan)}: asked for ${day}, got ${past.as_of}`);
    }
    backfill.push({ as_of: day, value: past.value });
  }
  const filled = backfill.length > 0
    ? await importData(login, plan, now.currency, now.started_on, backfill, null)
    : first;
  return {
    plan: masked(plan),
    holding_code: first.holding_code,
    claimed: first.claimed,
    value: now.value,
    currency: now.currency,
    values_added: (first.values_added ?? 0) + (backfill.length > 0 ? filled.values_added ?? 0 : 0),
    premiums: first.premiums,
    backfill_left: filled.missing_month_ends?.length ?? 0,
    withdrawals: withdrawn && Number(withdrawn) > 0 ? `${withdrawn} not imported (record them by hand)` : undefined,
  };
}

async function syncLogin(login: Rl360Login) {
  const session = new Rl360Session();
  await session.login(login.username, login.password);
  try {
    await pause();
    const plans = parsePlans(await session.get(`${RL360_BASE}/SC/`));
    const out = [];
    for (const plan of plans) out.push(await syncPlan(session, login, plan));
    return out;
  } finally {
    await session.logout();
  }
}

async function syncAll() {
  const logins = parseLogins(Deno.env.get("RL360_LOGINS"));
  if (logins.length === 0) return { skipped: "RL360_LOGINS is not set" };
  const results: Record<string, unknown> = {};
  const errors: string[] = [];
  for (const login of logins) {
    try {
      results[login.profile_code] = await syncLogin(login);
    } catch (e) {
      errors.push(`${login.profile_code}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  if (errors.length > 0) throw new Error(`rl360-sync: ${errors.join(" | ")} (done: ${JSON.stringify(results)})`);
  return results;
}

Deno.serve(withSentry("rl360-sync", handler));

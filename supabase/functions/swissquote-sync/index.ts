// swissquote-sync: a Swissquote portfolio → its cash account, positions, values and notes
// (tasks/todo.md §11). pg_cron calls it nightly with x-cron-secret (job `ledger-swissquote-sync`,
// 30 21 * * * UTC, 01:30 Dubai, after the US close).
//
// For each login in SWISSQUOTE_LOGINS ([{profile_code, username, password, card, currency?}], an
// Edge secret): sign in (password + the Level-3 matrix card, never the phone push), read the
// account, cash, positions, every transaction since the account opened and the daily performance
// index, and send them to import_broker_data, which keeps the ledger's account, holdings, marks
// and daily values (idempotent). Then, for positions still without terms (up to TERMS_PER_RUN,
// or {"terms": n} in a manual call), read the term sheet attached to the trade ticket into a
// structured note. Sign out. Any failure is recorded on the connection and thrown after the other
// logins ran, so Sentry captures it; messages never carry logins, codes or response bodies.

import { withSentry } from "../_shared/sentry.ts";
import { requireCron } from "../_shared/auth.ts";
import { pgErrorToHttp, readJson, requireMethod } from "../_shared/http.ts";
import { runCronJob } from "../_shared/cron.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { llmConfigured } from "../_shared/llm.ts";
import { dubaiDate } from "../metal-prices/quotes.ts";
import { readTermSheet } from "../termsheet-extract/read.ts";
import {
  cashIn,
  depositsByDay,
  normalizePositions,
  normalizeTransactions,
  parseLogins,
  rebuildValues,
  type SqMessage,
  type SqTransaction,
  type SwissquoteLogin,
  SwissquoteSession,
  termSheetFor,
} from "./swissquote.ts";

const TERMS_PER_RUN = 1;
const PAUSE_MS = 400;
const pause = () => new Promise((r) => setTimeout(r, PAUSE_MS));

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  await requireCron(req);
  const body = (await readJson(req.clone()).catch(() => ({}))) as { terms?: unknown } | null;
  const terms = typeof body?.terms === "number" && body.terms >= 0 && body.terms <= 20 ? body.terms : TERMS_PER_RUN;
  return await runCronJob(req, "swissquote-sync", () => syncAll(terms));
}

const dubaiDay = (iso: string) => dubaiDate(new Date(iso));

interface ImportResult {
  account_code: string;
  transactions_added: number;
  positions_marked: number;
  isins_without_terms: string[];
}

async function readPortfolio(s: SwissquoteSession, login: SwissquoteLogin) {
  const ccy = login.currency;
  const overview = await s.getJson<{ portfolioId?: string; iban?: string }>(
    "/eding_securities-retail-portfoliooverview-plugin/api/portfolio-overview/?SQApplicationId=WLS",
  );
  if (!overview.portfolioId) throw new Error("Swissquote: no portfolio");
  await pause();
  const config = await s.getJson<{ portfolioCreationDate?: string; portfolioPerformanceReferenceDate?: string }>(
    "/sq-passive-income-plugin/api/config",
  );
  const opened = /^\d{4}-\d{2}-\d{2}$/.test(config.portfolioCreationDate ?? "")
    ? config.portfolioCreationDate!
    : "2000-01-01";
  await pause();
  // The cash accounts, one per currency: "259744601 (USD)".
  const accounts = await s.getJson<{ name?: string; value?: string }[]>(
    "/eding_fox-transactions-plugin/rest-api/accounts?lang=en",
  );
  const accountNumber = accounts.find((a) => a.value === ccy)?.name?.match(/^(\d{6,34})/)?.[1] ?? null;
  await pause();
  const assets = await s.getJson<{ assets?: { currency?: string; cashBalance?: number }[] }>(
    `/eding_securities-retail-assets-plugin/api/assets/CHF/${ccy}?SQApplicationId=WLS`,
  );
  await pause();
  const positions = normalizePositions(
    await s.getJson(
      `/eding_securities-retail-positions-plugin/api/positions/CHF/${ccy}?groupingType=PRODUCT_TYPE&SQApplicationId=WLS`,
    ),
  );
  await pause();
  const fetchedAt = new Date();
  const tx = await s.postJson<
    { transactions?: SqTransaction[]; startDateCashBalance?: { currency?: string; value?: number }[] }
  >("/eding_fox-transactions-plugin/rest-api/transactions?lang=en", {
    fromDate: `${opened}T00:00:00.000Z`,
    toDate: fetchedAt.toISOString(),
    account: "ALL",
    specificSecurity: "ALL",
    showReversals: true,
    isOpen: true,
    categories: [],
  });
  const transactions = normalizeTransactions(tx.transactions ?? []).filter((t) => t.currency === ccy);
  const openingBalance = tx.startDateCashBalance?.find((x) => x.currency === ccy)?.value ?? 0;

  // A product's type for ISINs no longer held (a share bought and sold, a redeemed note).
  const held = new Set(positions.map((p) => p.isin));
  const securities = [];
  const exchanges = new Map<string, number>();
  for (const t of tx.transactions ?? []) {
    if (t.isin && typeof t.exchangeId === "number") exchanges.set(t.isin, t.exchangeId);
  }
  for (const [isin, exchange] of exchanges) {
    if (held.has(isin)) continue;
    await pause();
    const q = await s.getJson<{ fullQuoteData?: { productType?: string; productName?: string; symbol?: string } }>(
      `/eding_securities-retail-fullquote-plugin/api/fullQuote/${isin}/${exchange}_${ccy}?serviceName=QUOTE&SQApplicationId=WLS`,
    ).catch(() => ({ fullQuoteData: undefined }));
    securities.push({
      isin,
      name: q.fullQuoteData?.productName ?? null,
      symbol: q.fullQuoteData?.symbol ?? null,
      product_type: q.fullQuoteData?.productType ?? null,
      currency: ccy,
    });
  }

  // The value per day before the sync's own marks (the performance index walked back from today).
  await pause();
  const perf = await s.getJson<{ performanceEntries?: { date: string; twrPerf: number }[] }>(
    `/eding_securities-retail-accountsummary-plugin/api/performance/portfolio/${
      config.portfolioPerformanceReferenceDate ?? opened
    }/${ccy}?requestFromCache=true&SQApplicationId=WLS`,
  ).catch(() => ({ performanceEntries: [] }));
  const cash = cashIn(assets, ccy);
  const positionsValue = positions.reduce((sum, p) => sum + (p.value ? Number(p.value) : 0), 0);
  const today = dubaiDate(fetchedAt);
  const snapshots = cash === null ? [] : rebuildValues(
    perf.performanceEntries ?? [],
    depositsByDay(transactions, dubaiDay),
    today,
    Number(cash) + positionsValue,
  );

  return {
    portfolio_ref: overview.portfolioId,
    currency: ccy,
    iban: overview.iban ?? null,
    account_number: accountNumber,
    fetched_at: fetchedAt.toISOString(),
    cash,
    // The cash before the first movement (a minute before it; the account's creation date is
    // not always given).
    opening: transactions.length === 0 ? null : {
      as_of: new Date(Math.min(...transactions.map((t) => Date.parse(t.booked_at))) - 60_000).toISOString(),
      balance: String(openingBalance),
    },
    securities,
    transactions,
    positions,
    snapshots,
  };
}

async function importTerms(
  s: SwissquoteSession,
  login: SwissquoteLogin,
  accountCode: string,
  isins: string[],
  limit: number,
): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  if (isins.length === 0 || limit === 0) return out;
  if (!llmConfigured()) return { skipped: "reading term sheets is not configured" };
  const db = serviceClient();
  const tried = await db.from("broker_connections").select("terms_tried").eq("account_code", accountCode).single();
  const skip = new Set<string>((tried.data?.terms_tried as string[] | null) ?? []);
  const todo = isins.filter((i) => !skip.has(i)).slice(0, limit);
  if (todo.length === 0) return out;
  const found = await s.postJson<{ messages?: SqMessage[] }>("/sqc-messages-plugin/webapi/messages/findMessages", {
    unseenOnly: false,
    batchSize: 200,
    fromIndex: 0,
    portfolioId: null,
  });
  for (const isin of todo) {
    const ts = termSheetFor(found.messages ?? [], isin);
    try {
      if (!ts) {
        out[isin] = "no term sheet in Messages";
        continue;
      }
      const bytes = await s.getBytes(
        `/sqc-messages-plugin/webapi/issues/attachment/${ts.messageId}/${ts.attachmentId}`,
      );
      const { draft } = await readTermSheet(login.profile_code, bytes, ts.name);
      const { error } = await db.rpc("create_structured_note", {
        p_profile_code: login.profile_code,
        p_draft: {
          ...draft,
          institution: "Swissquote",
          notes: "Terms read from the Swissquote trade ticket: check them against the term sheet.",
          terms: { ...(draft.terms as Record<string, unknown>), isin },
          investment: { funding_account_code: accountCode },
        },
      });
      if (error) throw pgErrorToHttp(error, "create_structured_note failed");
      out[isin] = "note created";
    } catch (e) {
      out[isin] = e instanceof Error ? e.message.slice(0, 200) : "failed";
    } finally {
      // Tried once: a term sheet that cannot be read is not sent to the model again every night.
      await db.rpc("record_broker_terms_tried", { p_account_code: accountCode, p_isin: isin });
    }
  }
  return out;
}

async function syncLogin(login: SwissquoteLogin, terms: number) {
  const session = new SwissquoteSession();
  await session.login(login);
  try {
    const data = await readPortfolio(session, login);
    const { data: result, error } = await serviceClient().rpc("import_broker_data", {
      p_profile_code: login.profile_code,
      p_provider: "swissquote",
      p_data: data,
    });
    if (error) throw pgErrorToHttp(error, "import_broker_data failed");
    const r = result as ImportResult;
    const notes = await importTerms(session, login, r.account_code, r.isins_without_terms ?? [], terms);
    return {
      account_code: r.account_code,
      transactions_added: r.transactions_added,
      positions_marked: r.positions_marked,
      terms: notes,
    };
  } finally {
    await session.logout();
  }
}

async function syncAll(terms: number) {
  const logins = parseLogins(Deno.env.get("SWISSQUOTE_LOGINS"));
  if (logins.length === 0) return { skipped: "SWISSQUOTE_LOGINS is not set" };
  const results: Record<string, unknown> = {};
  const errors: string[] = [];
  for (const login of logins) {
    try {
      results[login.profile_code] = await syncLogin(login, terms);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      errors.push(`${login.profile_code}: ${msg}`);
      await serviceClient().rpc("record_broker_sync_error", {
        p_profile_code: login.profile_code,
        p_provider: "swissquote",
        p_error: msg,
      });
    }
  }
  if (errors.length > 0) throw new Error(`swissquote-sync: ${errors.join(" | ")} (done: ${JSON.stringify(results)})`);
  return results;
}

Deno.serve(withSentry("swissquote-sync", handler));

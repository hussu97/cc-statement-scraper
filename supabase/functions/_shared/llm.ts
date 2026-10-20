// Claude calls used by the worker: merchant categorisation and the SMS-template
// fallback. Only merchant names / example descriptions, the category list, and the
// text of an unparsed SMS are ever sent — never PDFs, amounts from statements, or
// account data. Responses are constrained with structured outputs and then
// re-validated here before they reach the database.

import { Anthropic } from "./deps.ts";

export const DEFAULT_LLM_MODEL = "claude-haiku-5-5";

export function llmModel(): string {
  return Deno.env.get("LLM_MODEL") || DEFAULT_LLM_MODEL;
}

export function llmConfigured(): boolean {
  return Boolean(Deno.env.get("ANTHROPIC_API_KEY"));
}

/** Per-request timeout. No SDK retries: the queue retries, and the worker budgets one call per round. */
export const LLM_TIMEOUT_MS = 60_000;

let _client: InstanceType<typeof Anthropic> | null = null;
function client(): InstanceType<typeof Anthropic> {
  if (!_client) {
    _client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY"), maxRetries: 0, timeout: LLM_TIMEOUT_MS });
  }
  return _client;
}

export class LlmOutputError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LlmOutputError";
  }
}

/** The model says the SMS is not a card transaction (OTP, promotion, ...): nothing to template. */
export class LlmNotApplicable extends Error {
  constructor(message = "not a card transaction") {
    super(message);
    this.name = "LlmNotApplicable";
  }
}

/**
 * A short, safe reason for Sentry/DLQ: our own validation text (never SMS content), with
 * anything but letters, digits, spaces and `._-` stripped.
 */
export function llmErrorReason(e: unknown): string {
  if (e instanceof LlmOutputError || e instanceof LlmNotApplicable) {
    return e.message.replace(/[^A-Za-z0-9 ._-]/g, "").slice(0, 80);
  }
  // deno-lint-ignore no-explicit-any
  const status = (e as any)?.status;
  if (typeof status === "number") return `http ${status}`;
  return String((e as Error)?.name ?? "error").replace(/[^A-Za-z0-9 ._-]/g, "").slice(0, 40);
}

/** Retry (leave the queue message) vs give up (DLQ). Auth/config errors are retried: they need a fix, not a DLQ. */
export function isTransientLlmError(e: unknown): boolean {
  if (e instanceof LlmOutputError || e instanceof LlmNotApplicable) return false;
  if (e instanceof Anthropic.APIConnectionError) return true;
  if (e instanceof Anthropic.APIError) {
    const s = e.status ?? 0;
    return s === 401 || s === 403 || s === 408 || s === 409 || s === 429 || s >= 500 || s === 0;
  }
  return true;
}

/** One structured-output request; returns the parsed JSON object. */
export async function structuredCall(opts: {
  system: string;
  user: string;
  schema: Record<string, unknown>;
  maxTokens?: number;
}): Promise<unknown> {
  // deno-lint-ignore no-explicit-any
  const params: any = {
    model: llmModel(),
    max_tokens: opts.maxTokens ?? 8000,
    system: opts.system,
    messages: [{ role: "user", content: opts.user }],
    output_config: { effort: "low", format: { type: "json_schema", schema: opts.schema } },
  };
  const res = await client().messages.create(params);
  if (res.stop_reason === "refusal") throw new LlmOutputError("model refused");
  if (res.stop_reason === "max_tokens") throw new LlmOutputError("output truncated (max_tokens)");
  const text = res.content
    // deno-lint-ignore no-explicit-any
    .filter((b: any) => b.type === "text")
    // deno-lint-ignore no-explicit-any
    .map((b: any) => b.text)
    .join("");
  try {
    return JSON.parse(text);
  } catch {
    throw new LlmOutputError("output is not JSON");
  }
}

// ── merchant categorisation ─────────────────────────────────────────────────

export interface LlmCategory {
  category_code: string;
  name: string;
  kind: string;
}
export interface LlmMerchant {
  merchant_code: string;
  name: string;
  examples: string[] | null;
}
export interface Suggestion {
  merchant_code: string;
  category_code: string;
  confidence: number;
}

/** Merchants per llm_categorize call; private.enqueue_llm_categorize batches the same way. */
export const LLM_BATCH_MAX = 100;

export const CATEGORIZE_SYSTEM = "You categorise credit-card merchants for a personal finance ledger in the UAE. " +
  "For each merchant, pick the single best category from the provided list, using the merchant name " +
  "and example statement descriptions. Answer with the merchant's ref and the category's ref. Give a " +
  "confidence between 0 and 1. If no category fits or you cannot tell what the merchant is, leave that " +
  "merchant out instead of guessing.";

// Prompt and output use short refs (m1…, c1…) instead of the 30-character codes: the model echoes
// two of them per merchant, so codes were most of the output tokens. Ref i+1 is index i.
const mRef = (i: number) => `m${i + 1}`;
const cRef = (i: number) => `c${i + 1}`;

export function categorizeSchema(merchantCount: number, categoryCount: number): Record<string, unknown> {
  return {
    type: "object",
    properties: {
      suggestions: {
        type: "array",
        items: {
          type: "object",
          properties: {
            merchant: { type: "string", enum: Array.from({ length: merchantCount }, (_, i) => mRef(i)) },
            category: { type: "string", enum: Array.from({ length: categoryCount }, (_, i) => cRef(i)) },
            confidence: { type: "number" },
          },
          required: ["merchant", "category", "confidence"],
          additionalProperties: false,
        },
      },
    },
    required: ["suggestions"],
    additionalProperties: false,
  };
}

export function categorizeUserPrompt(categories: LlmCategory[], merchants: LlmMerchant[]): string {
  return JSON.stringify({
    categories: categories.map((c, i) => ({ ref: cRef(i), name: c.name, kind: c.kind })),
    merchants: merchants.map((m, i) => ({ ref: mRef(i), name: m.name, examples: (m.examples ?? []).slice(0, 3) })),
  });
}

/**
 * Map the model's refs back to codes and keep only well-formed suggestions for known
 * merchants/categories; one per merchant (highest confidence). `merchantCodes` and
 * `categoryCodes` are in the order the prompt listed them.
 */
export function validateSuggestions(raw: unknown, merchantCodes: string[], categoryCodes: string[]): Suggestion[] {
  if (!raw || typeof raw !== "object") throw new LlmOutputError("output is not an object");
  const list = (raw as { suggestions?: unknown }).suggestions;
  if (!Array.isArray(list)) throw new LlmOutputError("suggestions is not an array");
  const merchants = new Map(merchantCodes.map((code, i) => [mRef(i), code]));
  const categories = new Map(categoryCodes.map((code, i) => [cRef(i), code]));
  const best = new Map<string, Suggestion>();
  for (const s of list) {
    if (!s || typeof s !== "object") continue;
    const { merchant, category, confidence } = s as Record<string, unknown>;
    const merchant_code = typeof merchant === "string" ? merchants.get(merchant) : undefined;
    const category_code = typeof category === "string" ? categories.get(category) : undefined;
    if (!merchant_code || !category_code) continue;
    const c = typeof confidence === "number" ? confidence : Number(confidence);
    if (!Number.isFinite(c)) continue;
    const conf = Math.round(Math.min(1, Math.max(0, c)) * 1000) / 1000;
    const prev = best.get(merchant_code);
    if (!prev || prev.confidence < conf) best.set(merchant_code, { merchant_code, category_code, confidence: conf });
  }
  return [...best.values()];
}

// ── SMS template fallback ───────────────────────────────────────────────────

export const MSG_KINDS = [
  "purchase",
  "preauth",
  "refund",
  "reversal",
  "payment",
  "declined",
  "debit_purchase",
  "account_credit",
  "account_debit",
  "debit_card",
  "other",
];
export const FIELD_NAMES = [
  "amount",
  "currency",
  "merchant",
  "last4",
  "date",
  "time",
  "available",
  "account_ref",
] as const;

export const SMS_SYSTEM = [
  "You write parsing templates for bank card SMS alerts. Given one SMS that no existing template matched,",
  "propose a template that matches this message and future messages of the same format.",
  "Rules for body_pattern and sender_pattern:",
  "- PostgreSQL POSIX ARE syntax, applied case-insensitively. Use \\s, \\d, [0-9], [A-Z], .*? as needed.",
  "- NO named groups, NO lookahead/lookbehind, NO backreferences. Use (?:...) for groups you do not capture.",
  "- Capture groups are numbered left to right; field_groups maps each field to its group number (null if absent).",
  "- Replace variable parts (amounts, merchant, card digits, dates, balances) with captures; keep fixed wording literal.",
  "- amount: digits with optional thousands separators and decimals, e.g. ([0-9,]+(?:\\.[0-9]+)?).",
  "- last4: the card digits shown; date_format is a PostgreSQL to_date format for the date group (e.g. DD/MM/YYYY, DD-MON-YY).",
  "- account_ref: the bank-account digits shown after the mask (XXX310001 -> 310001); available: the balance or available limit shown.",
  "msg_kind: purchase (completed card spend), preauth (authorisation/hold), refund, reversal, payment (card bill payment),",
  "declined, debit_purchase (a debit-card purchase from a bank account), account_credit (money into a bank account:",
  "salary, transfer in, remittance), account_debit (money out of a bank account: transfer, remittance, standing order),",
  "debit_card (any other debit-card or account notice), other (not a transaction).",
  "If the SMS is not a card transaction at all (OTP, promotion, balance or service notice), set msg_kind to other",
  "and field_groups.amount and expect.amount to null; the other fields can then be null or a best effort.",
  "expect: the values your template extracts from THIS message (amount as written without separators, currency code,",
  "last4, merchant as written).",
].join("\n");

export function smsTemplateSchema(bankCodes: string[]): Record<string, unknown> {
  const nullableInt = { type: ["integer", "null"] };
  const nullableStr = { type: ["string", "null"] };
  return {
    type: "object",
    properties: {
      bank_code: { type: "string", enum: bankCodes },
      name: { type: "string" },
      sender_pattern: { type: "string" },
      body_pattern: { type: "string" },
      field_groups: {
        type: "object",
        properties: Object.fromEntries(FIELD_NAMES.map((f) => [f, nullableInt])),
        required: [...FIELD_NAMES],
        additionalProperties: false,
      },
      date_format: nullableStr,
      msg_kind: { type: "string", enum: MSG_KINDS },
      expect: {
        type: "object",
        properties: { amount: nullableStr, currency: nullableStr, last4: nullableStr, merchant: nullableStr },
        required: ["amount", "currency", "last4", "merchant"],
        additionalProperties: false,
      },
    },
    required: [
      "bank_code",
      "name",
      "sender_pattern",
      "body_pattern",
      "field_groups",
      "date_format",
      "msg_kind",
      "expect",
    ],
    additionalProperties: false,
  };
}

export function smsUserPrompt(sender: string, body: string, banks: { bank_code: string; senders: string[] }[]): string {
  return JSON.stringify({ sender, body, banks });
}

/** Count capturing groups: "(" not escaped, not inside [...], not followed by "?". */
export function countCaptureGroups(pattern: string): number {
  let n = 0;
  let inClass = false;
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i];
    if (ch === "\\") {
      i++;
      continue;
    }
    if (inClass) {
      if (ch === "]") inClass = false;
      continue;
    }
    if (ch === "[") {
      inClass = true;
      if (pattern[i + 1] === "^") i++;
      if (pattern[i + 1] === "]") i++;
      continue;
    }
    if (ch === "(" && pattern[i + 1] !== "?") n++;
  }
  return n;
}

const FORBIDDEN_CONSTRUCTS = /\(\?P?<|\(\?=|\(\?!|\(\?<=|\(\?<!|\\[1-9]/;

function checkPattern(p: unknown, what: string, max: number): string {
  if (typeof p !== "string" || !p.trim()) throw new LlmOutputError(`${what} missing`);
  if (p.length > max) throw new LlmOutputError(`${what} too long`);
  if (FORBIDDEN_CONSTRUCTS.test(p)) throw new LlmOutputError(`${what} uses named groups, lookaround or backrefs`);
  try {
    new RegExp(p, "i");
  } catch {
    throw new LlmOutputError(`${what} does not compile`);
  }
  return p;
}

/** "1,234.5" → "1234.50" without floats; null when not a number. Mirrors private.parse_amount. */
export function normalizeAmount(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim().replace(/,/g, "");
  const m = /^([0-9]+)(?:\.([0-9]+))?$/.exec(s);
  if (!m) return null;
  const intPart = m[1].replace(/^0+(?=\d)/, "");
  const frac = m[2] ?? "";
  if (frac.length <= 2) return `${intPart}.${frac.padEnd(2, "0")}`;
  // Round half-up at 2 dp using integer arithmetic on the digit string.
  const cents = BigInt(intPart + frac.slice(0, 2)) + (Number(frac[2]) >= 5 ? 1n : 0n);
  const str = cents.toString().padStart(3, "0");
  return `${str.slice(0, -2)}.${str.slice(-2)}`;
}

/** Mirrors private.normalize_text: upper-case, collapse whitespace, trim " .,-". */
export function normalizeText(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.toUpperCase().replace(/\s+/g, " ").replace(/^[ .,-]+|[ .,-]+$/g, "");
  return s || null;
}

export interface TemplateProposal {
  bank_code: string;
  name: string;
  sender_pattern: string;
  body_pattern: string;
  field_groups: Record<string, number>;
  date_format: string | null;
  msg_kind: string;
  expect: Record<string, string>;
}

/** Validate the LLM's proposal and normalise it into propose_sms_template's shape. */
export function validateTemplateProposal(raw: unknown, bankCodes: string[]): TemplateProposal {
  if (!raw || typeof raw !== "object") throw new LlmOutputError("proposal is not an object");
  const r = raw as Record<string, unknown>;
  if (r.msg_kind === "other") {
    const fg = (r.field_groups && typeof r.field_groups === "object" ? r.field_groups : {}) as Record<string, unknown>;
    const ex = (r.expect && typeof r.expect === "object" ? r.expect : {}) as Record<string, unknown>;
    if (fg.amount === null || fg.amount === undefined || ex.amount === null || ex.amount === undefined) {
      throw new LlmNotApplicable();
    }
  }
  if (typeof r.bank_code !== "string" || !bankCodes.includes(r.bank_code)) {
    throw new LlmOutputError("unknown bank_code");
  }
  if (typeof r.msg_kind !== "string" || !MSG_KINDS.includes(r.msg_kind)) throw new LlmOutputError("invalid msg_kind");
  const body = checkPattern(r.body_pattern, "body_pattern", 1000);
  const sender = r.sender_pattern === undefined || r.sender_pattern === null || r.sender_pattern === ""
    ? ".*"
    : checkPattern(r.sender_pattern, "sender_pattern", 200);

  const groups = countCaptureGroups(body);
  const fg = r.field_groups;
  if (!fg || typeof fg !== "object") throw new LlmOutputError("field_groups missing");
  const fieldGroups: Record<string, number> = {};
  const used = new Set<number>();
  for (const [k, v] of Object.entries(fg as Record<string, unknown>)) {
    if (v === null || v === undefined) continue;
    if (!(FIELD_NAMES as readonly string[]).includes(k)) throw new LlmOutputError(`unknown field ${k}`);
    if (typeof v !== "number" || !Number.isInteger(v) || v < 1 || v > groups) {
      throw new LlmOutputError(`field ${k} points at a missing capture group`);
    }
    if (used.has(v)) throw new LlmOutputError(`capture group ${v} used twice`);
    used.add(v);
    fieldGroups[k] = v;
  }
  if (!fieldGroups.amount) throw new LlmOutputError("field_groups.amount is required");

  let dateFormat: string | null = null;
  if (typeof r.date_format === "string" && r.date_format.trim()) {
    dateFormat = r.date_format.trim();
    if (dateFormat.length > 40 || !/^[A-Za-z0-9 /\-.:,]+$/.test(dateFormat)) {
      throw new LlmOutputError("bad date_format");
    }
  }

  const ex = (r.expect && typeof r.expect === "object" ? r.expect : {}) as Record<string, unknown>;
  const expect: Record<string, string> = {};
  const amount = normalizeAmount(ex.amount);
  if (!amount) throw new LlmOutputError("expect.amount missing");
  expect.amount = amount;
  if (fieldGroups.currency && typeof ex.currency === "string" && /^[A-Za-z]{3}$/.test(ex.currency.trim())) {
    expect.currency = ex.currency.trim().toUpperCase();
  }
  if (fieldGroups.last4 && typeof ex.last4 === "string") {
    const d = ex.last4.replace(/[^0-9]/g, "").slice(-4);
    if (d.length === 4) expect.last4 = d;
  }
  if (fieldGroups.merchant) {
    const m = normalizeText(ex.merchant);
    if (m) expect.merchant = m;
  }

  const name = typeof r.name === "string" && r.name.trim() ? r.name.trim().slice(0, 80) : "LLM proposal";
  return {
    bank_code: r.bank_code,
    name: `LLM: ${name}`.slice(0, 90),
    sender_pattern: sender,
    body_pattern: body,
    field_groups: fieldGroups,
    date_format: dateFormat,
    msg_kind: r.msg_kind,
    expect,
  };
}

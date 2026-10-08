// Supabase client factories. The service client bypasses RLS: use it only
// after the caller has been authenticated (CLAUDE.md §3.3).
//
// API keys (PRODUCTION.md §2, "Supabase API keys"): the new `sb_secret_…` /
// `sb_publishable_…` keys are preferred over the legacy service_role / anon JWTs.
// Resolution order, first non-empty wins:
//   secret:      SUPABASE_SECRET_KEYS (runtime JSON {name: key}) → SB_SECRET_KEY (custom secret)
//                → SUPABASE_SERVICE_ROLE_KEY (legacy JWT)
//   publishable: SUPABASE_PUBLISHABLE_KEYS → SB_PUBLISHABLE_KEY → SUPABASE_ANON_KEY (legacy JWT)
// The hosted runtime injects the *_KEYS dictionaries; custom secrets cannot start with
// SUPABASE_, hence the SB_ names for the manual fallback.

import { createClient, type SupabaseClient } from "./deps.ts";

// deno-lint-ignore no-explicit-any
export type Db = SupabaseClient<any, "public", any>;

type Env = (name: string) => string | undefined;
const denoEnv: Env = (name) => Deno.env.get(name);

function env(name: string, ...fallbacks: string[]): string {
  for (const n of [name, ...fallbacks]) {
    const v = Deno.env.get(n);
    if (v) return v;
  }
  throw new Error(`missing env ${name}`);
}

export function supabaseUrl(): string {
  return env("SUPABASE_URL");
}

/**
 * Pick a key from a runtime-injected JSON dictionary (`{"default": "sb_secret_…"}`).
 * Prefers the key named `default`, else the first non-empty string. Malformed JSON → null.
 */
export function keyFromDictionary(raw: string | undefined, name = "default"): string | null {
  if (!raw) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const dict = parsed as Record<string, unknown>;
  const preferred = dict[name];
  if (typeof preferred === "string" && preferred) return preferred;
  for (const v of Object.values(dict)) if (typeof v === "string" && v) return v;
  return null;
}

export type KeyKind = "secret" | "publishable";

const SOURCES: Record<KeyKind, { dict: string; custom: string; legacy: string }> = {
  secret: { dict: "SUPABASE_SECRET_KEYS", custom: "SB_SECRET_KEY", legacy: "SUPABASE_SERVICE_ROLE_KEY" },
  publishable: { dict: "SUPABASE_PUBLISHABLE_KEYS", custom: "SB_PUBLISHABLE_KEY", legacy: "SUPABASE_ANON_KEY" },
};

/** Resolve an API key and the env var it came from (never the value in logs). */
export function resolveApiKey(kind: KeyKind, get: Env = denoEnv): { key: string; source: string } {
  const s = SOURCES[kind];
  const fromDict = keyFromDictionary(get(s.dict));
  if (fromDict) return { key: fromDict, source: s.dict };
  for (const n of [s.custom, s.legacy]) {
    const v = get(n)?.trim();
    if (v) return { key: v, source: n };
  }
  throw new Error(`missing env ${s.dict} / ${s.custom} / ${s.legacy}`);
}

const opts = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };

let _service: Db | null = null;
let _publishable: string | null = null;

/** Service client (secret key, cached per isolate). */
export function serviceClient(): Db {
  if (!_service) {
    const { key, source } = resolveApiKey("secret");
    console.info(`supabase: service client using ${source}`);
    _service = createClient(supabaseUrl(), key, opts) as Db;
  }
  return _service;
}

/**
 * Client acting as the end user: the publishable key goes in `apikey`, the user's own
 * JWT in `Authorization`, so RLS and `assert_member` apply as that user.
 */
export function userClient(jwt: string): Db {
  if (!_publishable) _publishable = resolveApiKey("publishable").key;
  return createClient(supabaseUrl(), _publishable, {
    ...opts,
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  }) as Db;
}

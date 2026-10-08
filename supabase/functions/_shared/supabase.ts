// Supabase client factories. The service-role client bypasses RLS: use it only
// after the caller has been authenticated (CLAUDE.md §3.3).

import { createClient, type SupabaseClient } from "./deps.ts";

// deno-lint-ignore no-explicit-any
export type Db = SupabaseClient<any, "public", any>;

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

const opts = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };

let _service: Db | null = null;

/** Service-role client (cached per isolate). */
export function serviceClient(): Db {
  if (!_service) {
    _service = createClient(supabaseUrl(), env("SUPABASE_SERVICE_ROLE_KEY"), opts) as Db;
  }
  return _service;
}

/** Client acting as the end user: RLS and `assert_member` apply. */
export function userClient(jwt: string): Db {
  return createClient(supabaseUrl(), env("SUPABASE_ANON_KEY"), {
    ...opts,
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  }) as Db;
}

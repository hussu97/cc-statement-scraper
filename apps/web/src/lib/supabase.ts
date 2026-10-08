import { createClient } from "@supabase/supabase-js";
import type { Database } from "@ledger/db-types";

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const supabaseConfigured = Boolean(url && anonKey);

export const supabase = createClient<Database>(url ?? "http://127.0.0.1:54321", anonKey ?? "missing-anon-key", {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: "ledger.auth",
  },
});

export type DB = Database["public"];
export type Tables<T extends keyof DB["Tables"]> = DB["Tables"][T]["Row"];
export type Views<T extends keyof DB["Views"]> = DB["Views"][T]["Row"];
export type RpcReturn<T extends keyof DB["Functions"]> = DB["Functions"][T]["Returns"];

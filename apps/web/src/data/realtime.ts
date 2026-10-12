import { useEffect, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { LEDGER_DOMAINS, type Domain } from "./keys";

/** Which cached domains a change on each realtime table makes stale. */
export const REALTIME_TABLES: Record<string, Domain[]> = {
  transactions: LEDGER_DOMAINS,
  sms_messages: ["overview", "health", "reviews", "sms"],
  documents: ["documents", "health", "statements", "accounts"],
  match_reviews: ["reviews", "overview"],
  insights: ["insights"],
};

/** Domains to invalidate for a batch of changed tables (deduplicated). */
export function domainsFor(tables: Iterable<string>): Domain[] {
  const out = new Set<Domain>();
  for (const t of tables) for (const d of REALTIME_TABLES[t] ?? []) out.add(d);
  return [...out];
}

/**
 * A fresh channel topic for each subscription. `supabase.channel(topic)`
 * returns the existing channel while a previous `removeChannel` is still
 * leaving, so a reused topic makes `subscribe()` a no-op and the pending leave
 * then tears it down (StrictMode, or an A→B→A profile switch). A unique suffix
 * per effect run keeps every subscription on its own channel.
 */
export function channelTopic(profileCode: string, nonce: string = crypto.randomUUID()): string {
  return `ledger:${profileCode}:${nonce}`;
}

/**
 * Subscribe to Postgres changes for the active profile and invalidate the
 * affected queries (debounced). Returns the last transaction insert time so
 * the UI can highlight live arrivals.
 */
export function useRealtimeInvalidation(profileCode: string | null): { lastInsertAt: number | null; connected: boolean } {
  const qc = useQueryClient();
  const pending = useRef(new Set<string>());
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [lastInsertAt, setLastInsertAt] = useState<number | null>(null);
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    if (!profileCode) return;
    const flush = () => {
      const tables = [...pending.current];
      pending.current.clear();
      for (const d of domainsFor(tables)) void qc.invalidateQueries({ queryKey: ["p", profileCode, d] });
    };
    const channel = supabase.channel(channelTopic(profileCode));
    for (const table of Object.keys(REALTIME_TABLES)) {
      channel.on(
        "postgres_changes",
        { event: "*", schema: "public", table, filter: `profile_code=eq.${profileCode}` },
        (payload) => {
          pending.current.add(table);
          if (table === "transactions" && payload.eventType === "INSERT") setLastInsertAt(Date.now());
          if (timer.current) clearTimeout(timer.current);
          timer.current = setTimeout(flush, 400);
        },
      );
    }
    channel.subscribe((status) => setConnected(status === "SUBSCRIBED"));
    return () => {
      if (timer.current) clearTimeout(timer.current);
      setConnected(false);
      void supabase.removeChannel(channel);
    };
  }, [profileCode, qc]);

  return { lastInsertAt, connected };
}

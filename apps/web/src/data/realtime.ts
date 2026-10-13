import { useEffect, useRef, useState } from "react";
import { useQueryClient, type QueryKey } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { LEDGER_DOMAINS, type Domain } from "./keys";

/** A cached key below ["p", profileCode]: a whole domain (["overview"]) or part of one (["reviews", "open"]). */
export type KeySuffix = readonly [Domain, ...string[]];

/**
 * Which cached keys a change on each realtime table makes stale. A transaction change touches
 * only the open-review list (its rows carry their contexts, WEB-10r), not the badge count:
 * the count moves with match_reviews events.
 */
export const REALTIME_TABLES: Record<string, KeySuffix[]> = {
  transactions: [...LEDGER_DOMAINS.filter((d) => d !== "reviews").map((d): KeySuffix => [d]), ["reviews", "open"]],
  sms_messages: [["overview"], ["health"], ["reviews"], ["sms"]],
  documents: [["documents"], ["health"], ["statements"], ["accounts"]],
  match_reviews: [["reviews"], ["overview"]],
  insights: [["insights"]],
};

const isPrefix = (a: readonly string[], b: readonly string[]) => a.length < b.length && a.every((x, i) => b[i] === x);

/**
 * Query keys to invalidate for a batch of changed tables: deduplicated, and a key already
 * covered by a shorter one (["reviews"] covers ["reviews", "open"]) is dropped. Pure, unit-tested.
 */
export function invalidationKeys(profileCode: string, tables: Iterable<string>): QueryKey[] {
  const all = new Map<string, KeySuffix>();
  for (const t of tables) for (const s of REALTIME_TABLES[t] ?? []) all.set(s.join("\u0000"), s);
  const suffixes = [...all.values()];
  return suffixes.filter((s) => !suffixes.some((o) => isPrefix(o, s))).map((s) => ["p", profileCode, ...s]);
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
      for (const queryKey of invalidationKeys(profileCode, tables)) void qc.invalidateQueries({ queryKey });
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

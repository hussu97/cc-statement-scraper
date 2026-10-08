// A small in-memory stand-in for the supabase-js client (SRV-11): enough of
// from().select/insert/update().eq().maybeSingle(), rpc() and storage for the Edge
// code paths under test. Not a test file itself (no _test suffix).

import type { Db } from "../_shared/supabase.ts";

export type Row = Record<string, unknown>;
export interface PgErr {
  code: string;
  message: string;
}
export type RpcResult = { data: unknown; error: PgErr | null };
export type RpcHandler = (args: Record<string, unknown>, db: FakeDb) => RpcResult | Promise<RpcResult>;

export interface Call {
  kind: "rpc" | "select" | "insert" | "update" | "upload" | "remove";
  name: string;
  args: unknown;
}

class Query {
  private op: "select" | "insert" | "update" = "select";
  private filters: [string, unknown][] = [];
  private payload: Row = {};

  constructor(private db: FakeDb, private table: string) {}

  select(_cols?: string) {
    return this;
  }
  eq(col: string, v: unknown) {
    this.filters.push([col, v]);
    return this;
  }
  insert(row: Row) {
    this.op = "insert";
    this.payload = row;
    return this;
  }
  update(values: Row) {
    this.op = "update";
    this.payload = values;
    return this;
  }
  private matches(r: Row) {
    return this.filters.every(([c, v]) => r[c] === v);
  }
  private exec(): { data: unknown; error: PgErr | null } {
    const rows = (this.db.tables[this.table] ??= []);
    if (this.op === "insert") {
      this.db.calls.push({ kind: "insert", name: this.table, args: this.payload });
      const err = this.db.insertError[this.table]?.(this.payload, this.db) ?? null;
      if (err) return { data: null, error: err };
      rows.push({ ...this.db.defaults[this.table], ...this.payload });
      return { data: null, error: null };
    }
    if (this.op === "update") {
      this.db.calls.push({ kind: "update", name: this.table, args: { set: this.payload, where: this.filters } });
      for (const r of rows.filter((r) => this.matches(r))) Object.assign(r, this.payload);
      return { data: null, error: null };
    }
    this.db.calls.push({ kind: "select", name: this.table, args: this.filters });
    const err = this.db.selectError[this.table];
    if (err) return { data: null, error: err };
    return { data: rows.filter((r) => this.matches(r)).map((r) => ({ ...r })), error: null };
  }
  maybeSingle() {
    const res = this.exec();
    const list = (res.data as Row[] | null) ?? [];
    return Promise.resolve({ data: res.error ? null : list[0] ?? null, error: res.error });
  }
  then<T>(ok: (v: { data: unknown; error: PgErr | null }) => T, fail?: (e: unknown) => T) {
    return Promise.resolve(this.exec()).then(ok, fail);
  }
}

export class FakeDb {
  tables: Record<string, Row[]> = {};
  calls: Call[] = [];
  rpcs: Record<string, RpcHandler> = {};
  insertError: Record<string, (row: Row, db: FakeDb) => PgErr | null> = {};
  selectError: Record<string, PgErr> = {};
  /** Column defaults applied on insert, as the real tables do. */
  defaults: Record<string, Row> = { documents: { parse_status: "queued" } };
  objects = new Map<string, Uint8Array>();
  uploadError: PgErr | null = null;
  private seq = 0;

  constructor(init: Partial<Pick<FakeDb, "tables" | "rpcs">> = {}) {
    Object.assign(this, init);
    this.rpcs = { gen_code: ({ prefix }) => ({ data: this.code(String(prefix)), error: null }), ...this.rpcs };
  }

  /** A well-formed `<prefix>_<26 chars>` code. */
  code(prefix: string): string {
    return `${prefix}_${String(++this.seq).padStart(26, "0")}`;
  }

  from(table: string) {
    return new Query(this, table);
  }

  async rpc(name: string, args: Record<string, unknown> = {}): Promise<RpcResult> {
    this.calls.push({ kind: "rpc", name, args });
    const h = this.rpcs[name];
    if (!h) return { data: null, error: { code: "PGRST202", message: `function ${name} not found` } };
    return await h(args, this);
  }

  storage = {
    from: (_bucket: string) => ({
      upload: (path: string, bytes: Uint8Array) => {
        this.calls.push({ kind: "upload", name: path, args: bytes.length });
        if (this.uploadError) return Promise.resolve({ data: null, error: this.uploadError });
        this.objects.set(path, bytes);
        return Promise.resolve({ data: { path }, error: null });
      },
      remove: (paths: string[]) => {
        this.calls.push({ kind: "remove", name: paths.join(","), args: paths });
        for (const p of paths) this.objects.delete(p);
        return Promise.resolve({ data: [], error: null });
      },
    }),
  };

  rpcCalls(name: string): Record<string, unknown>[] {
    return this.calls.filter((c) => c.kind === "rpc" && c.name === name).map((c) => c.args as Record<string, unknown>);
  }

  asDb(): Db {
    return this as unknown as Db;
  }
}

/**
 * merge_mailbox_sync_state as the migration defines it: shallow merge, the Gmail cursor
 * only moves forward, columns change only when passed.
 */
export const mergeSyncStateRpc: RpcHandler = (args, db) => {
  const mb = (db.tables.email_mailboxes ?? []).find((m) => m.mailbox_code === args.p_mailbox_code);
  if (!mb) return { data: null, error: { code: "P0002", message: "unknown mailbox" } };
  const patch = { ...(args.p_patch as Row) };
  const state = { ...((mb.sync_state as Row) ?? {}) };
  if ("gmail_history_id" in patch) {
    const n = String(patch.gmail_history_id ?? "");
    const o = String(state.gmail_history_id ?? "");
    delete patch.gmail_history_id;
    if (/^\d+$/.test(n) && (!/^\d+$/.test(o) || BigInt(n) > BigInt(o))) patch.gmail_history_id = n;
  }
  mb.sync_state = { ...state, ...patch, updated_at: "now" };
  if (args.p_last_synced_at) mb.last_synced_at = args.p_last_synced_at;
  if (args.p_watch_expires_at) mb.watch_expires_at = args.p_watch_expires_at;
  return { data: mb.sync_state, error: null };
};

export type FetchRoute = (url: URL, init: RequestInit | undefined) => Response | Promise<Response> | null;

/** A fetch that answers from `route` (null → 404) and records every URL. */
export function fakeFetch(route: FetchRoute): { fetch: typeof fetch; urls: string[] } {
  const urls: string[] = [];
  const fn = async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    urls.push(url.href);
    return (await route(url, init)) ?? new Response("not found", { status: 404 });
  };
  return { fetch: fn as typeof fetch, urls };
}

export const PDF_BYTES = new TextEncoder().encode("%PDF-1.4\n% fake\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n");

export function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

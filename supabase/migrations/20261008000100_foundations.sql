-- Foundations: extensions, the `private` schema, code generation, generic triggers.

create extension if not exists pg_trgm with schema extensions;
create extension if not exists pgmq;
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- `private` holds internals used by SECURITY DEFINER functions, triggers and
-- pg_cron. Client roles have no USAGE on it at all, so nothing in it is
-- reachable from the Data API.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

-- `authz` holds the membership helpers that RLS policies call. authenticated
-- needs USAGE so policies can evaluate them.
create schema if not exists authz;
revoke all on schema authz from public, anon;
grant usage on schema authz to authenticated, service_role;

-- !! Do not REVOKE EXECUTE on functions. On Supabase Postgres 17.6.1.104 a call
-- to a function the caller lacks EXECUTE on segfaults the server (reproduced
-- locally 2026-10-08). Every RPC instead guards itself in its body with
-- private.assert_service_role() / private.assert_member(); internals live in
-- `private`, which client roles cannot even see.

-- Who is calling? The `role` GUC survives SECURITY DEFINER (current_user does not):
--   'authenticated' / 'anon'  → a client through the Data API
--   'service_role'            → an Edge Function using the service key
--   'none'                    → an internal session (pg_cron, migrations, psql)
create or replace function private.caller_role()
returns text
language sql
stable
set search_path = ''
as $$ select coalesce(nullif(current_setting('role', true), ''), 'none') $$;

create or replace function private.assert_service_role()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if private.caller_role() not in ('service_role', 'none') then
    raise exception 'service role required' using errcode = '42501';
  end if;
end;
$$;

-- ── Codes ───────────────────────────────────────────────────────────────────
-- Every v2 entity is identified by `<prefix>_<26 chars>`. The 26 chars are a ULID
-- in lowercase Crockford base32: 10 chars of millisecond timestamp, then 16 chars
-- of randomness. Codes therefore sort by creation time and are opaque to clients.
create or replace function public.gen_code(prefix text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
  ts bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  rnd bytea := uuid_send(gen_random_uuid());
  ts_part text := '';
  rnd_part text := '';
  i int;
begin
  for i in 1..10 loop
    ts_part := substr(alphabet, (ts % 32)::int + 1, 1) || ts_part;
    ts := ts / 32;
  end loop;
  -- 256 is divisible by 32, so byte % 32 is uniform.
  for i in 0..15 loop
    rnd_part := rnd_part || substr(alphabet, (get_byte(rnd, i) % 32) + 1, 1);
  end loop;
  return prefix || '_' || ts_part || rnd_part;
end;
$$;

comment on function public.gen_code(text) is
  'ULID-style opaque identifier: <prefix>_<10 ts chars><16 random chars>, lowercase Crockford base32.';

-- ── updated_at ──────────────────────────────────────────────────────────────
create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ── Dubai calendar helper ───────────────────────────────────────────────────
-- Business dates are calendar dates in Asia/Dubai, not UTC.
create or replace function public.dubai_date(ts timestamptz)
returns date
language sql
immutable
parallel safe
set search_path = ''
as $$ select (ts at time zone 'Asia/Dubai')::date $$;

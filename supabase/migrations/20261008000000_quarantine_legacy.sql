-- Ledger v2 lives in the same Supabase project as the legacy FastAPI schema.
-- At cutover, every legacy table/type in `public` moves into a `legacy` schema.
-- The v2 schema then owns `public`, and data is migrated in-DB by SQL
-- (see 20261008000900_legacy_import.sql).
-- On a fresh database (local dev, CI) this migration only resets default privileges.

-- FV-01: production was created with Supabase's older defaults, which grant ALL
-- on every new `public` table/sequence to anon and authenticated. The v2
-- migrations grant clients only what they need (often per column) and never
-- revoke table-level privileges, so those defaults must be gone BEFORE any v2
-- table is created. `all` also covers MAINTAIN (PG 17). service_role keeps its
-- defaults. 20261008002100_reassert_client_grants.sql re-asserts the result.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;

create schema if not exists legacy;
revoke all on schema legacy from public, anon, authenticated;

do $$
declare
  t text;
  legacy_tables text[] := array[
    'alembic_version', 'audit_events', 'banks', 'categories', 'category_overrides',
    'category_rules', 'email_bank_routes', 'email_ingestion_events', 'email_mailboxes',
    'exports', 'job_items', 'job_logs', 'jobs', 'pdf_files', 'profile_banks', 'profiles',
    'runtime_settings', 'schedules', 'service_api_tokens', 'statement_lines', 'statements'
  ];
  legacy_types text[] := array[
    'sourcetype', 'referencesource', 'matchtype', 'jobstatus', 'jobtype', 'direction',
    'schedulestatus', 'exportstatus', 'emailprovider', 'emailingestionstatus'
  ];
begin
  -- Only act when the legacy marker table exists. This guards against moving
  -- v2 tables that share a name (profiles, banks, statements…) on a re-run.
  if to_regclass('public.alembic_version') is null then
    return;
  end if;

  foreach t in array legacy_tables loop
    if to_regclass(format('public.%I', t)) is not null then
      execute format('alter table public.%I set schema legacy', t);
    end if;
  end loop;

  foreach t in array legacy_types loop
    if exists (
      select 1 from pg_type ty join pg_namespace n on n.oid = ty.typnamespace
      where n.nspname = 'public' and ty.typname = t
    ) then
      execute format('alter type public.%I set schema legacy', t);
    end if;
  end loop;
end $$;

-- Set the two Vault secrets that pg_cron's private.invoke_edge() reads:
--   project_url       https://<ref>.supabase.co
--   edge_cron_secret  MUST equal the CRON_SECRET Edge Function secret
--
-- Template only: no values live in this file. Pass them as psql variables,
-- taking CRON_SECRET from the same file set-edge-secrets.sh pushes:
--
--   export CRON_SECRET="$(grep '^CRON_SECRET=' supabase/functions/.env.production | cut -d= -f2-)"
--   psql "$LEDGER_DB_URL" -X -q \
--     -v project_url=https://<project-ref>.supabase.co \
--     -v edge_cron_secret="$CRON_SECRET" \
--     -f scripts/cutover/set-vault-secrets.sql
--
-- Do NOT add -a/-e/--echo-*: they would echo the interpolated secret.
-- Setting edge_cron_secret turns the pg_cron → Edge calls on (PRODUCTION.md §10).
-- Idempotent: private.vault_upsert updates an existing secret instead of failing.

\set ON_ERROR_STOP on

\if :{?project_url}
\else
  do $$ begin raise exception 'missing psql variable: -v project_url=https://<ref>.supabase.co'; end $$;
\endif
\if :{?edge_cron_secret}
\else
  do $$ begin raise exception 'missing psql variable: -v edge_cron_secret="$CRON_SECRET"'; end $$;
\endif

begin;

-- Hand the values to the DO block via transaction-local settings, without printing them.
\o /dev/null
select set_config('ledger_cutover.project_url', :'project_url', true),
       set_config('ledger_cutover.edge_cron_secret', :'edge_cron_secret', true);
\o

do $$
declare
  v_url    text := current_setting('ledger_cutover.project_url');
  v_secret text := current_setting('ledger_cutover.edge_cron_secret');
begin
  if v_url !~ '^https://[a-z0-9]{20}\.supabase\.co$' then
    raise exception 'project_url must look like https://<20-char ref>.supabase.co';
  end if;
  if v_secret is null or length(v_secret) < 32 or v_secret ~ '[<>]' then
    raise exception 'edge_cron_secret is empty, a placeholder or shorter than 32 characters';
  end if;
  perform private.vault_upsert('project_url', v_url);
  perform private.vault_upsert('edge_cron_secret', v_secret);
end
$$;

commit;

-- Names and timestamps only. To check the value matches CRON_SECRET without printing it:
--   select encode(extensions.digest(decrypted_secret, 'sha256'), 'hex')
--     from vault.decrypted_secrets where name = 'edge_cron_secret';
--   printf %s "$CRON_SECRET" | shasum -a 256
select name, created_at, updated_at
  from vault.secrets
 where name in ('project_url', 'edge_cron_secret')
 order by name;

-- private.merge_accounts (20261010001400): two accounts of one card relationship become one.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local ledger.test_today = '2026-12-31';

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
-- A SIB transaction-history document: one history_extract per 12th-of-month cycle.
create function pg_temp.history(p_last4 text, p_type text, p_rows jsonb) returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'SIB',
    'document_kind', 'history_pdf',
    'statements', (
      select jsonb_agg(jsonb_build_object(
        'kind', 'history_extract', 'bank_code', 'SIB', 'statement_reference', 'SIB-H-' || p_last4 || '-' || c.stmt_date,
        'reference_source', 'fallback', 'statement_date', c.stmt_date, 'period_start', c.stmt_date - 30,
        'period_end', c.stmt_date, 'due_date', null, 'primary_card_last4', p_last4, 'card_holder', 'JANE Q SAMPLE',
        'card_type', p_type, 'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
        'lines', c.lines) order by c.stmt_date)
      from (
        select (case when extract(day from (r->>'d')::date) <= 12
                     then date_trunc('month', (r->>'d')::date) + interval '11 days'
                     else date_trunc('month', (r->>'d')::date) + interval '1 month 11 days' end)::date as stmt_date,
               jsonb_agg(jsonb_build_object('line_no', o, 'txn_date', r->>'d', 'txn_time', null, 'posting_date', r->>'d',
                 'description_raw', r->>'m', 'merchant_normalized', r->>'m', 'amount_original', r->>'a',
                 'currency_original', 'AED', 'amount_aed', r->>'a', 'fx_rate', '1', 'direction', 'debit',
                 'kind', 'purchase', 'country_code', null, 'card_last4', p_last4, 'card_holder', 'JANE Q SAMPLE',
                 'legacy_fingerprint', md5(p_last4 || (r->>'d') || (r->>'m') || (r->>'a'))) order by o) as lines
        from jsonb_array_elements(p_rows) with ordinality x(r, o)
        group by 1
      ) c))
$$;
create function pg_temp.ingest(p_payload jsonb) returns jsonb language sql as $$
  with d as (
    insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
    values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'history.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'),
            100, 'scraper')
    returning doc_code)
  select public.ingest_parsed_document((select doc_code from d), p_payload) $$;
create function pg_temp.sib_accounts() returns int language sql as $$
  select count(*)::int from public.accounts where profile_code = pg_temp.v('p') and bank_code = 'SIB' $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't28-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t28-' || left(pg_temp.v('uid'), 8), 'Cards'));
reset role;
select set_config('request.jwt.claims', '', true);

-- Two SIB accounts: products differ, so ingest keeps them apart.
select pg_temp.ingest(pg_temp.history('6774', 'SIB MC CASHBACK', '[
  {"d":"2026-06-20","m":"CORNER GROCERY SHARJAH","a":"150.00"},
  {"d":"2026-07-15","m":"BOOK SHOP DUBAI","a":"45.50"}]'::jsonb));
select pg_temp.ingest(pg_temp.history('4821', 'SIB PLATINUM', '[
  {"d":"2026-08-18","m":"PHARMACY SHARJAH","a":"60.00"}]'::jsonb));
select is(pg_temp.sib_accounts(), 2, 'two SIB accounts before the merge');
select pg_temp.set('into', (select account_code from public.cards where profile_code = pg_temp.v('p') and last4 = '6774'));
select pg_temp.set('from', (select account_code from public.cards where profile_code = pg_temp.v('p') and last4 = '4821'));

select pg_temp.set('res', private.merge_accounts(pg_temp.v('p'), pg_temp.v('from'), pg_temp.v('into'))::text);
select is((pg_temp.v('res')::jsonb->>'transactions')::int, 1, 'merge reports the moved transactions');
select is((select count(*)::int from public.cards where account_code = pg_temp.v('into')), 2, 'both cards on one account');
select is((select count(*)::int from public.statements where account_code = pg_temp.v('from'))
        + (select count(*)::int from public.statement_lines where account_code = pg_temp.v('from'))
        + (select count(*)::int from public.transactions where account_code = pg_temp.v('from'))
        + (select count(*)::int from public.cards where account_code = pg_temp.v('from')), 0,
          'nothing is left on the merged account');
select is((select status from public.accounts where account_code = pg_temp.v('from')), 'closed', 'the merged account is closed');
select is((select count(*)::int from public.transactions where account_code = pg_temp.v('into')), 3, 'all transactions on the kept account');

-- A later document for either card lands on the kept account.
select pg_temp.ingest(pg_temp.history('4821', 'SIB PLATINUM', '[
  {"d":"2026-09-02","m":"FUEL STATION SHARJAH","a":"120.25"}]'::jsonb));
select is((select count(*)::int from public.accounts where profile_code = pg_temp.v('p') and bank_code = 'SIB' and status = 'active'), 1,
          'a later statement for the merged card does not recreate an account');

-- Guards.
select throws_ok(format($$ select private.merge_accounts(%L, %L, %L) $$, pg_temp.v('p'), pg_temp.v('into'), pg_temp.v('into')),
                 '22023', null, 'an account cannot merge into itself');
select throws_ok(format($$ select private.merge_accounts(%L, %L, %L) $$, 'prf_00000000000000000000000000', pg_temp.v('from'), pg_temp.v('into')),
                 'P0002', null, 'accounts of another profile are refused');
select ok(not has_function_privilege('authenticated', 'private.merge_accounts(text,text,text)', 'execute')
          or not has_schema_privilege('authenticated', 'private', 'usage'), 'clients cannot reach merge_accounts');

select * from finish();
rollback;

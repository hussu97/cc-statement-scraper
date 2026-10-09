-- public.activity_summary (20261010001500): the Activity header for the list's filters.
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
        'authenticated', 't29-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t29-' || left(pg_temp.v('uid'), 8), 'Cards'));
reset role;
select set_config('request.jwt.claims', '', true);

select pg_temp.ingest(pg_temp.history('6774', 'SIB MC CASHBACK', '[
  {"d":"2026-06-20","m":"CORNER GROCERY SHARJAH","a":"150.00"},
  {"d":"2026-07-15","m":"BOOK SHOP DUBAI","a":"45.50"},
  {"d":"2026-08-01","m":"50% OFF STORE","a":"10.00"},
  {"d":"2026-08-10","m":"CREDIT CARD PAYMENT","a":"100.00"},
  {"d":"2026-08-11","m":"VOIDED CAFE","a":"999.00"}]'::jsonb));
-- A credit (payment) and a void, as the matcher would leave them.
update public.transactions set direction = 'credit', kind = 'payment'
where profile_code = pg_temp.v('p') and description = 'CREDIT CARD PAYMENT';
update public.transactions set status = 'void', voided_at = now()
where profile_code = pg_temp.v('p') and description = 'VOIDED CAFE';
create function pg_temp.s(p jsonb) returns jsonb language sql as $$
  select public.activity_summary(pg_temp.v('p'), (p->>'from')::date, (p->>'to')::date, p->>'account', p->>'card',
                                 p->>'category', coalesce((p->>'uncat')::boolean, false), p->>'status', p->>'source', p->>'q') $$;

select pg_temp.as_owner();
set local role authenticated;
select is(pg_temp.s('{}')->>'txn_count', '5', 'counts every row, void included');
select is(pg_temp.s('{}')->>'net_aed', '105.50', 'net AED: debits minus credits, void left out');
select is(pg_temp.s('{}')->>'earliest_date', '2026-06-20', 'earliest date');
select is(pg_temp.s('{}')->>'latest_date', '2026-08-11', 'latest date');
select is(pg_temp.s('{"from":"2026-07-01","to":"2026-08-05"}')->>'net_aed', '55.50', 'date range');
select is(pg_temp.s('{"q":"book"}')->>'txn_count', '1', 'search is case-insensitive');
select is(pg_temp.s('{"q":"50%"}')->>'txn_count', '1', '% is literal in the search');
select is(pg_temp.s('{"q":"5_%"}')->>'txn_count', '0', '_ is literal in the search');
select is(pg_temp.s('{"status":"void"}')->>'net_aed', '0.00', 'only void rows: nothing to sum');
select is(pg_temp.s('{"uncat":true}')->>'txn_count',
          (select count(*)::text from public.v_transactions where profile_code = pg_temp.v('p') and category_code is null),
          'uncategorized matches the list');
select is(pg_temp.s('{"source":"sms"}')->>'txn_count', '0', 'source: statement-only rows are not sms');
select is(pg_temp.s('{"q":"nothing like this"}'),
          '{"txn_count": 0, "net_aed": "0.00", "unpriced_count": 0, "has_estimate": false, "earliest_date": null, "latest_date": null}'::jsonb,
          'no rows: zero count, null dates');
select throws_ok($$ select pg_temp.s('{"status":"bogus"}') $$, '22023', null, 'an unknown status is refused');
reset role;

-- Another user cannot read this profile's summary.
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid2')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't29b-' || pg_temp.v('uid2') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid2'), 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok($$ select public.activity_summary(pg_temp.v('p')) $$, '42501', null, 'a non-member is refused');
reset role;

select * from finish();
rollback;

-- Spend filters (20261010001600): spend_series and spend_breakdown take categories, banks, cards, search.
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
        'authenticated', 't30-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t30-' || left(pg_temp.v('uid'), 8), 'Cards'));
reset role;
select set_config('request.jwt.claims', '', true);

select pg_temp.ingest(pg_temp.history('9218', 'SIB MC CASHBACK', '[
  {"d":"2026-06-20","m":"CORNER GROCERY SHARJAH","a":"150.00"},
  {"d":"2026-07-15","m":"BOOK SHOP DUBAI","a":"45.50"}]'::jsonb));
-- A second card on its own account (another product).
select pg_temp.ingest(pg_temp.history('4821', 'SIB PLATINUM', '[
  {"d":"2026-07-20","m":"CORNER GROCERY DUBAI","a":"60.00"}]'::jsonb));
select pg_temp.set('c4821', (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '4821'));
select pg_temp.set('cat', (select category_code from public.categories where profile_code = pg_temp.v('p') and kind = 'spend' order by name limit 1));
update public.transactions set manual_category_code = pg_temp.v('cat')
where profile_code = pg_temp.v('p') and description = 'BOOK SHOP DUBAI';

create function pg_temp.total(p_cats text[], p_banks text[], p_cards text[], p_q text) returns text language sql as $$
  select public.spend_breakdown(pg_temp.v('p'), '2026-06-01', '2026-07-31', 'bank', 10, p_cats, p_banks, p_cards, p_q)->>'total' $$;
create function pg_temp.series(p_cats text[], p_banks text[], p_cards text[], p_q text) returns numeric language sql as $$
  select coalesce(sum(amount), 0) from public.spend_series(pg_temp.v('p'), '2026-06-01', '2026-07-31', 'month', 'none', null,
                                                     p_cats, p_banks, p_cards, p_q) $$;

select pg_temp.as_owner();
set local role authenticated;
select is(pg_temp.total(null, null, null, null), '255.50', 'no filters: all spend');
select is(pg_temp.total(array[pg_temp.v('cat')], null, null, null), '45.50', 'category filter');
select is(pg_temp.total(array['__uncategorized__', pg_temp.v('cat')], null, null, null),
          (select coalesce(sum(spend_aed), 0)::numeric(14,2)::text from public.v_spend
           where profile_code = pg_temp.v('p') and (category_code is null or category_code = pg_temp.v('cat'))),
          '__uncategorized__ selects rows without a category');
select is(pg_temp.total(null, array['SIB'], null, null), '255.50', 'bank filter: SIB');
select is(pg_temp.total(null, array['FAB'], null, null), '0.00', 'bank filter: no FAB spend');
select is(pg_temp.total(null, null, array[pg_temp.v('c4821')], null), '60.00', 'card filter');
select is(pg_temp.total(null, null, null, 'corner grocery'), '210.00', 'search over description, case-insensitive');
select is(pg_temp.total(null, null, array[pg_temp.v('c4821')], 'corner'), '60.00', 'filters combine (AND)');
select is(pg_temp.total(array[]::text[], array[]::text[], array[]::text[], '  '), '255.50', 'empty arrays and a blank search = everything');
select is(pg_temp.series(null, null, array[pg_temp.v('c4821')], 'corner'), 60.00::numeric, 'spend_series takes the same filters');
select is(pg_temp.series(null, null, null, null), 255.50::numeric, 'spend_series unfiltered');
reset role;

-- Another user cannot read this profile's series (spend_series is now SECURITY DEFINER).
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid2')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't30b-' || pg_temp.v('uid2') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid2'), 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok($$ select * from public.spend_series(pg_temp.v('p'), '2026-06-01', '2026-07-31') $$, '42501', null,
                 'a non-member is refused by spend_series');
reset role;

select * from finish();
rollback;

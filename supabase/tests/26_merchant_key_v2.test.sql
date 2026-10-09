-- Merchant key v2 (20261010001200): the key strips glued places, references, countries and
-- foreign amounts but keeps branches; rekey_merchants merges v1 merchants onto survivors that
-- keep their codes, maps old keys through merchant_aliases, carries categories, skips and
-- recurring series (manual beats llm), repoints transactions and is idempotent.
-- Merchant names in the rekey fixture use the fake prefix ZZ.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local ledger.test_today = '2026-10-08';

-- ── merchant_key ────────────────────────────────────────────────────────────
create temp table cases (raw text, expected text);
insert into cases values
  -- the city column glued to the name
  ('CAREEM RIDEDUBAI', 'CAREEM RIDE'),
  ('CAREEM HALAABU DHABI', 'CAREEM HALA'),
  ('ADNOC MAYSALOON 783SHARJAH', 'ADNOC MAYSALOON'),
  ('MCDONALDS SZRDUBAI', 'MCDONALDS SZR'),
  ('ADNOCABU DHABI', 'ADNOC'),
  ('PRISON ISLAND DUBAIDXB', 'PRISON ISLAND'),
  -- references in the middle, countries v1 lacked, foreign amounts, the website column
  ('SPOTIFY AB P33F7BD2DC STOCKHOLM SWE', 'SPOTIFY AB'),
  ('WIX COM 1198729259 WWW WIX COM', 'WIX COM'),
  ('AMAZON 8828E0IM5 LONDON LND', 'AMAZON'),
  ('MCDONALDS KL SENT00155 APKUALA LUMPUR 2450618600 MYR 5 70 0', 'MCDONALDS KL SENT AP'),
  ('BOOKING COM4189415093ABU DHABI UN', 'BOOKING COM'),
  ('GRABTAXI BANGKOK THA 5 00 THB', 'GRABTAXI'),
  ('EMIRATES1762206730198DUBAI', 'EMIRATES'),
  ('NAME CHEAP COM ZM5XE4 PHOENIX AZ', 'NAME CHEAP COM'),
  -- branches and store names stay distinct
  ('MCDONALDS OASIS MALLDUBAI', 'MCDONALDS OASIS MALL'),
  ('ADNOC AL SAFA 2', 'ADNOC AL SAFA 2'),
  ('EMARAT 1390 ALGARHOUD', 'EMARAT 1390 ALGARHOUD'),
  -- v1 behaviour kept
  ('CARREFOUR CITY CENTRE 1234 DUBAI AE', 'CARREFOUR CITY CENTRE'),
  ('POS NOON.COM', 'NOON COM'),
  ('Apple Pay  Starbucks*Dubai Mall', 'STARBUCKS DUBAI MALL'),
  -- the first word is the name, even when it carries digits
  ('KIJRUNGRUENG888 KRABI', 'KIJRUNGRUENG888'),
  ('7 11 SOI SAMAKKHI', '7 11 SOI SAMAKKHI'),
  ('12GO NICOSIA CYP', '12GO NICOSIA');

select is(public.merchant_key(raw), expected, format('merchant_key(%L)', raw)) from cases;
select is(public.merchant_key(null), null, 'null has no key');
select is(public.merchant_key(' - '), null, 'punctuation only has no key');
select is((select count(*)::int from cases where public.merchant_key(public.merchant_key(raw)) is distinct from public.merchant_key(raw)),
          0, 'merchant_key is idempotent');

-- ── helpers ─────────────────────────────────────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;

create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric)
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date + 1,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', 'AED', 'amount_aed', p_amount::text, 'fx_rate', null, 'direction', 'debit',
    'kind', 'purchase', 'country_code', 'AE', 'card_last4', '9208', 'card_holder', null,
    'legacy_fingerprint', md5(p_desc || p_date || p_amount))
$$;
create function pg_temp.payload(p_date date, p_lines jsonb) returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB',
    'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'ADCB', 'statement_reference', 'REF' || p_date,
      'reference_source', 'explicit', 'statement_date', p_date, 'period_start', (p_date - 30),
      'period_end', p_date, 'due_date', p_date + 25, 'primary_card_last4', '9208', 'card_holder', 'TEST',
      'card_type', 'VISA', 'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
      'lines', p_lines)))
$$;
create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
  returning doc_code $$;
create function pg_temp.txn(p_desc text, p_amount numeric) returns text language sql as $$
  select t.txn_code from public.transactions t
  where t.profile_code = pg_temp.v('p') and t.description = p_desc and t.amount_original = p_amount $$;
create function pg_temp.merchant(p_key text) returns text language sql as $$
  select merchant_code from public.merchants where merchant_key = p_key $$;
create function pg_temp.mpc(p_merchant text) returns text language sql as $$
  select c.source || ':' || c.category_code from public.merchant_profile_category c
  where c.profile_code = pg_temp.v('p') and c.merchant_code = p_merchant $$;

-- ── setup ───────────────────────────────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't24-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t24-' || left(pg_temp.v('uid'), 8), 'Merchant keys'));
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.set('cat_a', (select category_code from public.categories where profile_code = pg_temp.v('p') order by name limit 1));
select pg_temp.set('cat_b', (select category_code from public.categories where profile_code = pg_temp.v('p') order by name limit 1 offset 1));

select pg_temp.set('doc', pg_temp.new_doc());
select public.ingest_parsed_document(pg_temp.v('doc'), pg_temp.payload('2026-09-28', jsonb_build_array(
  pg_temp.line(1, '2026-09-05', 'ZZCAB RIDEDUBAI', 10.00),
  pg_temp.line(2, '2026-09-06', 'ZZCAB RIDEDUBAI', 11.00),
  pg_temp.line(3, '2026-09-07', 'ZZCAB RIDE ABU DHABI', 12.00),
  pg_temp.line(4, '2026-09-08', 'ZZSTREAM AB P33F7BD2DC STOCKHOLM SWE', 20.00),
  pg_temp.line(5, '2026-09-09', 'ZZSTREAM AB P33F7BD2DC STOCKHOLM SWE', 21.00),
  pg_temp.line(6, '2026-09-10', 'ZZSTREAM AB P34B299B4E STOCKHOLM SWE', 22.00),
  pg_temp.line(7, '2026-09-11', 'ZZFUEL 783SHARJAH', 30.00),
  pg_temp.line(8, '2026-09-12', 'ZZFUEL 452', 31.00))));

select is((select count(distinct merchant_code)::int from public.transactions where profile_code = pg_temp.v('p')),
          3, 'v2 ingest: eight lines, three merchants');

-- Rebuild the state v1 left behind: one merchant per v1 key.
create function pg_temp.v1_split(p_v2_key text, p_v1_key text, p_desc text) returns text language plpgsql as $$
declare v_code text;
begin
  insert into public.merchants (merchant_key, display_name) values (p_v1_key, initcap(lower(p_v1_key)))
  returning merchant_code into v_code;
  update public.transactions set merchant_code = v_code
  where profile_code = pg_temp.v('p') and description = p_desc;
  return v_code;
end $$;
-- ZZCAB: the v2 key's holder becomes the v1 'ZZCAB RIDE' (1 txn); 'ZZCAB RIDEDUBAI' (2 txns) splits off.
select pg_temp.set('cab_keep', pg_temp.merchant('ZZCAB RIDE'));
select pg_temp.set('cab_old', pg_temp.v1_split('ZZCAB RIDE', 'ZZCAB RIDEDUBAI', 'ZZCAB RIDEDUBAI'));
-- ZZSTREAM: nobody holds the v2 key; the merchant with most transactions survives and is renamed.
update public.merchants set merchant_key = 'ZZSTREAM AB P33F7BD2DC STOCKHOLM SWE',
                            display_name = 'Zzstream Ab P33f7bd2dc Stockholm Swe'
where merchant_key = 'ZZSTREAM AB';
select pg_temp.set('stream_keep', pg_temp.merchant('ZZSTREAM AB P33F7BD2DC STOCKHOLM SWE'));
select pg_temp.set('stream_old', pg_temp.v1_split('ZZSTREAM AB', 'ZZSTREAM AB P34B299B4E STOCKHOLM SWE',
                                                  'ZZSTREAM AB P34B299B4E STOCKHOLM SWE'));
-- ZZFUEL: 'ZZFUEL' holds the key; 'ZZFUEL 783SHARJAH' splits off.
select pg_temp.set('fuel_keep', pg_temp.merchant('ZZFUEL'));
select pg_temp.set('fuel_old', pg_temp.v1_split('ZZFUEL', 'ZZFUEL 783SHARJAH', 'ZZFUEL 783SHARJAH'));

-- Categories, skips and series spread over the v1 merchants.
insert into public.merchant_profile_category (profile_code, merchant_code, category_code, source, confidence, model) values
  (pg_temp.v('p'), pg_temp.v('cab_old'),  pg_temp.v('cat_a'), 'manual', null, null),   -- manual on the loser ...
  (pg_temp.v('p'), pg_temp.v('cab_keep'), pg_temp.v('cat_b'), 'llm', 0.9, 'test'),     -- ... beats llm on the survivor
  (pg_temp.v('p'), pg_temp.v('fuel_old'), pg_temp.v('cat_b'), 'manual', null, null);   -- moves to a bare survivor
insert into public.merchant_category_skips (profile_code, merchant_code, reason)
values (pg_temp.v('p'), pg_temp.v('stream_old'), 'declined');
insert into public.recurring_series (profile_code, merchant_code, cadence, expected_amount, last_amount, occurrences,
                                     first_date, last_date, next_expected, status)
values (pg_temp.v('p'), pg_temp.v('stream_old'), 'monthly', 22.00, 22.00, 3, '2026-07-10', '2026-09-10', '2026-10-10', 'dismissed');

select is((select count(distinct merchant_code)::int from public.transactions where profile_code = pg_temp.v('p')),
          6, 'v1 state: six merchants');
select pg_temp.set('merchants_before', (select count(*)::text from public.merchants));

-- ── rekey ───────────────────────────────────────────────────────────────────
select pg_temp.set('run1', private.rekey_merchants()::text);

select is((select count(distinct merchant_code)::int from public.transactions where profile_code = pg_temp.v('p')),
          3, 'after rekey: three merchants again');
select is((select count(*)::text from public.merchants), pg_temp.v('merchants_before'),
          'no merchant is created and none deleted');
select is((select array_agg(distinct merchant_code) from public.transactions where description like 'ZZCAB%'),
          array[pg_temp.v('cab_keep')], 'ZZCAB: every transaction on the holder of the new key');
select is((select array_agg(distinct merchant_code) from public.transactions where description like 'ZZSTREAM%'),
          array[pg_temp.v('stream_keep')], 'ZZSTREAM: every transaction on the merchant that had most');
select is((select array_agg(distinct merchant_code) from public.transactions where description like 'ZZFUEL%'),
          array[pg_temp.v('fuel_keep')], 'ZZFUEL: every transaction on the holder of the new key');
select is((select merchant_key || ' / ' || display_name from public.merchants where merchant_code = pg_temp.v('stream_keep')),
          'ZZSTREAM AB / Zzstream Ab', 'the survivor takes the new key and its auto-made name follows; its code is unchanged');
select is((select merchant_key from public.merchants where merchant_code = pg_temp.v('cab_old')),
          'ZZCAB RIDEDUBAI', 'a merged-away merchant is kept as it was');

select results_eq(
  $$ select alias_key, merchant_code, source from public.merchant_aliases where alias_key like 'ZZ%' order by alias_key $$,
  format($$ values ('ZZCAB RIDEDUBAI', %L, 'auto'), ('ZZFUEL 783SHARJAH', %L, 'auto'),
                   ('ZZSTREAM AB P33F7BD2DC STOCKHOLM SWE', %L, 'auto'),
                   ('ZZSTREAM AB P34B299B4E STOCKHOLM SWE', %L, 'auto') $$,
         pg_temp.v('cab_keep'), pg_temp.v('fuel_keep'), pg_temp.v('stream_keep'), pg_temp.v('stream_keep')),
  'every old key maps to its survivor');
select is(private.resolve_merchant('ZZCAB RIDEDUBAI'), pg_temp.v('cab_keep'), 'a new line resolves to the survivor');
select is(private.resolve_merchant('ZZSTREAM AB P9ZZ99ZZ99 STOCKHOLM SWE'), pg_temp.v('stream_keep'),
          'a new reference resolves to the survivor');

select is(pg_temp.mpc(pg_temp.v('cab_keep')), 'manual:' || pg_temp.v('cat_a'), 'manual on a merged merchant beats llm on the survivor');
select is((select array_agg(distinct effective_category_code) from public.transactions where description like 'ZZCAB%'),
          array[pg_temp.v('cat_a')], 'the merged transactions are recategorised');
select is(pg_temp.mpc(pg_temp.v('fuel_keep')), 'manual:' || pg_temp.v('cat_b'), 'a category moves to a survivor without one');
select is(pg_temp.mpc(pg_temp.v('fuel_old')), null, '... and is not left behind');
select is(pg_temp.mpc(pg_temp.v('cab_old')), 'manual:' || pg_temp.v('cat_a'), 'a conflicting row stays, inert');
select is((select reason from public.merchant_category_skips where profile_code = pg_temp.v('p') and merchant_code = pg_temp.v('stream_keep')),
          'declined', 'the category skip moves to the survivor');
select is((select status from public.recurring_series where profile_code = pg_temp.v('p') and merchant_code = pg_temp.v('stream_keep')),
          'dismissed', 'the recurring series moves to the survivor, still dismissed');

-- Idempotent: a second run changes nothing.
select pg_temp.set('run2', private.rekey_merchants()::text);
select is((pg_temp.v('run2')::jsonb - 'keys' - 'merchants_merged'),
          '{"aliases": 0, "category_skips": 0, "merchants_renamed": 0, "recurring_series": 0, "merchant_categories": 0, "transactions_refreshed": 0}'::jsonb,
          'a second rekey is a no-op');

-- Only the service role or the database owner may run it.
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok($$ select private.rekey_merchants() $$, '42501', null, 'clients cannot rekey merchants');
reset role;

select * from finish();
rollback;

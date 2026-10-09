-- Glued-place backfill (20261010001300): separate_glued_place matches the parser, every place it
-- knows is also stripped by merchant_key, new profiles get spaced seed rules, and the backfill
-- spaces old line descriptions and glued rule patterns without moving a transaction's merchant,
-- line identity or category (a rule that newly matches applies). Fixture names use the prefix ZZ.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local ledger.test_today = '2026-10-08';

-- ── separate_glued_place ────────────────────────────────────────────────────
create temp table cases (raw text, expected text);
insert into cases values
  ('CAREEM HALA RIDEDUBAI', 'CAREEM HALA RIDE DUBAI'),
  ('CAREEM HALAABU DHABI', 'CAREEM HALA ABU DHABI'),
  ('ADNOC MAYSALOON 783SHARJAH', 'ADNOC MAYSALOON 783 SHARJAH'),
  ('JAYS ONE SWEET AND FLOWERAL AIN', 'JAYS ONE SWEET AND FLOWER AL AIN'),
  ('THE COVE ROTANA RESORT RARAS AL KHAIMA', 'THE COVE ROTANA RESORT RA RAS AL KHAIMA'),
  ('PRISON ISLAND DUBAIDXB', 'PRISON ISLAND DUBAI DXB'),
  ('careem hala ridedubai', 'careem hala ride dubai'),
  ('CAREEM HALA RIDE DUBAI', 'CAREEM HALA RIDE DUBAI'),
  ('SMART DUBAI GOVERNMENT', 'SMART DUBAI GOVERNMENT'),
  ('DUBAI', 'DUBAI');
select is(private.separate_glued_place(raw), expected, format('separate_glued_place(%L)', raw)) from cases;

-- Every place it separates, merchant_key strips glued (the two lists stay in step).
create temp table places as
select unnest(string_to_array(substring(pg_get_functiondef('private.separate_glued_place(text)'::regprocedure)
                                        from '\(\[\[:alnum:\]\]\)\(([^)]*)\)\$'), '|')) as place;
select ok((select count(*) from places) >= 40, 'the place list was read from the function');
select is((select array_agg(place order by place) from places
           where public.merchant_key('ZZSHOP' || place) is distinct from 'ZZSHOP'),
          null, 'merchant_key strips every glued place the backfill knows');

-- ── fixture ─────────────────────────────────────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric)
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date + 1,
    'description_raw', lower(p_desc), 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', 'AED', 'amount_aed', p_amount::text, 'fx_rate', null, 'direction', 'debit',
    'kind', 'purchase', 'country_code', null, 'card_last4', '9208', 'card_holder', null,
    'legacy_fingerprint', md5(p_desc || p_date || p_amount) || md5(p_desc))
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
create function pg_temp.txn(p_raw text) returns public.transactions language sql as $$
  select t.* from public.transactions t
  join public.transaction_evidence e on e.txn_code = t.txn_code and e.is_active
  join public.statement_lines l on l.line_code = e.line_code
  where l.profile_code = pg_temp.v('p') and l.description_raw = p_raw $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't27-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t27-' || left(pg_temp.v('uid'), 8), 'Glued places'));
reset role;
select set_config('request.jwt.claims', '', true);

-- New profiles: the seed rules are spaced already (the migration fixed private.seed_rules).
select is((select count(*)::int from public.category_rules where profile_code = pg_temp.v('p')
           and match_type <> 'regex' and private.separate_glued_place(pattern) <> pattern),
          0, 'a new profile gets no glued seed pattern');
select ok(exists (select 1 from public.category_rules where profile_code = pg_temp.v('p')
                  and pattern = 'KITOPI DUBAI' and name = 'seed: KITOPI DUBAI'), 'KITOPIDUBAI is seeded as KITOPI DUBAI');

-- The state before the parser fix: glued descriptions, and rules written against them.
select pg_temp.set('cat_a', (select category_code from public.categories where profile_code = pg_temp.v('p') order by name limit 1));
select pg_temp.set('cat_b', (select category_code from public.categories where profile_code = pg_temp.v('p') order by name limit 1 offset 1));
insert into public.category_rules (profile_code, category_code, name, match_type, pattern, priority, source) values
  (pg_temp.v('p'), pg_temp.v('cat_a'), 'seed: ZZKITCHENDUBAI', 'contains', 'ZZKITCHENDUBAI', 1, 'seed'),
  (pg_temp.v('p'), pg_temp.v('cat_b'), 'laundry', 'regex', '\mZZLAUNDRY\M', 1, 'user');
create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 't.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
  returning doc_code $$;
select public.ingest_parsed_document(pg_temp.new_doc(), pg_temp.payload('2026-09-28', jsonb_build_array(
  pg_temp.line(1, '2026-09-05', 'ZZKITCHENDUBAI', 40.00),
  pg_temp.line(2, '2026-09-06', 'ZZLAUNDRYDUBAI', 25.00),
  pg_temp.line(3, '2026-09-07', 'ZZCAFE OASIS', 15.00))));

select is((pg_temp.txn('zzkitchendubai')).effective_category_code, pg_temp.v('cat_a'), 'before: the glued rule matches the glued line');
select pg_temp.set('laundry_rule', (select rule_code from public.category_rules where profile_code = pg_temp.v('p') and name = 'laundry'));
select isnt((pg_temp.txn('zzlaundrydubai')).rule_code, pg_temp.v('laundry_rule'), 'before: \mZZLAUNDRY\M misses ZZLAUNDRYDUBAI');
select pg_temp.set('kitchen_merchant', (pg_temp.txn('zzkitchendubai')).merchant_code);
select pg_temp.set('kitchen_txn', (pg_temp.txn('zzkitchendubai')).txn_code);
select pg_temp.set('kitchen_key', (select line_key from public.statement_lines where description_raw = 'zzkitchendubai'));

-- ── backfill ────────────────────────────────────────────────────────────────
select pg_temp.set('run1', private.backfill_glued_places()::text);

select is((select description from public.statement_lines where description_raw = 'zzkitchendubai'),
          'ZZKITCHEN DUBAI', 'the line description gets the space');
select is((select line_key from public.statement_lines where description_raw = 'zzkitchendubai'),
          pg_temp.v('kitchen_key'), 'description_raw and line_key are untouched');
select is((pg_temp.txn('zzkitchendubai')).description, 'ZZKITCHEN DUBAI', 'the transaction description follows');
select is((pg_temp.txn('zzkitchendubai')).txn_code, pg_temp.v('kitchen_txn'), 'same transaction');
select is((pg_temp.txn('zzkitchendubai')).merchant_code, pg_temp.v('kitchen_merchant'), 'same merchant');
select is((select pattern || ' / ' || name from public.category_rules where profile_code = pg_temp.v('p') and category_code = pg_temp.v('cat_a') and priority = 1),
          'ZZKITCHEN DUBAI / seed: ZZKITCHEN DUBAI', 'the glued rule pattern (and its seed name) gets the space');
select is((pg_temp.txn('zzkitchendubai')).effective_category_code, pg_temp.v('cat_a'), 'the rewritten rule still categorises it');
select is((pg_temp.txn('zzlaundrydubai')).rule_code, pg_temp.v('laundry_rule'), 'a word rule now matches the spaced text');
select is((select description from public.statement_lines where description_raw = 'zzcafe oasis'),
          'ZZCAFE OASIS', 'a line without a glued place is untouched');
select is((select pattern from public.category_rules where profile_code = pg_temp.v('p') and match_type = 'regex' and name = 'laundry'),
          '\mZZLAUNDRY\M', 'regex rules are not rewritten');

select is(pg_temp.v('run1')::jsonb ->> 'statement_lines', '2', 'two lines spaced');
select is(private.backfill_glued_places(),
          '{"seed_rules": 0, "category_rules": 0, "statement_lines": 0, "transactions_refreshed": 0}'::jsonb,
          'a second backfill is a no-op');

select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok($$ select private.backfill_glued_places() $$, '42501', null, 'clients cannot run the backfill');
reset role;

select * from finish();
rollback;

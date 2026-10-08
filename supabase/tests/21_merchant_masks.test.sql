-- Private merchant masking (20261010000600): existing rows, new statement lines, new SMS,
-- re-parse idempotency, search, category precedence, and that no client role (nor the
-- service role) can read the mask configuration or the kept originals.
-- Only the fake token ZZMASKTEST is used; no real keyword appears in the repository.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local ledger.test_today = '2026-10-08';

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
create function pg_temp.sms(p_amount text, p_date text, p_merchant text, p_at timestamptz) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', 'ADCBAlert',
    'body', format('Your Cr.Card XXX9208 was used for AED%s on %s 10:00:00 at %s. Avl. Cr.limit is AED1000.00',
                   p_amount, p_date, p_merchant)))) $$;
-- Any client-visible text of this profile that still names the token.
create function pg_temp.leaks() returns int language sql as $$
  select (select count(*) from public.statement_lines where profile_code = pg_temp.v('p')
            and (description_raw ~* 'zzmasktest' or description ~* 'zzmasktest' or raw::text ~* 'zzmasktest'))::int
       + (select count(*) from public.sms_messages where profile_code = pg_temp.v('p')
            and (body ~* 'zzmasktest' or merchant_raw ~* 'zzmasktest' or description ~* 'zzmasktest'
                 or parsed_fields::text ~* 'zzmasktest'))::int
       + (select count(*) from public.transactions where profile_code = pg_temp.v('p') and description ~* 'zzmasktest')::int
       + (select count(*) from public.merchants where merchant_key ~* 'zzmasktest' or display_name ~* 'zzmasktest')::int
       + (select count(*) from public.merchant_aliases where alias_key ~* 'zzmasktest')::int
       + (select count(*) from public.insights where profile_code = pg_temp.v('p')
            and (title ~* 'zzmasktest' or body ~* 'zzmasktest'))::int $$;

-- ── setup ───────────────────────────────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't21-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
create function pg_temp.as_system() returns text language sql as $$
  select set_config('request.jwt.claims', '', true) $$;
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t21-' || left(pg_temp.v('uid'), 8), 'Masks'));
reset role;
select pg_temp.as_system();

-- Existing data, before any mask: a statement, an SMS, an insight that name the token.
select pg_temp.set('doc1', pg_temp.new_doc());
select public.ingest_parsed_document(pg_temp.v('doc1'), pg_temp.payload('2026-09-28', jsonb_build_array(
  pg_temp.line(1, '2026-09-05', 'ZZMASKTEST SHOP DUBAI', 50.00),
  pg_temp.line(2, '2026-09-06', 'GROCERY MART', 30.00))));
select pg_temp.set('line1', (select line_code from public.statement_lines
                             where profile_code = pg_temp.v('p') and description_raw = 'ZZMASKTEST SHOP DUBAI'));
select pg_temp.set('key1', (select line_key from public.statement_lines where line_code = pg_temp.v('line1')));
select pg_temp.set('txn1', (select txn_code from public.transaction_evidence where line_code = pg_temp.v('line1') and is_active));
select pg_temp.sms('25.00', '01/10/2026', 'ZzMaskTest Kiosk', '2026-10-01 06:00:00+00');
select pg_temp.set('sms1', (select sms_code from public.sms_messages where profile_code = pg_temp.v('p') and amount = 25.00));
select pg_temp.set('hash1', (select body_hash from public.sms_messages where sms_code = pg_temp.v('sms1')));
insert into public.insights (profile_code, kind, severity, dedupe_key, title, body)
values (pg_temp.v('p'), 'large_transaction', 'warn', 't21', 'Unusually large: Zzmasktest Shop', 'AED 50 at ZZMASKTEST SHOP.');

select ok(pg_temp.leaks() > 0, 'before a mask the token is visible (the fixture is meaningful)');
select is((select merchant_code is not null from public.transactions where txn_code = pg_temp.v('txn1')), true,
          'the transaction had a merchant of its own');

-- ── validation ──────────────────────────────────────────────────────────────
select throws_ok($$ insert into private.merchant_masks (pattern, replacement_merchant_name) values ('(zz', 'X Shop') $$,
                 '22023', null, 'an invalid regex is rejected');
select throws_ok($$ insert into private.merchant_masks (pattern, replacement_merchant_name) values ('z*', 'X Shop') $$,
                 '22023', null, 'a pattern that matches empty text is rejected');
select throws_ok($$ insert into private.merchant_masks (pattern, replacement_merchant_name) values ('shop', 'Some Shop') $$,
                 '22023', null, 'a replacement that matches its own pattern is rejected');

-- ── the mask: applied at once to existing data ──────────────────────────────
insert into private.merchant_masks (pattern, replacement_merchant_name, replacement_category_name)
values ('zzmasktest', 'General Store', 'T21 Masked');

select is(pg_temp.leaks(), 0, 'inserting a mask masks every existing client-visible text at once');
select is((select description_raw || ' / ' || description from public.statement_lines where line_code = pg_temp.v('line1')),
          'General Store / GENERAL STORE', 'the statement line shows the generic name');
select is((select line_key from public.statement_lines where line_code = pg_temp.v('line1')), pg_temp.v('key1'),
          'the line keeps its identity (line_key)');
select is((select description from public.statement_lines
           where profile_code = pg_temp.v('p') and line_no = 2 and is_current), 'GROCERY MART',
          'an unrelated line is untouched');
select is((select original from private.masked_originals
           where table_name = 'statement_lines' and row_code = pg_temp.v('line1') and column_name = 'description_raw'),
          'ZZMASKTEST SHOP DUBAI', 'the original is kept for the database owner');
select ok((select body ~ 'at General Store\. Avl' from public.sms_messages where sms_code = pg_temp.v('sms1')),
          'the SMS body names the generic merchant where the merchant was');
select is((select body_hash from public.sms_messages where sms_code = pg_temp.v('sms1')), pg_temp.v('hash1'),
          'the SMS dedup hash is unchanged');
select is((select merchant_name || ' / ' || description from public.v_transactions where txn_code = pg_temp.v('txn1')),
          'General Store / GENERAL STORE', 'v_transactions shows the generic merchant and description');
select is((select count(distinct merchant_code)::int from public.transactions
           where profile_code = pg_temp.v('p') and description = 'GENERAL STORE'), 1,
          'every masked transaction points at one generic merchant');
select is((select category_name || ' / ' || category_source from public.v_transactions where txn_code = pg_temp.v('txn1')),
          'T21 Masked / merchant', 'the mask category applies as a merchant-level manual category');

-- ── new data after the mask ─────────────────────────────────────────────────
select pg_temp.set('doc2', pg_temp.new_doc());
select pg_temp.set('ing2', public.ingest_parsed_document(pg_temp.v('doc2'), pg_temp.payload('2026-10-05', jsonb_build_array(
  pg_temp.line(1, '2026-10-02', 'ZZMASKTEST CAFE', 42.00),
  pg_temp.line(2, '2026-10-03', 'BOOK STORE', 18.00))))::text);
select pg_temp.sms('77.00', '04/10/2026', 'ZZMASKTEST CORNER', '2026-10-04 06:00:00+00');
select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
  'client_msg_id', gen_random_uuid(), 'received_at', '2026-10-04 07:00:00+00', 'sender', 'ADCBAlert',
  'body', 'Points credited for your visit to ZZMASKTEST-OUTLET today')));
select is(pg_temp.leaks(), 0, 'new statement lines and new SMS (parsed or not) are masked as they arrive');
select is((select body from public.sms_messages where profile_code = pg_temp.v('p') and body like 'Points credited%'),
          'Points credited for your visit to General Store today', 'an unparsed SMS has the matching word replaced');
select is((select description from public.sms_messages where profile_code = pg_temp.v('p') and amount = 77.00),
          'GENERAL STORE', 'a new SMS parses to the generic merchant');
select is((select merchant_name from public.v_transactions where profile_code = pg_temp.v('p') and amount_original = 42.00),
          'General Store', 'a new statement transaction lands on the generic merchant');
select is((select merchant_name from public.v_transactions where profile_code = pg_temp.v('p') and amount_original = 77.00),
          'General Store', 'a new SMS transaction lands on the generic merchant');

-- ── re-parse of the same document: idempotent, still masked ─────────────────
select pg_temp.set('n_lines', (select count(*)::text from public.statement_lines where profile_code = pg_temp.v('p')));
select pg_temp.set('n_txns', (select count(*)::text from public.transactions where profile_code = pg_temp.v('p')));
select is((public.ingest_parsed_document(pg_temp.v('doc2'), pg_temp.payload('2026-10-05', jsonb_build_array(
             pg_temp.line(1, '2026-10-02', 'ZZMASKTEST CAFE', 42.00),
             pg_temp.line(2, '2026-10-03', 'BOOK STORE', 18.00))))->'statements'->0->>'lines_new')::int, 0,
          're-parsing the same statement adds no line');
select is((select count(*)::text from public.statement_lines where profile_code = pg_temp.v('p')), pg_temp.v('n_lines'),
          'no duplicate statement lines after a re-parse');
select is((select count(*)::text from public.transactions where profile_code = pg_temp.v('p')), pg_temp.v('n_txns'),
          'no duplicate transactions after a re-parse');
select is(pg_temp.leaks(), 0, 'a re-parse does not unmask anything');

-- ── a profile whose first masked transaction arrives after the mask ────────
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p2', public.create_profile('t21b-' || left(pg_temp.v('uid'), 8), 'Masks 2'));
reset role;
select pg_temp.as_system();
with d as (
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p2'), 'x/' || gen_random_uuid(), 't.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 1, 'upload')
  returning doc_code)
select public.ingest_parsed_document((select doc_code from d), pg_temp.payload('2026-10-05', jsonb_build_array(
  pg_temp.line(1, '2026-10-01', 'THE ZZMASKTEST PLACE', 15.00))));
select is((select merchant_name || ' / ' || category_name || ' / ' || category_source from public.v_transactions
           where profile_code = pg_temp.v('p2')), 'General Store / T21 Masked / merchant',
          'a new profile''s masked transaction gets the generic merchant and the mask category');

-- ── a manual choice still wins ──────────────────────────────────────────────
select pg_temp.set('dining', (select category_code from public.categories where profile_code = pg_temp.v('p') and name = 'Dining'));
select pg_temp.as_owner();
set local role authenticated;
update public.transactions set manual_category_code = pg_temp.v('dining') where txn_code = pg_temp.v('txn1');
select is((select category_name || ' / ' || category_source from public.v_transactions where txn_code = pg_temp.v('txn1')),
          'Dining / manual', 'a transaction''s manual category outranks the mask category');

-- ── search and analytics as the owner ───────────────────────────────────────
select is((select count(*)::int from public.v_transactions where profile_code = pg_temp.v('p')
           and (description ilike '%zzmasktest%' or merchant_name ilike '%zzmasktest%')), 0,
          'searching the activity list for the original keyword finds nothing');
select is((select count(*)::int from public.merchant_search(pg_temp.v('p'), 'zzmasktest')), 0,
          'merchant search for the original keyword finds nothing');
select is((select display_name from public.merchant_search(pg_temp.v('p'), 'general store') limit 1), 'General Store',
          'merchant search finds the generic merchant first');
select ok(not exists (select 1 from jsonb_array_elements(
            public.spend_breakdown(pg_temp.v('p'), '2026-09-01', '2026-10-31', 'merchant')->'groups') g
          where g->>'label' ~* 'zzmasktest'),
          'spend_breakdown rolls masked spend up under the generic name');
select ok(exists (select 1 from jsonb_array_elements(
            public.spend_breakdown(pg_temp.v('p'), '2026-09-01', '2026-10-31', 'merchant')->'groups') g
          where g->>'label' = 'General Store'),
          'spend_breakdown shows the generic merchant');
select ok((public.statement_detail(pg_temp.v('p'), (select stmt_code from public.statement_lines where line_code = pg_temp.v('line1')))::text
           !~* 'zzmasktest'), 'statement_detail shows only masked text');

-- ── nobody but the database owner reads the configuration ──────────────────
select throws_ok($$ select count(*) from private.merchant_masks $$, '42501', null,
                 'authenticated cannot read private.merchant_masks');
select throws_ok($$ select count(*) from private.masked_originals $$, '42501', null,
                 'authenticated cannot read private.masked_originals');
select throws_ok($$ select private.apply_merchant_masks() $$, '42501', null,
                 'authenticated cannot run apply_merchant_masks');
reset role;
set local role anon;
select throws_ok($$ select count(*) from private.merchant_masks $$, '42501', null, 'anon cannot read private.merchant_masks');
select throws_ok($$ select count(*) from private.masked_originals $$, '42501', null, 'anon cannot read private.masked_originals');
reset role;
set local role service_role;
select throws_ok($$ select count(*) from private.merchant_masks $$, '42501', null,
                 'not even the service role reads private.merchant_masks');
select throws_ok($$ select count(*) from private.masked_originals $$, '42501', null,
                 'not even the service role reads private.masked_originals');
select lives_ok($$ select private.apply_merchant_masks() $$, 'the service role may re-apply the masks');
reset role;
select pg_temp.as_system();
select ok(not exists (select 1 from information_schema.role_routine_grants
                      where routine_schema = 'public' and routine_name ~ 'mask'),
          'no public RPC exposes the masks');
select ok(not exists (select 1 from pg_policies where schemaname = 'private'),
          'no policy opens the private tables');

-- ── re-apply is idempotent and keeps the first original ─────────────────────
select is((private.apply_merchant_masks(pg_temp.v('p'))->>'statement_lines')::int, 0,
          'a second apply finds nothing left to mask');
select is((select original from private.masked_originals
           where table_name = 'statement_lines' and row_code = pg_temp.v('line1') and column_name = 'description_raw'),
          'ZZMASKTEST SHOP DUBAI', 'the first original is never overwritten');

select * from finish();
rollback;

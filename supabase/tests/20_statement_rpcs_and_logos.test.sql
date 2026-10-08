-- Bank logos (20261010000100), statement_detail and spend_breakdown (20261010000200).
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local ledger.test_today = '2026-10-08';

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric, p_dir text default 'debit',
                             p_kind text default 'purchase', p_last4 text default '1111')
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date + 1,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', 'AED', 'amount_aed', p_amount::text, 'fx_rate', null, 'direction', p_dir,
    'kind', p_kind, 'country_code', 'AE', 'card_last4', p_last4, 'card_holder', null,
    'legacy_fingerprint', md5(p_desc || p_date || p_amount))
$$;
create function pg_temp.payload(p_bank text, p_date date, p_lines jsonb, p_last4 text default '1111') returns jsonb
language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', p_bank,
    'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', p_bank, 'statement_reference', 'R' || p_bank || p_date,
      'reference_source', 'explicit', 'statement_date', p_date, 'period_start', (p_date - 30),
      'period_end', p_date, 'due_date', p_date + 25, 'primary_card_last4', p_last4, 'card_holder', 'TEST',
      'card_type', 'VISA',
      'totals', jsonb_build_object('opening_balance', '100.00', 'closing_balance', '1234.50',
                                   'total_debits', '1180.00', 'total_credits', '45.50', 'min_due', '61.73',
                                   'credit_limit', '20000.00'),
      'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb, 'lines', p_lines)))
$$;
create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
  returning doc_code $$;

-- ── logos ───────────────────────────────────────────────────────────────────
select is((select array_agg(bank_code || '=' || logo_path order by bank_code) from public.banks
           where bank_code in ('ADCB', 'EIB', 'ENBD', 'FAB', 'MASHREQ', 'SIB')),
          array['ADCB=ADCB.png', 'EIB=EIB.png', 'ENBD=ENBD.png', 'FAB=FAB.png', 'MASHREQ=MASHREQ.png', 'SIB=SIB.png'],
          'the six banks carry logo_path = <bank_code>.png');
select is((select public from storage.buckets where id = 'bank-logos'), true, 'the bank-logos bucket is public');
select ok(not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                      and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL') and qual::text || coalesce(with_check::text, '') ~ 'bank-logos'),
          'no storage policy lets clients write bank logos');
select throws_ok($$ update public.banks set logo_path = '../x.png' where bank_code = 'FAB' $$, '23514', null,
                 'logo_path is a plain file name');

-- ── setup ───────────────────────────────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't20-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid2')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't20b-' || pg_temp.v('uid2') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t20-' || left(pg_temp.v('uid'), 8), 'Statements'));
reset role;
select set_config('request.jwt.claims', '', true);

select pg_temp.set('doc', pg_temp.new_doc());
select public.ingest_parsed_document(pg_temp.v('doc'), pg_temp.payload('FAB', '2026-08-28', jsonb_build_array(
  pg_temp.line(3, '2026-08-10', 'CINEMA CITY', 80.00),
  pg_temp.line(1, '2026-08-02', 'GROCERY MART', 1100.00),
  pg_temp.line(2, '2026-08-02', 'REFUND GROCERY MART', 45.50, 'credit', 'refund'),
  pg_temp.line(4, '2026-08-12', 'COFFEE HOUSE', 0.00, 'debit', 'purchase', '2222'))));
select pg_temp.set('stmt', (select stmt_code from public.statements where profile_code = pg_temp.v('p')));
select public.ingest_parsed_document(pg_temp.new_doc(), pg_temp.payload('ADCB', '2026-07-28', jsonb_build_array(
  pg_temp.line(1, '2026-07-05', 'CINEMA CITY', 60.00)), '3333'));

-- ── statement_detail ───────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('d', public.statement_detail(pg_temp.v('p'), pg_temp.v('stmt'))::text);
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.v('d')::jsonb) k),
          array['credits', 'debits', 'statement'], 'statement_detail has statement, debits, credits');
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.v('d')::jsonb->'statement') k),
          array['account_code', 'bank_code', 'card_last4s', 'closing_balance', 'credit_limit', 'doc_code', 'due_date',
                'kind', 'min_due', 'opening_balance', 'period_end', 'period_start', 'recon_checks', 'recon_status',
                'statement_date', 'stmt_code', 'total_credits', 'total_debits', 'utilisation'],
          'the statement object has exactly the contract keys');
select ok((pg_temp.v('d')::jsonb->'statement'->>'utilisation') is null
          or (pg_temp.v('d')::jsonb->'statement'->>'utilisation')::numeric >= 0,
          'utilisation is server-computed: closing / limit, never negative');
select is(pg_temp.v('d')::jsonb->'statement'->>'closing_balance', '1234.50', 'money is a decimal string');
select is(pg_temp.v('d')::jsonb->'statement'->>'bank_code', 'FAB', 'bank_code comes from the account');
select is(pg_temp.v('d')::jsonb->'statement'->'card_last4s', '["1111", "2222"]'::jsonb,
          'card_last4s lists the primary and every line card');
select is((pg_temp.v('d')::jsonb->'debits'->>'count')::int, 3, 'three debit lines');
select is(pg_temp.v('d')::jsonb->'debits'->>'total', '1180.00', 'debit total as a decimal string');
select is(pg_temp.v('d')::jsonb->'credits'->>'total', '45.50', 'credit total');
select is((select array_agg(x->>'description' order by o) from jsonb_array_elements(pg_temp.v('d')::jsonb->'debits'->'lines')
           with ordinality e(x, o)), array['GROCERY MART', 'CINEMA CITY', 'COFFEE HOUSE'],
          'lines are ordered by txn_date, line_no');
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.v('d')::jsonb->'debits'->'lines'->0) k),
          array['amount_aed', 'amount_original', 'card_last4', 'category_code', 'currency_original', 'description',
                'kind', 'line_code', 'merchant_name', 'posting_date', 'txn_code', 'txn_date'],
          'each line has exactly the contract keys');
select ok((pg_temp.v('d')::jsonb->'debits'->'lines'->0->>'txn_code') ~ '^txn_', 'a line carries its transaction code');
select is(pg_temp.v('d')::jsonb->'debits'->'lines'->0->>'merchant_name', 'Grocery Mart', 'and its merchant name');
select is(pg_temp.v('d')::jsonb->'debits'->'lines'->0->>'amount_aed', '1100.00', 'line money is a decimal string');
select throws_ok($$ select public.statement_detail(pg_temp.v('p'), 'stm_00000000000000000000000000') $$, 'P0002', null,
                 'an unknown statement raises P0002');
reset role;

-- another user cannot read it
select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select public.statement_detail(pg_temp.v('p'), pg_temp.v('stmt')) $$, '42501', null,
                 'a non-member cannot read statement_detail');
select throws_ok($$ select public.spend_breakdown(pg_temp.v('p'), '2026-07-01', '2026-09-30', 'category') $$, '42501', null,
                 'a non-member cannot read spend_breakdown');
reset role;

-- ── spend_breakdown ─────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('b', public.spend_breakdown(pg_temp.v('p'), '2026-07-01', '2026-09-30', 'bank')::text);
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.v('b')::jsonb) k),
          array['group_by', 'groups', 'months', 'series', 'total'], 'spend_breakdown has the contract keys');
select is(pg_temp.v('b')::jsonb->'months', '["2026-07", "2026-08", "2026-09"]'::jsonb,
          'every month of the range is listed');
select is(pg_temp.v('b')::jsonb->>'total', '1194.50', 'total = all spend in the range (refunds net)');
select is((select array_agg(g->>'key' || ':' || (g->>'total') || ':' || (g->>'share') || ':' || coalesce(g->>'logo_path', '-')
                            order by o)
           from jsonb_array_elements(pg_temp.v('b')::jsonb->'groups') with ordinality e(g, o)),
          array['FAB:1134.50:0.9498:FAB.png', 'ADCB:60.00:0.0502:ADCB.png'],
          'bank groups carry totals, 4-dp shares and logo_path, largest first');
select is((select s->'values' from jsonb_array_elements(pg_temp.v('b')::jsonb->'series') s where s->>'month' = '2026-09'),
          '{"ADCB": "0.00", "FAB": "0.00"}'::jsonb, 'a month without spend is zero-filled');
select is((select s->>'total' from jsonb_array_elements(pg_temp.v('b')::jsonb->'series') s where s->>'month' = '2026-08'),
          '1134.50', 'monthly totals');

select pg_temp.set('c', public.spend_breakdown(pg_temp.v('p'), '2026-07-01', '2026-09-30', 'merchant', 1)::text);
select is((select array_agg(g->>'label' order by o) from jsonb_array_elements(pg_temp.v('c')::jsonb->'groups')
           with ordinality e(g, o)), array['Grocery Mart', 'Others'], 'top N keeps N groups and folds the rest into Others');
select is((select g->>'key' from jsonb_array_elements(pg_temp.v('c')::jsonb->'groups') g where g->>'label' = 'Others'),
          '__other__', 'the fold key is __other__');
select is((select g->>'total' from jsonb_array_elements(pg_temp.v('c')::jsonb->'groups') g where g->>'key' = '__other__'),
          '94.50', 'Others sums the folded groups (refunds net)');
select ok((select bool_and(g->'color_token' = 'null'::jsonb and g->'logo_path' = 'null'::jsonb)
           from jsonb_array_elements(pg_temp.v('c')::jsonb->'groups') g),
          'merchant groups carry no colour or logo');

select pg_temp.set('g', public.spend_breakdown(pg_temp.v('p'), '2026-07-01', '2026-09-30', 'category')::text);
select ok((select bool_and(g->>'key' = '__uncategorized__' or g->>'color_token' is not null)
           from jsonb_array_elements(pg_temp.v('g')::jsonb->'groups') g),
          'category groups carry their colour token');
select is((select sum((s->>'total')::numeric) from jsonb_array_elements(pg_temp.v('g')::jsonb->'series') s)::text,
          '1194.50', 'the series adds up to the total');
select throws_ok($$ select public.spend_breakdown(pg_temp.v('p'), '2026-07-01', '2026-09-30', 'card') $$, '22023', null,
                 'an unknown group_by is rejected');
select is((public.spend_breakdown(pg_temp.v('p'), '2025-01-01', '2025-02-28', 'category'))::jsonb,
          '{"group_by": "category", "total": "0.00", "months": ["2025-01", "2025-02"], "groups": [],
            "series": [{"month": "2025-01", "total": "0.00", "values": {}}, {"month": "2025-02", "total": "0.00", "values": {}}]}'::jsonb,
          'an empty range still lists its months with zero totals');

-- ── logo_path in existing RPCs ──────────────────────────────────────────────
select is((select logo_path from public.statement_cycles(pg_temp.v('p')) where stmt_code = pg_temp.v('stmt')), 'FAB.png',
          'statement_cycles carries logo_path');
select is((select a->>'logo_path' from jsonb_array_elements(public.overview(pg_temp.v('p'))->'accounts') a
           where a->>'bank_code' = 'FAB'), 'FAB.png', 'overview accounts carry logo_path');
select is((select b->>'logo_path' from jsonb_array_elements(public.filter_meta(pg_temp.v('p'))->'banks') b
           where b->>'bank_code' = 'SIB'), 'SIB.png', 'filter_meta banks carry logo_path');
reset role;

select * from finish();
rollback;

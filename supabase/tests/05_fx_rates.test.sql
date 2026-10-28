-- Daily FX-rate fallback: public.fx_rates feeds private.estimate_fx when the
-- card's bank has no statement rate for a currency, upsert_fx_rates re-estimates
-- pending SMS transactions, the bank's own statement rates and the USD peg still
-- win, a bank's markup (private.bank_fx_fees) applies to the peg and market rate,
-- another bank's rate is never used, only purchase-like lines give a rate, a posted
-- estimate stores its rate, and only the service role may write rates.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ── helpers ─────────────────────────────────────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.sms(p_body text, p_at timestamptz) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', 'ADCBAlert', 'body', p_body))) -> 0
$$;
create function pg_temp.txn(p_key text) returns public.transactions language sql as $$
  select * from public.transactions where txn_code = pg_temp.v(p_key)::jsonb->>'txn_code' $$;

-- ── setup: a profile with an ADCB card ─────────────────────────────────────
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('55555555-5555-5555-5555-555555555555', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'fx@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('fx', 'FX'));
reset role;

with a as (
  insert into public.accounts (profile_code, bank_code, product_name)
  values (pg_temp.v('p'), 'ADCB', 'FX card') returning account_code, profile_code
)
insert into public.cards (profile_code, account_code, bank_code, last4)
select profile_code, account_code, 'ADCB', '9208' from a;

-- The migration backfills real daily rates (20261011170000).
select is((select count(*)::int from private.fx_rate_history where source = 'currency-api'), 6360,
          'backfill: 10 currencies × 636 days');
select is((select aed_per_unit from private.fx_rate_history where currency = 'INR' and as_of = '2026-10-03'),
          0.03818088::numeric(18,8), 'backfill: INR on 2026-10-03 (SIB posting date)');
select ok((select relrowsecurity from pg_class where oid = 'private.fx_rate_history'::regclass), 'fx_rate_history has RLS');

-- Start from a known table state (the local stack may hold real rates).
delete from public.fx_rates;
delete from private.fx_rate_history;

-- ── table shape ─────────────────────────────────────────────────────────────
select ok((select relrowsecurity from pg_class where oid = 'public.fx_rates'::regclass), 'fx_rates has RLS');
select throws_ok($$ insert into public.fx_rates (currency, aed_per_unit, source, as_of) values ('egp', 1, 't', current_date) $$,
                 '23514', null, 'currency must be an upper-case ISO code');
select throws_ok($$ insert into public.fx_rates (currency, aed_per_unit, source, as_of) values ('EGP', 0, 't', current_date) $$,
                 '23514', null, 'a rate must be positive');
select is((select count(*)::int from cron.job where jobname = 'ledger-fx-rates' and schedule = '0 21 * * *'
             and command like '%invoke_edge(''fx-rates'')%'), 1, 'daily 21:00 UTC cron job calls the fx-rates function');

-- ── a pending EGP SMS with no known rate ────────────────────────────────────
select pg_temp.set('egp', pg_temp.sms(
  'Credit Card XX9208 was used for EGP69.94 on 09/09/2026 11:44:55 at UBER *TRIP HELP.UBER, help.uber.com-NL. Available limit  AED19965.95',
  '2026-09-09 07:45:00+00')::text);
select is(pg_temp.v('egp')::jsonb->>'status', 'created', 'EGP SMS creates a transaction');
select ok((select status = 'pending' and amount_aed is null and amount_aed_is_estimate from pg_temp.txn('egp')),
          'without any rate the EGP transaction is pending with no AED amount');

-- ── upsert rates (as the service / postgres caller) ─────────────────────────
select pg_temp.set('up', public.upsert_fx_rates(
  '{"EGP": "0.07560000", "INR": 0.0441, "USD": 3.67242, "bad": 1, "XYZW": 2, "JPY": -1, "GBP": "abc", "KWD": 0}'::jsonb,
  'test', '2026-10-07')::text);
select is(pg_temp.v('up')::jsonb->>'upserted', '3', 'valid rates are upserted, junk entries skipped');
-- (other pending transactions in the shared local DB may be refreshed too)
select ok((pg_temp.v('up')::jsonb->>'reestimated')::int >= 1, 'pending transactions are re-estimated');
select results_eq($$ select currency, aed_per_unit, source, as_of from public.fx_rates order by currency $$,
  $$ values ('EGP'::text, 0.07560000::numeric(18,8), 'test'::text, '2026-10-07'::date),
            ('INR', 0.04410000, 'test', '2026-10-07'),
            ('USD', 3.67242000, 'test', '2026-10-07') $$,
  'rates stored as AED per unit');

select results_eq(
  $$ select status, amount_aed, fx_rate, amount_aed_is_estimate from pg_temp.txn('egp') $$,
  $$ values ('pending'::text, 5.51::numeric(14,2), 0.07875585::numeric, true) $$,
  'pending EGP transaction now carries an estimate from fx_rates plus ADCB''s 4.1744% (69.94 × 0.0756 × 1.041744)');

-- a newer rate re-estimates again; an older one never overwrites it
select is(public.upsert_fx_rates('{"EGP": 0.08}'::jsonb, 'test', '2026-10-08')->>'upserted', '1', 'a newer rate replaces the old');
select is((select amount_aed from pg_temp.txn('egp')), 5.83::numeric(14,2), 'the estimate follows the newer rate');
select is(public.upsert_fx_rates('{"EGP": 0.01}'::jsonb, 'stale', '2026-10-01')->>'upserted', '0', 'an older rate is ignored');
select results_eq($$ select as_of, aed_per_unit from private.fx_rate_history where currency = 'EGP' order by as_of $$,
  $$ values ('2026-10-01'::date, 0.01::numeric(18,8)), ('2026-10-07', 0.0756), ('2026-10-08', 0.08) $$,
  'every update is kept in the history under its own date (an older one too)');
select is((select amount_aed from pg_temp.txn('egp')), 5.83::numeric(14,2),
          'an SMS older than every history row uses the newest rate');
select is((select aed_per_unit from public.fx_rates where currency = 'EGP'), 0.08::numeric(18,8), 'EGP keeps the newer rate');

-- ── precedence: statement rate > peg > fx_rates (peg and market × the bank's markup) ──
select is(private.estimate_fx(pg_temp.v('p'), 'USD', 'ADCB', null), 3.82580484::numeric, 'the USD peg (× 1.041744) beats a market quote');
select is(private.estimate_fx(pg_temp.v('p'), 'AED', 'ADCB', null), 1::numeric, 'AED is 1');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'ADCB', null), 0.04594091::numeric, 'INR falls back to fx_rates × 1.041744');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', null, null), 0.0441::numeric, 'with no known bank it is the bare mid rate');
select is(private.estimate_fx(pg_temp.v('p'), 'CHF', 'ADCB', null), null::numeric, 'an unknown currency has no estimate');

-- a statement line in INR with the card's own (marked-up) rate
create function pg_temp.ingest_inr_statement() returns jsonb language plpgsql as $$
declare v_doc text;
begin
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
  returning doc_code into v_doc;
  return public.ingest_parsed_document(v_doc, jsonb_build_object('contract_version', 1, 'parser_version', 'test',
    'bank_code', 'ADCB', 'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'ADCB', 'statement_reference', 'REF-FX-1', 'reference_source', 'explicit',
      'statement_date', '2026-08-31', 'period_start', '2026-08-01', 'period_end', '2026-08-31', 'due_date', '2026-09-25',
      'primary_card_last4', '9208', 'card_holder', 'TEST', 'card_type', 'VISA',
      'totals', jsonb_build_object('opening_balance', null, 'closing_balance', null, 'total_debits', null,
        'total_credits', null, 'min_due', null, 'credit_limit', '27000.00'),
      'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
      'lines', jsonb_build_array(jsonb_build_object('line_no', 1, 'txn_date', '2026-08-15', 'txn_time', null,
        'posting_date', '2026-08-16', 'description_raw', 'AIR INDIA DELHI', 'merchant_normalized', 'AIR INDIA DELHI',
        'amount_original', '1000.00', 'currency_original', 'INR', 'amount_aed', '50.00', 'fx_rate', '0.05',
        'direction', 'debit', 'kind', 'purchase', 'country_code', 'IN', 'card_last4', '9208', 'card_holder', null,
        'legacy_fingerprint', md5('fx-air-india')))))));
end $$;
select lives_ok($$ select pg_temp.ingest_inr_statement() $$, 'INR statement ingests');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'ADCB', null), 0.05::numeric, 'the bank''s own statement rate beats fx_rates');

select pg_temp.set('inr', pg_temp.sms(
  'Credit Card XX9208 was used for INR840.96 on 06/10/2026 12:43:13 at UBER * PENDING, help.uber.com-NL. Available limit AED26967.39',
  '2026-10-06 08:43:30+00')::text);
select results_eq(
  $$ select status, amount_aed, fx_rate, amount_aed_is_estimate from pg_temp.txn('inr') $$,
  $$ values ('pending'::text, 42.05::numeric(14,2), 0.05::numeric, true) $$,
  'a pending INR SMS uses the statement rate (840.96 × 0.05), not fx_rates');
select lives_ok($$ select public.upsert_fx_rates('{"INR": 0.04}'::jsonb, 'test', '2026-10-08') $$, 'INR rate refresh');
select is((select amount_aed from pg_temp.txn('inr')), 42.05::numeric(14,2), 're-estimation keeps the statement rate');

-- ── bank-aware estimates: SIB's markup, never another bank's rate ───────────
-- Real case: SIB billed INR 28,400.00 as AED 1,123.72 on 2026-10-03 (mid ≈ 0.03816247).
select results_eq($$ select bank_code, markup from private.bank_fx_fees order by bank_code $$,
  $$ values ('ADCB'::text, 0.041744::numeric(8,6)), ('COIN', 0.000000), ('DFM', 0.011500), ('EIB', 0.037192),
            ('ENBD', 0.031629), ('FAB', 0.037900), ('KITE', 0.000000), ('MASHREQ', 0.040732), ('SIB', 0.036788), ('SWQ', 0.009500), ('WIO', 0.007500), ('ZRD', 0.000000) $$,
  'each bank carries its all-in FX markup');
select is((select count(*)::int from public.banks b
            where not exists (select 1 from private.bank_fx_fees f where f.bank_code = b.bank_code)), 0,
          'every bank has an FX markup (a new bank needs one)');
select ok((select relrowsecurity from pg_class where oid = 'private.bank_fx_fees'::regclass), 'bank_fx_fees has RLS');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'private' and p.proname = 'estimate_fx' and p.pronargs <> 4), 0,
          'only the bank- and date-aware estimate_fx exists');

with a as (
  insert into public.accounts (profile_code, bank_code, product_name)
  values (pg_temp.v('p'), 'SIB', 'SIB covered card') returning account_code, profile_code
)
insert into public.cards (profile_code, account_code, bank_code, last4)
select profile_code, account_code, 'SIB', '9213' from a;
select lives_ok($$ select public.upsert_fx_rates('{"INR": "0.03816247"}'::jsonb, 'test', '2026-10-09') $$, 'INR mid rate');

select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'SIB', null), 0.03956639::numeric,
          'SIB INR is mid × 1.036788, not the ADCB statement rate on the same profile');
select is(private.estimate_fx(pg_temp.v('p'), 'USD', 'SIB', null), 3.80760393::numeric, 'SIB USD is the peg × 1.036788');
select is(private.estimate_fx(pg_temp.v('p'), 'AED', 'SIB', null), 1::numeric, 'SIB AED is 1');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'FAB', null), 0.03960883::numeric, 'FAB INR is mid × 1.0379');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'ENBD', null), 0.03936951::numeric, 'ENBD INR is mid × 1.031629');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'EIB', null), 0.03958181::numeric, 'EIB INR is mid × 1.037192');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'MASHREQ', null), 0.03971690::numeric, 'MASHREQ INR is mid × 1.040732');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'ADCB', null), 0.05::numeric, 'ADCB keeps its own statement rate');

select pg_temp.set('sib', (public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
  'client_msg_id', gen_random_uuid(), 'received_at', '2026-10-02 05:36:30+00', 'sender', 'SIB',
  'body', 'A txn on your Covered Card XXXX9213 at EMIRATES for INR 28,400.00 on 02-10-2026 09:36 is approved. Your available balance is AED 7,512.13'
))) -> 0)::text);
select results_eq(
  $$ select status, amount_aed, fx_rate, amount_aed_is_estimate from pg_temp.txn('sib') $$,
  $$ values ('pending'::text, 1123.69::numeric(14,2), 0.03956639::numeric, true) $$,
  'a pending SIB INR SMS lands within AED 0.03 of what SIB billed (1,123.72)');

-- ── only purchase rates teach an estimate; a posted estimate keeps its rate ──
-- FAB prints "VAT ON SERVICE CHARGES" beside the foreign purchase's currency and amount
-- (USD 23.20 … AED 0.16). Parsers up to 2026.10.6 stored that pair (rate 0.00689655), and it
-- priced an SIB USD 249.99 history row at AED 1.72.
create function pg_temp.ingest_lines(p_bank text, p_kind text, p_last4 text, p_ref text, p_date date, p_lines jsonb)
returns jsonb language plpgsql as $$
declare v_doc text;
begin
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
  returning doc_code into v_doc;
  return public.ingest_parsed_document(v_doc, jsonb_build_object('contract_version', 1, 'parser_version', 'test',
    'bank_code', p_bank, 'document_kind', case when p_kind = 'statement' then 'statement_pdf' else 'history_pdf' end,
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', p_kind, 'bank_code', p_bank, 'statement_reference', p_ref, 'reference_source', 'explicit',
      'statement_date', p_date, 'period_start', p_date - 30, 'period_end', p_date, 'due_date', null,
      'primary_card_last4', p_last4, 'card_holder', 'TEST', 'card_type', 'CASHBACK',
      'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
      'lines', (select jsonb_agg(jsonb_build_object('line_no', o, 'txn_date', r->>'d', 'txn_time', null,
        'posting_date', r->>'d', 'description_raw', r->>'m', 'merchant_normalized', r->>'m',
        'amount_original', r->>'a', 'currency_original', r->>'c', 'amount_aed', r->>'aed', 'fx_rate', r->>'fx',
        'direction', 'debit', 'kind', r->>'k', 'country_code', null, 'card_last4', p_last4, 'card_holder', null,
        'legacy_fingerprint', md5(p_ref || o)) order by o)
        from jsonb_array_elements(p_lines) with ordinality x(r, o))))));
end $$;

with a as (
  insert into public.accounts (profile_code, bank_code, product_name)
  values (pg_temp.v('p'), 'FAB', 'FAB cashback') returning account_code, profile_code
)
insert into public.cards (profile_code, account_code, bank_code, last4)
select profile_code, account_code, 'FAB', '9206' from a;
select lives_ok($$ select pg_temp.ingest_lines('FAB', 'statement', '9206', 'REF-FAB-VAT', '2026-09-30',
  '[{"d": "2026-09-07", "m": "VAT ON SERVICE CHARGES", "a": "23.20", "c": "USD", "aed": "0.16", "fx": "0.00689655", "k": "fee"}]'::jsonb) $$,
  'a FAB statement whose only USD line is a legacy-parsed VAT row ingests');
select is(private.estimate_fx(pg_temp.v('p'), 'USD', 'FAB', null), 3.81168775::numeric,
          'a fee line''s rate is ignored: FAB USD is the peg × 1.0379');

select lives_ok($$ select pg_temp.ingest_lines('SIB', 'history_extract', '9213', 'REF-SIB-H', '2026-07-12',
  '[{"d": "2026-06-22", "m": "PLEXINC PASS LIFETIME", "a": "249.99", "c": "USD", "aed": null, "fx": null, "k": "purchase"}]'::jsonb) $$,
  'an SIB history row without an AED amount ingests');
select results_eq(
  $$ select t.status, t.amount_aed, t.fx_rate, t.amount_aed_is_estimate from public.transactions t
     where t.profile_code = pg_temp.v('p') and t.description = 'PLEXINC PASS LIFETIME' $$,
  $$ values ('posted'::text, 951.86::numeric(14,2), 3.80760393::numeric(18,8), true) $$,
  'the posted SIB estimate is the peg × 1.036788 and stores the rate it used');

-- ── the rate of the transaction's own date (private.fx_rate_history) ───────
insert into private.fx_rate_history (currency, as_of, aed_per_unit, source)
values ('INR', '2026-10-02', 0.03814140, 'test'), ('INR', '2026-10-03', 0.03818088, 'test');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'SIB', '2026-10-03'), 0.03958548::numeric,
          'the posting date''s mid rate × SIB''s markup');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'SIB', '2026-10-05'), 0.03958548::numeric,
          'a day without a rate uses the latest one before it');
select is(private.estimate_fx(pg_temp.v('p'), 'INR', 'SIB', '2020-01-01'), 0.03956639::numeric,
          'a date before any history uses the newest rate');
select is(private.estimate_fx(pg_temp.v('p'), 'USD', 'SIB', '2026-10-03'), 3.80760393::numeric, 'USD stays on the peg');
select lives_ok($$ select private.refresh_transaction(pg_temp.v('sib')::jsonb->>'txn_code') $$, 're-derive the SIB SMS');
select is((select amount_aed from pg_temp.txn('sib')), 1123.07::numeric(14,2),
          'the SIB SMS (2026-10-02) now uses that day''s rate: 28,400 × 0.03814140 × 1.036788');

-- ── input validation and authorisation ─────────────────────────────────────
select throws_ok($$ select public.upsert_fx_rates('[]'::jsonb, 'test', '2026-10-08') $$, '22023', null,
                 'rates must be a JSON object');
select throws_ok($$ select public.upsert_fx_rates('{}'::jsonb, '', '2026-10-08') $$, '22023', null,
                 'a source is required');

set local role authenticated;
select is((select count(*)::int from public.fx_rates), 3, 'members can read the global rates');
select throws_ok($$ select public.upsert_fx_rates('{"EGP": 1}'::jsonb, 'evil', '2026-12-31') $$, '42501', null,
                 'an authenticated user cannot write rates');
select throws_ok($$ insert into public.fx_rates (currency, aed_per_unit, source, as_of) values ('CHF', 4, 'x', current_date) $$,
                 '42501', null, 'an authenticated user cannot insert rates directly');
reset role;
set local role anon;
select throws_ok($$ select public.upsert_fx_rates('{"EGP": 1}'::jsonb, 'evil', '2026-12-31') $$, '42501', null,
                 'anon cannot write rates');
reset role;
select is((select aed_per_unit from public.fx_rates where currency = 'EGP'), 0.08::numeric(18,8), 'rates unchanged by rejected callers');

select * from finish();
rollback;

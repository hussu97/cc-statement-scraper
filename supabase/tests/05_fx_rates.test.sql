-- Daily FX-rate fallback: public.fx_rates feeds private.estimate_fx when the
-- profile has no statement rate for a currency, upsert_fx_rates re-estimates
-- pending SMS transactions, statement rates and the USD peg still win, and only
-- the service role may write rates.
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

-- Start from a known table state (the local stack may hold real rates).
delete from public.fx_rates;

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
  $$ values ('pending'::text, 5.29::numeric(14,2), 0.0756::numeric, true) $$,
  'pending EGP transaction now carries an estimate from fx_rates (69.94 × 0.0756)');

-- a newer rate re-estimates again; an older one never overwrites it
select is(public.upsert_fx_rates('{"EGP": 0.08}'::jsonb, 'test', '2026-10-08')->>'upserted', '1', 'a newer rate replaces the old');
select is((select amount_aed from pg_temp.txn('egp')), 5.60::numeric(14,2), 'the estimate follows the newer rate');
select is(public.upsert_fx_rates('{"EGP": 0.01}'::jsonb, 'stale', '2026-10-01')->>'upserted', '0', 'an older rate is ignored');
select is((select aed_per_unit from public.fx_rates where currency = 'EGP'), 0.08::numeric(18,8), 'EGP keeps the newer rate');

-- ── precedence: statement rate > peg > fx_rates ─────────────────────────────
select is(private.estimate_fx(pg_temp.v('p'), 'USD'), 3.6725::numeric, 'the USD peg beats a market quote');
select is(private.estimate_fx(pg_temp.v('p'), 'AED'), 1::numeric, 'AED is 1');
select is(private.estimate_fx(pg_temp.v('p'), 'INR'), 0.0441::numeric, 'INR falls back to fx_rates');
select is(private.estimate_fx(pg_temp.v('p'), 'CHF'), null::numeric, 'an unknown currency has no estimate');

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
select is(private.estimate_fx(pg_temp.v('p'), 'INR'), 0.05::numeric, 'the profile''s statement rate beats fx_rates');

select pg_temp.set('inr', pg_temp.sms(
  'Credit Card XX9208 was used for INR840.96 on 06/10/2026 12:43:13 at UBER * PENDING, help.uber.com-NL. Available limit AED26967.39',
  '2026-10-06 08:43:30+00')::text);
select results_eq(
  $$ select status, amount_aed, fx_rate, amount_aed_is_estimate from pg_temp.txn('inr') $$,
  $$ values ('pending'::text, 42.05::numeric(14,2), 0.05::numeric, true) $$,
  'a pending INR SMS uses the statement rate (840.96 × 0.05), not fx_rates');
select lives_ok($$ select public.upsert_fx_rates('{"INR": 0.04}'::jsonb, 'test', '2026-10-08') $$, 'INR rate refresh');
select is((select amount_aed from pg_temp.txn('inr')), 42.05::numeric(14,2), 're-estimation keeps the statement rate');

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

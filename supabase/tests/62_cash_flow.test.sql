-- Phase 2c (20261020130318_cash_flow): saving/support categories, v_spend's instrument and the
-- p_instruments filter, bank→card repayments, and the monthly cash flow.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.cat(p_name text) returns text language sql as $$
  select category_code from public.categories where profile_code = pg_temp.v('p') and name = p_name $$;
-- A transaction on an account, optionally filed under a category by hand.
create function pg_temp.txn(p_acc text, p_kind text, p_dir text, p_aed numeric, p_day int, p_cat text default null,
                            p_card text default null)
returns text language sql as $$
  insert into public.transactions (profile_code, account_code, card_code, status, kind, direction, txn_date,
                                   description, amount_original, currency_original, amount_aed, amount_source,
                                   manual_category_code)
  values (pg_temp.v('p'), pg_temp.v(p_acc), p_card, 'posted', p_kind, p_dir, pg_temp.v('m')::date + p_day,
          upper(p_kind) || ' ' || p_aed, p_aed, 'AED', p_aed, 'manual', pg_temp.cat(p_cat))
  returning txn_code $$;

-- ── setup: an owner, a stranger, a ledger with an ADCB card and an ADCB current account ─────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't62-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t62-' || left(pg_temp.v('uid'), 8), 'Cash flow'));
select pg_temp.set('bank', public.create_bank_account(pg_temp.v('p'), 'ADCB', 'current', '310001'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ADCB')
returning pg_temp.set('card', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), pg_temp.v('card'), 'ADCB', '9208');
insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), pg_temp.v('bank'), 'ADCB', '9211')
returning pg_temp.set('debit_card', card_code);
select pg_temp.set('m', date_trunc('month', public.dubai_date(now()) - 40)::date::text);

-- ── categories ──────────────────────────────────────────────────────────────
select results_eq(
  $$ select name, kind from public.categories
     where profile_code = pg_temp.v('p') and name in ('Salary', 'Transfers', 'Family support', 'Savings & investing')
     order by sort_order $$,
  $$ values ('Salary'::text, 'income'::text), ('Transfers', 'transfer'), ('Family support', 'support'),
            ('Savings & investing', 'saving') $$,
  'a new ledger gets Salary, Transfers, Family support and Savings & investing');

-- ── one month of money ──────────────────────────────────────────────────────
select pg_temp.set('card_buy', pg_temp.txn('card', 'purchase', 'debit', 100.00, 2));
select pg_temp.set('debit_buy', pg_temp.txn('bank', 'purchase', 'debit', 40.00, 3, null, pg_temp.v('debit_card')));
select pg_temp.txn('bank', 'transfer_in', 'credit', 50000.00, 1, 'Salary');
select pg_temp.txn('bank', 'transfer_out', 'debit', 23700.00, 2, 'Family support');
select pg_temp.txn('bank', 'transfer_out', 'debit', 7400.00, 2, 'Savings & investing');
select pg_temp.set('repay_out', pg_temp.txn('bank', 'transfer_out', 'debit', 7065.00, 10));
select pg_temp.set('repay_in', pg_temp.txn('card', 'payment', 'credit', 7065.00, 11));
select pg_temp.txn('bank', 'transfer_out', 'debit', 500.00, 12);
select pg_temp.txn('bank', 'transfer_in', 'credit', 1000.00, 13, 'Transfers');
select pg_temp.txn('bank', 'transfer_out', 'debit', 1200.00, 14, 'Utilities');

-- ── v_spend ─────────────────────────────────────────────────────────────────
select results_eq(
  $$ select txn_code, instrument from public.v_spend where profile_code = pg_temp.v('p') order by spend_aed desc $$,
  $$ values (pg_temp.v('card_buy'), 'credit_card'::text), (pg_temp.v('debit_buy'), 'debit_card'::text) $$,
  'spend is the two purchases, each with its instrument; no transfer is spend');

select pg_temp.as_user('uid');
set local role authenticated;
select is((public.spend_breakdown(pg_temp.v('p'), pg_temp.v('m')::date, pg_temp.v('m')::date + 27, 'category',
                                  p_instruments => array['debit_card'])->>'total')::numeric, 40.00,
          'spend_breakdown: debit cards only');
select is((select sum(amount) from public.spend_series(pg_temp.v('p'), pg_temp.v('m')::date, pg_temp.v('m')::date + 27,
                                                       p_instruments => array['credit_card'])), 100.00::numeric,
          'spend_series: credit cards only');
select is((select sum(amount) from public.spend_series(pg_temp.v('p'), pg_temp.v('m')::date, pg_temp.v('m')::date + 27)),
          140.00::numeric, 'no filter: both, as before');
reset role;

-- ── repayments ──────────────────────────────────────────────────────────────
select results_eq(
  $$ select from_txn_code, to_txn_code from public.card_transfers where profile_code = pg_temp.v('p') $$,
  $$ values (pg_temp.v('repay_out'), pg_temp.v('repay_in')) $$,
  'a bank transfer and the card payment of the same amount a day later are one repayment');

-- ── cash flow ───────────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select results_eq(
  $$ select flow, amount_aed from public.cash_flow(pg_temp.v('p'), pg_temp.v('m')::date, pg_temp.v('m')::date + 27)
     order by flow $$,
  $$ values ('card_repayment'::text, 7065.00::numeric), ('income', 50000.00), ('internal_in', 1000.00),
            ('money_out', 500.00), ('net', 17060.00), ('saving', 7400.00), ('spend', 140.00),
            ('spend_transfer', 1200.00), ('support', 23700.00) $$,
  'each flow, and net = 50,000 in − 140 spend − 1,200 by transfer − 23,700 support − 7,400 saving − 500 unfiled');
reset role;

select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select * from public.cash_flow(pg_temp.v('p'), pg_temp.v('m')::date, pg_temp.v('m')::date + 27) $$,
                 '42501', null, 'a stranger cannot read the ledger''s cash flow');
select is((select count(*)::int from public.v_cash_flow where profile_code = pg_temp.v('p')), 0,
          'nor its rows');
reset role;

select * from finish();
rollback;

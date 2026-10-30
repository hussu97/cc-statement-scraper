-- Wealth mode (20261020162834_wealth_mode): the spending scope, a bank account's ledger with
-- running balances, end-of-day balances, net worth and its series, cash flow per account with
-- partial months, and the wealth insights.
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
-- A posted AED transaction at 10:00 Dubai on a day (an offset from the month m), optionally filed.
create function pg_temp.txn(p_acc text, p_kind text, p_dir text, p_aed numeric, p_day date, p_cat text default null,
                            p_desc text default null)
returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, txn_at,
                                   description, amount_original, currency_original, amount_aed, amount_source,
                                   manual_category_code)
  values (pg_temp.v('p'), pg_temp.v(p_acc), 'posted', p_kind, p_dir, p_day,
          (p_day + time '10:00') at time zone 'Asia/Dubai',
          coalesce(p_desc, upper(p_kind) || ' ' || p_aed), p_aed, 'AED', p_aed, 'manual', pg_temp.cat(p_cat))
  returning txn_code $$;
create function pg_temp.at(p_day date, p_time time) returns timestamptz language sql as $$
  select (p_day + p_time) at time zone 'Asia/Dubai' $$;

-- ── setup: an owner, a stranger; a card, a current account and a salary account ──────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't64-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t64-' || left(pg_temp.v('uid'), 8), 'Wealth'));
select pg_temp.set('bank', public.create_bank_account(pg_temp.v('p'), 'ADCB', 'current', '310001'));
select pg_temp.set('sal', public.create_bank_account(pg_temp.v('p'), 'FAB', 'current', '220002', 'FAB salary'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code, nickname) values (pg_temp.v('p'), 'ADCB', 'ADCB card')
returning pg_temp.set('card', account_code);
select pg_temp.set('m', date_trunc('month', public.dubai_date(now()) - 40)::date::text);
select pg_temp.set('m0', (pg_temp.v('m')::date - interval '1 month')::date::text);

-- ── one month on the current account, two checkpoints ───────────────────────
--   m+0  salary   +50,000      → 51,450   (anchored on cp1: 30,000 + 21,450)
--   m+1  support  −21,450      → 30,000
--   m+2  cp1 (manual) 30,000 at noon
--   m+3  debit buy −40         → 29,000   (anchored on cp2, the next checkpoint: the bank's figure wins)
--   m+5  cp2 (manual) 29,000
--   m+6  transfer in +1,000    → 30,000   (after the latest checkpoint)
select pg_temp.set('t1', pg_temp.txn('bank', 'transfer_in', 'credit', 50000.00, pg_temp.v('m')::date, 'Salary'));
select pg_temp.set('t2', pg_temp.txn('bank', 'transfer_out', 'debit', 21450.00, pg_temp.v('m')::date + 1, 'Family support'));
select pg_temp.set('t3', pg_temp.txn('bank', 'purchase', 'debit', 40.00, pg_temp.v('m')::date + 3));
select pg_temp.set('t4', pg_temp.txn('bank', 'transfer_in', 'credit', 1000.00, pg_temp.v('m')::date + 6));
select pg_temp.set('c1', pg_temp.txn('card', 'purchase', 'debit', 100.00, pg_temp.v('m')::date + 2));
select pg_temp.set('c0', pg_temp.txn('card', 'purchase', 'debit', 75.00, pg_temp.v('m0')::date + 2));
select pg_temp.as_user('uid');
set local role authenticated;
select public.record_balance(pg_temp.v('p'), pg_temp.v('bank'), '30000.00', pg_temp.at(pg_temp.v('m')::date + 2, '12:00'));
select public.record_balance(pg_temp.v('p'), pg_temp.v('bank'), '29000.00', pg_temp.at(pg_temp.v('m')::date + 5, '12:00'));
reset role;

-- ── spending scope ──────────────────────────────────────────────────────────
select results_eq(
  $$ select txn_code, account_kind, in_spending from public.v_transactions
     where txn_code in (pg_temp.v('t1'), pg_temp.v('t3'), pg_temp.v('c1')) order by amount_aed desc $$,
  $$ values (pg_temp.v('t1'), 'current'::text, false), (pg_temp.v('c1'), 'credit_card', true),
            (pg_temp.v('t3'), 'current', true) $$,
  'a card row and a debit purchase are spending; a salary transfer is not');
select pg_temp.as_user('uid');
set local role authenticated;
select is((public.activity_summary(pg_temp.v('p'), p_scope => 'spending')->>'txn_count')::int, 3,
          'activity_summary, spending scope: the two card purchases and the debit purchase');
select is((public.activity_summary(pg_temp.v('p'))->>'txn_count')::int, 6, 'no scope: every row, as before');
select is((select count(*)::int from public.activity_day_totals(pg_temp.v('p'), '{"scope":"spending"}'::jsonb,
                                                                  array[pg_temp.v('m')::date])), 0,
          'the day of the salary has no spending rows');
select throws_ok($$ select public.activity_summary(pg_temp.v('p'), p_scope => 'wealth') $$, '22023', null,
                 'an unknown scope is refused');

-- ── account_ledger ──────────────────────────────────────────────────────────
select results_eq(
  $$ select l->>'opening_balance', l->>'closing_balance', l->>'money_in', l->>'money_out', (l->>'unpriced_count')::int
     from (select public.account_ledger(pg_temp.v('p'), pg_temp.v('bank'), pg_temp.v('m')::date, pg_temp.v('m')::date + 27) l) x $$,
  $$ values ('1450.00'::text, '30000.00'::text, '51000.00'::text, '21490.00'::text, 0) $$,
  'opening 1,450, closing 30,000, 51,000 in, 21,490 out');
select results_eq(
  $$ select r->>'txn_code', r->>'flow', r->>'amount', r->>'balance_after'
     from jsonb_array_elements(public.account_ledger(pg_temp.v('p'), pg_temp.v('bank'), pg_temp.v('m')::date,
                                                     pg_temp.v('m')::date + 27)->'rows') with ordinality a(r, n)
     order by n $$,
  $$ values (pg_temp.v('t4'), 'money_in'::text, '1000.00'::text, '30000.00'::text),
            (pg_temp.v('t3'), 'spend', '40.00', '29000.00'),
            (pg_temp.v('t2'), 'support', '21450.00', '30000.00'),
            (pg_temp.v('t1'), 'income', '50000.00', '51450.00') $$,
  'newest first, each with its flow and the balance after it, anchored on the next checkpoint');
select is(jsonb_array_length(public.account_ledger(pg_temp.v('p'), pg_temp.v('bank'), pg_temp.v('m')::date + 1,
                                                   pg_temp.v('m')::date + 1)->'rows'), 1, 'the period bounds the rows');
select throws_ok($$ select public.account_ledger(pg_temp.v('p'), pg_temp.v('card'), pg_temp.v('m')::date, pg_temp.v('m')::date) $$,
                 'P0002', null, 'a card has no bank ledger');

-- ── bank_balance_series ─────────────────────────────────────────────────────
select results_eq(
  $$ select x->>'date', x->>'balance'
     from jsonb_array_elements(public.bank_balance_series(pg_temp.v('p'), pg_temp.v('bank'), pg_temp.v('m')::date - 1,
                                                          pg_temp.v('m')::date + 6)) x $$,
  $$ values ((pg_temp.v('m')::date - 1)::text, null::text), (pg_temp.v('m')::date::text, '51450.00'),
            ((pg_temp.v('m')::date + 1)::text, '30000.00'), ((pg_temp.v('m')::date + 2)::text, '29040.00'),
            ((pg_temp.v('m')::date + 3)::text, '29000.00'), ((pg_temp.v('m')::date + 4)::text, '29000.00'),
            ((pg_temp.v('m')::date + 5)::text, '29000.00'), ((pg_temp.v('m')::date + 6)::text, '30000.00') $$,
  'end-of-day balances: unknown before the first evidence; the 960 gap falls between the checkpoints');
reset role;

-- ── net worth ───────────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select results_eq(
  $$ select n->>'cash_aed', (n->>'cash_complete')::boolean, (n->>'cash_missing_count')::int, n->>'owed_aed',
            (n->>'owed_complete')::boolean, n->>'net_aed', (n->>'complete')::boolean, jsonb_array_length(n->'cards')
     from (select public.net_worth(pg_temp.v('p')) n) x $$,
  $$ values ('30000.00'::text, false, 1, '0.00'::text, false, '30000.00'::text, false, 1) $$,
  'net worth: 30,000 cash (the salary account has no balance yet), the card unanchored, so not complete');
reset role;
insert into public.net_worth_snapshots (profile_code, snap_date, cash_aed, owed_aed, net_aed, complete)
values (pg_temp.v('p'), pg_temp.v('m')::date + 3, 1000, 400, 600, true),
       (pg_temp.v('p'), pg_temp.v('m')::date + 20, 2000, 500, 1500, true);
select pg_temp.as_user('uid');
set local role authenticated;
select results_eq(
  $$ select x->>'month', x->>'net_aed', (x->>'is_live')::boolean
     from jsonb_array_elements(public.net_worth_series(pg_temp.v('p'), 12)) x $$,
  $$ values (pg_temp.v('m'), '1500.00'::text, false),
            (date_trunc('month', public.dubai_date(now()))::date::text, '30000.00', true) $$,
  'series: the month''s last snapshot, then this month live');
select is((select count(*)::int from public.net_worth_snapshots where profile_code = pg_temp.v('p')), 2,
          'members read their snapshots');
reset role;
select private.snapshot_net_worth(pg_temp.v('p'));
select private.snapshot_net_worth(pg_temp.v('p'));
select is((select count(*)::int from public.net_worth_snapshots
           where profile_code = pg_temp.v('p') and snap_date = public.dubai_date(now())), 1,
          'one snapshot a day, rewritten');

-- ── cash flow: per account, partial months ──────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select results_eq(
  $$ select month, flow, amount_aed, is_partial
     from public.cash_flow(pg_temp.v('p'), pg_temp.v('m0')::date, pg_temp.v('m')::date + 27) where flow in ('net', 'spend')
     order by month, flow $$,
  $$ values (pg_temp.v('m0')::date, 'net'::text, -75.00::numeric, true), (pg_temp.v('m0')::date, 'spend', 75.00, true),
            (pg_temp.v('m')::date, 'net', 29410.00, false), (pg_temp.v('m')::date, 'spend', 140.00, false) $$,
  'the month before any bank evidence is partial; the first covered month is not');
select results_eq(
  $$ select flow, amount_aed from public.cash_flow(pg_temp.v('p'), pg_temp.v('m')::date, pg_temp.v('m')::date + 27,
                                                    pg_temp.v('bank')) order by flow $$,
  $$ values ('income'::text, 50000.00::numeric), ('money_in', 1000.00), ('net', 29510.00), ('spend', 40.00),
            ('support', 21450.00) $$,
  'one account: its own flows, without the card''s spend');
reset role;

select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select public.account_ledger(pg_temp.v('p'), pg_temp.v('bank'), pg_temp.v('m')::date, pg_temp.v('m')::date) $$,
                 '42501', null, 'a stranger cannot read the ledger');
select throws_ok($$ select public.net_worth(pg_temp.v('p')) $$, '42501', null, 'nor its net worth');
select is((select count(*)::int from public.net_worth_snapshots where profile_code = pg_temp.v('p')), 0, 'nor its snapshots');
reset role;
select set_config('request.jwt.claims', '', true);

-- ── insights ────────────────────────────────────────────────────────────────
-- Drift: an SMS balance 8 days ago that is 250 below the manual one 12 days ago plus the alerts between.
select pg_temp.set('today', public.dubai_date(now())::text);
select pg_temp.txn('bank', 'transfer_out', 'debit', 500.00, pg_temp.v('today')::date - 10);
insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source)
values (pg_temp.v('p'), pg_temp.v('bank'), pg_temp.at(pg_temp.v('today')::date - 12, '09:00'), 20000.00, 'manual');
insert into public.sms_messages (profile_code, client_msg_id, received_at, sender, body, body_hash, parse_status)
values (pg_temp.v('p'), gen_random_uuid(), pg_temp.at(pg_temp.v('today')::date - 8, '09:00'), 'ADCBAlert',
        't64 balance alert', 't64-hash', 'ignored')
returning pg_temp.set('sms', sms_code);
insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source, sms_code)
values (pg_temp.v('p'), pg_temp.v('bank'), pg_temp.at(pg_temp.v('today')::date - 8, '09:00'), 19250.00, 'sms', pg_temp.v('sms'))
returning pg_temp.set('cp_sms', checkpoint_code);
-- Salary history on the FAB account: the 1st of each of the last three months, none this month.
select pg_temp.txn('sal', 'transfer_in', 'credit', 30000.00,
                   (date_trunc('month', pg_temp.v('today')::date) - make_interval(months => i))::date, 'Salary')
from generate_series(1, 3) i;
-- An annual fee two weeks ago on the card, against 100 of cashback.
select pg_temp.txn('card', 'fee', 'debit', 750.00, pg_temp.v('today')::date - 14, null, 'ANNUAL FEE');
select pg_temp.txn('card', 'fee', 'debit', 37.50, pg_temp.v('today')::date - 14, null, 'VAT ON ANNUAL FEE');
select pg_temp.txn('card', 'refund', 'credit', 100.00, pg_temp.v('today')::date - 20, 'Cashback', 'CASHBACK');

select private.generate_insights(pg_temp.v('p'));
select results_eq(
  $$ select kind, title from public.insights where profile_code = pg_temp.v('p')
       and kind in ('balance_stale', 'balance_drift', 'annual_fee') order by kind, title $$,
  $$ values ('annual_fee'::text, 'ADCB card: AED 788 fee, AED 100 back'::text),
            ('balance_drift', 'ADCB Current ··310001: AED 250 unaccounted for'),
            ('balance_stale', 'ADCB Current ··310001 balance is 8 days old'),
            ('balance_stale', 'No balance yet for FAB salary') $$,
  'an annual fee above cashback, a missed alert, a stale and a missing balance');
select is((select data->>'difference' from public.insights where profile_code = pg_temp.v('p') and kind = 'balance_drift'),
          '-250.00', 'the drift is money out');
select is((select count(*)::int from public.insights where profile_code = pg_temp.v('p') and kind = 'salary_late'),
          case when extract(day from public.dubai_date(now())) > 4 then 1 else 0 end,
          'salary late once the 1st plus three days has passed with no salary this month');

-- A fresh balance retires the stale card; a salary arriving retires the late one.
select pg_temp.as_user('uid');
set local role authenticated;
select public.record_balance(pg_temp.v('p'), pg_temp.v('bank'), '19000.00');
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.txn('sal', 'transfer_in', 'credit', 30000.00, pg_temp.v('today')::date, 'Salary');
select private.generate_insights(pg_temp.v('p'));
select results_eq(
  $$ select kind, title from public.insights where profile_code = pg_temp.v('p')
       and kind in ('balance_stale', 'salary_late') order by title $$,
  $$ values ('balance_stale'::text, 'No balance yet for FAB salary'::text) $$,
  'only the account still without a balance remains; salary landed');

select * from finish();
rollback;

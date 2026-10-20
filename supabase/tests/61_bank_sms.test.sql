-- Phase 2b (20261020120744_bank_sms_capture): debit-card and account alerts become transactions
-- on the ledger's bank accounts. A ledger with an ADCB credit card (•3687), an ADCB current
-- account (…810001) and a FAB savings account (…9001).
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.sms(p_sender text, p_body text, p_at timestamptz) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', p_sender, 'body', p_body))) -> 0
$$;
-- The newest message with this body.
create function pg_temp.msg(p_body text) returns public.sms_messages language sql as $$
  select * from public.sms_messages where profile_code = pg_temp.v('p') and body = p_body
  order by received_at desc, sms_code desc limit 1 $$;
create function pg_temp.txn_of(p_body text) returns public.transactions language sql as $$
  select t.* from public.transactions t
  join public.transaction_evidence e on e.txn_code = t.txn_code and e.is_active and e.role = 'primary'
  where e.sms_code = (pg_temp.msg(p_body)).sms_code $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't61-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't61-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t61-' || left(pg_temp.v('uid'), 8), 'Bank SMS'));
select pg_temp.set('cur', public.create_bank_account(pg_temp.v('p'), 'ADCB', 'current', '810001', 'Salary'));
select pg_temp.set('sav', public.create_bank_account(pg_temp.v('p'), 'FAB', 'savings', '9001'));
reset role;
insert into public.accounts (profile_code, bank_code, nickname)
values (pg_temp.v('p'), 'ADCB', 'ADCB card') returning pg_temp.set('card_acc', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4)
values (pg_temp.v('p'), pg_temp.v('card_acc'), 'ADCB', '3687');

-- Fixed times (yesterday 06:00 Dubai), so which balance is newest never depends on the clock.
select pg_temp.set('t0', ((((now() at time zone 'Asia/Dubai')::date - 1) + time '06:00') at time zone 'Asia/Dubai')::text);
select pg_temp.set('credit', 'A Cr. transaction of AED 1100.00 on your account number XXX810001 was successful.Available balance is 1105.04.');
select pg_temp.set('debit', 'A Dr. transaction of AED 250.00 on your account number XXX810001 was successful.Available balance is 855.04.');

-- ── an account credit: money in, posted, and the balance it prints ──────────
select is(pg_temp.sms('ADCBAlert', pg_temp.v('credit'), pg_temp.v('t0')::timestamptz)->>'status', 'created',
          'an ADCB account credit becomes a transaction');
select results_eq(
  $$ select account_code, kind, direction, status, amount_aed, card_code is null
     from pg_temp.txn_of(pg_temp.v('credit')) $$,
  $$ values (pg_temp.v('cur'), 'transfer_in'::text, 'credit'::text, 'posted'::text, 1100.00::numeric, true) $$,
  'on the current account it names, as money in, posted (no statement to wait for)');
select results_eq(
  $$ select balance, source, sms_code = (pg_temp.msg(pg_temp.v('credit'))).sms_code
     from public.balance_checkpoints where account_code = pg_temp.v('cur') $$,
  $$ values (1105.04::numeric, 'sms'::text, true) $$,
  'its printed balance is a checkpoint from that SMS');
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('cur')), 1105.04::numeric,
          'the account balance is the one the bank printed');

-- ── the same alert again (both automations fired) ───────────────────────────
select is(pg_temp.sms('ADCBAlert', pg_temp.v('credit'), pg_temp.v('t0')::timestamptz + interval '20 seconds')->>'status',
          'duplicate', 'a repeat of the same alert is a duplicate');
select is((select count(*)::int from public.transactions where account_code = pg_temp.v('cur')), 1,
          'still one transaction');
select is((select count(*)::int from public.balance_checkpoints where account_code = pg_temp.v('cur')), 1,
          'and one checkpoint');

-- ── an account debit after it ───────────────────────────────────────────────
select is(pg_temp.sms('ADCBAlert', pg_temp.v('debit'), pg_temp.v('t0')::timestamptz + interval '1 hour')->>'status', 'created',
          'an ADCB account debit becomes a transaction');
select results_eq(
  $$ select kind, direction, status from pg_temp.txn_of(pg_temp.v('debit')) $$,
  $$ values ('transfer_out'::text, 'debit'::text, 'posted'::text) $$,
  'as money out');
select results_eq(
  $$ select anchor_balance, balance from public.v_bank_balances where account_code = pg_temp.v('cur') $$,
  $$ values (855.04::numeric, 855.04::numeric) $$,
  'the newer printed balance is the anchor');

-- ── a debit card on an account the ledger doesn't have yet ──────────────────
select pg_temp.set('adcb_debit', 'Debit card XXX4467 linked to acc. XXX820001 used for AED3.50 (+2.49% foreign txn fee) on '
  || to_char(pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai', 'Mon FMDD YYYY') || '  4:33PM at GOOGLEYOUTUBE M,US. Avl.Bal AED 51.54.');
select is(pg_temp.sms('ADCBAlert', pg_temp.v('adcb_debit'), pg_temp.v('t0')::timestamptz)->>'status', 'no_bank_account',
          'an alert for account …820001, which the ledger lacks, waits');
select results_eq(
  $$ select parse_status, ignore_reason, msg_kind from pg_temp.msg(pg_temp.v('adcb_debit')) $$,
  $$ values ('ignored'::text, 'no_bank_account'::text, 'debit_purchase'::text) $$,
  'ignored as no_bank_account (not routed to the only other ADCB bank account)');

select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('sav2', public.create_bank_account(pg_temp.v('p'), 'ADCB', 'savings', '820001'));
reset role;
select results_eq(
  $$ select t.account_code, t.kind, t.direction, t.status, t.amount_aed, c.last4, ca.account_code
     from pg_temp.txn_of(pg_temp.v('adcb_debit')) t
     join public.cards c on c.card_code = t.card_code
     join public.accounts ca on ca.account_code = c.account_code $$,
  $$ values (pg_temp.v('sav2'), 'purchase'::text, 'debit'::text, 'posted'::text, 3.50::numeric, '4467'::text, pg_temp.v('sav2')) $$,
  'adding the account re-runs it: a posted purchase on …820001, with debit card •4467 registered there');
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('sav2')), 51.54::numeric,
          'and its printed balance');
select ok(exists (select 1 from public.v_spend where txn_code = (pg_temp.txn_of(pg_temp.v('adcb_debit'))).txn_code),
          'a debit-card purchase counts as spend');
select ok(not exists (select 1 from public.v_spend s join public.transactions t using (txn_code)
                      where t.account_code = pg_temp.v('cur')),
          'account credits and debits do not');

-- ── FAB: a debit card with no account digits, and an outward remittance ─────
select pg_temp.set('fab_debit', E'Debit Card Purchase\nCard No XXXX1234\nAED 20.00\nCARREFOUR DUBAI\n'
  || to_char(pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai', 'DD/MM/YY') || E' 10:40\nAvl Bal AED 100.00');
select is(pg_temp.sms('FAB', pg_temp.v('fab_debit'), pg_temp.v('t0')::timestamptz)->>'status', 'created',
          'a FAB debit-card purchase is captured');
select results_eq(
  $$ select t.account_code, c.last4 from pg_temp.txn_of(pg_temp.v('fab_debit')) t join public.cards c using (card_code) $$,
  $$ values (pg_temp.v('sav'), '1234'::text) $$,
  'with no account digits it goes to FAB''s only bank account, and the card joins it');

select pg_temp.set('fab_remit', E'Outward Remittance Debit\nAccount XXXX9001\nAED 2100.00\nDate '
  || to_char(pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai', 'DD/MM/YYYY') || E'\nBalance AED 3644.98');
select is(pg_temp.sms('FAB', pg_temp.v('fab_remit'), pg_temp.v('t0')::timestamptz + interval '6 hours')->>'status', 'created',
          'a FAB outward remittance is captured');
select results_eq(
  $$ select account_code, kind, direction from pg_temp.txn_of(pg_temp.v('fab_remit')) $$,
  $$ values (pg_temp.v('sav'), 'transfer_out'::text, 'debit'::text) $$,
  'as money out of the savings account');
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('sav')), 3644.98::numeric,
          'its balance line is the newest checkpoint');

-- ── cards are unaffected ────────────────────────────────────────────────────
select pg_temp.set('card_sms', 'Credit Card XX3687 was used for AED52.25 on '
  || to_char(pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai', 'DD/MM/YYYY') || ' 10:00:00 at CARREFOUR, DUBAI-AE. Available limit  AED19947.75');
select pg_temp.sms('ADCBAlert', pg_temp.v('card_sms'), pg_temp.v('t0')::timestamptz);
select results_eq(
  $$ select account_code, status from pg_temp.txn_of(pg_temp.v('card_sms')) $$,
  $$ values (pg_temp.v('card_acc'), 'pending'::text) $$,
  'an ADCB credit-card alert still goes to the card, pending until its statement');

-- A debit card whose digits match the credit card's never lands on the card account.
select pg_temp.set('clash', 'Debit card XXX3687 linked to acc. XXX810001 used for AED9.00 on '
  || to_char(pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai', 'Mon FMDD YYYY') || '  9:15AM at ZOOM,US. Avl.Bal AED 846.04.');
select pg_temp.sms('ADCBAlert', pg_temp.v('clash'), pg_temp.v('t0')::timestamptz + interval '90 minutes');
select results_eq(
  $$ select account_code, card_code is null from pg_temp.txn_of(pg_temp.v('clash')) $$,
  $$ values (pg_temp.v('cur'), true) $$,
  'a debit card sharing a credit card''s digits stays on its bank account, without a card');

-- ── FAB salary, and a transfer to the ledger's own Wio account (real formats, 2026-10-20) ─────
select pg_temp.set('salary', E'Salary Credit\nAccount XXXX9001\nAED 52290.00\n'
  || to_char(pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai', 'DD/MM/YYYY') || E'\nBalance AED 55521.07');
select is(pg_temp.sms('FAB', pg_temp.v('salary'), pg_temp.v('t0')::timestamptz + interval '7 hours')->>'status', 'created',
          'a FAB salary credit is captured');
select results_eq(
  $$ select t.account_code, t.kind, t.description, c.name, c.kind
     from pg_temp.txn_of(pg_temp.v('salary')) t left join public.categories c on c.category_code = t.effective_category_code $$,
  $$ values (pg_temp.v('sav'), 'transfer_in'::text, 'SALARY CREDIT'::text, 'Salary'::text, 'income'::text) $$,
  'on FAB …9001, filed under Salary by the seed rule');

select pg_temp.set('notice', 'Dear Customer, your funds transfer request of  AED 50,000.00 to IBAN/Account/Card XXXX2289  has been processed successfully from your account/ card XXXX9001 on '
  || to_char(pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai', 'DD/MM/YYYY') || ' 13:58');
select is(pg_temp.sms('FAB', pg_temp.v('notice'), pg_temp.v('t0')::timestamptz + interval '8 hours')->>'status', 'noted',
          'the funds-transfer notice is noted, not a transaction');
select results_eq(
  $$ select parse_status, msg_kind, account_code, parsed_fields->>'counterparty_ref' from pg_temp.msg(pg_temp.v('notice')) $$,
  $$ values ('parsed'::text, 'transfer_notice'::text, pg_temp.v('sav'), '2289'::text) $$,
  'parsed against FAB …9001, naming …2289');
select pg_temp.set('to_wio', E'Outward Remittance Debit\nAccount XXXX9001\nAED 50000.00\nDate '
  || to_char(pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai', 'DD/MM/YYYY') || E'\nBalance AED 5520.58');
select pg_temp.sms('FAB', pg_temp.v('to_wio'), pg_temp.v('t0')::timestamptz + interval '8 hours 1 minute');
select is((select flow from public.v_cash_flow where txn_code = (pg_temp.txn_of(pg_temp.v('to_wio'))).txn_code),
          'money_out', 'with no …2289 account in the ledger, the 50,000 is unfiled money out');

select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('wio', public.create_bank_account(pg_temp.v('p'), 'WIO', 'current', '2289', 'Wio'));
reset role;
select is((select flow from public.v_cash_flow where txn_code = (pg_temp.txn_of(pg_temp.v('to_wio'))).txn_code),
          'internal_out', 'once Wio …2289 is in the ledger, the notice makes it a move between own accounts');
insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                 amount_original, currency_original, amount_aed, amount_source)
values (pg_temp.v('p'), pg_temp.v('wio'), 'posted', 'transfer_in', 'credit',
        (pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai')::date, 'ACCOUNT CREDIT', 50000, 'AED', 50000, 'manual')
returning pg_temp.set('wio_in', txn_code);
select is((select flow from public.v_cash_flow where txn_code = pg_temp.v('wio_in')), 'internal_in',
          'Wio''s side of the same 50,000 is a move in, not new money');

-- ── the old "(ignored)" templates stepped aside ─────────────────────────────
select is((select count(*)::int from public.sms_templates
           where name in ('ADCB account credit/debit (ignored)', 'ADCB debit card purchase (ignored)',
                          'FAB debit card purchase (ignored)', 'FAB outward remittance (ignored)',
                          'FAB funds transfer (ignored)') and active), 0,
          'the seeded ignored debit and account templates are off');

select * from finish();
rollback;

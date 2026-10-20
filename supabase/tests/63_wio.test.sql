-- Wio (20261020154502_wio_accounts), from real Wio alerts: a debit account (…2289) and Wio Credit,
-- a credit line (account …5059, card 3424) that pays the other cards and is cleared by autopay.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.sms(p_body text, p_at timestamptz) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', 'WioPersonal', 'body', p_body))) -> 0
$$;
create function pg_temp.txn(p_body text) returns public.transactions language sql as $$
  select t.* from public.transactions t
  join public.transaction_evidence e on e.txn_code = t.txn_code and e.is_active and e.role = 'primary'
  join public.sms_messages s on s.sms_code = e.sms_code
  where s.profile_code = pg_temp.v('p') and s.body = p_body $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't63-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't63-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t63-' || left(pg_temp.v('uid'), 8), 'Wio'));
select pg_temp.set('debit', public.create_bank_account(pg_temp.v('p'), 'WIO', 'current', '2289', 'Wio'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code, nickname, account_ref) values (pg_temp.v('p'), 'WIO', 'Wio Credit', '5059')
returning pg_temp.set('credit', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), pg_temp.v('credit'), 'WIO', '3424');
insert into public.accounts (profile_code, bank_code, nickname) values (pg_temp.v('p'), 'SIB', 'SIB card')
returning pg_temp.set('sib', account_code);
select pg_temp.set('t0', ((((now() at time zone 'Asia/Dubai')::date - 2) + time '10:00') at time zone 'Asia/Dubai')::text);

-- ── Wio Credit pays another card ────────────────────────────────────────────
select pg_temp.set('pay_sib', 'Your local transfer of AED 468 to Hussain Fahim Akhter from your account number 39XXXX5059 was processed.');
select is(pg_temp.sms(pg_temp.v('pay_sib'), pg_temp.v('t0')::timestamptz)->>'status', 'created',
          'a local transfer from Wio Credit is captured');
select results_eq(
  $$ select account_code, kind, direction, status, amount_aed, description from pg_temp.txn(pg_temp.v('pay_sib')) $$,
  $$ values (pg_temp.v('credit'), 'transfer_out'::text, 'debit'::text, 'posted'::text, 468.00::numeric, 'HUSSAIN FAHIM AKHTER'::text) $$,
  'on Wio Credit (…5059, a credit_card account), posted');
insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                 amount_original, currency_original, amount_aed, amount_source)
values (pg_temp.v('p'), pg_temp.v('sib'), 'posted', 'payment', 'credit',
        (pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai')::date + 1, 'CREDIT CARD PAYMENT', 468, 'AED', 468, 'manual')
returning pg_temp.set('sib_payment', txn_code);
select results_eq(
  $$ select from_txn_code, to_txn_code from public.card_transfers where profile_code = pg_temp.v('p') $$,
  $$ values ((pg_temp.txn(pg_temp.v('pay_sib'))).txn_code, pg_temp.v('sib_payment')) $$,
  'the SIB payment a day later pairs with it: a repayment, counted once');
select ok(not exists (select 1 from public.v_cash_flow where txn_code = (pg_temp.txn(pg_temp.v('pay_sib'))).txn_code),
          'a credit line paying a card is not cash flow (debt moved between cards)');

-- ── the debit account ───────────────────────────────────────────────────────
select pg_temp.set('father', 'Your local transfer of AED 23,700 to Fahim Akhter Shabbir Abbasi from your account number 63XXXX2289 was processed.');
select pg_temp.sms(pg_temp.v('father'), pg_temp.v('t0')::timestamptz + interval '1 hour');
select results_eq(
  $$ select account_code, kind, description from pg_temp.txn(pg_temp.v('father')) $$,
  $$ values (pg_temp.v('debit'), 'transfer_out'::text, 'FAHIM AKHTER SHABBIR ABBASI'::text) $$,
  'a transfer from the debit account names its recipient, so it can be filed once like a merchant');
select is((select flow from public.v_cash_flow where txn_code = (pg_temp.txn(pg_temp.v('father'))).txn_code), 'money_out',
          'unfiled until the recipient is filed');

select pg_temp.set('intl', 'You have initiated an international transfer of USD 15,000 to HUSSAIN FAHIM AKHTER ABBASI. AED 55,162.50 will be debited from your AED account.');
select pg_temp.sms(pg_temp.v('intl'), pg_temp.v('t0')::timestamptz + interval '2 hours');
select results_eq(
  $$ select account_code, kind, amount_aed, currency_original from pg_temp.txn(pg_temp.v('intl')) $$,
  $$ values (pg_temp.v('debit'), 'transfer_out'::text, 55162.50::numeric, 'AED'::text) $$,
  'an international transfer is the AED it debits, from the debit account (Wio''s only bank account)');

select pg_temp.set('cashback', 'Your AED 205.33 cashback for September has been credited to your account');
select pg_temp.sms(pg_temp.v('cashback'), pg_temp.v('t0')::timestamptz + interval '3 hours');
select results_eq(
  $$ select account_code, kind, direction, description from pg_temp.txn(pg_temp.v('cashback')) $$,
  $$ values (pg_temp.v('debit'), 'transfer_in'::text, 'credit'::text, 'CASHBACK'::text) $$,
  'cashback is money into the debit account');

-- ── Wio Credit: autopay and a purchase ──────────────────────────────────────
select pg_temp.set('autopay', 'You''ve made an autopay of AED 19,082 towards your Wio Credit balance.');
select pg_temp.sms(pg_temp.v('autopay'), pg_temp.v('t0')::timestamptz + interval '4 hours');
select results_eq(
  $$ select account_code, kind, direction, amount_aed from pg_temp.txn(pg_temp.v('autopay')) $$,
  $$ values (pg_temp.v('credit'), 'payment'::text, 'credit'::text, 19082.00::numeric) $$,
  'the autopay is a payment on Wio Credit');

select pg_temp.set('rl360', 'Payment of USD 2,000 (AED 7,400) was done at RI using your Wio Personal card 3424 with Credit money');
select pg_temp.sms(pg_temp.v('rl360'), pg_temp.v('t0')::timestamptz + interval '5 hours');
select results_eq(
  $$ select t.account_code, t.kind, t.amount_aed, t.currency_original, c.last4
     from pg_temp.txn(pg_temp.v('rl360')) t join public.cards c using (card_code) $$,
  $$ values (pg_temp.v('credit'), 'purchase'::text, 7400.00::numeric, 'AED'::text, '3424'::text) $$,
  'a purchase that prints its AED amount keeps it exactly, on card 3424');

update public.transactions set manual_category_code = (select category_code from public.categories
                                                      where profile_code = pg_temp.v('p') and name = 'Savings & investing')
where txn_code = (pg_temp.txn(pg_temp.v('rl360'))).txn_code;
select results_eq(
  $$ select flow, instrument, amount_aed from public.v_cash_flow where txn_code = (pg_temp.txn(pg_temp.v('rl360'))).txn_code $$,
  $$ values ('saving'::text, 'credit_card'::text, 7400.00::numeric) $$,
  'filed under Savings & investing, the card purchase is saving in cash flow (and not spend)');
select ok(not exists (select 1 from public.v_spend where txn_code = (pg_temp.txn(pg_temp.v('rl360'))).txn_code), 'not spend');

-- ── notices ─────────────────────────────────────────────────────────────────
select is(pg_temp.sms('Your credit payment is due today. Statement amount: AED 19,082. Auto-pay will be processed at 9:00 PM tonight. You can adjust the repayment amount in the app before then.',
                      pg_temp.v('t0')::timestamptz + interval '6 hours')->>'status', 'ignored', 'the due-today notice is ignored');
select is(pg_temp.sms('DAWOUD ALI MOHAMED AHMED ALZEYOUDI has been added as a local transfer beneficiary. If it wasn''t you, reset your password right away and call us on 600 500 946',
                      pg_temp.v('t0')::timestamptz + interval '7 hours')->>'status', 'ignored', 'a new beneficiary is ignored');

select * from finish();
rollback;

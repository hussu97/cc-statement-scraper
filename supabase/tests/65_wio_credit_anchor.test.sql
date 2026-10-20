-- Wio Credit anchor and autopay leg (20261020170933_wio_credit_anchor_and_autopay): the due-today
-- SMS becomes the month-end statement that anchors what Wio Credit owes, and the autopay is money
-- out of the Wio debit account too, paired with the payment so cash flow counts it once.
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
create function pg_temp.at(p_day date, p_time time) returns timestamptz language sql as $$
  select (p_day + p_time) at time zone 'Asia/Dubai' $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't65-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't65-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t65-' || left(pg_temp.v('uid'), 8), 'Wio'));
select pg_temp.set('debit', public.create_bank_account(pg_temp.v('p'), 'WIO', 'current', '2289', 'Wio'));
reset role;
select set_config('request.jwt.claims', '', true);
-- Wio Credit as production has it, with the close day the migration sets on existing accounts.
insert into public.accounts (profile_code, bank_code, nickname, account_ref, cycle_close_day)
values (pg_temp.v('p'), 'WIO', 'Wio Credit', '5059', 31)
returning pg_temp.set('credit', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), pg_temp.v('credit'), 'WIO', '3424');

-- Last month closed on its last day; this month's 1st is the due day.
select pg_temp.set('close', ((date_trunc('month', public.dubai_date(now())) - interval '1 day')::date)::text);
select pg_temp.set('due', (pg_temp.v('close')::date + 1)::text);
insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source)
values (pg_temp.v('p'), pg_temp.v('debit'), pg_temp.at(pg_temp.v('close')::date - 5, '08:00'), 50000, 'manual');

-- ── templates ───────────────────────────────────────────────────────────────
select is((select due_on_receipt from public.sms_templates where bank_code = 'WIO' and name = 'Wio credit statement summary'),
          true, 'the Wio summary template is due on receipt');
select is((select pays_from_current_account from public.sms_templates where bank_code = 'WIO' and name = 'Wio credit autopay'),
          true, 'the Wio autopay template pays from the current account');
select ok((select body_pattern !~ 'due today' from public.sms_templates where bank_code = 'WIO' and name = 'Wio credit notices (ignored)'),
          'the due-today notice is no longer ignored');
select is(count(*)::int, 0, 'no other template uses either flag')
from public.sms_templates
where (due_on_receipt or pays_from_current_account)
  and name not in ('Wio credit statement summary', 'Wio credit autopay');
select throws_ok(
  $$ insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind, source)
     values ('WIO', 't65 summary', '^Wio', 'Statement amount: AED ([0-9,]+)', '{"amount":1}', 'statement_summary', 'seed') $$,
  '23514', null, 'a summary template without a due date still needs due_on_receipt');
select throws_ok(
  $$ insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind, source, due_on_receipt)
     values ('WIO', 't65 purchase', '^Wio', 'spent AED ([0-9,]+)', '{"amount":1}', 'purchase', 'seed', true) $$,
  '23514', null, 'due_on_receipt is for statement summaries only');
select throws_ok(
  $$ insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind, source, pays_from_current_account)
     values ('WIO', 't65 refund', '^Wio', 'refund AED ([0-9,]+)', '{"amount":1}', 'refund', 'seed', true) $$,
  '23514', null, 'pays_from_current_account is for payments only');

-- ── last month on Wio Credit ────────────────────────────────────────────────
select pg_temp.sms('Payment of USD 2,000 (AED 7,400) was done at RI using your Wio Personal card 3424 with Credit money',
                   pg_temp.at(pg_temp.v('close')::date - 10, '12:00'));
select pg_temp.sms('Your local transfer of AED 468 to Hussain Fahim Akhter from your account number 39XXXX5059 was processed.',
                   pg_temp.at(pg_temp.v('close')::date - 8, '12:00'));
select is((select anchor_kind from public.v_account_balances where account_code = pg_temp.v('credit')), 'none',
          'before the statement SMS, Wio Credit has no anchor');
select is((select private.net_worth(pg_temp.v('p'))->>'owed_complete'), 'false', 'so what is owed is incomplete');

-- ── the due-today SMS is the statement ──────────────────────────────────────
select pg_temp.set('due_sms', 'Your credit payment is due today. Statement amount: AED 19,082. Auto-pay will be processed at 9:00 PM tonight. You can adjust the repayment amount in the app before then.');
select is(pg_temp.sms(pg_temp.v('due_sms'), pg_temp.at(pg_temp.v('due')::date, '09:00'))->>'status', 'statement',
          'the due-today SMS makes a statement');
select results_eq(
  $$ select st.account_code, st.kind, st.statement_date, st.period_start, st.period_end, st.due_date, st.closing_balance,
            st.doc_code is null, st.sms_code is not null
     from public.statements st where st.profile_code = pg_temp.v('p') $$,
  $$ values (pg_temp.v('credit'), 'statement'::text, pg_temp.v('close')::date,
             date_trunc('month', pg_temp.v('close')::date)::date, pg_temp.v('close')::date, pg_temp.v('due')::date,
             19082.00::numeric, true, true) $$,
  'on Wio Credit: the cycle that closed at month end, due the day the SMS came, AED 19,082');
select is((select parsed_fields->>'due_date' from public.sms_messages
           where profile_code = pg_temp.v('p') and body = pg_temp.v('due_sms')), pg_temp.v('due'),
          'the SMS records the due date it was given');
select results_eq(
  $$ select anchor_kind, anchor_date, anchor_balance, outstanding_aed from public.v_account_balances
     where account_code = pg_temp.v('credit') $$,
  $$ values ('statement'::text, pg_temp.v('close')::date, 19082.00::numeric, 19082.00::numeric) $$,
  'v_account_balances anchors Wio Credit on it');
select is((select private.net_worth(pg_temp.v('p'))->>'owed_complete'), 'true', 'what is owed is now complete');
select is(pg_temp.sms(pg_temp.v('due_sms'), pg_temp.at(pg_temp.v('due')::date, '15:00'))->>'status', 'statement_exists',
          'a second due-today SMS the same day leaves the statement alone');

-- ── the autopay: two legs, counted once ─────────────────────────────────────
select pg_temp.set('autopay', 'You''ve made an autopay of AED 19,082 towards your Wio Credit balance.');
select is(pg_temp.sms(pg_temp.v('autopay'), pg_temp.at(pg_temp.v('due')::date, '21:00'))->>'status', 'created',
          'the autopay is captured');
select pg_temp.set('payment', (select e.txn_code from public.transaction_evidence e join public.sms_messages s using (sms_code)
                               where s.profile_code = pg_temp.v('p') and s.body = pg_temp.v('autopay') and e.is_active));
select pg_temp.set('leg', (select txn_code from public.transactions where leg_of_txn_code = pg_temp.v('payment')));
select results_eq(
  $$ select account_code, kind, direction, status, amount_aed from public.transactions where txn_code = pg_temp.v('payment') $$,
  $$ values (pg_temp.v('credit'), 'payment'::text, 'credit'::text, 'pending'::text, 19082.00::numeric) $$,
  'a payment on Wio Credit');
select results_eq(
  $$ select account_code, kind, direction, status, amount_aed, txn_date, txn_at, description
     from public.transactions where txn_code = pg_temp.v('leg') $$,
  $$ values (pg_temp.v('debit'), 'transfer_out'::text, 'debit'::text, 'posted'::text, 19082.00::numeric,
             pg_temp.v('due')::date, pg_temp.at(pg_temp.v('due')::date, '21:00'), 'AUTOPAY WIO CREDIT'::text) $$,
  'and a posted transfer_out of the same money from the Wio debit account, at the same moment');
select results_eq(
  $$ select from_txn_code, to_txn_code from public.card_transfers where profile_code = pg_temp.v('p') $$,
  $$ values (pg_temp.v('leg'), pg_temp.v('payment')) $$,
  'the two legs are paired');
select results_eq(
  $$ select txn_code, flow, amount_aed from public.v_cash_flow
     where profile_code = pg_temp.v('p') and txn_code in (pg_temp.v('leg'), pg_temp.v('payment')) $$,
  $$ values (pg_temp.v('leg'), 'card_repayment'::text, 19082.00::numeric) $$,
  'cash flow: one card repayment');
select is((select outstanding_aed from public.v_account_balances where account_code = pg_temp.v('credit')), 0.00::numeric,
          'Wio Credit owes nothing after the autopay');
select is((select balance_aed from public.v_bank_balances where account_code = pg_temp.v('debit')), 30918.00::numeric,
          'the debit account is 19,082 lower');
select is((select (r->>'balance_after') from jsonb_array_elements(
             public.account_ledger(pg_temp.v('p'), pg_temp.v('debit'), pg_temp.v('close')::date - 10, pg_temp.v('due')::date + 1)->'rows') r
           where r->>'txn_code' = pg_temp.v('leg')), '30918.00',
          'the account ledger shows the autopay with its running balance');
select is((select (r->>'flow') from jsonb_array_elements(
             public.account_ledger(pg_temp.v('p'), pg_temp.v('debit'), pg_temp.v('close')::date - 10, pg_temp.v('due')::date + 1)->'rows') r
           where r->>'txn_code' = pg_temp.v('leg')), 'card_repayment', 'as a card repayment');

-- The bank's next balance agrees: no drift.
insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source, sms_code)
values (pg_temp.v('p'), pg_temp.v('debit'), pg_temp.at(pg_temp.v('due')::date + 1, '08:00'), 30918, 'sms',
        (select sms_code from public.sms_messages where profile_code = pg_temp.v('p') and body = pg_temp.v('autopay')));
select private.generate_wealth_insights(pg_temp.v('p'));
select is((select count(*)::int from public.insights where profile_code = pg_temp.v('p') and kind = 'balance_drift'), 0,
          'the next balance matches the ledger: no balance drift');

-- ── the leg follows its payment ─────────────────────────────────────────────
update public.transactions set voided_at = now(), void_reason = 't65' where txn_code = pg_temp.v('payment');
select private.refresh_transaction(pg_temp.v('payment'));
select results_eq(
  $$ select status, void_reason from public.transactions where txn_code = pg_temp.v('leg') $$,
  $$ values ('void'::text, 'payment_gone'::text) $$,
  'a voided payment voids its leg');
select ok(not exists (select 1 from public.card_transfers where profile_code = pg_temp.v('p')), 'and unpairs them');
update public.transactions set voided_at = null, void_reason = null where txn_code = pg_temp.v('payment');
select private.refresh_transaction(pg_temp.v('payment'));
select results_eq(
  $$ select status, void_reason from public.transactions where txn_code = pg_temp.v('leg') $$,
  $$ values ('posted'::text, null::text) $$,
  'restored, the leg stands again');
select results_eq(
  $$ select from_txn_code, to_txn_code from public.card_transfers where profile_code = pg_temp.v('p') $$,
  $$ values (pg_temp.v('leg'), pg_temp.v('payment')) $$,
  'and pairs again');
select is(private.add_payment_leg(pg_temp.v('payment')), pg_temp.v('leg'), 'add_payment_leg is idempotent');
select is((select count(*)::int from public.transactions where leg_of_txn_code = pg_temp.v('payment')), 1, 'one leg');

-- ── no current account: no leg ──────────────────────────────────────────────
update public.accounts set status = 'closed' where account_code = pg_temp.v('debit');
select pg_temp.sms('You''ve made an autopay of AED 1,234 towards your Wio Credit balance.', pg_temp.at(pg_temp.v('due')::date, '22:00'));
select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p') and amount_aed = 1234 and kind = 'transfer_out'),
          0, 'without an active current account the payment has no leg');

select * from finish();
rollback;

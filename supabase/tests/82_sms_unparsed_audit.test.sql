-- The SMS clean-up of 20261102080341_sms_unparsed_audit: formats that were lost (a FAB remittance
-- with a broken first line, FAB standing instructions, Liv purchases), noise that stayed unparsed
-- (Indian adverts, a SIB reminder, LLM "not a transaction"), ENBD's mini statement as a statement
-- summary, and the fallback's proposals: reused, closed when a message parses, and reviewed when the
-- sender is not the bank's. Synthetic data throughout.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.sms(p_profile text, p_sender text, p_body text, p_at timestamptz default now()) returns jsonb
language sql as $$
  select public.ingest_sms(p_profile, jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', p_sender, 'body', p_body))) -> 0
$$;
create function pg_temp.row(p_sms text) returns public.sms_messages language sql as $$
  select * from public.sms_messages where sms_code = p_sms $$;
create function pg_temp.txn(p_sms text) returns public.transactions language sql as $$
  select t.* from public.transactions t
  join public.transaction_evidence e on e.txn_code = t.txn_code and e.is_active
  where e.sms_code = p_sms limit 1 $$;
create function pg_temp.as_user(p_uid text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true) $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't82-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't82-%' order by created_at desc limit 1));
select pg_temp.as_user(pg_temp.v('uid'));
set local role authenticated;
select pg_temp.set('p', public.create_profile('t82-' || left(pg_temp.v('uid'), 8), 'Audit'));
select pg_temp.set('q', public.create_profile('t82q-' || left(pg_temp.v('uid'), 8), 'Other'));
select pg_temp.set('fab', public.create_bank_account(pg_temp.v('p'), 'FAB', 'current', '3101', 'FAB'));
reset role;
select set_config('request.jwt.claims', '', true);

-- Dates in the bodies are yesterday (Dubai), so they sit next to the arrival time.
select pg_temp.set('d', to_char((now() at time zone 'Asia/Dubai')::date - 1, 'DD/MM/YYYY'));

-- ── 1. FAB remittance with a broken first line ──────────────────────────────
select pg_temp.set('in', pg_temp.sms(pg_temp.v('p'), 'FAB',
  E'Inward Remittance \nCredit  \nAccount XXXX3101 \nAED 250.00\nDate ' || pg_temp.v('d') || E' \nBalance AED 1234.50')->>'sms_code');
select is((pg_temp.row(pg_temp.v('in'))).msg_kind, 'account_credit', 'a split "Inward Remittance / Credit" is a remittance');
select is((pg_temp.txn(pg_temp.v('in'))).account_code, pg_temp.v('fab'), 'on the FAB account it names');
select is((pg_temp.txn(pg_temp.v('in'))).amount_aed, 250.00::numeric, 'for its amount');
select pg_temp.set('out', pg_temp.sms(pg_temp.v('p'), 'FAB',
  E'Outward Remittance \nDebit  \nAccount XXXX3101 \nAED 40.00\nDate ' || pg_temp.v('d') || E' \nBalance AED 1194.50')->>'sms_code');
select is((pg_temp.row(pg_temp.v('out'))).msg_kind, 'account_debit', 'a split "Outward Remittance / Debit" too');

-- ── 2. FAB standing instruction (20261102105907: charged to the credit card) ─
-- A profile without a FAB card account: the charge has no account to go to.
select pg_temp.set('si_q', pg_temp.sms(pg_temp.v('q'), 'FAB',
  'Dear Customer, Your standing instructions of AED 55.00 to SAMPLE UTILITY for consumer number 1000000002 has been processed on '
  || pg_temp.v('d') || '.')->>'sms_code');
select ok(exists (select 1 from public.match_reviews where subject_code = pg_temp.v('si_q') and reason = 'unknown_card'),
  'a standing instruction with no FAB card account asks which card');
insert into public.accounts (profile_code, bank_code, nickname) values (pg_temp.v('p'), 'FAB', 'FAB card')
returning pg_temp.set('fabcard', account_code);
select pg_temp.set('si', pg_temp.sms(pg_temp.v('p'), 'FAB',
  'Dear Customer, Your standing instructions of AED 123.40 to SAMPLE UTILITY for consumer number 1000000001 has been processed on '
  || pg_temp.v('d') || '.')->>'sms_code');
select results_eq(
  $$ select parse_status, msg_kind, amount, description, account_code, parsed_fields ? 'counterparty_ref'
     from public.sms_messages where sms_code = pg_temp.v('si') $$,
  $$ values ('parsed'::text, 'purchase'::text, 123.40::numeric(14,2), 'SAMPLE UTILITY'::text, pg_temp.v('fabcard'), false) $$,
  'a standing instruction is a purchase on the FAB credit card from its payee, not a debit of the FAB bank account');
select results_eq(
  $$ select account_code, kind, direction, amount_aed from public.transactions
     where txn_code = (pg_temp.txn(pg_temp.v('si'))).txn_code $$,
  $$ values (pg_temp.v('fabcard'), 'purchase'::text, 'debit'::text, 123.40::numeric(14,2)) $$,
  'and a card purchase on that account');

-- ── 3. Liv: waits for an ENBD bank account, then lands on it ─────────────────
select pg_temp.set('liv', pg_temp.sms(pg_temp.v('p'), 'Liv',
  'Purchase of USD 12.34 with Debit Card ending 9201 at SAMPLE STORE, Dublin. Avl Balance is AED 2,345.67.  Pls refer stmt for exact amt.')::text);
select is(pg_temp.v('liv')::jsonb->>'status', 'no_bank_account', 'a Liv purchase waits for its bank account');
select pg_temp.as_user(pg_temp.v('uid'));
set local role authenticated;
select pg_temp.set('enbd', public.create_bank_account(pg_temp.v('p'), 'ENBD', 'current', null, 'Liv'));
reset role;
select set_config('request.jwt.claims', '', true);
select results_eq(
  $$ select parse_status, msg_kind, currency, amount, description, account_code
     from public.sms_messages where sms_code = pg_temp.v('liv')::jsonb->>'sms_code' $$,
  $$ values ('parsed'::text, 'debit_purchase'::text, 'USD'::text, 12.34::numeric(14,2), 'SAMPLE STORE, DUBLIN'::text, pg_temp.v('enbd')) $$,
  'once the ENBD account exists, the purchase is read onto it');
select is((select last4 from public.cards where account_code = pg_temp.v('enbd')), '9201', 'with its debit card');

-- ── 4–5. noise ──────────────────────────────────────────────────────────────
select pg_temp.set('adv', pg_temp.sms(pg_temp.v('p'), 'INDUSA-P', 'Festive offers on your Debit Card: vouchers for top spenders.')->>'sms_code');
select results_eq($$ select parse_status, ignore_reason from public.sms_messages where sms_code = pg_temp.v('adv') $$,
                  $$ values ('ignored'::text, 'promotion'::text) $$, 'an Indian "-P" sender is an advert');
select is((pg_temp.row(pg_temp.sms(pg_temp.v('p'), 'INDUSB-S', 'Your debit card limits change next month.')->>'sms_code')).parse_status,
          'unparsed', 'a "-S" (service) sender is not');
select pg_temp.set('sibr', pg_temp.sms(pg_temp.v('p'), 'SIB', 'Reminder: Please update your new Covered Card details with the Merchants, Service Providers & Subscriptions for your recurring bills payment and standing orders, as your old card has been blocked.')->>'sms_code');
select results_eq($$ select parse_status, ignore_reason from public.sms_messages where sms_code = pg_temp.v('sibr') $$,
                  $$ values ('ignored'::text, 'other'::text) $$, 'SIB''s card-details reminder is an ignored notice');

-- ── 6. the LLM's "not a transaction" ─────────────────────────────────────────
select pg_temp.set('rcpt', pg_temp.sms(pg_temp.v('p'), 'SomeBiller', 'Your payment of AED 50.00 has been received.')->>'sms_code');
select is((pg_temp.row(pg_temp.v('rcpt'))).parse_status, 'unparsed', 'a biller''s receipt is unparsed');
select pg_temp.as_user(pg_temp.v('uid'));
set local role authenticated;
select throws_ok($$ select public.mark_sms_not_transaction(pg_temp.v('rcpt')) $$, '42501', null,
                 'only the worker records the LLM''s verdict');
reset role;
select set_config('request.jwt.claims', '', true);
select is(public.mark_sms_not_transaction(pg_temp.v('rcpt')), true, 'the worker records it');
select results_eq($$ select parse_status, ignore_reason from public.sms_messages where sms_code = pg_temp.v('rcpt') $$,
                  $$ values ('ignored'::text, 'llm_not_txn'::text) $$, 'the receipt is ignored');
select is(public.mark_sms_not_transaction(pg_temp.v('si')), false, 'a parsed message is left alone');

-- ── 7. ENBD mini statement → statement summary on its printed statement date ──
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ENBD');
select pg_temp.set('cc', (select account_code from public.accounts
                          where profile_code = pg_temp.v('p') and bank_code = 'ENBD' and kind = 'credit_card'));
insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), pg_temp.v('cc'), 'ENBD', '9207');
select pg_temp.set('close', ((now() at time zone 'Asia/Dubai')::date - 2)::text);
select pg_temp.set('mini', pg_temp.sms(pg_temp.v('p'), 'EmiratesNBD',
  'Emirates NBD Credit Card Mini Stmt for Card ending 9207: Statement date ' || to_char(pg_temp.v('close')::date, 'DD/MM/YY')
  || '. Total Amt Due AED 2,345.67, Due Date ' || to_char(pg_temp.v('close')::date + 25, 'DD/MM/YY')
  || '. Min Amt Due AED 117.28')->>'sms_code');
select is((pg_temp.row(pg_temp.v('mini'))).msg_kind, 'statement_summary', 'the mini statement is a statement summary');
select results_eq(
  $$ select statement_date, due_date, closing_balance, min_due, sms_code from public.statements
     where account_code = pg_temp.v('cc') and kind = 'statement' $$,
  $$ values (pg_temp.v('close')::date, pg_temp.v('close')::date + 25, 2345.67::numeric(14,2), 117.28::numeric(14,2), pg_temp.v('mini')) $$,
  'it makes the statement of the date it prints, with no cycle day known');

-- ── 8. one proposal per format ──────────────────────────────────────────────
create function pg_temp.weird(p_amount text) returns text language sql as $$
  select 'T82 odd alert paid AED ' || p_amount || ' at SAMPLE SHOP' $$;
create function pg_temp.proposal() returns jsonb language sql as $$
  select jsonb_build_object('bank_code', 'FAB', 'name', 't82 proposal', 'sender_pattern', '.*',
    'body_pattern', 'T82 odd alert paid ([A-Z]{3}) ([0-9.]+) at (.+)$',
    'field_groups', jsonb_build_object('currency', 1, 'amount', 2, 'merchant', 3), 'msg_kind', 'account_debit',
    'expect', jsonb_build_object('amount', '12.50')) $$;
select pg_temp.set('w1', pg_temp.sms(pg_temp.v('p'), 'FAB', pg_temp.weird('12.50'))->>'sms_code');
select pg_temp.set('tpl', public.propose_sms_template(pg_temp.v('w1'), pg_temp.proposal()));
select pg_temp.set('w2', pg_temp.sms(pg_temp.v('p'), 'FAB', pg_temp.weird('7.25'))->>'sms_code');
select is(public.reuse_sms_proposal(pg_temp.v('w2')), pg_temp.v('tpl'), 'the next message of the format reuses the open proposal');
select is((select candidates from public.match_reviews where subject_code = pg_temp.v('w2') and status = 'open'),
          jsonb_build_array(jsonb_build_object('template_code', pg_temp.v('tpl'))), 'in a review of its own');
select pg_temp.set('wq', pg_temp.sms(pg_temp.v('q'), 'FAB', pg_temp.weird('3.00'))->>'sms_code');
select is(public.reuse_sms_proposal(pg_temp.v('wq')), null, 'another profile''s message never reuses it');
select is(public.reuse_sms_proposal(pg_temp.v('rcpt')), null, 'nor does a message it doesn''t read');
select pg_temp.as_user(pg_temp.v('uid'));
set local role authenticated;
select throws_ok($$ select public.reuse_sms_proposal(pg_temp.v('w2')) $$, '42501', null, 'reuse is the worker''s');
select lives_ok($$ select public.set_sms_template_active(pg_temp.v('tpl'), true) $$, 'the owner approves the proposal');
reset role;
select set_config('request.jwt.claims', '', true);
select results_eq(
  $$ select sms_code, parse_status from public.sms_messages where sms_code in (pg_temp.v('w1'), pg_temp.v('w2')) order by sms_code $$,
  $$ select x, 'parsed'::text from unnest(array[pg_temp.v('w1'), pg_temp.v('w2')]) x order by x $$,
  'approving it parses both messages');
select is((select count(*)::int from public.match_reviews
           where subject_code in (pg_temp.v('w1'), pg_temp.v('w2')) and status = 'resolved' and resolved_by is not null),
          2, 'and closes both reviews as the owner''s decision');

-- ── 9. duplicate proposals close when a message parses ──────────────────────
create function pg_temp.dup(p_amount text) returns text language sql as $$
  select 'T82 second odd alert AED ' || p_amount || ' to SAMPLE PAYEE' $$;
create function pg_temp.dup_proposal() returns jsonb language sql as $$
  select jsonb_build_object('bank_code', 'FAB', 'name', 't82 duplicate', 'sender_pattern', '.*',
    'body_pattern', 'T82 second odd alert ([A-Z]{3}) ([0-9.]+) to (.+)$',
    'field_groups', jsonb_build_object('currency', 1, 'amount', 2, 'merchant', 3), 'msg_kind', 'account_debit',
    'expect', '{}'::jsonb) $$;
select pg_temp.set('d1', pg_temp.sms(pg_temp.v('p'), 'FAB', pg_temp.dup('1.00'))->>'sms_code');
select pg_temp.set('d2', pg_temp.sms(pg_temp.v('p'), 'FAB', pg_temp.dup('2.00'))->>'sms_code');
select pg_temp.set('d3', pg_temp.sms(pg_temp.v('p'), 'FAB', pg_temp.dup('3.00'))->>'sms_code');
-- As before reuse existed: one proposal per message.
select pg_temp.set('t1', public.propose_sms_template(pg_temp.v('d1'), pg_temp.dup_proposal()));
select pg_temp.set('t2', public.propose_sms_template(pg_temp.v('d2'), pg_temp.dup_proposal()));
select pg_temp.set('t3', public.propose_sms_template(pg_temp.v('d3'), pg_temp.dup_proposal()));
select pg_temp.as_user(pg_temp.v('uid'));
set local role authenticated;
select lives_ok($$ select public.set_sms_template_active(pg_temp.v('t1'), true) $$, 'the owner approves one of three');
reset role;
select set_config('request.jwt.claims', '', true);
select is((select count(*)::int from public.sms_messages
           where sms_code in (pg_temp.v('d1'), pg_temp.v('d2'), pg_temp.v('d3')) and parse_status = 'parsed'), 3,
          'all three messages parse');
select is((select count(*)::int from public.match_reviews
           where subject_code in (pg_temp.v('d1'), pg_temp.v('d2'), pg_temp.v('d3')) and status = 'open'), 0,
          'no review is left open');
select is((select resolution->>'auto' from public.match_reviews where subject_code = pg_temp.v('d2')), 'sms_parsed',
          'the duplicates'' reviews close on their own');
select is((select count(*)::int from public.sms_templates where template_code in (pg_temp.v('t2'), pg_temp.v('t3'))), 0,
          'and their proposals are deleted');
select is((select active from public.sms_templates where template_code = pg_temp.v('t1')), true, 'the approved one stays');

select * from finish();
rollback;

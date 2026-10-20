-- Real bank SMS templates (ADCB, FAB, ENBD, SIB): every captured sample is
-- classified by the intended template with the right fields, non-transaction
-- alerts are ignored (never 'unparsed', which would call the LLM), and real
-- alerts flow end to end through public.ingest_sms.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ── constraint: amount is required only for transaction kinds ──────────────
select lives_ok($$
  insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind, priority, examples)
  values ('ADCB', 'test: amountless notice', '^ADCB', 'zz amountless notice zz', '{}', 'other', 999,
          '[{"sender":"ADCBAlert","body":"zz amountless notice zz","expect":{}}]')
$$, 'an "other" template needs no amount group');
select throws_ok($$
  insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind, examples)
  values ('ADCB', 'test: amountless purchase', '^ADCB', 'Card X+([0-9]{4}) used', '{"last4":1}', 'purchase', '[]')
$$, '23514', null, 'a purchase template still requires an amount group');
select throws_ok($$
  insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind, examples)
  values ('ADCB', 'test: purchase without amount', '^ADCB', 'Card X+([0-9]{4}) used(?: for ([0-9.]+))?',
          '{"last4":1,"amount":2}', 'purchase', '[{"sender":"ADCBAlert","body":"Card XXX1234 used"}]')
$$, '22023', null, 'a purchase template whose example yields no amount is rejected');

select is((select sms_senders from public.banks where bank_code = 'ADCB'), array['ADCBAlert'], 'ADCB real sender id');
select is((select sms_senders from public.banks where bank_code = 'FAB'), array['FAB'], 'FAB real sender id');
select is((select sms_senders from public.banks where bank_code = 'ENBD'), array['EmiratesNBD'], 'ENBD real sender id');
select is((select sms_senders from public.banks where bank_code = 'SIB'), array['SIB'], 'SIB real sender id');

-- ── every real sample → intended template, kind and fields ─────────────────
create temp table cases (label text primary key, sender text, body text, kind text, tpl text, expect jsonb);
insert into cases values
 ('ADCB a', 'ADCBAlert', 'Your Cr.Card XXX3687 was used for AED46.00 on 09/08/2026 13:43:40 at Vox Cinemas,Dubai-AE. Avl. Cr.limit is AED26953.75',
  'purchase', 'ADCB credit card purchase (Cr.Card)',
  '{"amount":"46.00","currency":"AED","last4":"3687","merchant":"VOX CINEMAS,DUBAI-AE","date":"2026-08-09","time":"13:43:40","available":"26953.75"}'),
 ('ADCB b', 'ADCBAlert', 'Credit Card XX3687 was used for EGP69.94 on 09/09/2026 11:44:55 at UBER *TRIP HELP.UBER, help.uber.com-NL. Available limit  AED19965.95',
  'purchase', 'ADCB credit card purchase (Credit Card)',
  '{"amount":"69.94","currency":"EGP","last4":"3687","merchant":"UBER *TRIP HELP.UBER, HELP.UBER.COM-NL","date":"2026-09-09","time":"11:44:55","available":"19965.95"}'),
 ('ADCB c', 'ADCBAlert', 'Credit Card XX3687 was used for INR840.96 on 06/10/2026 12:43:13 at UBER * PENDING, help.uber.com-NL. Available limit AED26967.39',
  'purchase', 'ADCB credit card purchase (Credit Card)',
  '{"amount":"840.96","currency":"INR","last4":"3687","merchant":"UBER * PENDING, HELP.UBER.COM-NL","date":"2026-10-06","time":"12:43:13","available":"26967.39"}'),
 ('ADCB d', 'ADCBAlert', E'Review your transaction\nTap to approve your transaction at Vox Cinemas for AED46.00 on your ADCB Card XXX3687, valid for 10 minutes. If not initiated by you, please deny and call +971600502030',
  'other', 'ADCB card approval prompt (ignored)',
  '{"amount":"46.00","currency":"AED","last4":"3687","merchant":"VOX CINEMAS"}'),
 ('ADCB e', 'ADCBAlert', 'A Cr. transaction of AED 1100.00 on your account number XXX810001 was successful.Available balance is 1105.04.',
  'account_credit', 'ADCB account credit', '{"amount":"1100.00","currency":"AED","account_ref":"810001","available":"1105.04"}'),
 ('ADCB f', 'ADCBAlert', 'Debit card XXX4467 linked to acc. XXX820001 used for AED3.50 (+2.49% foreign txn fee) on Sep 11 2026  4:33PM at GOOGLEYOUTUBE M,US. Avl.Bal AED 51.54.',
  'debit_purchase', 'ADCB debit card purchase',
  '{"amount":"3.50","currency":"AED","last4":"4467","account_ref":"820001","merchant":"GOOGLEYOUTUBE M,US","date":"2026-09-11","time":"4:33PM","available":"51.54"}'),
 ('ADCB g', 'ADCBAlert', 'Cr.Card XXX3687 Billing alert: Total due to avoid fin. charges: AED172.09. Due date Sep 18 2026; Pay min. AED100.00 by due date to avoid AED241.50 late fee',
  'other', 'ADCB credit card billing alert (ignored)', '{"last4":"3687"}'),
 ('ADCB h', 'ADCBAlert', 'Your request to redeem TPs 5500 at Noon Food was successful on 22/09/2026 18:10:01. TPs balance: 265. Earn more with the TouchPoints app: adcb.com/tpapp',
  'other', 'ADCB TouchPoints redemption (ignored)', '{"merchant":"NOON FOOD"}'),
 ('ADCB i', 'ADCBAlert', 'Your account number XXX810001 has been inactive since 2026.01.31. Kindly make a transaction to avoid account from becoming dormant.',
  'other', 'ADCB account dormancy notice (ignored)', '{}'),
 ('FAB a', 'FAB', E'Credit Card Purchase\nCard No XXXX2777\nAED 133.96\nAPPLE.COM/BILL CORK IRL\n05/10/26 10:40\nAvl Bal AED 28335.60\nOctober statement due on 26/10/2026',
  'purchase', 'FAB credit card purchase (multi-line)',
  '{"amount":"133.96","currency":"AED","last4":"2777","merchant":"APPLE.COM/BILL CORK IRL","date":"2026-10-05","time":"10:40","available":"28335.60"}'),
 ('FAB b', 'FAB', E'October statement due on 26/10/2026\nCredit Card Purchase\nCard No XXXX2132\nUSD 6.00\nINDIGO AIRLINES NEW YORK USA\n04/10/26 10:38',
  'purchase', 'FAB credit card purchase (multi-line)',
  '{"amount":"6.00","currency":"USD","last4":"2132","merchant":"INDIGO AIRLINES NEW YORK USA","date":"2026-10-04","time":"10:38"}'),
 ('FAB c', 'FAB', E'Debit Card Purchase\nCard No XXXX1234\nAED 20.00\nCARREFOUR DUBAI\n05/10/26 10:40\nAvl Bal AED 100.00',
  'debit_purchase', 'FAB debit card purchase',
  '{"amount":"20.00","currency":"AED","last4":"1234","merchant":"CARREFOUR DUBAI","date":"2026-10-05","available":"100.00"}'),
 ('FAB d', 'FAB', E'Outward Remittance Debit\nAccount XXXX9001\nAED 2100.00\nDate 02/10/2026\nBalance AED 3644.98',
  'account_debit', 'FAB outward remittance', '{"amount":"2100.00","currency":"AED","date":"2026-10-02","account_ref":"9001","available":"3644.98"}'),
 ('FAB d2', 'FAB', E'Inward Remittance Credit\nAccount XXXX9001\nAED 500.00\nDate 03/10/2026\nBalance AED 4144.98',
  'account_credit', 'FAB inward remittance', '{"amount":"500.00","account_ref":"9001","available":"4144.98"}'),
 ('FAB e', 'FAB', 'Dear Customer, your funds transfer request of  AED 2,100.00 to IBAN/Account/Card XXXX4301  has been processed successfully from your account/ card XXXX9001 on 02/10/2026 14:19',
  'transfer_notice', 'FAB funds transfer', '{"amount":"2100.00","currency":"AED","date":"2026-10-02","time":"14:19","counterparty_ref":"4301","account_ref":"9001"}'),
 ('FAB f', 'FAB', 'Your statement of the card ending with 2777 dated 01Oct26 has been sent to you and can also be viewed in the new FAB mobile banking app. Download it from the App Store https://apple.co/FB7qEZ or Google Play https://goo.gl/7dXnNc. The total amount due is AED 515.26. Minimum due is AED 100.00. Due date is 26Oct26',
  'other', 'FAB statement issued (ignored)', '{"last4":"2777"}'),
 ('FAB g', 'FAB', 'Login detected on FAB Mobile', 'other', 'FAB login notice (ignored)', '{}'),
 ('ENBD a', 'EmiratesNBD', 'Purchase of AED 73.69 with Credit Card ending 7205 at Noon Minutes, Dubai. Avl Cr. Limit is AED 19,626.23',
  'purchase', 'ENBD credit card purchase',
  '{"amount":"73.69","currency":"AED","last4":"7205","merchant":"NOON MINUTES, DUBAI","available":"19626.23"}'),
 ('ENBD b', 'EmiratesNBD', 'Payment of AED 42.00 to Noon with Credit Card ending 7205. Avl Cr. Limit is AED 19,951.23.',
  'purchase', 'ENBD credit card merchant payment',
  '{"amount":"42.00","currency":"AED","last4":"7205","merchant":"NOON","available":"19951.23"}'),
 ('ENBD c', 'EmiratesNBD', 'Payment of AED 12.50 to noon one with Credit Card ending 7205. Avl Cr. Limit is AED 19,938.73.',
  'purchase', 'ENBD credit card merchant payment',
  '{"amount":"12.50","currency":"AED","last4":"7205","merchant":"NOON ONE","available":"19938.73"}'),
 ('ENBD d', 'EmiratesNBD', 'Amount of AED 91.00 from NAMSHI has been credited to your card ending with 7205. Available limit is AED 19,532.39.',
  'refund', 'ENBD credit card refund',
  '{"amount":"91.00","currency":"AED","last4":"7205","merchant":"NAMSHI","available":"19532.39"}'),
 ('ENBD e', 'EmiratesNBD', 'Emirates NBD Credit Card Mini Stmt for Card ending 7205: Statement date 28/08/26. Total Amt Due AED 48.77, Due Date 22/09/26. Min Amt Due AED 48.77',
  'other', 'ENBD credit card mini statement (ignored)', '{"last4":"7205"}'),
 ('ENBD f', 'EmiratesNBD', 'Payment for Credit Card ending 7205 is due on 22/09/26. Total Amt - AED 48.77; Min Amt - AED 48.77. Please pay by due date to avoid charges.',
  'other', 'ENBD credit card due reminder (ignored)', '{"last4":"7205"}'),
 ('ENBD g', 'EmiratesNBD', 'A payment on your card needs confirmation. Please check your Emirates NBD app.',
  'other', 'ENBD payment confirmation prompt (ignored)', '{}'),
 ('ENBD h', 'EmiratesNBD', 'A new login to Mobile/Online Banking has been authorised on your device.',
  'other', 'ENBD login notice (ignored)', '{}'),
 ('SIB a', 'SIB', 'A txn on your Covered Card XXXX5052 at Tesla Motors Netherlan for AED 52.91 on 02-10-2026 12:19 is approved. Your available balance is AED 7,459.22',
  'purchase', 'SIB covered card purchase',
  '{"amount":"52.91","currency":"AED","last4":"5052","merchant":"TESLA MOTORS NETHERLAN","date":"2026-10-02","time":"12:19","available":"7459.22"}'),
 ('SIB b', 'SIB', 'A txn on your Covered Card XXXX5052 at EMIRATES for INR 28,400.00 on 02-10-2026 09:36 is approved. Your available balance is AED 7,512.13',
  'purchase', 'SIB covered card purchase',
  '{"amount":"28400.00","currency":"INR","last4":"5052","merchant":"EMIRATES","date":"2026-10-02","time":"09:36"}'),
 ('SIB c', 'SIB', 'A txn on your Covered Card XXXX5052 at NOQ*Ejari for AED 177.75 on 03-10-2026 14:36 is approved. Your available balance is AED 7,241.47',
  'purchase', 'SIB covered card purchase',
  '{"amount":"177.75","currency":"AED","last4":"5052","merchant":"NOQ*EJARI","date":"2026-10-03"}'),
 ('SIB d', 'SIB', 'A txn on your Covered Card XXXX5052 at INTEGRATED GAS SERVICE for AED 105.75 on 08-10-2026 11:23 is approved. Your available balance is AED 7,135.72',
  'purchase', 'SIB covered card purchase',
  '{"amount":"105.75","currency":"AED","last4":"5052","merchant":"INTEGRATED GAS SERVICE","date":"2026-10-08"}'),
 ('SIB declined', 'SIB', 'A txn on your Covered Card XXXX5052 at Tesla Motors Netherlan for AED 1.00 on 02-10-2026 12:19 is declined. Your available balance is AED 7,459.22',
  'declined', 'SIB covered card declined', '{"amount":"1.00","currency":"AED","last4":"5052","merchant":"TESLA MOTORS NETHERLAN"}'),
 ('SIB e', 'SIB', 'Thank you for activating your new SIB Covered Card and accepting the updated Terms & Conditions. Your new card is now ready to use. Remember to update your card details across secure digital wallets and subscriptions. To view Terms & Conditions and Key Facts Statement, visit www.sib.ae/CSU',
  'other', 'SIB card activation notice (ignored)', '{}');

select is(m.msg_kind, c.kind, c.label || ': msg_kind')
from cases c left join lateral private.match_sms_template(c.sender, c.body) m on true
order by c.label;
select is(t.name, c.tpl, c.label || ': template')
from cases c
left join lateral private.match_sms_template(c.sender, c.body) m on true
left join public.sms_templates t on t.template_code = m.template_code
order by c.label;
select is(m.fields->>e.key, e.value, c.label || ': ' || e.key)
from cases c
cross join lateral private.match_sms_template(c.sender, c.body) m
cross join lateral jsonb_each_text(c.expect) e
order by c.label, e.key;

-- formats no template knows stay unmatched (→ 'unparsed' → LLM fallback)
select is((select count(*)::int from private.match_sms_template('ADCBAlert', 'Hello, this is not a bank format')), 0,
          'an unknown ADCB format is not swallowed by a catch-all');
select is((select count(*)::int from private.match_sms_template('FAB',
          'FAB Alert: Credit Card ending 7310 charged AED 64.00 by PARKVIEW PARKING on 06-10-2026 at 09:15.')), 0,
          'an unknown FAB card format is not swallowed by a catch-all');
select is((select count(*)::int from private.match_sms_template('SomeoneElse',
          'Purchase of AED 73.69 with Credit Card ending 7205 at Noon Minutes, Dubai. Avl Cr. Limit is AED 19,626.23')), 0,
          'templates are gated by sender');

-- ── end to end through public.ingest_sms ───────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.sms(p_sender text, p_body text, p_at timestamptz) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', p_sender, 'body', p_body))) -> 0
$$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'sms-templates@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('smstpl', 'SMS templates'));
reset role;

-- the ADCB card the app's "add card" flow would register
with a as (
  insert into public.accounts (profile_code, bank_code, product_name)
  values (pg_temp.v('p'), 'ADCB', 'Test card') returning account_code, profile_code
)
insert into public.cards (profile_code, account_code, bank_code, last4)
select profile_code, account_code, 'ADCB', '3687' from a;

select pg_temp.set('a', pg_temp.sms('ADCBAlert', (select body from cases where label = 'ADCB a'), '2026-08-09 09:43:45+00')::text);
select pg_temp.set('b', pg_temp.sms('ADCBAlert', (select body from cases where label = 'ADCB b'), '2026-09-09 07:45:00+00')::text);
select pg_temp.set('d', pg_temp.sms('ADCBAlert', (select body from cases where label = 'ADCB d'), '2026-08-09 09:43:00+00')::text);
select pg_temp.set('e', pg_temp.sms('ADCBAlert', (select body from cases where label = 'ADCB e'), '2026-09-01 06:00:00+00')::text);
select pg_temp.set('g', pg_temp.sms('ADCBAlert', (select body from cases where label = 'ADCB g'), '2026-09-05 06:00:00+00')::text);
select pg_temp.set('sib', pg_temp.sms('SIB', (select body from cases where label = 'SIB a'), '2026-10-02 08:19:30+00')::text);

select is(pg_temp.v('a')::jsonb->>'status', 'created', 'ADCB a (old Cr.Card format) creates a transaction');
select is(pg_temp.v('b')::jsonb->>'status', 'created', 'ADCB b (new Credit Card format, EGP) creates a transaction');
select is(pg_temp.v('d')::jsonb->>'status', 'ignored', 'ADCB d approval prompt is ignored');
select is(pg_temp.v('e')::jsonb->>'status', 'no_bank_account', 'ADCB e account credit waits for its bank account');
select is(pg_temp.v('g')::jsonb->>'status', 'ignored', 'ADCB g billing alert is ignored');
select is(pg_temp.v('sib')::jsonb->>'status', 'unknown_card', 'SIB alert for an unregistered card is held as unknown_card');

select results_eq(
  $$ select status, currency_original, amount_original, amount_aed, amount_aed_is_estimate, description, txn_date
     from public.transactions where txn_code = pg_temp.v('a')::jsonb->>'txn_code' $$,
  $$ values ('pending'::text, 'AED'::text, 46.00::numeric(14,2), 46.00::numeric(14,2), false, 'VOX CINEMAS,DUBAI-AE'::text, '2026-08-09'::date) $$,
  'AED purchase: pending, exact AED amount, merchant and date from the SMS');
select is((select txn_at from public.transactions where txn_code = pg_temp.v('a')::jsonb->>'txn_code'),
          '2026-08-09 13:43:40+04'::timestamptz, 'the printed Dubai time becomes txn_at');
select results_eq(
  $$ select status, currency_original, amount_original, amount_aed_is_estimate, description
     from public.transactions where txn_code = pg_temp.v('b')::jsonb->>'txn_code' $$,
  $$ values ('pending'::text, 'EGP'::text, 69.94::numeric(14,2), true, 'UBER *TRIP HELP.UBER, HELP.UBER.COM-NL'::text) $$,
  'foreign purchase: pending, original EGP amount, AED flagged as an estimate');
select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p')), 2,
          'only the two real purchases became transactions (the approval prompt did not)');
select is((select count(*)::int from public.sms_messages where profile_code = pg_temp.v('p') and parse_status = 'unparsed'), 0,
          'nothing is left unparsed');
select is((select ignore_reason from public.sms_messages where sms_code = pg_temp.v('d')::jsonb->>'sms_code'), 'other',
          'approval prompt ignore_reason = other');
select is((select ignore_reason from public.sms_messages where sms_code = pg_temp.v('e')::jsonb->>'sms_code'), 'no_bank_account',
          'an account credit for an account the ledger lacks waits as no_bank_account (Phase 2b)');
select ok((select amount is null from public.sms_messages where sms_code = pg_temp.v('g')::jsonb->>'sms_code'),
          'an amountless alert is stored without an amount');

select * from finish();
rollback;

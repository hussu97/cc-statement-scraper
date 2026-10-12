-- EIB, Wio and ENBD templates (20261012154553): every real sample reaches the intended
-- template with the right fields, look-alikes stay unmatched, and alerts flow end to
-- end through public.ingest_sms (Wio prints no date: the transaction is dated at
-- received_at).
begin;
create extension if not exists pgtap with schema extensions;
set local client_min_messages = warning;
select no_plan();

select is((select sms_senders from public.banks where bank_code = 'EIB'), array['EI SMS'], 'EIB real sender id');
select is((select sms_senders from public.banks where bank_code = 'WIO'), array['WioPersonal'], 'Wio real sender id');

create temp table cases (label text primary key, sender text, body text, kind text, tpl text, expect jsonb);
insert into cases values
 ('EIB purchase', 'EI SMS', E'Credit Card Purchase\nCard Ending: 9212\nAt: NATIONAL TAXI, DUBAI\nAmount: AED 59.50\nDate: 16/09/2026, 12:14\nAvailable Limit: AED 36,957.01',
  'purchase', 'EIB credit card purchase (multi-line)',
  '{"amount":"59.50","currency":"AED","last4":"9212","merchant":"NATIONAL TAXI, DUBAI","date":"2026-09-16","time":"12:14","available":"36957.01"}'),
 ('EIB purchase, no limit line', 'EI SMS', E'Credit Card Purchase\nCard Ending: 9216\nAt: AMAZON.AE\nAmount: USD 12\nDate: 01/10/2026, 09:05',
  'purchase', 'EIB credit card purchase (multi-line)',
  '{"amount":"12.00","currency":"USD","last4":"9216","merchant":"AMAZON.AE","date":"2026-10-01","time":"09:05"}'),
 ('EIB mini statement', 'EI SMS', E'Credit Card Mini Statement\nCard Starting: 459220\nStatement Date: 10/10/2026\nMinimum Amount Due: AED 229.45\nAmount to be paid to avoid charges:  AED 4,589.03\nDue Date: 04/11/2026',
  'other', 'EIB credit card mini statement (ignored)', '{}'),
 ('EIB wallet enrolled', 'EI SMS', 'Dear Customer, your card ending 9212 has been enrolled into Apple Wallet. If you did not initiate this, please call 600599995',
  'other', 'EIB wallet enrolment notice (ignored)', '{}'),
 ('EIB wallet disabled', 'EI SMS', 'Dear Customer, your card ending 9212 has been disabled from Apple Wallet. If you did not initiate this transaction, please call 600599995',
  'other', 'EIB wallet enrolment notice (ignored)', '{}'),
 ('EIB smart pass', 'EI SMS', 'Dear Carol Sample, Your Smart Pass has been deactivated from your old device, please continue transacting on the new device.',
  'other', 'EIB mobile banking access notice (ignored)', '{}'),
 ('EIB regained access', 'EI SMS', 'Dear Carol Sample, you have regained access to your EI+ Mobile/Online banking successfully. If this wasn''t you, please call +971 600 599995 and report fraud.',
  'other', 'EIB mobile banking access notice (ignored)', '{}'),
 ('Wio payment', 'WioPersonal', 'Payment of AED 593.03 was done at Dubai Electricity using your Wio Personal card 9202 with Credit money',
  'purchase', 'Wio credit card payment', '{"amount":"593.03","currency":"AED","last4":"9202","merchant":"DUBAI ELECTRICITY"}'),
 ('Wio whole dirhams', 'WioPersonal', 'Payment of AED 650 was done at Dubai Duty Free using your Wio Personal card 9202 with Credit money',
  'purchase', 'Wio credit card payment', '{"amount":"650.00","last4":"9202","merchant":"DUBAI DUTY FREE"}'),
 ('Wio merchant with spaces', 'WioPersonal', 'Payment of AED 587.09 was done at DU Apple Pay using your Wio Personal card 9202 with Credit money',
  'purchase', 'Wio credit card payment', '{"amount":"587.09","merchant":"DU APPLE PAY"}'),
 ('Wio apple pay added', 'WioPersonal', 'Your Wio Personal card ending with 9202 has been added to Apple Pay. If it wasn''t you, freeze this card in the App and contact us immediately at 600 500 946',
  'other', 'Wio wallet notice (ignored)', '{}'),
 ('ENBD recovery', 'EmiratesNBD', 'Dear Bob, you''ve initiated a request to recover access to your ENBD X profile. If this wasn''t you, please call +971 600 54 0000 and report fraud.',
  'other', 'ENBD account recovery notice (ignored)', '{}'),
 ('ENBD mini statement (existing)', 'EmiratesNBD', 'Emirates NBD Credit Card Mini Stmt for Card ending 9201: Statement date 12/09/26. Total Amt Due AED 8007.80, Due Date 07/10/26. Min Amt Due AED 474.93',
  'other', 'ENBD credit card mini statement (ignored)', '{}');

select is(m.msg_kind, c.kind, c.label || ': kind')
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

-- look-alikes stay unmatched, so they reach the LLM fallback instead of being guessed
select is((select count(*)::int from private.match_sms_template('WioPersonal',
  'Payment of AED 20.00 was done at Careem using your Wio Personal card 9202 with Personal money')), 0,
  'a Wio payment from another balance is not a credit-card purchase');
select is((select count(*)::int from private.match_sms_template('SomeoneElse',
  'Payment of AED 20.00 was done at Careem using your Wio Personal card 9202 with Credit money')), 0,
  'the Wio template needs a Wio sender');
select is((select count(*)::int from private.match_sms_template('EI SMS', 'Dear Customer, a new offer awaits you')), 0,
  'an unknown EIB message is not matched');

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
values ('33333333-3333-4333-8333-333333333333', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'sms-eib-wio@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('smseibwio', 'EIB and Wio SMS'));
reset role;

with a as (
  insert into public.accounts (profile_code, bank_code, product_name)
  values (pg_temp.v('p'), 'WIO', 'Wio credit'), (pg_temp.v('p'), 'EIB', 'EIB card')
  returning account_code, profile_code, bank_code
)
insert into public.cards (profile_code, account_code, bank_code, last4)
select profile_code, account_code, bank_code, case bank_code when 'WIO' then '9202' else '9212' end from a;

select pg_temp.set('wio', pg_temp.sms('WioPersonal', (select body from cases where label = 'Wio payment'), '2026-09-12 06:46:20+00')::text);
select pg_temp.set('eib', pg_temp.sms('EI SMS', (select body from cases where label = 'EIB purchase'), '2026-09-16 08:14:30+00')::text);
select pg_temp.set('ign', pg_temp.sms('EI SMS', (select body from cases where label = 'EIB mini statement'), '2026-10-12 00:24:00+00')::text);

select is(pg_temp.v('wio')::jsonb->>'status', 'created', 'a Wio payment creates a transaction');
select is(pg_temp.v('eib')::jsonb->>'status', 'created', 'an EIB purchase creates a transaction');
select is(pg_temp.v('ign')::jsonb->>'status', 'ignored', 'an EIB mini statement is ignored');

select is((select t.txn_date from public.transactions t join public.accounts a using (account_code)
           where t.profile_code = pg_temp.v('p') and a.bank_code = 'WIO'), date '2026-09-12',
          'the Wio transaction is dated at received_at (Dubai date)');
select is((select t.amount_original from public.transactions t join public.accounts a using (account_code)
           where t.profile_code = pg_temp.v('p') and a.bank_code = 'WIO'), 593.03::numeric(14,2), 'Wio amount');
select is((select t.txn_date from public.transactions t join public.accounts a using (account_code)
           where t.profile_code = pg_temp.v('p') and a.bank_code = 'EIB'), date '2026-09-16', 'EIB date from the alert');

select * from finish();
rollback;

-- SMS clean-up (20261026170630_sms_noise_bins_ivestor): adverts and bank notices are ignored,
-- EIB's payment confirmation finds its card by first6 (the BIN), merge_cards folds a card made
-- by mistake into the real one, and DFM's iVESTOR credits land on a bank account as Dividends.
-- A ledger with two EIB card accounts (Amazon •6177, RTA •4557) and, later, a DFM account.
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
create function pg_temp.msg(p_body text) returns public.sms_messages language sql as $$
  select * from public.sms_messages where profile_code = pg_temp.v('p') and body = p_body
  order by received_at desc, sms_code desc limit 1 $$;
create function pg_temp.txn_of(p_body text) returns public.transactions language sql as $$
  select t.* from public.transactions t
  join public.transaction_evidence e on e.txn_code = t.txn_code and e.is_active and e.role = 'primary'
  where e.sms_code = (pg_temp.msg(p_body)).sms_code $$;
-- An EIB payment confirmation for the card starting with p_bin, dated the day of t0.
create function pg_temp.eib_payment(p_amount text, p_bin text) returns text language sql as $$
  select 'This is to confirm receipt of your payment of AED ' || p_amount || ' towards your Credit Card starting with '
         || p_bin || '  on ' || to_char(pg_temp.v('t0')::timestamptz at time zone 'Asia/Dubai', 'DD/MM/YYYY')
         || '. Available limit is   AED 37,969.57.' $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't70-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't70-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t70-' || left(pg_temp.v('uid'), 8), 'SMS clean-up'));
reset role;
insert into public.accounts (profile_code, bank_code, nickname)
values (pg_temp.v('p'), 'EIB', 'EIB Amazon') returning pg_temp.set('amazon', account_code);
insert into public.accounts (profile_code, bank_code, nickname)
values (pg_temp.v('p'), 'EIB', 'EIB RTA') returning pg_temp.set('rta', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4)
values (pg_temp.v('p'), pg_temp.v('amazon'), 'EIB', '6177') returning pg_temp.set('c6177', card_code);
insert into public.cards (profile_code, account_code, bank_code, last4, first6)
values (pg_temp.v('p'), pg_temp.v('rta'), 'EIB', '4557', '457828') returning pg_temp.set('c4557', card_code);

select pg_temp.set('t0', ((((now() at time zone 'Asia/Dubai')::date - 1) + time '06:00') at time zone 'Asia/Dubai')::text);

-- ── adverts and bank notices ────────────────────────────────────────────────
select pg_temp.set('promo', 'Stock up on groceries and more, and earn up to 50,000 extra FAB Rewards! SMS GROC to 2121. Conditions apply.');
select is(pg_temp.sms('AD-FAB', pg_temp.v('promo'), pg_temp.v('t0')::timestamptz)->>'status', 'ignored',
          'an AD- sender (the UAE advert prefix) is ignored');
select results_eq(
  $$ select parse_status, ignore_reason, template_code is null from pg_temp.msg(pg_temp.v('promo')) $$,
  $$ values ('ignored'::text, 'promotion'::text, true) $$,
  'as a promotion, without a template');

select is(pg_temp.sms(n.sender, n.body, pg_temp.v('t0')::timestamptz)->>'status', 'ignored', n.what)
from (values
  ('FAB', 'Your FAB Credit Card Key Facts Statement has been updated. Please review it to be informed about card terms, conditions and fees. https://vkq.be/etzc5IgH.',
   'FAB''s Key Facts Statement notice is ignored'),
  ('FAB', 'Dear Customer, the payment due date of your FAB Credit Card ending with 2777 is 26-10-2026. The total amount due is AED 515.26 and the Minimum due amount is AED 100.00. Please ignore the message, if already paid.',
   'FAB''s payment-due reminder is ignored'),
  ('EI SMS', E'Reminder for Credit Card Payment\nCard Starting: 542459\nDue Date: 25/10/2026\nMinimum Amount Due: AED 61.79\nAmount to be paid to avoid charges: AED 61.79\nPlease pay on or before due date to avoid commitment to donate amount.',
   'EIB''s payment reminder is ignored')
) as n(sender, body, what);
select is((select count(*)::int from public.sms_messages
           where profile_code = pg_temp.v('p') and parse_status = 'ignored' and ignore_reason = 'other'), 3,
          'the three notices are stored ignored as other');

-- ── EIB payments named by the card's first six digits ──────────────────────
select is(private.apply_sms_template(t, 'EI SMS', pg_temp.eib_payment('62.00', '542459')) - 'date',
          '{"currency":"AED","amount":"62.00","first6":"542459","available":"37969.57"}'::jsonb,
          'the EIB template reads the BIN as first6, never as last4')
from public.sms_templates t where t.name = 'EIB credit card payment received';

select pg_temp.set('pay_rta', pg_temp.eib_payment('5133.00', '457828'));
select is(pg_temp.sms('EI SMS', pg_temp.v('pay_rta'), pg_temp.v('t0')::timestamptz)->>'status', 'created',
          'a payment for a BIN a card carries becomes a transaction');
select results_eq(
  $$ select t.account_code, t.card_code, t.kind, m.card_last4 is null, m.parsed_fields->>'first6'
     from pg_temp.txn_of(pg_temp.v('pay_rta')) t, pg_temp.msg(pg_temp.v('pay_rta')) m $$,
  $$ values (pg_temp.v('rta'), pg_temp.v('c4557'), 'payment'::text, true, '457828'::text) $$,
  'on that card''s account and card; the message has no last4');

select pg_temp.set('pay_amazon', pg_temp.eib_payment('62.00', '542459'));
select is(pg_temp.sms('EI SMS', pg_temp.v('pay_amazon'), pg_temp.v('t0')::timestamptz + interval '1 hour')->>'status',
          'unknown_card', 'a BIN no card carries asks which account');
select pg_temp.set('review', (select review_code from public.match_reviews
                               where subject_code = (pg_temp.msg(pg_temp.v('pay_amazon'))).sms_code and reason = 'unknown_card'));
select ok((select candidates @> '[{"bank_code":"EIB","first6":"542459"}]'::jsonb from public.match_reviews
           where review_code = pg_temp.v('review')),
          'the review names the BIN');

set local role authenticated;
select is(public.resolve_review(pg_temp.v('review'), jsonb_build_object('card', jsonb_build_object('account_code', pg_temp.v('amazon'))))->>'outcome',
          'card_registered', 'the owner puts it on EIB Amazon');
reset role;
select results_eq(
  $$ select account_code, kind from pg_temp.txn_of(pg_temp.v('pay_amazon')) $$,
  $$ values (pg_temp.v('amazon'), 'payment'::text) $$,
  'the payment is on EIB Amazon');
select is((select count(*)::int from public.cards where profile_code = pg_temp.v('p')), 2,
          'and no card was made from the BIN');

select pg_temp.set('pay_amazon2', pg_temp.eib_payment('100.00', '542459'));
select is(pg_temp.sms('EI SMS', pg_temp.v('pay_amazon2'), pg_temp.v('t0')::timestamptz + interval '2 hours')->>'status',
          'created', 'the next payment with that BIN needs no review');
select results_eq(
  $$ select account_code, card_code is null from pg_temp.txn_of(pg_temp.v('pay_amazon2')) $$,
  $$ values (pg_temp.v('amazon'), true) $$,
  'it goes to the account the review chose');

-- ── merge_cards ─────────────────────────────────────────────────────────────
insert into public.cards (profile_code, account_code, bank_code, last4, first6, is_supplementary)
values (pg_temp.v('p'), pg_temp.v('amazon'), 'EIB', '2459', '542459', true) returning pg_temp.set('c2459', card_code);
update public.transactions set card_code = pg_temp.v('c2459')
where txn_code = (pg_temp.txn_of(pg_temp.v('pay_amazon2'))).txn_code;
update public.sms_messages set card_code = pg_temp.v('c2459')
where sms_code = (pg_temp.msg(pg_temp.v('pay_amazon2'))).sms_code;
insert into public.category_rules (profile_code, category_code, name, match_type, pattern, conditions, source)
select pg_temp.v('p'), c.category_code, 'by card', 'contains', 'NOON', jsonb_build_object('card_code', pg_temp.v('c2459')), 'user'
from public.categories c where c.profile_code = pg_temp.v('p') and c.name = 'Shopping';

select results_eq(
  $$ select (r->>'transactions')::int, (r->>'sms_messages')::int, (r->>'rules')::int
     from private.merge_cards(pg_temp.v('p'), pg_temp.v('c6177'), pg_temp.v('c2459')) r $$,
  $$ values (1, 1, 1) $$,
  'merge_cards moves the transaction, the message and the rule');
select is((select count(*)::int from public.transactions where card_code = pg_temp.v('c2459'))
          + (select count(*)::int from public.sms_messages where card_code = pg_temp.v('c2459'))
          + (select count(*)::int from public.category_rules where conditions->>'card_code' = pg_temp.v('c2459')), 0,
          'nothing names the merged card any more');
select results_eq(
  $$ select status, first6 from public.cards where card_code = pg_temp.v('c2459') $$,
  $$ values ('closed'::text, null::text) $$,
  'the merged card is closed and keeps no BIN');
select is((select first6 from public.cards where card_code = pg_temp.v('c6177')), '542459',
          'the real card takes its BIN');

select pg_temp.set('pay_amazon3', pg_temp.eib_payment('40.00', '542459'));
select is(pg_temp.sms('EI SMS', pg_temp.v('pay_amazon3'), pg_temp.v('t0')::timestamptz + interval '3 hours')->>'status',
          'created', 'a payment with that BIN now finds the card');
select results_eq(
  $$ select account_code, card_code from pg_temp.txn_of(pg_temp.v('pay_amazon3')) $$,
  $$ values (pg_temp.v('amazon'), pg_temp.v('c6177')) $$,
  'EIB Amazon •6177');

select throws_ok(
  format('select private.merge_cards(%L, %L, %L)', pg_temp.v('p'), pg_temp.v('c6177'), pg_temp.v('c6177')),
  'P0002', null, 'merge_cards refuses to merge a card into itself');

-- ── DFM iVESTOR: dividends on a bank account ───────────────────────────────
select pg_temp.set('dividend', 'Dear customer, Your iVESTOR card xxxx5246 has been credited with AED 113.92. Your available balance is  AED 517.78');
select is(pg_temp.sms('DFM', pg_temp.v('dividend'), pg_temp.v('t0')::timestamptz)->>'status', 'no_bank_account',
          'an iVESTOR credit waits until the ledger has a DFM account');

set local role authenticated;
select pg_temp.set('dfm', public.create_bank_account(pg_temp.v('p'), 'DFM', 'current', null, 'DFM iVESTOR'));
reset role;
select results_eq(
  $$ select t.account_code, t.kind, t.direction, t.status, t.amount_aed, t.description, c.name, c.kind
     from pg_temp.txn_of(pg_temp.v('dividend')) t
     join public.categories c on c.category_code = t.effective_category_code $$,
  $$ values (pg_temp.v('dfm'), 'transfer_in'::text, 'credit'::text, 'posted'::text, 113.92::numeric,
             'IVESTOR CARD'::text, 'Dividends'::text, 'income'::text) $$,
  'adding the account turns it into money in on it, filed as Dividends (income)');
select results_eq(
  $$ select account_code, last4 from public.cards where profile_code = pg_temp.v('p') and bank_code = 'DFM' $$,
  $$ values (pg_temp.v('dfm'), '5246'::text) $$,
  'the iVESTOR card joins the account');
select is((select balance from public.balance_checkpoints where account_code = pg_temp.v('dfm')), 517.78::numeric,
          'the printed balance is a checkpoint');
select is_empty(
  $$ select 1 from public.v_spend where txn_code = (pg_temp.txn_of(pg_temp.v('dividend'))).txn_code $$,
  'a dividend is not spend');

select * from finish();
rollback;

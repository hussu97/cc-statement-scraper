-- SIB SMS formats (20261030152122): the alert before SIB's card-system update (no year: its time
-- is the SMS's own), the one after it that prints "Card" alone, the payment and cashback credits,
-- and the zero-amount check and notices, which are ignored.
-- Runs on a non-empty DB: every assertion is scoped to this run's profile.
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
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', 'SIB', 'body', p_body))) -> 0
$$;
create function pg_temp.txn(p_res jsonb) returns public.transactions language sql as $$
  select * from public.transactions where txn_code = p_res->>'txn_code' $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't81-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't81-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t81-' || left(pg_temp.v('uid'), 8), 'SIB'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code, nickname) values (pg_temp.v('p'), 'SIB', 'SIB card')
returning pg_temp.set('sib', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4)
values (pg_temp.v('p'), pg_temp.v('sib'), 'SIB', '9214'), (pg_temp.v('p'), pg_temp.v('sib'), 'SIB', '9213');
select pg_temp.set('t0', (((public.dubai_date(now()) - 5) + time '19:42') at time zone 'Asia/Dubai')::text);

-- ── the older alert: no year, so the SMS's own time ─────────────────────────
select pg_temp.set('old', pg_temp.sms('A txn on your Card XXXX9214 at CORNER GROCERY for AED  12.50 on 05-Aug at 19:42  is approved. Your available balance is 4821.30',
                                      pg_temp.v('t0')::timestamptz)::text);
select results_eq(
  $$ select t.account_code, t.kind, t.direction, t.status, t.amount_aed, t.description, c.last4, t.txn_at
     from pg_temp.txn(pg_temp.v('old')::jsonb) t join public.cards c using (card_code) $$,
  $$ values (pg_temp.v('sib'), 'purchase'::text, 'debit'::text, 'pending'::text, 12.50::numeric, 'CORNER GROCERY'::text,
             '9214'::text, pg_temp.v('t0')::timestamptz) $$,
  'the older purchase alert is a pending purchase on its card, at the time the SMS came');

select is(pg_temp.sms('A txn on your Card XXXX9214 at SAMPLE DELIVERY for AED  0.00 on 07-Aug at 10:15  is approved. Your available balance is 4821.30',
                      pg_temp.v('t0')::timestamptz + interval '1 hour')->>'status', 'ignored',
          'a zero-amount card check is ignored, not a 0.00 purchase');

-- ── the newer alert with "Card" alone ───────────────────────────────────────
select pg_temp.set('new', pg_temp.sms('A txn on your Card XXXX9213 at Tesla Motors Netherlan for AED 41.27 on '
                                      || to_char(public.dubai_date(now()) - 4, 'DD-MM-YYYY')
                                      || ' 18:05 is approved. Your available balance is AED 6,912.40',
                                      pg_temp.v('t0')::timestamptz + interval '1 day')::text);
select results_eq(
  $$ select t.kind, t.amount_aed, c.last4, t.txn_date from pg_temp.txn(pg_temp.v('new')::jsonb) t join public.cards c using (card_code) $$,
  $$ values ('purchase'::text, 41.27::numeric, '9213'::text, public.dubai_date(now()) - 4) $$,
  'the newer alert parses without "Covered", on the date it prints');

-- ── credits ─────────────────────────────────────────────────────────────────
select pg_temp.set('pay', pg_temp.sms('Thank you for your payment against your  Card. AED 1250.00 has been credited to your card account XXXX9214',
                                      pg_temp.v('t0')::timestamptz + interval '2 days')::text);
select results_eq(
  $$ select account_code, kind, direction, amount_aed from pg_temp.txn(pg_temp.v('pay')::jsonb) $$,
  $$ values (pg_temp.v('sib'), 'payment'::text, 'credit'::text, 1250.00::numeric) $$,
  'a payment confirmation with a doubled space and no final period is a payment');

select pg_temp.set('cb', pg_temp.sms('Total Cashback of AED 214.00 has been credited to your card ending with XXXX9214.',
                                     pg_temp.v('t0')::timestamptz + interval '2 days 1 minute')::text);
select results_eq(
  $$ select kind, direction, amount_aed, description from pg_temp.txn(pg_temp.v('cb')::jsonb) $$,
  $$ values ('refund'::text, 'credit'::text, 214.00::numeric, 'CASHBACK'::text) $$,
  'cashback is a credit on the card, as on its statement (CASHBACK REDEEMED is a refund)');

-- ── notices ─────────────────────────────────────────────────────────────────
select is(pg_temp.sms(b, pg_temp.v('t0')::timestamptz + interval '3 days')->>'status', 'ignored', 'ignored: ' || left(b, 40))
from unnest(array[
  'A txn attempt on Card. XXXX9213 at SAMPLE STORE for AED 0.00 on 04-10-2026 09:48 was not processed. For assistance call us on 600 000000',
  'Covered Card ending with XXXX9214 payment is due on 30-Aug, outstanding amount is AED 412.18, minimum payment due is AED 100.00. Ensure paying before 30-Aug to avoid deducting any amount under commitment to donate clause. Total Cashback points is 120',
  'Dear Customer, your new Covered Card XXXX9213 has been activated successfully, for info call 600 000000 or visit www.example.ae',
  'Your SIB card 400000XXXXXX9213 is ready for Apple Pay. You can use it wherever you see the contactless symbol or Apple Pay mark.'
]) b;

select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p') and status <> 'void'), 4,
          'four transactions: two purchases, a payment and the cashback');

select * from finish();
rollback;

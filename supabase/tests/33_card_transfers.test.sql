-- Card transfers (20261012151140): a Wio payment onto another card is linked to that card's
-- credit; ambiguous, same-account, out-of-window and non-payment rows stay unlinked; a side that
-- is voided drops its link; v_transactions names the other card; members only.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.account(p_bank text, p_last4 text) returns text language plpgsql as $$
declare v_acc text;
begin
  insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), p_bank) returning account_code into v_acc;
  insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), v_acc, p_bank, p_last4);
  return v_acc;
end $$;
create function pg_temp.txn(p_acc text, p_date date, p_desc text, p_amount numeric, p_dir text,
                            p_kind text default 'payment', p_status text default 'posted') returns text
language sql as $$
  insert into public.transactions (profile_code, account_code, card_code, status, kind, direction, txn_date,
                                   description, amount_original, currency_original, amount_aed, amount_source)
  values (pg_temp.v('p'), p_acc, (select card_code from public.cards where account_code = p_acc), p_status, p_kind,
          p_dir, p_date, p_desc, p_amount, 'AED', p_amount, 'statement_line')
  returning txn_code $$;
create function pg_temp.partner(p_txn text) returns text language sql as $$
  select case when from_txn_code = p_txn then to_txn_code else from_txn_code end
  from public.card_transfers where from_txn_code = p_txn or to_txn_code = p_txn $$;

-- ── setup ───────────────────────────────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't33-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t33-' || left(pg_temp.v('uid'), 8), 'Cards'));
reset role;
select set_config('request.jwt.claims', '', true);

select pg_temp.set('wio', pg_temp.account('WIO', '2010'));
select pg_temp.set('enbd', pg_temp.account('ENBD', '1287'));
select pg_temp.set('eib', pg_temp.account('EIB', '6177'));
select pg_temp.set('mashreq', pg_temp.account('MASHREQ', '4421'));

-- ── the paid card's credit arrives first, then Wio's debit ──────────────────
select pg_temp.set('enbd_in', pg_temp.txn(pg_temp.v('enbd'), '2026-06-21', 'TRANSFER PAYMENT RECEIVED THANK YOU', 7913.00, 'credit'));
select pg_temp.set('wio_out', pg_temp.txn(pg_temp.v('wio'), '2026-06-21', 'ENBD payment', 7913.00, 'debit'));
select results_eq($$ select from_txn_code, to_txn_code from public.card_transfers where profile_code = pg_temp.v('p')
                     and from_txn_code = pg_temp.v('wio_out') $$,
                  $$ values (pg_temp.v('wio_out'), pg_temp.v('enbd_in')) $$,
                  'Wio''s debit payment is linked to the ENBD credit: from the payer, to the paid card');

-- ── Wio's debit first, the credit a day later ──────────────────────────────
select pg_temp.set('wio_out2', pg_temp.txn(pg_temp.v('wio'), '2026-06-29', 'Mashreq payment', 1.00, 'debit'));
select is(pg_temp.partner(pg_temp.v('wio_out2')), null, 'no credit yet: unlinked');
select pg_temp.set('mashreq_in', pg_temp.txn(pg_temp.v('mashreq'), '2026-06-30', 'INWARD IPP CC', 1.00, 'credit'));
select is(pg_temp.partner(pg_temp.v('wio_out2')), pg_temp.v('mashreq_in'), 'the credit one day later links it');

-- ── v_transactions names the other card on both sides ─────────────────────
select results_eq(
  $$ select transfer_txn_code, transfer_bank_code, transfer_card_last4 from public.v_transactions
     where txn_code = pg_temp.v('wio_out') $$,
  $$ values (pg_temp.v('enbd_in'), 'ENBD'::text, '1287'::text) $$, 'the Wio row names ENBD •1287');
select results_eq(
  $$ select transfer_txn_code, transfer_bank_code, transfer_card_last4 from public.v_transactions
     where txn_code = pg_temp.v('enbd_in') $$,
  $$ values (pg_temp.v('wio_out'), 'WIO'::text, '2010'::text) $$, 'the ENBD row names WIO •2010');
select is((select transfer_txn_code from public.v_transactions where txn_code = (
             select txn_code from public.transactions where account_code = pg_temp.v('enbd') limit 0)), null,
          '(unlinked rows have no transfer columns)');

-- ── not linked ──────────────────────────────────────────────────────────────
-- Ambiguous: two equal credits in the window.
select pg_temp.set('amb_in1', pg_temp.txn(pg_temp.v('eib'), '2026-07-05', 'TRANSFER PAYMENT RECEIVED THANK YOU', 600.00, 'credit'));
select pg_temp.set('amb_in2', pg_temp.txn(pg_temp.v('mashreq'), '2026-07-06', 'INWARD IPP CC', 600.00, 'credit'));
select pg_temp.set('amb_out', pg_temp.txn(pg_temp.v('wio'), '2026-07-05', 'EIB AZ payment', 600.00, 'debit'));
select is(pg_temp.partner(pg_temp.v('amb_out')), null, 'two candidate credits: left unlinked, not guessed');
-- Same account.
select pg_temp.set('same_in', pg_temp.txn(pg_temp.v('wio'), '2026-07-10', 'Credit Repayment', 250.00, 'credit'));
select pg_temp.set('same_out', pg_temp.txn(pg_temp.v('wio'), '2026-07-10', 'ENBD payment', 250.00, 'debit'));
select is(pg_temp.partner(pg_temp.v('same_out')), null, 'a credit on the same card is not a transfer');
-- Out of the 3-day window.
select pg_temp.set('far_in', pg_temp.txn(pg_temp.v('enbd'), '2026-07-20', 'TRANSFER PAYMENT RECEIVED THANK YOU', 333.00, 'credit'));
select pg_temp.set('far_out', pg_temp.txn(pg_temp.v('wio'), '2026-07-15', 'ENBD payment', 333.00, 'debit'));
select is(pg_temp.partner(pg_temp.v('far_out')), null, 'five days apart: unlinked');
-- A purchase is not a payment.
select pg_temp.set('buy', pg_temp.txn(pg_temp.v('wio'), '2026-07-22', 'NOON', 444.00, 'debit', 'purchase'));
select pg_temp.set('buy_in', pg_temp.txn(pg_temp.v('eib'), '2026-07-22', 'TRANSFER PAYMENT RECEIVED THANK YOU', 444.00, 'credit'));
select is(pg_temp.partner(pg_temp.v('buy_in')), null, 'a purchase of the same amount is not linked');

-- ── a voided side drops its link ────────────────────────────────────────────
update public.transactions set status = 'void', voided_at = now() where txn_code = pg_temp.v('mashreq_in');
select is(pg_temp.partner(pg_temp.v('wio_out2')), null, 'voiding the credit unlinks the pair');
-- …and the payer links again when another candidate appears.
select pg_temp.set('mashreq_in2', pg_temp.txn(pg_temp.v('mashreq'), '2026-06-30', 'INWARD IPP CC', 1.00, 'credit'));
select is(pg_temp.partner(pg_temp.v('wio_out2')), pg_temp.v('mashreq_in2'), 'a new credit relinks the payer');

-- ── spend is unchanged: payments are never spend ────────────────────────────
select is((select count(*)::int from public.v_spend where txn_code in (pg_temp.v('wio_out'), pg_temp.v('enbd_in'))), 0,
          'neither side of a transfer is spend');

-- ── members only ────────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select is((select count(*)::int from public.card_transfers), 2, 'the owner reads the profile''s transfers');
select throws_ok($$ insert into public.card_transfers (profile_code, from_txn_code, to_txn_code)
                    values (pg_temp.v('p'), pg_temp.v('far_out'), pg_temp.v('far_in')) $$,
                 '42501', null, 'clients cannot write transfers');
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select is((select count(*)::int from public.card_transfers), 0, 'another user sees none');
reset role;

select * from finish();
rollback;

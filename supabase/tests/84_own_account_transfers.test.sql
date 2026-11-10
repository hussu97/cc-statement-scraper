-- Own-account transfers (20261110090321_own_account_transfer_links): a bank transfer_out and a
-- bank transfer_in on two of the ledger's own accounts are linked in card_transfers; a leg filed
-- as income is nobody's partner (and filing it changes the link); an ambiguous pair stays
-- unlinked; v_transactions names the other account by its account_ref; v_cash_flow keeps
-- card_repayment for card payments and shows a linked own transfer as internal.
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
create function pg_temp.txn(p_acc text, p_kind text, p_dir text, p_aed numeric, p_day int, p_cat text default null)
returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date,
                                   description, amount_original, currency_original, amount_aed, amount_source,
                                   manual_category_code)
  values (pg_temp.v('p'), pg_temp.v(p_acc), 'posted', p_kind, p_dir, pg_temp.v('m')::date + p_day,
          upper(p_kind) || ' ' || p_aed, p_aed, 'AED', p_aed, 'manual', pg_temp.cat(p_cat))
  returning txn_code $$;
create function pg_temp.partner(p_txn text) returns text language sql as $$
  select case when from_txn_code = pg_temp.v(p_txn) then to_txn_code else from_txn_code end
  from public.card_transfers where from_txn_code = pg_temp.v(p_txn) or to_txn_code = pg_temp.v(p_txn) $$;
create function pg_temp.flow(p_txn text) returns text language sql as $$
  select flow from public.v_cash_flow where txn_code = pg_temp.v(p_txn) $$;

-- ── setup: a savings and a current account at one bank, a current account at another, a card ──
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't84-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t84-' || left(pg_temp.v('uid'), 8), 'Own transfers'));
select pg_temp.set('saver', public.create_bank_account(pg_temp.v('p'), 'ADCB', 'savings', '310001'));
select pg_temp.set('current', public.create_bank_account(pg_temp.v('p'), 'ADCB', 'current', '310002'));
select pg_temp.set('other', public.create_bank_account(pg_temp.v('p'), 'FAB', 'current', '310003'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'EIB')
returning pg_temp.set('card', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), pg_temp.v('card'), 'EIB', '9208');
select pg_temp.set('m', date_trunc('month', public.dubai_date(now()) - 40)::date::text);

-- ── out of savings, into current, the same day ─────────────────────────────
select pg_temp.set('sweep_out', pg_temp.txn('saver', 'transfer_out', 'debit', 1250.00, 1));
select pg_temp.set('sweep_in', pg_temp.txn('current', 'transfer_in', 'credit', 1250.00, 1));
select results_eq(
  $$ select from_txn_code, to_txn_code from public.card_transfers where from_txn_code = pg_temp.v('sweep_out') $$,
  $$ values (pg_temp.v('sweep_out'), pg_temp.v('sweep_in')) $$,
  'a transfer out of savings is linked to the same amount into current: from the debit, to the credit');
select results_eq(
  $$ select transfer_txn_code, transfer_bank_code, transfer_card_last4 from public.v_transactions
     where txn_code = pg_temp.v('sweep_out') $$,
  $$ values (pg_temp.v('sweep_in'), 'ADCB'::text, '310002'::text) $$,
  'v_transactions names the other account by its account_ref (no card on a bank account)');
select results_eq(
  $$ select transfer_txn_code, transfer_card_last4 from public.v_transactions where txn_code = pg_temp.v('sweep_in') $$,
  $$ values (pg_temp.v('sweep_out'), '310001'::text) $$,
  'and the credit names the savings account');
select is(pg_temp.flow('sweep_out'), 'internal_out', 'a linked own transfer out is internal, not a card repayment');
select is(pg_temp.flow('sweep_in'), 'internal_in', 'its other leg is internal in');

-- ── a leg filed as income is nobody's partner ──────────────────────────────
select pg_temp.set('salary_in', pg_temp.txn('other', 'transfer_in', 'credit', 7000.00, 10, 'Salary'));
select pg_temp.set('move_out', pg_temp.txn('current', 'transfer_out', 'debit', 7000.00, 10));
select is(pg_temp.partner('move_out'), null, 'a transfer out does not pair with a credit filed as income');
update public.transactions set manual_category_code = pg_temp.cat('Transfers') where txn_code = pg_temp.v('salary_in');
select is(pg_temp.partner('move_out'), pg_temp.v('salary_in'), 'refiling the credit as a transfer links the pair');
update public.transactions set manual_category_code = pg_temp.cat('Salary') where txn_code = pg_temp.v('salary_in');
select is(pg_temp.partner('move_out'), null, 'filing it back as income drops the link');

-- ── ambiguous: two equal credits on other accounts in the window ────────────
-- (A pair already linked keeps its link when a third equal row arrives later, as for cards.)
select pg_temp.set('amb_in1', pg_temp.txn('current', 'transfer_in', 'credit', 500.00, 15));
select pg_temp.set('amb_in2', pg_temp.txn('saver', 'transfer_in', 'credit', 500.00, 16));
select pg_temp.set('amb_out', pg_temp.txn('other', 'transfer_out', 'debit', 500.00, 15));
select is((select count(*)::int from public.card_transfers
           where pg_temp.v('amb_out') in (from_txn_code, to_txn_code)
              or pg_temp.v('amb_in1') in (from_txn_code, to_txn_code)
              or pg_temp.v('amb_in2') in (from_txn_code, to_txn_code)), 0,
          'a transfer out with two equal credits in the window stays unlinked');

-- ── out of window and same account stay unlinked ───────────────────────────
select pg_temp.set('far_out', pg_temp.txn('saver', 'transfer_out', 'debit', 333.00, 1));
select pg_temp.set('far_in', pg_temp.txn('current', 'transfer_in', 'credit', 333.00, 5));
select is(pg_temp.partner('far_out'), null, 'legs more than 3 days apart stay unlinked');
select pg_temp.set('self_out', pg_temp.txn('other', 'transfer_out', 'debit', 444.00, 20));
select pg_temp.set('self_in', pg_temp.txn('other', 'transfer_in', 'credit', 444.00, 20));
select is(pg_temp.partner('self_out'), null, 'two legs on the same account stay unlinked');

-- ── a card repayment is still one ──────────────────────────────────────────
select pg_temp.set('repay_out', pg_temp.txn('other', 'transfer_out', 'debit', 900.00, 22));
select pg_temp.set('repay_in', pg_temp.txn('card', 'payment', 'credit', 900.00, 23));
select is(pg_temp.partner('repay_out'), pg_temp.v('repay_in'), 'a bank transfer out still pairs with a card payment');
select is(pg_temp.flow('repay_out'), 'card_repayment', 'and is a card repayment in cash flow');

-- ── a voided leg drops its link ────────────────────────────────────────────
update public.transactions set status = 'void', voided_at = now() where txn_code = pg_temp.v('sweep_in');
select is(pg_temp.partner('sweep_out'), null, 'voiding one leg drops the link');

select * from finish();
rollback;

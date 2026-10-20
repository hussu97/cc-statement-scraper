-- Phase 2a (20261020110310_bank_accounts): current and savings accounts beside the cards.
-- create_bank_account / record_balance are owner-only; v_bank_balances is the latest checkpoint
-- plus the account's transactions after it; a bank account never shows up where a card is
-- expected; and every function that reads public.accounts is listed here, so a new reader fails
-- this test until someone decides whether it is card-only.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;

-- ── setup: an owner, a viewer, one ledger with an ADCB card ──────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('viewer', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't60-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('viewer')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t60-' || left(pg_temp.v('uid'), 8), 'Bank accounts'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.profile_members (profile_code, user_id, role) values (pg_temp.v('p'), pg_temp.v('viewer')::uuid, 'viewer');

insert into public.accounts (profile_code, bank_code, nickname, credit_limit)
values (pg_temp.v('p'), 'ADCB', 'ADCB card', 20000)
returning pg_temp.set('card_acc', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4)
values (pg_temp.v('p'), pg_temp.v('card_acc'), 'ADCB', '3687');

-- ── create_bank_account ─────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('cur', public.create_bank_account(pg_temp.v('p'), 'ADCB', 'current', '810001', 'Salary'));
select pg_temp.set('sav', public.create_bank_account(pg_temp.v('p'), 'FAB', 'savings', ' 9001 ', null));
select pg_temp.set('old', public.create_bank_account(pg_temp.v('p'), 'FAB', 'current', '9002'));
reset role;

select results_eq(
  $$ select kind, bank_code, account_ref, nickname, currency, credit_limit is null and cycle_close_day is null
     from public.accounts where account_code = pg_temp.v('cur') $$,
  $$ values ('current'::text, 'ADCB'::text, '810001'::text, 'Salary'::text, 'AED'::text, true) $$,
  'the owner adds a current account; card-only columns stay null');
select is((select account_ref from public.accounts where account_code = pg_temp.v('sav')), '9001',
          'the account ref is trimmed');

select pg_temp.as_user('uid');
set local role authenticated;
select throws_ok($$ select public.create_bank_account(pg_temp.v('p'), 'ADCB', 'savings', '810001') $$,
                 '23505', null, 'a second ADCB account ending 810001 is refused');
select throws_ok($$ select public.create_bank_account(pg_temp.v('p'), 'ADCB', 'credit_card', '1234') $$,
                 '22023', null, 'cards are not created here');
select throws_ok($$ select public.create_bank_account(pg_temp.v('p'), 'ADCB', 'current', 'XX12') $$,
                 '22023', null, 'the ref is digits only');
select throws_ok($$ select public.create_bank_account(pg_temp.v('p'), 'NOPE', 'current', '1234') $$,
                 'P0002', null, 'an unknown bank is refused');
reset role;
select pg_temp.as_user('viewer');
set local role authenticated;
select throws_ok($$ select public.create_bank_account(pg_temp.v('p'), 'ADCB', 'savings', '777') $$,
                 '42501', null, 'a viewer cannot add a bank account');
select throws_ok($$ select public.record_balance(pg_temp.v('p'), pg_temp.v('cur'), '10.00') $$,
                 '42501', null, 'a viewer cannot record a balance');
reset role;

select throws_ok($$ update public.accounts set credit_limit = 1000 where account_code = pg_temp.v('cur') $$,
                 '23514', null, 'a bank account cannot carry a credit limit');

-- ── record_balance and v_bank_balances ──────────────────────────────────────
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('cur')), null,
          'no checkpoint yet: no balance');

select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('cp1', public.record_balance(pg_temp.v('p'), pg_temp.v('cur'), '1000.00', now() - interval '2 days'));
select throws_ok($$ select public.record_balance(pg_temp.v('p'), pg_temp.v('card_acc'), '10.00') $$,
                 'P0002', null, 'a card has no recorded balance');
select throws_ok($$ select public.record_balance(pg_temp.v('p'), pg_temp.v('cur'), '12.345') $$,
                 '22023', null, 'at most two decimals');
select throws_ok($$ select public.record_balance(pg_temp.v('p'), pg_temp.v('cur'), 'abc') $$,
                 '22023', null, 'a balance is a number');
select throws_ok($$ select public.record_balance(pg_temp.v('p'), pg_temp.v('cur'), '1.00', now() + interval '1 day') $$,
                 '22023', null, 'no balances dated in the future');
select pg_temp.set('cp_old', public.record_balance(pg_temp.v('p'), pg_temp.v('old'), '-50.25', now() - interval '10 days'));
reset role;

select results_eq(
  $$ select source, created_by::text from public.balance_checkpoints where checkpoint_code = pg_temp.v('cp1') $$,
  $$ values ('manual'::text, pg_temp.v('uid')) $$,
  'a manual checkpoint records who entered it');

-- One debit and one credit after the checkpoint, one debit before it (already in the balance).
insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, txn_at,
                                 description, amount_original, currency_original, amount_aed, amount_source)
values
  (pg_temp.v('p'), pg_temp.v('cur'), 'posted', 'purchase', 'debit', public.dubai_date(now()), now() - interval '1 day',
   'CARREFOUR', 250.00, 'AED', 250.00, 'sms'),
  (pg_temp.v('p'), pg_temp.v('cur'), 'pending', 'refund', 'credit', public.dubai_date(now()), now() - interval '1 hour',
   'REFUND', 40.50, 'AED', 40.50, 'sms'),
  (pg_temp.v('p'), pg_temp.v('cur'), 'posted', 'purchase', 'debit', public.dubai_date(now()) - 3, now() - interval '3 days',
   'BEFORE', 999.00, 'AED', 999.00, 'sms'),
  (pg_temp.v('p'), pg_temp.v('cur'), 'void', 'purchase', 'debit', public.dubai_date(now()), now() - interval '1 hour',
   'VOIDED', 500.00, 'AED', 500.00, 'sms');

select results_eq(
  $$ select anchor_balance, balance, balance_aed, unpriced_count, is_stale
     from public.v_bank_balances where account_code = pg_temp.v('cur') $$,
  $$ values (1000.00::numeric, 790.50::numeric, 790.50::numeric, 0, false) $$,
  'balance = checkpoint − later debits + later credits; earlier and void rows are left out');

select results_eq(
  $$ select balance, is_stale from public.v_bank_balances where account_code = pg_temp.v('old') $$,
  $$ values (-50.25::numeric, true) $$,
  'an overdrawn balance is kept; a checkpoint older than 7 days is stale');

select pg_temp.as_user('uid');
set local role authenticated;
select public.record_balance(pg_temp.v('p'), pg_temp.v('cur'), '800.00');
reset role;
select results_eq(
  $$ select anchor_balance, balance from public.v_bank_balances where account_code = pg_temp.v('cur') $$,
  $$ values (800.00::numeric, 800.00::numeric) $$,
  'a newer checkpoint supersedes the older one and the activity before it');

select throws_ok($$ insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source)
                    values (pg_temp.v('p'), pg_temp.v('card_acc'), now(), 1, 'manual') $$,
                 '22023', null, 'the table itself refuses a checkpoint on a card');

select pg_temp.as_user('viewer');
set local role authenticated;
select is((select count(*)::int from public.v_bank_balances where profile_code = pg_temp.v('p')), 3,
          'a viewer reads the ledger''s bank balances');
reset role;

-- ── card-only readers ignore bank accounts ──────────────────────────────────
select is((select count(*)::int from public.v_account_balances where profile_code = pg_temp.v('p')), 1,
          'v_account_balances lists the card only');
select pg_temp.as_user('uid');
set local role authenticated;
select is((select jsonb_agg(x->>'account_code') from jsonb_array_elements(public.overview(pg_temp.v('p'))->'accounts') x),
          jsonb_build_array(pg_temp.v('card_acc')), 'overview lists the card only');
select is((select jsonb_agg(x->>'kind') from jsonb_array_elements(public.filter_meta(pg_temp.v('p'))->'accounts') x),
          '["credit_card", "current", "savings", "current"]'::jsonb,
          'filter_meta lists every account with its kind, the card first (Phase 2d)');
-- cash_position: the three bank accounts, their balances and the AED total (Phase 2d).
select results_eq(
  $$ select (c->>'total_aed')::numeric, (c->>'complete')::boolean, (c->>'stale_count')::int, (c->>'missing_count')::int,
            jsonb_array_length(c->'accounts')
     from (select public.cash_position(pg_temp.v('p')) c) x $$,
  $$ values (749.75::numeric, false, 1, 1, 3) $$,
  'cash_position: 800.00 + (−50.25), one stale, one with no balance yet (so not complete)');
select is((select x->>'balance' from jsonb_array_elements(public.cash_position(pg_temp.v('p'))->'accounts') x
           where x->>'account_code' = pg_temp.v('cur')), '800.00', 'balances are decimal strings');
reset role;
select is(private.resolve_statement_account(pg_temp.v('p'), 'ADCB', null, null, null, null, null, null, null),
          pg_temp.v('card_acc'), 'a statement without a card number still finds the one ADCB card account');
select throws_ok($$ select private.merge_accounts(pg_temp.v('p'), pg_temp.v('cur'), pg_temp.v('card_acc')) $$,
                 '22023', null, 'a bank account cannot be merged into a card account');

-- ── guard: every reader of public.accounts is classified ────────────────────
-- Adding a function that reads accounts? Decide whether it is card-only (filter kind =
-- 'credit_card', as in 20261020110310) or reads any account, then add it here.
select set_eq(
  $$ select n.nspname || '.' || p.proname
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private', 'authz') and p.prokind = 'f'
       and pg_get_functiondef(p.oid) ~ '\mpublic\.accounts\M' $$,
  array[
    -- card-only, filtered on kind = 'credit_card'
    'private.process_sms', 'private.reprocess_waiting_sms', 'private.resolve_statement_account',
    'private.successor_card_account', 'public.overview', 'public.resolve_review',
    -- refuses to mix kinds
    'private.merge_accounts',
    -- bank accounts (Phase 2a), and every account (2d)
    'public.create_bank_account', 'public.record_balance', 'private.balance_checkpoint_bank_only',
    'public.cash_position', 'public.filter_meta',
    -- reach an account through its statements or transactions, or read a single known account
    -- (refresh_transaction: bank-account SMS is final, Phase 2b)
    'private.account_bank', 'private.apply_sms_statement', 'private.refresh_transaction', 'private.estimate_fx', 'private.filtered_spend',
    'private.generate_insights', 'private.ingest_one_statement', 'private.recategorize',
    'public.budget_status', 'public.preview_rule', 'public.spend_breakdown', 'public.spend_series',
    'public.statement_cycles', 'public.statement_detail',
    -- one-off tooling
    'private.legacy_parity_report', 'private.seed_review_demo'
  ],
  'every function reading public.accounts is classified (card-only or any account)');

select * from finish();
rollback;

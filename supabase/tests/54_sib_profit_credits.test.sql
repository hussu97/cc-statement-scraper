-- SIB profit credits net off the Murabaha charge (20261020110137_sib_profit_credits_net_fees.sql).
-- Runs on a non-empty DB: every key is unique to this run and every assertion is scoped to
-- this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.txn(p_acc text, p_desc text, p_amount numeric, p_kind text, p_direction text) returns text
language sql as $$
  insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description, merchant_code,
                                   amount_original, currency_original, amount_aed, amount_source, status)
  values (pg_temp.v('p'), pg_temp.v(p_acc), p_kind, p_direction, date '2026-05-14', p_desc,
          private.resolve_merchant(p_desc), p_amount, 'AED', p_amount, 'statement_line', 'posted')
  returning txn_code $$;
create function pg_temp.cat_of(p_txn text) returns text language sql as $$
  select c.name from public.transactions t left join public.categories c on c.category_code = t.effective_category_code
  where t.txn_code = p_txn $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't54-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t54-' || left(pg_temp.v('uid'), 8), 'SIB profit'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'SIB'), (pg_temp.v('p'), 'FAB');
select pg_temp.set('sib', (select account_code from public.accounts where profile_code = pg_temp.v('p') and bank_code = 'SIB'));
select pg_temp.set('fab', (select account_code from public.accounts where profile_code = pg_temp.v('p') and bank_code = 'FAB'));

-- ── the seed rules a new profile gets ───────────────────────────────────────
select is((select c.name || ' ' || (r.conditions->>'direction') from public.category_rules r
           join public.categories c using (profile_code, category_code)
           where r.profile_code = pg_temp.v('p') and r.pattern = 'WAKALA PROFIT'),
          'Bank Fees & Interest credit', 'WAKALA PROFIT is a Bank Fees & Interest credit rule');
select is((select r.name || ' ' || r.priority from public.category_rules r
           where r.profile_code = pg_temp.v('p') and r.conditions->>'bank_code' = 'SIB'),
          'seed: BONUS (SIB) 90', 'the SIB BONUS rule is named for its bank and outranks the generic one');

-- ── the May 2026 SIB cycle: 348.90 charge, 341.57 + 7.33 back ───────────────
select pg_temp.set('murabaha', pg_temp.txn('sib', 'MURABAHA PROFIT', 348.90, 'interest', 'debit'));
select pg_temp.set('wakala', pg_temp.txn('sib', 'WAKALA PROFIT', 341.57, 'refund', 'credit'));
select pg_temp.set('bonus', pg_temp.txn('sib', 'BONUS', 7.33, 'refund', 'credit'));
select is(pg_temp.cat_of(pg_temp.v('wakala')), 'Bank Fees & Interest', 'a WAKALA PROFIT credit is a bank-fee refund');
select is(pg_temp.cat_of(pg_temp.v('bonus')), 'Bank Fees & Interest', 'an SIB BONUS credit is a bank-fee refund');
select is((select sum(s.spend_aed) from public.v_spend s join public.categories c on c.category_code = s.category_code
           where s.profile_code = pg_temp.v('p') and c.name = 'Bank Fees & Interest'),
          0.00::numeric, 'net Bank Fees & Interest = 348.90 debit − 341.57 − 7.33 credits');

select pg_temp.set('fee2', pg_temp.txn('sib', 'MURABAHA PROFIT', 360.53, 'interest', 'debit'));
select pg_temp.set('wak2', pg_temp.txn('sib', 'WAKALA PROFIT', 304.99, 'refund', 'credit'));
select pg_temp.set('bon2', pg_temp.txn('sib', 'BONUS', 55.54, 'refund', 'credit'));
select is((select sum(s.spend_aed) from public.v_spend s join public.categories c on c.category_code = s.category_code
           where s.profile_code = pg_temp.v('p') and c.name = 'Bank Fees & Interest'),
          0.00::numeric, 'two cycles: net fee stays debit − credits');

-- ── what stays as it was ────────────────────────────────────────────────────
select is(pg_temp.cat_of(pg_temp.txn('fab', 'BONUS', 25, 'refund', 'credit')), 'Cashback',
          'another bank''s BONUS credit is still Cashback');
select is(pg_temp.cat_of(pg_temp.txn('sib', 'BONUS', 25, 'purchase', 'debit')), null,
          'an SIB BONUS debit matches neither rule');
select is(pg_temp.cat_of(pg_temp.txn('sib', 'MURABAHA PROFIT', 10, 'refund', 'credit')), 'Cashback',
          'a MURABAHA PROFIT credit is still Cashback (DP-09)');

select * from finish();
rollback;

-- merchant_context (20261013181400, audit MA-4): visits, average, 6-month total and first-seen
-- date of a merchant in one ledger, from v_spend.
-- Runs on a non-empty DB: every assertion is scoped to this run's profile; the 6-month window is
-- relative to today (Asia/Dubai).
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.new_user(p_key text) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't50-' || p_key || '-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now())
  returning pg_temp.set(p_key, id::text) $$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.txn(p_profile text, p_acc text, p_date date, p_aed numeric, p_kind text default 'purchase',
                            p_status text default 'posted', p_exclude boolean default false)
returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   merchant_code, amount_original, currency_original, amount_aed, amount_source,
                                   exclude_from_spend, voided_at)
  values (pg_temp.v(p_profile), pg_temp.v(p_acc), p_status, p_kind,
          case when p_kind in ('refund', 'payment') then 'credit' else 'debit' end, p_date, 'T50 CAFE',
          pg_temp.v('m'), p_aed, 'AED', p_aed, 'manual', p_exclude, case when p_status = 'void' then now() end)
  returning txn_code $$;
create function pg_temp.ctx(p_profile text default 'p') returns jsonb language sql as $$
  select public.merchant_context(pg_temp.v(p_profile), pg_temp.v('m')) $$;

select pg_temp.new_user('owner');
select pg_temp.new_user('other');
select pg_temp.as_user('owner');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t50-' || left(pg_temp.v('owner'), 8), 'Merchant'));
reset role;
select pg_temp.as_user('other');
set local role authenticated;
select pg_temp.set('q', public.create_profile('t50o-' || left(pg_temp.v('other'), 8), 'Other'));
reset role;
select set_config('request.jwt.claims', '', true);
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ADCB') returning account_code)
select pg_temp.set('acc', account_code) from a;
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('q'), 'ADCB') returning account_code)
select pg_temp.set('acc_q', account_code) from a;
with m as (insert into public.merchants (merchant_key, display_name)
           values ('t50 cafe ' || gen_random_uuid(), 'T50 Cafe') returning merchant_code)
select pg_temp.set('m', merchant_code) from m;
select pg_temp.set('today', public.dubai_date(now())::text);

-- An empty ledger first: no visits, no error.
select pg_temp.as_user('owner');
set local role authenticated;
select is(pg_temp.ctx(), jsonb_build_object('merchant_code', pg_temp.v('m'), 'visit_count', 0, 'avg_aed', null,
                                            'total_6m_aed', '0.00', 'first_seen', null),
          'a merchant with no spend: zero visits, 0.00 in 6 months, no average or first date');
reset role;

-- Two old visits (a year ago), three recent ones, a refund, and rows that are not spend.
select pg_temp.txn('p', 'acc', pg_temp.v('today')::date - 400, 100.00);
select pg_temp.txn('p', 'acc', pg_temp.v('today')::date - 365, 200.00);
select pg_temp.txn('p', 'acc', pg_temp.v('today')::date - 30, 300.00);
select pg_temp.txn('p', 'acc', pg_temp.v('today')::date - 2, 150.50);
select pg_temp.txn('p', 'acc', pg_temp.v('today')::date, 50.00, 'purchase', 'pending');
select pg_temp.txn('p', 'acc', pg_temp.v('today')::date - 1, 20.00, 'refund');
select pg_temp.txn('p', 'acc', pg_temp.v('today')::date - 3, 999.00, 'purchase', 'void');
select pg_temp.txn('p', 'acc', pg_temp.v('today')::date - 3, 888.00, 'purchase', 'posted', true);
-- The edge of the window: exactly 6 months ago is out, the day after is in.
select pg_temp.txn('p', 'acc', (pg_temp.v('today')::date - interval '6 months')::date, 7.00);
select pg_temp.txn('p', 'acc', (pg_temp.v('today')::date - interval '6 months')::date + 1, 3.00);
-- Another ledger's visit at the same merchant.
select pg_temp.txn('q', 'acc_q', pg_temp.v('today')::date - 5, 5000.00);

select pg_temp.as_user('owner');
set local role authenticated;
select is((pg_temp.ctx()->>'visit_count')::int, 7,
          'visits: purchases in v_spend, pending included; refunds, void and excluded rows are not visits');
select is(pg_temp.ctx()->>'avg_aed', '115.79', 'avg_aed: the purchases'' average, 2 dp (810.50 / 7)');
select is(pg_temp.ctx()->>'total_6m_aed', '483.50',
          'total_6m_aed: net of the refund, from the day after the same date 6 months ago');
select is(pg_temp.ctx()->>'first_seen', (pg_temp.v('today')::date - 400)::text, 'first_seen: the earliest spend date');
select is(jsonb_typeof(pg_temp.ctx()->'total_6m_aed'), 'string', 'money is a decimal string');
select is(jsonb_typeof(pg_temp.ctx()->'avg_aed'), 'string', 'the average too');

select is(pg_temp.ctx()->>'total_6m_aed',
          (select coalesce(sum(spend_aed), 0)::numeric(14,2)::text from public.v_spend
           where profile_code = pg_temp.v('p') and merchant_code = pg_temp.v('m')
             and txn_date > (pg_temp.v('today')::date - interval '6 months')::date),
          'the 6-month total is v_spend''s, nothing re-derived');

-- ── other ledgers ──────────────────────────────────────────────────────────
select throws_ok($$ select public.merchant_context(pg_temp.v('q'), pg_temp.v('m')) $$, '42501', null,
                 'a non-member is refused');
select pg_temp.as_user('other');
select is((pg_temp.ctx('q')->>'visit_count')::int, 1, 'each ledger counts only its own visits');
select is(pg_temp.ctx('q')->>'total_6m_aed', '5000.00', 'and its own total');
reset role;
select set_config('request.jwt.claims', '', true);

select * from finish();
rollback;

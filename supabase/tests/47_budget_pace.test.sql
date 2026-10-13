-- budget_status's pace columns (20261013112601, audit WEB-38): for the current month the server
-- says where a budget should be by today (expected_share, expected_aed) and how far over or under
-- that it is (over_pace_aed), so the web draws the "expected by today" tick and "AED X over pace"
-- without computing them. A past or future month has no "by today": the columns are null.
-- Runs on a non-empty DB: every assertion is scoped to this run's profile; dates are relative to
-- today (Asia/Dubai).
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.txn(p_aed numeric, p_cat text) returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source, manual_category_code)
  values (pg_temp.v('p'), pg_temp.v('acc'), 'posted', 'purchase', 'debit', public.dubai_date(now()), 'T47 SHOP',
          p_aed, 'AED', p_aed, 'manual', p_cat)
  returning txn_code $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't47-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now())
returning pg_temp.set('uid', id::text);
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t47-' || left(pg_temp.v('uid'), 8), 'Pace'));
reset role;
select set_config('request.jwt.claims', '', true);
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ADCB') returning account_code)
select pg_temp.set('acc', account_code) from a;
select pg_temp.set('dining', (select category_code from public.categories
                              where profile_code = pg_temp.v('p') and name = 'Dining'));

select pg_temp.set('month', date_trunc('month', public.dubai_date(now()))::date::text);
-- Days gone, today included, and days in the month: what the expected figures are built from.
select pg_temp.set('elapsed', (public.dubai_date(now()) - pg_temp.v('month')::date + 1)::text);
select pg_temp.set('in_month', extract(day from (pg_temp.v('month')::date + interval '1 month')::date - 1)::text);

-- A total budget far over pace (the whole budget spent today) and a Dining budget barely touched.
insert into public.budgets (profile_code, account_code, category_code, amount_aed, effective_from) values
  (pg_temp.v('p'), null, null, 3000, (pg_temp.v('month')::date - interval '2 month')::date),
  (pg_temp.v('p'), null, pg_temp.v('dining'), 31000, (pg_temp.v('month')::date - interval '2 month')::date);
select pg_temp.txn(3000, null);
select pg_temp.txn(10, pg_temp.v('dining'));

select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;

-- ── the current month ──────────────────────────────────────────────────────
select is((select expected_share from public.budget_status(pg_temp.v('p')) where category_code is null),
          round(pg_temp.v('elapsed')::numeric / pg_temp.v('in_month')::numeric, 4),
          'expected_share is the share of the month gone, today included');

select is((select expected_aed from public.budget_status(pg_temp.v('p')) where category_code is null),
          round(3000 * pg_temp.v('elapsed')::numeric / pg_temp.v('in_month')::numeric, 2),
          'expected_aed is the budget''s even share by today');

select is((select over_pace_aed from public.budget_status(pg_temp.v('p')) where category_code is null),
          3010.00 - round(3000 * pg_temp.v('elapsed')::numeric / pg_temp.v('in_month')::numeric, 2),
          'over_pace_aed is spent (AED 3,010 across categories) minus expected');

select ok((select over_pace_aed > 0 from public.budget_status(pg_temp.v('p')) where category_code is null),
          'more than the whole budget spent is over pace on any day');

select ok((select over_pace_aed < 0 from public.budget_status(pg_temp.v('p')) where category_code = pg_temp.v('dining')),
          'a barely used budget is under pace: over_pace_aed is negative');

select is((select count(*)::int from public.budget_status(pg_temp.v('p'))
           where (over_pace_aed > 0) is distinct from (projected_aed > budget_aed)),
          0, 'over pace exactly when the month is projected to overspend');

select is((select expected_share from public.budget_status(pg_temp.v('p'), pg_temp.v('month')::date, true)
           where category_code is null),
          round(pg_temp.v('elapsed')::numeric / pg_temp.v('in_month')::numeric, 4),
          'the month passed explicitly reads the same as the default');

-- ── a past or future month has no "by today" ──────────────────────────────
select is((select array[expected_share, expected_aed, over_pace_aed]
           from public.budget_status(pg_temp.v('p'), (pg_temp.v('month')::date - interval '1 month')::date)
           where category_code is null),
          array[null, null, null]::numeric[], 'last month: no pace figures');

select is((select array[expected_share, expected_aed, over_pace_aed]
           from public.budget_status(pg_temp.v('p'), (pg_temp.v('month')::date + interval '1 month')::date)
           where category_code is null),
          array[null, null, null]::numeric[], 'next month: no pace figures');

select results_eq(
  $$ select budget_aed, spent_aed from public.budget_status(pg_temp.v('p')) $$,
  $$ values (3000.00::numeric, 3010.00::numeric), (31000.00, 10.00) $$,
  'existing columns are unchanged');
reset role;
select set_config('request.jwt.claims', '', true);

select lives_ok($$ select private.generate_insights(pg_temp.v('p')) $$, 'insights still read the two-argument form');

select * from finish();
rollback;

-- Recurring detection finds variable-amount monthly billers (20261020131549_recurring_variable_billers.sql).
-- Runs on a non-empty DB: every assertion is scoped to this run's profile. Dates are relative to
-- today, the way detect_recurring reads them.
begin;
create extension if not exists pgtap with schema extensions;
set local client_min_messages = warning;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
-- p_amounts[i] is charged (months - i) months before the 1st of this month, plus p_days_off[i] days.
create function pg_temp.charges(p_desc text, p_amounts numeric[], p_days_off int[] default null) returns void
language sql as $$
  insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description, merchant_code,
                                   amount_original, currency_original, amount_aed, amount_source, status)
  select pg_temp.v('p'), pg_temp.v('acc'), 'purchase', 'debit',
         (date_trunc('month', public.dubai_date(now())) - make_interval(months => (cardinality(p_amounts) - i)::int))::date
           + coalesce(p_days_off[i::int], 0),
         p_desc, private.resolve_merchant(p_desc), a, 'AED', a, 'statement_line', 'posted'
  from unnest(p_amounts) with ordinality as x(a, i) $$;
create function pg_temp.series(p_desc text) returns text language sql as $$
  select r.cadence || ' ' || r.occurrences || ' ' || r.status
  from public.recurring_series r
  where r.profile_code = pg_temp.v('p') and r.merchant_code = private.resolve_merchant(p_desc) $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't56-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't56-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t56-' || left(pg_temp.v('uid'), 8), 'Recurring billers'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'FAB');
select pg_temp.set('acc', (select account_code from public.accounts where profile_code = pg_temp.v('p')));

-- DEWA as production has it: one bill on the 1st, AED 286–417 (cv ≈ 0.15).
select pg_temp.charges('T56 FAB DEWA', array[411.76, 416.58, 288.33, 289.96, 288.62, 340.53, 309.04, 286.65]);
-- Etisalat: two bills on the 1st of every month.
select pg_temp.charges('T56 FAB ETISALAT', array[157.50, 174.03, 157.50, 159.90, 175.00, 158.65]);
select pg_temp.charges('T56 FAB ETISALAT', array[418.95, 418.95, 418.95, 418.95, 418.95, 418.95]);
-- A fixed-price subscription (the old rule, kept).
select pg_temp.charges('T56 STREAMING SUB', array[39, 39, 39]);
-- Variable amounts at an unsteady interval: a monthly median gap, but no gap is 26–35 days.
select pg_temp.charges('T56 CORNER SHOP', array[40, 95, 22, 130, 61, 18, 77],
                       array[0, 12, -10, 9, 0, -12, 0]);
-- Frequent variable purchases (in-app, Supercharger): several a month.
select pg_temp.charges('T56 APPLE IN APP', array[150, 220, 45, 310, 90, 15, 205, 60], array[0, 0, 0, 0, 0, 0, 0, 0]);
select pg_temp.charges('T56 APPLE IN APP', array[35, 140, 80, 12, 260, 75, 33, 120], array[9, 11, 13, 8, 14, 10, 7, 12]);
select pg_temp.charges('T56 APPLE IN APP', array[99, 18, 210, 44, 67, 150, 23, 81], array[20, 19, 22, 18, 21, 23, 17, 20]);

select private.detect_recurring(pg_temp.v('p'));

select is(pg_temp.series('T56 FAB DEWA'), 'monthly 8 active', 'a monthly bill whose amount varies 15% is recurring');
select ok((select amount_cv > 0.10 from public.recurring_series
           where profile_code = pg_temp.v('p') and merchant_code = private.resolve_merchant('T56 FAB DEWA')),
          'and keeps its high amount_cv');
select is(pg_temp.series('T56 FAB ETISALAT'), 'monthly 6 active', 'two bills on one day are one monthly billing event');
select is((select expected_amount from public.recurring_series
           where profile_code = pg_temp.v('p') and merchant_code = private.resolve_merchant('T56 FAB ETISALAT')),
          round((157.50 + 174.03 + 157.50 + 159.90 + 175.00 + 158.65) / 6 + 418.95, 2),
          'its expected amount is the two bills together');
select is((select count(*)::int from public.transactions
           where profile_code = pg_temp.v('p') and merchant_code = private.resolve_merchant('T56 FAB ETISALAT')
             and recurring_code is not null),
          12, 'both bills of every month link to the series');
select is(pg_temp.series('T56 STREAMING SUB'), 'monthly 3 active', 'a fixed-price subscription is still recurring');
select is(pg_temp.series('T56 CORNER SHOP'), null, 'variable amounts at an unsteady interval are not recurring');
select is(pg_temp.series('T56 APPLE IN APP'), null, 'frequent variable purchases are not recurring');

select * from finish();
rollback;

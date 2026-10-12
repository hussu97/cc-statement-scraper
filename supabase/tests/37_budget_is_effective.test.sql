-- budget_status.is_effective (20261012210407, audit WEB-28): the server says which budget counts
-- for a month, so no client re-derives the "newest budget of the scope wins" rule. Called as
-- before it returns only the effective budgets; p_include_inactive adds the replaced, upcoming
-- and ended ones flagged false. A non-member is refused.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;

-- ── setup: an owner, a stranger, one ledger ─────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't37-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t37-' || left(pg_temp.v('uid'), 8), 'Budgets'));
reset role;
select set_config('request.jwt.claims', '', true);

select pg_temp.set('month', date_trunc('month', public.dubai_date(now()))::date::text);
select pg_temp.set('dining', (select category_code from public.categories
                              where profile_code = pg_temp.v('p') and kind = 'spend' order by category_code limit 1));

-- Total: an older budget (replaced) and the newer one that counts. Dining: one that ended last
-- month and one that starts next month, so no dining budget counts this month.
insert into public.budgets (profile_code, account_code, category_code, amount_aed, effective_from, effective_to) values
  (pg_temp.v('p'), null, null, 1000, (pg_temp.v('month')::date - interval '2 month')::date, null),
  (pg_temp.v('p'), null, null, 1500, pg_temp.v('month')::date, null),
  (pg_temp.v('p'), null, pg_temp.v('dining'), 300, (pg_temp.v('month')::date - interval '3 month')::date,
   (pg_temp.v('month')::date - interval '1 month')::date),
  (pg_temp.v('p'), null, pg_temp.v('dining'), 400, (pg_temp.v('month')::date + interval '1 month')::date, null);

-- ── as the owner ───────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;

select results_eq(
  $$ select budget_aed, is_effective from public.budget_status(pg_temp.v('p'), pg_temp.v('month')::date) $$,
  $$ values (1500.00::numeric, true) $$,
  'called as before: only the budget that counts, flagged effective');

select results_eq(
  $$ select budget_aed, is_effective
     from public.budget_status(pg_temp.v('p'), pg_temp.v('month')::date, p_include_inactive => true) $$,
  $$ values (1500.00::numeric, true), (1000.00, false), (400.00, false), (300.00, false) $$,
  'p_include_inactive: every budget, the effective one first; replaced, ended and upcoming are not effective');

select results_eq(
  $$ select effective_from, effective_to
     from public.budget_status(pg_temp.v('p'), pg_temp.v('month')::date, true) where budget_aed = 300 $$,
  $$ values ((pg_temp.v('month')::date - interval '3 month')::date, (pg_temp.v('month')::date - interval '1 month')::date) $$,
  'each row carries its own range, so a client can say when it started or ended');

select set_eq(
  $$ select budget_code from public.budget_status(pg_temp.v('p'), pg_temp.v('month')::date, true) where is_effective $$,
  $$ select budget_code from public.budget_status(pg_temp.v('p'), pg_temp.v('month')::date) $$,
  'the effective rows of the full list are exactly what the two-argument call returns');

-- Next month the dining budget starts and counts; the total is unchanged.
select set_eq(
  $$ select budget_aed from public.budget_status(pg_temp.v('p'), (pg_temp.v('month')::date + interval '1 month')::date) $$,
  $$ values (1500.00::numeric), (400.00) $$,
  'an upcoming budget becomes effective in its first month');

-- Two months ago only the old total counts (the newer one hasn't started).
select results_eq(
  $$ select budget_aed, is_effective
     from public.budget_status(pg_temp.v('p'), (pg_temp.v('month')::date - interval '2 month')::date, true)
     where category_code is null $$,
  $$ values (1000.00::numeric, true), (1500.00, false) $$,
  'before the newer budget starts, the older one is effective');
reset role;

-- ── a non-member is refused, not handed an empty list ─────────────────────
select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok(
  $$ select * from public.budget_status(pg_temp.v('p'), pg_temp.v('month')::date) $$,
  '42501', null, 'a non-member cannot read another ledger''s budgets');
reset role;
select set_config('request.jwt.claims', '', true);

-- Insights still read the two-argument form.
select lives_ok($$ select private.generate_insights(pg_temp.v('p')) $$, 'insights still generate');

select * from finish();
rollback;

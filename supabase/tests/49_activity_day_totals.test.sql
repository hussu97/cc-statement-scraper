-- activity_day_totals (20261013181102, audit MA-3): per-day totals for the Activity date headers,
-- over the whole filtered set (private.activity_selection), for the days a page shows.
-- Runs on a non-empty DB: every assertion is scoped to this run's profile.
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
          't49-' || p_key || '-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now())
  returning pg_temp.set(p_key, id::text) $$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.txn(p_date date, p_desc text, p_aed numeric, p_dir text default 'debit',
                            p_status text default 'posted', p_estimate boolean default false)
returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_aed_is_estimate,
                                   amount_source, voided_at)
  values (pg_temp.v('p'), pg_temp.v('acc'), p_status, case when p_dir = 'credit' then 'refund' else 'purchase' end,
          p_dir, p_date, p_desc, coalesce(p_aed, 10), case when p_aed is null then 'USD' else 'AED' end, p_aed,
          p_estimate, 'manual', case when p_status = 'void' then now() end)
  returning txn_code $$;

select pg_temp.new_user('owner');
select pg_temp.new_user('other');
select pg_temp.as_user('owner');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t49-' || left(pg_temp.v('owner'), 8), 'Days'));
reset role;
select set_config('request.jwt.claims', '', true);
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ADCB') returning account_code)
select pg_temp.set('acc', account_code) from a;

-- 31 Aug: two purchases, a refund, a void and an unpriced foreign charge. 1 Sep: one estimated.
select pg_temp.txn('2026-08-31', 'T49 CAFE', 25.50);
select pg_temp.txn('2026-08-31', 'T49 SHOP', 100.00);
select pg_temp.txn('2026-08-31', 'T49 SHOP REFUND', 20.00, 'credit');
select pg_temp.txn('2026-08-31', 'T49 CAFE VOID', 999.00, 'debit', 'void');
select pg_temp.txn('2026-08-31', 'T49 ABROAD', null);
select pg_temp.txn('2026-09-01', 'T49 CAFE', 40.00, 'debit', 'pending', true);
select pg_temp.txn('2026-09-03', 'T49 CAFE', 7.00);

select pg_temp.as_user('owner');
set local role authenticated;

select results_eq(
  $$ select txn_date, txn_count, net_aed, unpriced_count, has_estimate
     from public.activity_day_totals(pg_temp.v('p'), '{}'::jsonb, array['2026-09-01', '2026-08-31']::date[]) $$,
  $$ values ('2026-09-01'::date, 1, '40.00'::text, 0, true),
            ('2026-08-31'::date, 5, '105.50', 1, false) $$,
  'each asked day: every matching row counted, net of pending and posted only (void and unpriced left out), newest first');

select is((select count(*)::int from public.activity_day_totals(pg_temp.v('p'), '{}'::jsonb, array['2026-09-02']::date[])),
          0, 'a day with nothing on it returns no row');
select is((select count(*)::int from public.activity_day_totals(pg_temp.v('p'), '{}'::jsonb, '{}'::date[])),
          0, 'no days, no rows');
select is((select array_agg(txn_date order by txn_date)
           from public.activity_day_totals(pg_temp.v('p'), '{}'::jsonb, array['2026-08-31', '2026-09-03']::date[])),
          array['2026-08-31', '2026-09-03']::date[], 'only the asked days, not the ones between them');

-- The same filters as the list: search, status, and the filter's own date bounds.
select results_eq(
  $$ select txn_date, txn_count, net_aed from public.activity_day_totals(pg_temp.v('p'), '{"q": "cafe"}'::jsonb,
                                                                   array['2026-08-31', '2026-09-01']::date[]) $$,
  $$ values ('2026-09-01'::date, 1, '40.00'::text), ('2026-08-31'::date, 2, '25.50') $$,
  'the search filter applies (the void CAFE row counts, its amount does not)');
select results_eq(
  $$ select txn_date, txn_count, net_aed from public.activity_day_totals(pg_temp.v('p'), '{"status": "posted"}'::jsonb,
                                                                   array['2026-08-31', '2026-09-01']::date[]) $$,
  $$ values ('2026-08-31'::date, 4, '105.50'::text) $$,
  'the status filter applies');
select is((select count(*)::int from public.activity_day_totals(pg_temp.v('p'), '{"from": "2026-09-01"}'::jsonb,
                                                               array['2026-08-31', '2026-09-01']::date[])),
          1, 'the filter''s from date still bounds the result');
select is((select sum(txn_count)::int from public.activity_day_totals(pg_temp.v('p'), '{}'::jsonb,
                                                                     array['2026-08-31', '2026-09-01', '2026-09-03']::date[])),
          (public.activity_summary(pg_temp.v('p'), '2026-08-31', '2026-09-03')->>'txn_count')::int,
          'the day counts add up to the summary row for the same span');

select throws_ok($$ select * from public.activity_day_totals(pg_temp.v('p'), '{"colour": "red"}'::jsonb, array['2026-08-31']::date[]) $$,
                 '22023', null, 'an unknown filter key is refused, as for the bulk actions');
select throws_ok($$ select * from public.activity_day_totals(pg_temp.v('p'), '{}'::jsonb,
                     (select array_agg(d::date) from generate_series('2020-01-01'::date, '2020-01-01'::date + 2000, '1 day') d)) $$,
                 '22023', null, 'at most 2000 days per call');

-- ── another user ───────────────────────────────────────────────────────────
select pg_temp.as_user('other');
select throws_ok($$ select * from public.activity_day_totals(pg_temp.v('p'), '{}'::jsonb, array['2026-08-31']::date[]) $$,
                 '42501', null, 'a non-member is refused');
reset role;
select set_config('request.jwt.claims', '', true);

select * from finish();
rollback;

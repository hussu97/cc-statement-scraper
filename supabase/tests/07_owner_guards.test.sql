-- Owner guards: add_profile_member cannot demote the last owner; category_breakdown
-- returns a server-side change fraction vs the previous period.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ── helpers ─────────────────────────────────────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.new_user(p_key text, p_email text) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_email,
          '{}', '{}', now(), now());
  select pg_temp.set(p_key, (select id::text from auth.users where email = p_email));
$$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.role_of(p_key text) returns text language sql as $$
  select m.role from public.profile_members m
  where m.profile_code = pg_temp.v('p') and m.user_id = pg_temp.v(p_key)::uuid $$;
create function pg_temp.txn(p_date date, p_desc text, p_aed numeric, p_category text) returns void language sql as $$
  insert into public.transactions (profile_code, account_code, card_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source, manual_category_code)
  select pg_temp.v('p'), c.account_code, c.card_code, 'posted', 'purchase', 'debit', p_date, p_desc,
         p_aed, 'AED', p_aed, 'manual', p_category
  from public.cards c where c.card_code = pg_temp.v('card')
$$;

-- ── setup: owner A, viewer B, signed-up outsider C ─────────────────────────
select pg_temp.new_user('ua', 'guard-a@test.dev');
select pg_temp.new_user('ub', 'guard-b@test.dev');
select pg_temp.new_user('uc', 'guard-c@test.dev');

select pg_temp.as_user('ua');
set local role authenticated;
select pg_temp.set('p', public.create_profile('guards', 'Guards'));
select is(public.add_profile_member(pg_temp.v('p'), 'guard-b@test.dev', 'viewer'), 'added', 'B is added as a viewer');

-- ── 1. the last owner cannot be demoted ────────────────────────────────────
select throws_ok(format('select public.add_profile_member(%L, %L, %L)', pg_temp.v('p'), 'guard-a@test.dev', 'viewer'),
                 '22023', null, 'the sole owner cannot demote themselves to viewer');
select throws_ok(format('select public.add_profile_member(%L, %L, %L)', pg_temp.v('p'), 'GUARD-A@test.dev', 'viewer'),
                 '22023', null, 'the guard matches the email case-insensitively');
select is(pg_temp.role_of('ua'), 'owner', 'A is still the owner after the refused demotion');
select is(public.add_profile_member(pg_temp.v('p'), 'guard-a@test.dev', 'owner'), 'added',
          're-asserting the last owner as owner is allowed');
select is(public.add_profile_member(pg_temp.v('p'), 'guard-c@test.dev', 'viewer'), 'added',
          'adding a new viewer is unaffected by the guard');
select is(public.add_profile_member(pg_temp.v('p'), 'later@test.dev', 'viewer'), 'invited',
          'inviting a not-yet-signed-up email as viewer still works');
select is(public.add_profile_member(pg_temp.v('p'), 'guard-b@test.dev', 'viewer'), 'added',
          'setting an existing viewer to viewer again is a no-op, not an error');

-- ── 2. with a second owner, demotion is allowed — until one owner remains ──
select is(public.add_profile_member(pg_temp.v('p'), 'guard-b@test.dev', 'owner'), 'added', 'B is promoted to owner');
select is(public.add_profile_member(pg_temp.v('p'), 'guard-a@test.dev', 'viewer'), 'added',
          'A may step down to viewer while B is also an owner');
select is(pg_temp.role_of('ua'), 'viewer', 'A is now a viewer');
select throws_ok(format('select public.add_profile_member(%L, %L, %L)', pg_temp.v('p'), 'guard-c@test.dev', 'viewer'),
                 '42501', null, 'a demoted viewer can no longer change members');

select pg_temp.as_user('ub');
select throws_ok(format('select public.add_profile_member(%L, %L, %L)', pg_temp.v('p'), 'guard-b@test.dev', 'viewer'),
                 '22023', null, 'B, now the only owner, cannot demote themselves');
select is(pg_temp.role_of('ub'), 'owner', 'B is still the owner');
select is((select count(*)::int from public.profile_members m where m.profile_code = pg_temp.v('p') and m.role = 'owner'), 1,
          'the profile keeps exactly one owner');
reset role;

-- ── 3. category_breakdown.change ───────────────────────────────────────────
with a as (
  insert into public.accounts (profile_code, bank_code, product_name)
  values (pg_temp.v('p'), 'ADCB', 'Guard card') returning account_code
)
select pg_temp.set('acc', account_code) from a;
insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), pg_temp.v('acc'), 'ADCB', '4242');
select pg_temp.set('card', (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '4242'));
select pg_temp.set('dining', (select category_code from public.categories where profile_code = pg_temp.v('p') and name = 'Dining'));
select pg_temp.set('travel', (select category_code from public.categories where profile_code = pg_temp.v('p') and name = 'Travel'));

-- Current period 2024-03-01..2024-03-31; the previous period is the 31 days before it.
select pg_temp.txn('2024-02-10', 'ZQG DINER', 100, pg_temp.v('dining'));
select pg_temp.txn('2024-03-10', 'ZQG DINER', 150, pg_temp.v('dining'));
select pg_temp.txn('2024-03-12', 'ZQG FLIGHT', 80, pg_temp.v('travel'));
select pg_temp.txn('2024-02-14', 'ZQG UNKNOWN', 80, null);
select pg_temp.txn('2024-03-14', 'ZQG UNKNOWN', 40, null);
select pg_temp.txn('2024-01-29', 'ZQG DINER', 999, pg_temp.v('dining')); -- before the previous period

select pg_temp.as_user('ub');
set local role authenticated;
select is((select change from public.category_breakdown(pg_temp.v('p'), '2024-03-01', '2024-03-31')
           where category_code = pg_temp.v('dining')), 0.5000::numeric, 'Dining 100 → 150 is +0.5');
select is((select change from public.category_breakdown(pg_temp.v('p'), '2024-03-01', '2024-03-31')
           where category_code is null), -0.5000::numeric, 'Uncategorized 80 → 40 is −0.5');
select is((select change from public.category_breakdown(pg_temp.v('p'), '2024-03-01', '2024-03-31')
           where category_code = pg_temp.v('travel')), null::numeric, 'change is null when the previous period had no spend');
select is((select prev_amount from public.category_breakdown(pg_temp.v('p'), '2024-03-01', '2024-03-31')
           where category_code = pg_temp.v('travel')), 0::numeric, 'prev_amount is still 0, not null');
select is((select string_agg(name || ':' || amount || ':' || share || ':' || prev_amount, ',' order by amount desc)
           from public.category_breakdown(pg_temp.v('p'), '2024-03-01', '2024-03-31')),
          'Dining:150.00:0.5556:100.00,Travel:80.00:0.2963:0,Uncategorized:40.00:0.1481:80.00',
          'existing columns are unchanged');

select pg_temp.as_user('uc');
select is((select count(*)::int from public.category_breakdown(pg_temp.v('p'), '2024-03-01', '2024-03-31')), 3,
          'a viewer can read the breakdown');
reset role;

select ok(has_function_privilege('authenticated', 'public.category_breakdown(text, date, date)', 'execute'),
          'authenticated keeps execute on category_breakdown');
select ok(has_function_privilege('service_role', 'public.category_breakdown(text, date, date)', 'execute'),
          'service_role keeps execute on category_breakdown');

select * from finish();
rollback;

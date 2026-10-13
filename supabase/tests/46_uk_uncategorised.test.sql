-- "No category" reads "Uncategorised" from every RPC (20261013111525, audit WEB-31), as it does on
-- every screen. The keys stay codes (`__uncategorized__`). A guard keeps the US spelling out of
-- every function body, except the legacy import, which matches v1's own category name.
-- Runs on a non-empty DB: every assertion is scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.txn(p_desc text, p_aed numeric, p_cat text) returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source, manual_category_code)
  values (pg_temp.v('p'), pg_temp.v('acc'), 'posted', 'purchase', 'debit', '2024-03-10', p_desc,
          p_aed, 'AED', p_aed, 'manual', p_cat)
  returning txn_code $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't46-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now())
returning pg_temp.set('uid', id::text);
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t46-' || left(pg_temp.v('uid'), 8), 'Spelling'));
reset role;
select set_config('request.jwt.claims', '', true);
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ADCB') returning account_code)
select pg_temp.set('acc', account_code) from a;
select pg_temp.set('dining', (select category_code from public.categories
                              where profile_code = pg_temp.v('p') and name = 'Dining'));

select pg_temp.txn('T46 DINER', 100, pg_temp.v('dining'));
select pg_temp.txn('T46 SOMETHING', 40, null);

select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;

select is((select name from public.category_breakdown(pg_temp.v('p'), '2024-03-01', '2024-03-31')
           where category_code is null),
          'Uncategorised', 'category_breakdown names no category "Uncategorised"');

select is((select group_label from public.spend_series(pg_temp.v('p'), '2024-03-01', '2024-03-31', 'month', 'category')
           where group_key is null),
          'Uncategorised', 'spend_series labels the no-category series "Uncategorised"');

select is((select g->>'label'
           from jsonb_array_elements(public.spend_breakdown(pg_temp.v('p'), '2024-03-01', '2024-03-31', 'category')->'groups') g
           where g->>'key' = '__uncategorized__'),
          'Uncategorised', 'spend_breakdown labels its __uncategorized__ group "Uncategorised"; the key is unchanged');
reset role;
select set_config('request.jwt.claims', '', true);

-- ── guard: the US spelling is not a label anywhere ────────────────────────────
select is(array(select p.oid::regprocedure::text
                from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname in ('public', 'private', 'authz')
                  and p.prosrc like '%''Uncategorized''%'
                  and p.oid <> 'private.import_legacy_metadata(jsonb, text)'::regprocedure
                order by 1),
          '{}'::text[],
          'no function outside the legacy import says ''Uncategorized'' (UK spelling, WEB-31)');

select * from finish();
rollback;

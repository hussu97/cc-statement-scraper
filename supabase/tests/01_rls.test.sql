-- Guard: every public table has RLS + a policy; profiles are isolated per member.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ── helpers (pg_temp: vanish with the session) ──────────────────────────────
create function pg_temp.new_user(p_email text) returns uuid language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_email,
          '{}', '{}', now(), now())
  returning id $$;
create function pg_temp.claims(p_uid uuid) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true) $$;

-- ── guard: RLS everywhere ───────────────────────────────────────────────────
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  null,
  'every public table has row level security enabled'
);
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname)),
  null,
  'every public table has at least one policy'
);
select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')),
  null,
  'every SECURITY DEFINER function pins search_path'
);
select is(
  (select array_agg(v.relname::text) from pg_class v join pg_namespace n on n.oid = v.relnamespace
   where n.nspname = 'public' and v.relkind = 'v'
     and not coalesce((select option_value = 'true' from pg_options_to_table(v.reloptions) where option_name = 'security_invoker'), false)),
  null,
  'every public view is security_invoker'
);

select is(
  (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'authz') and p.prokind = 'f'
     and (not has_function_privilege('anon', p.oid, 'EXECUTE') or not has_function_privilege('authenticated', p.oid, 'EXECUTE'))
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')),
  null,
  'no public/authz function has EXECUTE revoked (calling one segfaults PG 17.6.1.104); guard in the body instead'
);

-- ── two users, two profiles ─────────────────────────────────────────────────
create temp table ids (k text primary key, v text);
grant all on ids to authenticated;
insert into ids values ('ua', pg_temp.new_user('a@test.dev')::text), ('ub', pg_temp.new_user('b@test.dev')::text);

select pg_temp.claims((select v::uuid from ids where k = 'ua'));
set local role authenticated;
insert into ids select 'pa', public.create_profile('alice', 'Alice');
reset role;
select pg_temp.claims((select v::uuid from ids where k = 'ub'));
set local role authenticated;
insert into ids select 'pb', public.create_profile('bob', 'Bob');
reset role;

select is((select count(*)::int from public.categories where profile_code = (select v from ids where k = 'pa')), 28,
          'create_profile seeds 28 default categories');
select is((select count(*)::int from public.category_rules where profile_code = (select v from ids where k = 'pa')), 244,
          'create_profile seeds 244 default rules');

-- Data for bob's profile, written by the system.
insert into public.accounts (profile_code, bank_code) select v, 'FAB' from ids where k = 'pb';

select pg_temp.claims((select v::uuid from ids where k = 'ua'));
set local role authenticated;
select is((select count(*)::int from public.profiles), 1, 'alice sees only her profile');
select is((select count(*)::int from public.accounts), 0, 'alice cannot see bob''s accounts');
select is((select count(*)::int from public.categories where profile_code = (select v from ids where k = 'pb')), 0,
          'alice cannot see bob''s categories');
select throws_ok(
  $$ insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
     select v, 'x', 'x.pdf', repeat('a', 64), 1, 'upload' from ids where k = 'pa' $$,
  '42501', null, 'clients cannot insert documents directly');
select throws_ok(
  $$ select public.ingest_sms((select v from ids where k = 'pb'), '[]'::jsonb) $$,
  '42501', null, 'alice cannot ingest SMS into bob''s profile');
select throws_ok(
  $$ select public.ingest_parsed_document('doc_x', '{}'::jsonb) $$,
  '42501', null, 'clients cannot call the worker ingest RPC');
select throws_ok(
  $$ select token_hash from public.service_tokens $$,
  '42501', null, 'token hashes are not readable by clients');
select lives_ok(
  $$ select public.create_service_token((select v from ids where k = 'pa'), 'scraper', array['statements:upload']) $$,
  'an owner can create a service token');
select throws_ok(
  $$ select public.create_service_token((select v from ids where k = 'pb'), 'evil', array['statements:upload']) $$,
  '42501', null, 'a non-member cannot create a token for another profile');
reset role;

-- ── service token authentication ────────────────────────────────────────────
select pg_temp.claims((select v::uuid from ids where k = 'ua'));
set local role authenticated;
insert into ids select 'tok', (public.create_service_token((select v from ids where k = 'pa'), 'cli', array['statements:upload']))->>'token';
reset role;
select set_config('request.jwt.claims', '', true);
select is(public.authenticate_service_token((select v from ids where k = 'tok'), 'statements:upload', 'alice'),
          (select v from ids where k = 'pa'), 'a valid token resolves to its profile');
select throws_ok($$ select public.authenticate_service_token((select v from ids where k = 'tok'), 'sms:ingest') $$,
                 '28000', null, 'a token without the scope is rejected');
select throws_ok($$ select public.authenticate_service_token((select v from ids where k = 'tok'), 'statements:upload', 'bob') $$,
                 '28000', null, 'a token cannot act for another profile key');
select throws_ok($$ select public.authenticate_service_token('ccs_nope', 'statements:upload') $$,
                 '28000', null, 'an unknown token is rejected');

-- ── anon sees nothing ───────────────────────────────────────────────────────
set local role anon;
select throws_ok($$ select count(*) from public.transactions $$, '42501', null, 'anon has no table access');
reset role;

select * from finish();
rollback;

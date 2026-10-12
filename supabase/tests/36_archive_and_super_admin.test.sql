-- Super admin reads every active profile but writes only its own; archived profiles are
-- invisible to everyone; queue messages are archived, never deleted.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated, service_role;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.new_user(p_key text, p_confirmed boolean default true) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                          created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't36-' || p_key || '-' || gen_random_uuid() || '@test.dev', case when p_confirmed then now() end, '{}', '{}',
          now(), now())
  returning pg_temp.set(p_key, id::text) $$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.as_system() returns text language sql as $$ select set_config('request.jwt.claims', '', true) $$;
create function pg_temp.new_profile(p_user text, p_key text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  v := public.create_profile('t36' || p_key || '-' || left(md5(random()::text), 8), 'T36 ' || p_key);
  reset role;
  perform pg_temp.as_system();
  return pg_temp.set('p' || p_key, v);
end $$;

-- sa: super admin (own profile S); un: super-admin email, unconfirmed; ub: owner of B; uc: stranger
select pg_temp.new_user('sa'), pg_temp.new_user('un', false), pg_temp.new_user('ub'), pg_temp.new_user('uc');
insert into private.super_admins (email)
select lower(email) from auth.users where id in (pg_temp.v('sa')::uuid, pg_temp.v('un')::uuid);
select pg_temp.new_profile('sa', 's'), pg_temp.new_profile('ub', 'b'), pg_temp.new_profile('uc', 'c');
select pg_temp.as_system();
select ok(public.ingest_sms(pg_temp.v('pb'), jsonb_build_array(jsonb_build_object(
  'client_msg_id', gen_random_uuid(), 'received_at', now(), 'sender', 'ADCBAlert', 'body', 't36 body'))) is not null,
  'B has an SMS');

-- ── super admin: reads everything ───────────────────────────────────────────
select pg_temp.as_user('sa');
set local role authenticated;
select ok(authz.is_super_admin(), 'a confirmed super-admin email is a super admin');
select ok(pg_temp.v('pb') = any (authz.my_profile_codes()) and pg_temp.v('pc') = any (authz.my_profile_codes()),
          'the super admin can read every profile');
select ok(not (pg_temp.v('pb') = any (authz.my_owned_profile_codes())), 'but owns only its own');
select is((select count(*)::int from public.profiles where profile_code in (pg_temp.v('pb'), pg_temp.v('pc'))), 2,
          'other profiles are visible');
select is((select count(*)::int from public.sms_messages where profile_code = pg_temp.v('pb')), 1, 'with their data');
select is((select count(*)::int from public.profile_members where profile_code = pg_temp.v('pb')), 1, 'and members');
select lives_ok($$ select public.list_profile_members(pg_temp.v('pb')) $$, 'member-level RPCs work on others');
select lives_ok($$ select public.list_profile_secrets(pg_temp.v('pb')) $$, 'including secret names');

-- … and writes nothing but its own
update public.profiles set name = 'hijacked' where profile_code = pg_temp.v('pb');
select throws_ok($$ insert into public.budgets (profile_code, amount_aed, effective_from)
                    values (pg_temp.v('pb'), 100, date_trunc('month', current_date)) $$,
                 '42501', null, 'the super admin cannot insert into another ledger');
select throws_ok($$ select public.ingest_sms(pg_temp.v('pb'), '[]'::jsonb) $$, '42501', null,
                 'nor call owner RPCs on it');
select throws_ok($$ select public.add_profile_member(pg_temp.v('pb'), 'x@test.dev', 'viewer') $$, '42501', null,
                 'nor add members');
select throws_ok($$ select public.delete_profile(pg_temp.v('pb'), 'whatever') $$, '42501', null, 'nor archive it');
update public.profiles set name = 'T36 mine' where profile_code = pg_temp.v('ps');
select lives_ok($$ insert into public.budgets (profile_code, amount_aed, effective_from)
                   values (pg_temp.v('ps'), 100, date_trunc('month', current_date)) $$,
                'the super admin edits its own ledger');
reset role;
select pg_temp.as_system();
select is((select name from public.profiles where profile_code = pg_temp.v('pb')), 'T36 b', 'the update of B changed nothing');
select is((select name from public.profiles where profile_code = pg_temp.v('ps')), 'T36 mine', 'its own update applied');

-- ── unconfirmed super-admin email, and ordinary users ───────────────────────
select pg_temp.as_user('un');
set local role authenticated;
select ok(not authz.is_super_admin(), 'an unconfirmed email is not a super admin');
select is((select count(*)::int from public.profiles where profile_code = pg_temp.v('pb')), 0, 'and sees no other profile');
reset role;
select pg_temp.as_user('uc');
set local role authenticated;
select ok(not authz.is_super_admin(), 'an ordinary user is not a super admin');
select is((select count(*)::int from public.profiles where profile_code in (pg_temp.v('pb'), pg_temp.v('ps'))), 0,
          'an ordinary user still sees only its own profiles');
select throws_ok($$ select public.list_profile_members(pg_temp.v('pb')) $$, '42501', null, 'and cannot read others');
reset role;

-- ── archived profiles are invisible, also to the super admin ────────────────
select pg_temp.as_system();
update public.profiles set archived_at = now() where profile_code = pg_temp.v('pc');
select pg_temp.as_user('sa');
set local role authenticated;
select is((select count(*)::int from public.profiles where profile_code = pg_temp.v('pc')), 0,
          'an archived profile is hidden from the super admin');
select throws_ok($$ select public.list_profile_members(pg_temp.v('pc')) $$, '42501', null, 'and its RPCs refuse');
reset role;
select pg_temp.as_system();

-- ── queues archive, never delete ────────────────────────────────────────────
set local role service_role;
select pg_temp.set('m1', public.queue_send('sms_fallback', jsonb_build_object('t36', 1))::text);
select ok(public.queue_delete('sms_fallback', pg_temp.v('m1')::bigint), 'queue_delete acknowledges');
select pg_temp.set('m2', public.queue_send('sms_fallback', jsonb_build_object('t36', 2))::text);
select public.queue_to_dlq('sms_fallback', pg_temp.v('m2')::bigint, jsonb_build_object('t36', 2), 't36 reason');
select cmp_ok(public.drain_dlq('sms_fallback'), '>=', 1::bigint, 'drain_dlq counts what it archives');
reset role;
select ok(not exists (select 1 from pgmq.q_sms_fallback where message ? 't36'), 'acknowledged messages leave the queue');
select ok(exists (select 1 from pgmq.a_sms_fallback where msg_id = pg_temp.v('m1')::bigint), 'but are archived');
select ok(exists (select 1 from pgmq.a_sms_fallback where msg_id = pg_temp.v('m2')::bigint),
          'a dead-lettered message is archived from its queue');
select ok(not exists (select 1 from pgmq.q_sms_fallback_dlq where message ? 't36'), 'drain_dlq empties the DLQ');
select ok(exists (select 1 from pgmq.a_sms_fallback_dlq where message->>'dlq_reason' = 't36 reason'),
          'and keeps the dead letter with its reason');

select * from finish();
rollback;

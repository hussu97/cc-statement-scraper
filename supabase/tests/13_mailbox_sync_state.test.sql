-- SRV-15: merge_mailbox_sync_state merges keys instead of overwriting the snapshot,
-- never moves the Gmail cursor backwards, and is service-role only.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated, service_role;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;

-- ── setup (as postgres): a profile with one Gmail mailbox ───────────────────
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'sync-state@test.dev', '{}', '{}', now(), now());
select pg_temp.set('u', (select id::text from auth.users where email = 'sync-state@test.dev'));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('u'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('syncstate', 'Sync state'));
reset role;
insert into public.email_mailboxes (profile_code, provider, mailbox_email, sync_state)
values (pg_temp.v('p'), 'gmail', 'me@gmail.test', '{"gmail_history_id": "100", "watch_label_ids": ["INBOX"]}');
select pg_temp.set('m', (select mailbox_code from public.email_mailboxes where profile_code = pg_temp.v('p')));

-- ── merge semantics ─────────────────────────────────────────────────────────
set local role service_role;
select is(public.merge_mailbox_sync_state(pg_temp.v('m'), '{"gmail_history_id": "150", "provider": "gmail"}') ->> 'gmail_history_id',
          '150', 'a newer cursor replaces the stored one');
select is(public.merge_mailbox_sync_state(pg_temp.v('m'), '{"gmail_history_id": "120", "last_error": null}') ->> 'gmail_history_id',
          '150', 'an older cursor (a stale concurrent writer) never moves it backwards');
select is(public.merge_mailbox_sync_state(pg_temp.v('m'), '{"gmail_history_id": null}') ->> 'gmail_history_id',
          '150', 'a null cursor never clears the stored one');
select is(public.merge_mailbox_sync_state(pg_temp.v('m'), '{"gmail_history_id": "9007199254740993"}') ->> 'gmail_history_id',
          '9007199254740993', 'cursors beyond 2^53 compare numerically');
select is((select sync_state -> 'watch_label_ids' from public.email_mailboxes where mailbox_code = pg_temp.v('m')),
          '["INBOX"]'::jsonb, 'keys absent from the patch are kept');
select ok((select sync_state ? 'last_error' and sync_state ? 'updated_at' and sync_state ->> 'provider' = 'gmail'
           from public.email_mailboxes where mailbox_code = pg_temp.v('m')),
          'patched keys are merged and updated_at is stamped');

select public.merge_mailbox_sync_state(pg_temp.v('m'), '{}', '2026-10-09 10:00+00', '2026-10-16 10:00+00');
select is((select last_synced_at from public.email_mailboxes where mailbox_code = pg_temp.v('m')),
          '2026-10-09 10:00+00'::timestamptz, 'last_synced_at is set when passed');
select public.merge_mailbox_sync_state(pg_temp.v('m'), '{"x": 1}');
select is((select watch_expires_at from public.email_mailboxes where mailbox_code = pg_temp.v('m')),
          '2026-10-16 10:00+00'::timestamptz, 'null column arguments keep the stored values');

select throws_ok(format('select public.merge_mailbox_sync_state(%L, %L)', pg_temp.v('m'), '[1]'),
                 '22023', null, 'a non-object patch is rejected');
select throws_ok($$select public.merge_mailbox_sync_state('mbx_00000000000000000000000000', '{}')$$,
                 'P0002', null, 'an unknown mailbox is P0002');
reset role;

-- ── service role only ───────────────────────────────────────────────────────
set local role authenticated;
select throws_ok(format('select public.merge_mailbox_sync_state(%L, %L)', pg_temp.v('m'), '{"gmail_history_id": "1"}'),
                 '42501', null, 'a signed-in member cannot write sync_state through the RPC');
reset role;

select * from finish();
rollback;

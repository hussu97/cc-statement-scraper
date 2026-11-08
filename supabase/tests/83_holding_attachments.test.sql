-- Holding attachments (20261108112842_holding_attachments): the private bucket's policies,
-- add/remove_holding_attachment, and holding_detail's attachments.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;

-- ── setup: an owner, a viewer, a stranger with their own ledger ─────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('viewer', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't83-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('viewer'), pg_temp.v('uid2')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t83-' || left(pg_temp.v('uid'), 8), 'Attachments'));
select pg_temp.set('bar', public.save_holding(pg_temp.v('p'), '100 g bar', 'gold', '100', p_cost_aed => '30000.00'));
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select pg_temp.set('p2', public.create_profile('t83b-' || left(pg_temp.v('uid2'), 8), 'Other'));
select pg_temp.set('bar2', public.save_holding(pg_temp.v('p2'), 'Their bar', 'gold', '50'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.profile_members (profile_code, user_id, role) values (pg_temp.v('p'), pg_temp.v('viewer')::uuid, 'viewer');

select pg_temp.set('path', pg_temp.v('p') || '/' || pg_temp.v('bar') || '/invoice-1.jpg');

-- ── bucket ──────────────────────────────────────────────────────────────────
select is((select public from storage.buckets where id = 'holding-attachments'), false, 'the bucket is private');
select is((select file_size_limit from storage.buckets where id = 'holding-attachments'), 10485760::bigint, '10 MB a file');

-- The owner uploads into their ledger's folder; nobody else can.
select pg_temp.as_user('uid');
set local role authenticated;
select lives_ok(
  format($$ insert into storage.objects (bucket_id, name, metadata) values ('holding-attachments', %L,
            '{"mimetype": "image/jpeg", "size": 2400000}'::jsonb) $$, pg_temp.v('path')),
  'an owner uploads into their ledger''s folder');
select throws_ok(
  format($$ insert into storage.objects (bucket_id, name, metadata) values ('holding-attachments', %L, '{}'::jsonb) $$,
         pg_temp.v('p2') || '/' || pg_temp.v('bar2') || '/x.jpg'),
  '42501', null, 'not into another ledger''s folder');
reset role;

select pg_temp.as_user('viewer');
set local role authenticated;
select throws_ok(
  format($$ insert into storage.objects (bucket_id, name, metadata) values ('holding-attachments', %L, '{}'::jsonb) $$,
         pg_temp.v('p') || '/' || pg_temp.v('bar') || '/viewer.jpg'),
  '42501', null, 'a viewer cannot upload');
select is((select count(*)::int from storage.objects where bucket_id = 'holding-attachments' and name = pg_temp.v('path')),
          1, 'a viewer reads the ledger''s files');
reset role;

select pg_temp.as_user('uid2');
set local role authenticated;
select is((select count(*)::int from storage.objects where bucket_id = 'holding-attachments' and name = pg_temp.v('path')),
          0, 'a stranger does not see them');
reset role;

-- ── add_holding_attachment ──────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('att', public.add_holding_attachment(pg_temp.v('p'), pg_temp.v('bar'), pg_temp.v('path'), 'Invoice.jpg', ' Purchase invoice '));
select matches(pg_temp.v('att'), '^hat_[0-9a-z]{26}$', 'returns an attachment code');
select results_eq(
  format($$ select mime_type, size_bytes, caption, file_name from public.holding_attachments where attachment_code = %L $$, pg_temp.v('att')),
  $$ values ('image/jpeg'::text, 2400000::bigint, 'Purchase invoice'::text, 'Invoice.jpg'::text) $$,
  'type and size come from Storage; the caption is trimmed');
select is(public.add_holding_attachment(pg_temp.v('p'), pg_temp.v('bar'), pg_temp.v('path'), 'Invoice.jpg'), pg_temp.v('att'),
          'recording the same path again returns the same attachment');
select throws_ok(
  format($$ select public.add_holding_attachment(%L, %L, %L, 'x.jpg') $$, pg_temp.v('p'), pg_temp.v('bar'),
         pg_temp.v('p') || '/' || pg_temp.v('bar') || '/missing.jpg'),
  'P0002', 'the file has not been uploaded', 'a path with no object is refused');
select throws_ok(
  format($$ select public.add_holding_attachment(%L, %L, %L, 'x.jpg') $$, pg_temp.v('p'), pg_temp.v('bar'),
         pg_temp.v('p') || '/invoice-1.jpg'),
  '22023', null, 'a path outside the holding''s folder is refused');
select throws_ok(
  format($$ select public.add_holding_attachment(%L, %L, %L, 'x.jpg') $$, pg_temp.v('p'), pg_temp.v('bar2'), pg_temp.v('path')),
  'P0002', 'holding not found', 'another ledger''s holding is refused');
select throws_ok(
  format($$ select public.add_holding_attachment(%L, %L, %L, 'x.jpg') $$, pg_temp.v('p2'), pg_temp.v('bar2'),
         pg_temp.v('p2') || '/' || pg_temp.v('bar2') || '/x.jpg'),
  '42501', null, 'not an owner of another ledger');

-- ── holding_detail ──────────────────────────────────────────────────────────
select results_eq(
  format($$ select a->>'attachment_code', a->>'storage_path', a->>'mime_type', a->>'size_bytes'
            from jsonb_array_elements(public.holding_detail(%L, %L)->'attachments') a $$, pg_temp.v('p'), pg_temp.v('bar')),
  format($$ values (%L::text, %L::text, 'image/jpeg'::text, '2400000'::text) $$, pg_temp.v('att'), pg_temp.v('path')),
  'holding_detail lists the attachment');
reset role;

select pg_temp.as_user('viewer');
set local role authenticated;
select is(jsonb_array_length(public.holding_detail(pg_temp.v('p'), pg_temp.v('bar'))->'attachments'), 1, 'a viewer sees it');
select is((select count(*)::int from public.holding_attachments), 1, 'a viewer reads the row');
select throws_ok(
  format($$ select public.add_holding_attachment(%L, %L, %L, 'x.jpg') $$, pg_temp.v('p'), pg_temp.v('bar'), pg_temp.v('path')),
  '42501', null, 'a viewer cannot add');
select throws_ok(
  format($$ select public.remove_holding_attachment(%L, %L) $$, pg_temp.v('p'), pg_temp.v('att')),
  '42501', null, 'a viewer cannot remove');
reset role;

select pg_temp.as_user('uid2');
set local role authenticated;
select is((select count(*)::int from public.holding_attachments where profile_code = pg_temp.v('p')), 0, 'a stranger reads no rows');
reset role;

-- ── remove_holding_attachment ───────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select is(public.remove_holding_attachment(pg_temp.v('p'), pg_temp.v('att')), pg_temp.v('path'), 'removing returns the path to delete');
select is(jsonb_array_length(public.holding_detail(pg_temp.v('p'), pg_temp.v('bar'))->'attachments'), 0, 'and it is gone');
select throws_ok(
  format($$ select public.remove_holding_attachment(%L, %L) $$, pg_temp.v('p'), pg_temp.v('att')),
  'P0002', 'attachment not found', 'removing twice is refused');
reset role;

select * from finish();
rollback;

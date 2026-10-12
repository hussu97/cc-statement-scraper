-- retry_sms_fallback, resolve_review {"not_a_transaction"}, merchant_search,
-- statement_cycles' limit and the distinct seed colours
-- (20261008001900_web_review_and_search.sql). Runs on a non-empty DB.
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
          't10-' || p_key || '-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now())
  returning pg_temp.set(p_key, id::text) $$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.sms(p_body text) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', '2026-09-01T08:00:00Z', 'sender', 'ADCBAlert', 'body', p_body))) -> 0 $$;

select pg_temp.new_user('owner'), pg_temp.new_user('viewer'), pg_temp.new_user('other');
select pg_temp.as_user('owner');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t10-' || left(md5(random()::text), 8), 'Web'));
reset role;
insert into public.profile_members (profile_code, user_id, role) values (pg_temp.v('p'), pg_temp.v('viewer')::uuid, 'viewer');

-- ── seed colours ────────────────────────────────────────────────────────────
select results_eq(
  $$ select name, color_token from public.categories where profile_code = pg_temp.v('p')
     and name in ('Apple in-app purchase', 'Forex Charge', 'Medicine') order by name $$,
  $$ values ('Apple in-app purchase'::text, 'cat-15'::text), ('Forex Charge', 'cat-8'), ('Medicine', 'cat-9') $$,
  'new profiles get the distinct seed colours (16-hue palette, WEB-17r)');

-- ── retry_sms_fallback ──────────────────────────────────────────────────────
select pg_temp.set('sms', (pg_temp.sms('XYZ alert: nothing any template knows'))->>'sms_code');
insert into public.match_reviews (profile_code, subject_type, subject_code, reason)
values (pg_temp.v('p'), 'sms', pg_temp.v('sms'), 'unparsed_sms');
select pg_temp.set('rev', (select review_code from public.match_reviews where subject_code = pg_temp.v('sms')
                           and reason = 'unparsed_sms'));
select pg_temp.set('q_before', (select count(*)::text from pgmq.q_sms_fallback where message->>'sms_code' = pg_temp.v('sms')));
select pg_temp.as_user('viewer');
set local role authenticated;
select throws_ok($$ select public.retry_sms_fallback(pg_temp.v('rev')) $$, '42501', null, 'a viewer cannot retry the fallback');
reset role;
select pg_temp.as_user('other');
set local role authenticated;
select throws_ok($$ select public.retry_sms_fallback(pg_temp.v('rev')) $$, '42501', null, 'nor a non-member');
reset role;
select pg_temp.as_user('owner');
set local role authenticated;
select lives_ok($$ select public.retry_sms_fallback(pg_temp.v('rev')) $$, 'an owner retries the fallback');
reset role;
select is((select status from public.match_reviews where review_code = pg_temp.v('rev')), 'dismissed', 'the review is dismissed');
select is((select count(*)::int from pgmq.q_sms_fallback where message->>'sms_code' = pg_temp.v('sms')),
          pg_temp.v('q_before')::int + 1, 'and the message is queued for the fallback again');
select pg_temp.as_user('owner');
set local role authenticated;
select throws_ok($$ select public.retry_sms_fallback(pg_temp.v('rev')) $$, '22023', null, 'a closed review cannot be retried');
reset role;

-- ── resolve_review {"not_a_transaction"} ───────────────────────────────────
insert into public.match_reviews (profile_code, subject_type, subject_code, reason)
values (pg_temp.v('p'), 'sms', pg_temp.v('sms'), 'unparsed_sms');
select pg_temp.set('rev2', (select review_code from public.match_reviews where subject_code = pg_temp.v('sms')
                            and reason = 'unparsed_sms' and status = 'open'));
select pg_temp.as_user('owner');
set local role authenticated;
select is(public.resolve_review(pg_temp.v('rev2'), '{"not_a_transaction": true}')->>'outcome', 'ignored',
          'the owner marks the message as not a transaction');
reset role;
select is((select parse_status || ':' || ignore_reason from public.sms_messages where sms_code = pg_temp.v('sms')),
          'ignored:user_not_txn', 'the message is ignored with reason user_not_txn');
select is((select status from public.match_reviews where review_code = pg_temp.v('rev2')), 'resolved', 'and the review resolved');

-- ── merchant_search ─────────────────────────────────────────────────────────
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ADCB') returning account_code)
insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description, amount_original,
                                 currency_original, amount_aed, amount_source, status, merchant_code)
select pg_temp.v('p'), a.account_code, 'purchase', 'debit', d, x.descr, 1, 'AED', 1, 'manual', 'posted',
       private.resolve_merchant(x.descr)
from a, (values ('T10 ZEBRA CAFE'), ('T10 ZEBRA CAFE'), ('T10 YAK SHOP')) x(descr), (values ('2026-01-05'::date)) d(d);
select pg_temp.as_user('viewer');
set local role authenticated;
select results_eq(
  $$ select display_name, txn_count, last_date from public.merchant_search(pg_temp.v('p'), 'zebra') $$,
  $$ values ('T10 Zebra Cafe'::text, 2::bigint, '2026-01-05'::date) $$,
  'a member finds a merchant case-insensitively, with its count and last date');
select is((select count(*)::int from public.merchant_search(pg_temp.v('p'), null)), 2, 'no query lists every merchant');
select is((select count(*)::int from public.merchant_search(pg_temp.v('p'), null, 1, 1)), 1, 'offset/limit page the result');
select is((select count(*)::int from public.merchant_search(pg_temp.v('p'), '%')), 0, 'LIKE wildcards are literal');
reset role;
select pg_temp.as_user('other');
set local role authenticated;
select throws_ok($$ select * from public.merchant_search(pg_temp.v('p'), 'zebra') $$, '42501', null,
                 'a non-member cannot search the profile''s merchants');
reset role;

-- ── statement_cycles accepts up to 5000 ─────────────────────────────────────
select ok(pg_get_functiondef('public.statement_cycles(text, int)'::regprocedure) like '%least(greatest(p_limit, 1), 5000)%',
          'statement_cycles caps p_limit at 5000');

select * from finish();
rollback;

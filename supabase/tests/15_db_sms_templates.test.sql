-- SMS template safety and targeted re-processing (20261009000300_db_sms_templates.sql):
-- DB-22, DB-26r. Runs on a non-empty DB; every key is unique to this run.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.user(p_key text) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          email_confirmed_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          p_key || '-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now(), now())
  returning id::text $$;
create function pg_temp.as_user(p_uid text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true) $$;
create function pg_temp.sms(p_profile text, p_sender text, p_body text) returns jsonb language sql as $$
  select public.ingest_sms(p_profile, jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', now(), 'sender', p_sender, 'body', p_body)))->0 $$;
create function pg_temp.status(p_sms text) returns text language sql as $$
  select parse_status from public.sms_messages where sms_code = p_sms $$;

-- two profiles, each with one ADCB account
select pg_temp.set('ua', pg_temp.user('t15a'));
select pg_temp.set('ub', pg_temp.user('t15b'));
select pg_temp.as_user(pg_temp.v('ua'));
set local role authenticated;
select pg_temp.set('pa', public.create_profile('t15a-' || left(pg_temp.v('ua'), 8), 'Templates A'));
reset role;
select pg_temp.as_user(pg_temp.v('ub'));
set local role authenticated;
select pg_temp.set('pb', public.create_profile('t15b-' || left(pg_temp.v('ub'), 8), 'Templates B'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('pa'), 'ADCB'), (pg_temp.v('pb'), 'ADCB');

-- ═══ DB-26r: every template needs an example ══════════════════════════════
select throws_ok($$ insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind)
                    values ('ADCB', 't15 no example', '^ADCB', 'paid ([0-9.]+)', '{"amount":1}', 'purchase') $$,
                 '23514', null, 'a template without an example is rejected (DB-26r)');
select ok((select convalidated from pg_constraint where conname = 'sms_templates_examples_required'),
          'the examples constraint is validated');

-- ═══ DB-26r: LLM proposals ════════════════════════════════════════════════
create function pg_temp.weird(p_amount text) returns text language sql as $$
  select 'T15 weird format paid AED ' || p_amount || ' at T15 SHOP' $$;
create function pg_temp.proposal() returns jsonb language sql as $$
  select jsonb_build_object('bank_code', 'ADCB', 'name', 't15 proposal', 'sender_pattern', '.*',
    'body_pattern', 'T15 weird format paid ([A-Z]{3}) ([0-9.]+) at (.+)$',
    'field_groups', jsonb_build_object('currency', 1, 'amount', 2, 'merchant', 3), 'msg_kind', 'purchase',
    'expect', jsonb_build_object('amount', '12.50')) $$;
select pg_temp.set('sa', pg_temp.sms(pg_temp.v('pa'), 'ADCBAlert', pg_temp.weird('12.50'))->>'sms_code');
select pg_temp.set('sb', pg_temp.sms(pg_temp.v('pb'), 'ADCBAlert', pg_temp.weird('9.75'))->>'sms_code');
select is(pg_temp.status(pg_temp.v('sa')), 'unparsed', 'an unknown format is unparsed');
select pg_temp.set('tpl', public.propose_sms_template(pg_temp.v('sa'), pg_temp.proposal()));
select is((select sender_pattern || ' ' || scope_profile_code from public.sms_templates where template_code = pg_temp.v('tpl')),
          '^(ADCBAlert) ' || pg_temp.v('pa'),
          'the proposal''s sender pattern comes from the bank''s senders and it is scoped to the profile');
select pg_temp.set('sx', pg_temp.sms(pg_temp.v('pa'), 'SomeoneElse', pg_temp.weird('1.00'))->>'sms_code');
select throws_ok($$ select public.propose_sms_template(pg_temp.v('sx'), pg_temp.proposal()) $$, '22023', null,
                 'a proposal for a message from an unknown sender is rejected');

select pg_temp.as_user(pg_temp.v('ua'));
set local role authenticated;
select lives_ok($$ select public.set_sms_template_active(pg_temp.v('tpl'), true) $$, 'the owner approves the proposal');
reset role;
select set_config('request.jwt.claims', '', true);
select is(pg_temp.status(pg_temp.v('sa')), 'parsed', 'the proposing profile''s message now parses');
select is(pg_temp.status(pg_temp.v('sb')), 'unparsed', 'another profile''s identical message does not (scoped)');
select is(pg_temp.sms(pg_temp.v('pb'), 'ADCBAlert', pg_temp.weird('3.00'))->>'status', 'unparsed',
          'nor does a new message in another profile');
select lives_ok($$ select public.promote_sms_template(pg_temp.v('tpl')) $$, 'an operator promotes the template');
select is(pg_temp.status(pg_temp.v('sb')), 'parsed', 'promotion re-processes the other profiles'' messages');
select pg_temp.as_user(pg_temp.v('ua'));
set local role authenticated;
select throws_ok($$ select public.promote_sms_template(pg_temp.v('tpl')) $$, '42501', null,
                 'promotion is service-role only');
reset role;
select set_config('request.jwt.claims', '', true);

-- ═══ DB-22: only live, pattern-changing edits re-process, by sender ═══════
-- sg never parses: re-processing it would turn 'failed' back into 'unparsed'.
select pg_temp.set('sg', pg_temp.sms(pg_temp.v('pa'), 'ADCBAlert', 'T15 nothing parses this')->>'sms_code');
update public.sms_messages set parse_status = 'failed' where sms_code = pg_temp.v('sg');
update public.sms_templates set active = false where template_code = pg_temp.v('tpl');
select is(pg_temp.status(pg_temp.v('sg')), 'failed', 'a deactivation does not re-process');
select pg_temp.set('sf', pg_temp.sms(pg_temp.v('pa'), 'ADCBAlert', pg_temp.weird('4.00'))->>'sms_code');
select is(pg_temp.status(pg_temp.v('sf')), 'unparsed', 'with the template off, its format is unparsed');
update public.sms_templates set name = 't15 renamed' where template_code = pg_temp.v('tpl');
select is(pg_temp.status(pg_temp.v('sg')), 'failed', 'a rename does not re-process');
update public.sms_templates set priority = priority + 1
where template_code = (select min(template_code) from public.sms_templates where active and bank_code = 'SIB');
select is(pg_temp.status(pg_temp.v('sg')), 'failed', 'a change to another bank''s template leaves ADCB messages alone');
update public.sms_templates set active = true where template_code = pg_temp.v('tpl');
select is(pg_temp.status(pg_temp.v('sf')), 'parsed', 'an activation re-processes the template''s senders');
select is(pg_temp.status(pg_temp.v('sg')), 'unparsed', 'including the failed one');

select * from finish();
rollback;

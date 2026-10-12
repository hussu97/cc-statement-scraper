-- App Review demo ledger (20261012130000): private.create_review_demo fills an isolated
-- ledger through the real ingest paths, leaves no parse or LLM-fallback jobs behind,
-- refuses a second run, a user who already has a ledger, and client roles.
begin;
create extension if not exists pgtap with schema extensions;
set local client_min_messages = warning;
select no_plan();

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token,
  email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token,
  reauthentication_token)
values ('00000000-0000-0000-0000-000000000000', 'a0a0a0a0-0000-4000-8000-0000000000a1', 'authenticated',
        'authenticated', 'review-test@ledger.local', '', now(), '{}', '{}', now(), now(), '', '', '', '', '', '', '', '');

create temp table k as
select private.create_review_demo('a0a0a0a0-0000-4000-8000-0000000000a1', date '2026-10-12') as prof;

select is((select p.key from public.profiles p join k on p.profile_code = k.prof), 'app-review', 'creates the app-review ledger');
select is((select m.role from public.profile_members m join k on m.profile_code = k.prof
           where m.user_id = 'a0a0a0a0-0000-4000-8000-0000000000a1'), 'owner', 'the review user owns it');
select is((select count(*)::int from public.profile_members m
           where m.user_id = 'a0a0a0a0-0000-4000-8000-0000000000a1'), 1, 'and belongs to no other ledger');
select is((select count(*)::int from public.cards c join k on c.profile_code = k.prof), 2, 'two cards');
select is((select count(*)::int from public.statements s join k on s.profile_code = k.prof), 12, 'six statements per card');
select is((select count(*)::int from public.statement_recon r join k on r.profile_code = k.prof where r.status <> 'ok'), 0,
          'every statement reconciles');
select is((select max(s.statement_date) from public.statements s join k on s.profile_code = k.prof), date '2026-10-05',
          'statements end at the last close before today');
select ok((select count(*) from public.transactions t join k on t.profile_code = k.prof where t.status = 'posted') > 200,
          'posted transactions');
select ok((select count(*) from public.transactions t join k on t.profile_code = k.prof
           where t.status = 'pending' and t.txn_date < date '2026-10-12') > 0, 'unbilled alerts stay pending');
select is((select count(*)::int from public.transactions t join k on t.profile_code = k.prof where t.txn_date >= date '2026-10-12'), 0,
          'nothing dated today or later');
select is((select count(*)::int from public.sms_messages s join k on s.profile_code = k.prof where s.parse_status <> 'parsed'), 0,
          'every alert parses with the production templates');
select is((select count(*)::int from pgmq.q_sms_fallback), 0, 'no LLM fallback jobs');
select is((select count(*)::int from pgmq.q_parse_document q join public.documents d on d.doc_code = q.message->>'doc_code'
           join k on d.profile_code = k.prof), 0, 'no parse jobs for PDFs that do not exist');
select ok((select count(*) from public.budgets b join k on b.profile_code = k.prof) >= 4, 'budgets');
select ok((select count(*) from public.recurring_series r join k on r.profile_code = k.prof) > 0, 'recurring series');
select ok((select count(*) from public.insights i join k on i.profile_code = k.prof) > 0, 'insights');

select throws_ok($$ select private.create_review_demo('a0a0a0a0-0000-4000-8000-0000000000a1', date '2026-10-12') $$,
                 '22023', null, 'refuses a user who already has a ledger');

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token,
  email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token,
  reauthentication_token)
values ('00000000-0000-0000-0000-000000000000', 'a0a0a0a0-0000-4000-8000-0000000000a2', 'authenticated',
        'authenticated', 'review-test-2@ledger.local', '', now(), '{}', '{}', now(), now(), '', '', '', '', '', '', '', '');
select throws_ok($$ select private.create_review_demo('a0a0a0a0-0000-4000-8000-0000000000a2', date '2026-10-12') $$,
                 '23505', null, 'refuses a second demo ledger');

set local role authenticated;
select throws_ok($$ select private.create_review_demo('a0a0a0a0-0000-4000-8000-0000000000a2') $$,
                 '42501', null, 'client roles cannot reach it');
reset role;

select * from finish();
rollback;

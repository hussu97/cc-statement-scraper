-- Ops health and worker RPCs (20261009000400_db_ops_and_worker_rpcs.sql):
-- SRV-10, DB-38, SRV-22, DB-25 (job_errors_24h), SRV-15, SRV-20.
-- Runs on a non-empty DB: assertions are scoped to this run's rows or use deltas.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.doc(p_status text, p_updated timestamptz default now()) returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source, parse_status,
                                updated_at)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'),
          100, 'upload', p_status, p_updated)
  returning doc_code $$;
create function pg_temp.status(p_doc text) returns text language sql as $$
  select parse_status from public.documents where doc_code = p_doc $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't16-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t16-' || left(pg_temp.v('uid'), 8), 'Ops'));
reset role;
select set_config('request.jwt.claims', '', true);

-- ═══ SRV-10: mailbox checks ═══════════════════════════════════════════════
insert into public.email_mailboxes (profile_code, provider, mailbox_email, sync_state, watch_expires_at, last_synced_at)
values (pg_temp.v('p'), 'gmail', 't16-stale@test.dev',
        '{"last_error":{"at":"2026-10-01T00:00:00Z","code":"invalid_grant"}}', now() + interval '2 hours',
        now() - interval '3 days'),
       (pg_temp.v('p'), 'outlook', 't16-fresh@test.dev', '{"last_error":null}', null, now());
select pg_temp.set('mb_stale', (select mailbox_code from public.email_mailboxes where mailbox_email = 't16-stale@test.dev'));
select pg_temp.set('mb_fresh', (select mailbox_code from public.email_mailboxes where mailbox_email = 't16-fresh@test.dev'));
select pg_temp.set('h', public.ops_health()::text);
create function pg_temp.codes(p_key text) returns text[] language sql as $$
  select coalesce(array_agg(x->>'mailbox_code' order by x->>'mailbox_code'), '{}')
  from jsonb_array_elements(pg_temp.v('h')::jsonb->p_key) x
  where x->>'mailbox_code' in (pg_temp.v('mb_stale'), pg_temp.v('mb_fresh')) $$;
select is(pg_temp.codes('mailboxes_stale'), array[pg_temp.v('mb_stale')], 'a mailbox unsynced for 3 days is stale (SRV-10)');
select is(pg_temp.codes('gmail_watch_expiring'), array[pg_temp.v('mb_stale')], 'a Gmail watch expiring within 24 h is reported');
select is(pg_temp.codes('mailbox_errors'), array[pg_temp.v('mb_stale')], 'a mailbox with last_error is reported (a null one is not)');
select is((select x->>'code' from jsonb_array_elements(pg_temp.v('h')::jsonb->'mailbox_errors') x
           where x->>'mailbox_code' = pg_temp.v('mb_stale')), 'invalid_grant', 'with its error code');
select ok(pg_temp.v('h')::jsonb ? 'job_errors_24h' and pg_temp.v('h')::jsonb ? 'open_reviews_total'
          and pg_temp.v('h')::jsonb ? 'documents_queued_oldest_age_s', 'the new counters are present');
select ok((pg_temp.v('h')::jsonb->'queues'->'parse_document_dlq') ? 'newest_age_s',
          'queue metrics carry the newest message age (SRV-22)');

-- ═══ DB-38 / SRV-22: windows ══════════════════════════════════════════════
select pg_temp.set('before', public.ops_health()::text);
insert into public.match_reviews (profile_code, subject_type, subject_code, reason, created_at)
values (pg_temp.v('p'), 'transaction', 'txn_t16old', 'orphaned', now() - interval '10 days');
select pg_temp.doc('parsing', now() - interval '2 hours');
select pg_temp.doc('queued', now() - interval '2 hours');
select pg_temp.set('after', public.ops_health()::text);
select is((pg_temp.v('after')::jsonb->>'open_reviews')::int - (pg_temp.v('before')::jsonb->>'open_reviews')::int, 0,
          'a review opened 10 days ago is outside open_reviews (DB-38)');
select is((pg_temp.v('after')::jsonb->>'open_reviews_total')::int - (pg_temp.v('before')::jsonb->>'open_reviews_total')::int, 1,
          'but still in open_reviews_total');
select is((pg_temp.v('after')::jsonb->>'documents_stuck')::int - (pg_temp.v('before')::jsonb->>'documents_stuck')::int, 1,
          'only the document parsing for 2 h is stuck; a queued one is not (SRV-22)');
select ok((pg_temp.v('after')::jsonb->>'documents_queued_oldest_age_s')::int >= 7000, 'the queued one shows as queue age');

-- ═══ SRV-22: drain_dlq / requeue_dlq ══════════════════════════════════════
select pg_temp.set('dfail', pg_temp.doc('failed'));
select pgmq.send('parse_document_dlq', jsonb_build_object('doc_code', pg_temp.v('dfail'), 'attempt', 5,
                                                          'dlq_reason', 'max reads', 'dlq_at', now()));
select pg_temp.set('pd_before', (select count(*)::text from pgmq.q_parse_document where message->>'doc_code' = pg_temp.v('dfail')));
select ok(public.requeue_dlq('parse_document') >= 1, 'requeue_dlq moves messages back');
select is((select count(*)::int from pgmq.q_parse_document_dlq where message->>'doc_code' = pg_temp.v('dfail')), 0,
          'the DLQ no longer holds it');
select is((select count(*)::int from pgmq.q_parse_document where message->>'doc_code' = pg_temp.v('dfail'))
          - pg_temp.v('pd_before')::int, 1, 'it is back on the work queue');
select ok(not exists (select 1 from pgmq.q_parse_document where message->>'doc_code' = pg_temp.v('dfail')
                      and (message ? 'dlq_reason' or message ? 'dlq_at' or message ? 'attempt')),
          'without DLQ fields or an attempt count');
select is(pg_temp.status(pg_temp.v('dfail')), 'queued', 'and its failed document is queued again');
select pgmq.send('llm_categorize_dlq', '{"profile_code":"x","merchant_codes":["y"]}');
select pgmq.send('llm_categorize_dlq', '{"profile_code":"x","merchant_codes":["z"]}');
select ok(public.drain_dlq('llm_categorize') >= 2, 'drain_dlq empties a DLQ');
select is((select count(*)::int from pgmq.q_llm_categorize_dlq), 0, 'nothing left');
select throws_ok($$ select public.drain_dlq('profiles') $$, '22023', null, 'only known queues');
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok($$ select public.drain_dlq('parse_document') $$, '42501', null, 'drain_dlq is service-role only');
select throws_ok($$ select public.requeue_dlq('parse_document') $$, '42501', null, 'requeue_dlq is service-role only');
select throws_ok($$ select public.save_mailbox_sync_state(pg_temp.v('mb_fresh'), '{}') $$, '42501', null,
                 'save_mailbox_sync_state is service-role only');
select throws_ok($$ select public.begin_document_parse(pg_temp.v('dfail')) $$, '42501', null,
                 'begin_document_parse is service-role only');
reset role;
select set_config('request.jwt.claims', '', true);

-- ═══ SRV-15: sync state merge ═════════════════════════════════════════════
select public.save_mailbox_sync_state(pg_temp.v('mb_fresh'), '{"delta:inbox":"https://graph/a","gmail_history_id":"100"}');
select public.save_mailbox_sync_state(pg_temp.v('mb_fresh'), '{"delta:archive":"https://graph/b"}');
select is((select sync_state->>'delta:inbox' || '|' || (sync_state->>'delta:archive')
           from public.email_mailboxes where mailbox_code = pg_temp.v('mb_fresh')),
          'https://graph/a|https://graph/b', 'two writers'' keys are both kept (SRV-15)');
select is(public.save_mailbox_sync_state(pg_temp.v('mb_fresh'), '{"gmail_history_id":"90"}')->>'gmail_history_id', '100',
          'the Gmail cursor never moves back');
select is(public.save_mailbox_sync_state(pg_temp.v('mb_fresh'), '{"gmail_history_id":"120"}')->>'gmail_history_id', '120',
          'and moves forward');
select is(public.save_mailbox_sync_state(pg_temp.v('mb_fresh'), '{"last_error":null}')->'last_error', 'null'::jsonb,
          'a key can be cleared');
select public.save_mailbox_sync_state(pg_temp.v('mb_fresh'), '{}', now() - interval '1 day');
select ok((select last_synced_at > now() - interval '1 hour' from public.email_mailboxes where mailbox_code = pg_temp.v('mb_fresh')),
          'last_synced_at never moves back');

-- ═══ SRV-20: idempotent parse claims ══════════════════════════════════════
select pg_temp.set('dq', pg_temp.doc('queued'));
select pg_temp.set('claim', public.begin_document_parse(pg_temp.v('dq'), 2)::text);
select is(pg_temp.v('claim')::jsonb->'skip', 'null'::jsonb, 'a queued document is claimed');
select is(pg_temp.v('claim')::jsonb->'doc'->>'parse_status', 'parsing', 'and returned as parsing');
select ok(pg_temp.v('claim')::jsonb ? 'settings', 'with its settings');
select is((select parse_attempts::int from public.documents where doc_code = pg_temp.v('dq')), 2, 'attempt recorded');
select pg_temp.set('dp', pg_temp.doc('parsed'));
select is(public.begin_document_parse(pg_temp.v('dp'))->>'skip', 'parsed', 'a duplicate message for a parsed document is skipped');
select is(pg_temp.status(pg_temp.v('dp')), 'parsed', 'and the document stays parsed');
select pg_temp.set('df', pg_temp.doc('failed'));
select is(public.begin_document_parse(pg_temp.v('df'))->>'skip', 'failed', 'a stale message for a failed document is skipped');
select is(public.begin_document_parse('doc_00000000000000000000000000'), null, 'a deleted document returns null');
select public.fail_document(pg_temp.v('dp'), 'X', 'late failure', true);
select is(pg_temp.status(pg_temp.v('dp')), 'parsed', 'fail_document never flips a parsed document back');
select is(public.resubmit_document(pg_temp.v('p'), pg_temp.v('df')),
          jsonb_build_object('doc_code', pg_temp.v('df'), 'parse_status', 'queued', 'requeued', true),
          're-uploading a failed PDF re-queues it');
select ok(exists (select 1 from pgmq.q_parse_document where message->>'doc_code' = pg_temp.v('df')), 'with a queue message');
select is(public.resubmit_document(pg_temp.v('p'), pg_temp.v('dp'))->>'requeued', 'false', 'a parsed one is just a duplicate');
select throws_ok($$ select public.resubmit_document('prf_00000000000000000000000000', pg_temp.v('dp')) $$, 'P0002', null,
                 'another profile''s document is unknown');

select * from finish();
rollback;

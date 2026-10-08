-- Statement upload / parse event log (20261010000500, 20261010000600).
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local ledger.test_today = '2026-10-08';

create temp table k (name text primary key, v text);
grant all on k to authenticated, service_role;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.payload(p_date date, p_n int) returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'FAB',
    'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'FAB', 'statement_reference', 'R' || p_date, 'reference_source', 'explicit',
      'statement_date', p_date, 'period_start', p_date - 30, 'period_end', p_date, 'due_date', p_date + 25,
      'primary_card_last4', '5151', 'card_holder', 'TEST', 'card_type', 'VISA', 'totals', '{}'::jsonb,
      'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
      'lines', (select jsonb_agg(jsonb_build_object('line_no', i, 'txn_date', p_date - i, 'txn_time', null,
                  'posting_date', p_date - i, 'description_raw', 'SHOP ' || i, 'merchant_normalized', 'SHOP ' || i,
                  'amount_original', (10 * i)::text, 'currency_original', 'AED', 'amount_aed', (10 * i)::text,
                  'fx_rate', null, 'direction', 'debit', 'kind', 'purchase', 'country_code', 'AE', 'card_last4', '5151',
                  'card_holder', null, 'legacy_fingerprint', md5('t22' || i)))
                from generate_series(1, p_n) i))))
$$;
create function pg_temp.events(p_doc text) returns text[] language sql as $$
  select coalesce(array_agg(stage order by created_at, event_code), '{}') from public.document_events
  where doc_code = p_doc $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't22-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid2')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't22b-' || pg_temp.v('uid2') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t22-' || left(pg_temp.v('uid'), 8), 'Events'));
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select pg_temp.set('p2', public.create_profile('t22b-' || left(pg_temp.v('uid2'), 8), 'Other'));
reset role;
select set_config('request.jwt.claims', '', true);

-- ── shape ───────────────────────────────────────────────────────────────────
select has_table('public', 'document_events', 'document_events exists');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                  and schemaname = 'public' and tablename = 'document_events'),
          'document_events is published over Realtime');
select throws_ok($$ insert into public.document_events (profile_code, doc_code, stage, message)
                    values (pg_temp.v('p'), 'doc_01k4e95bxwmzs4hd3n90z7t3qy', 'uploaded', 'x') $$,
                 '23514', null, 'stage is checked');

-- ── upload-side events, through the service-role RPC ───────────────────────
select pg_temp.set('doc', public.gen_code('doc'));
set local role service_role;
select lives_ok($$ select public.log_document_event(pg_temp.v('p'), pg_temp.v('doc'), 'received', 'info',
                     'Received a.pdf (1 KB).', '{"filename":"a.pdf"}') $$,
                'the service role logs received before the document row exists');
select public.log_document_event(pg_temp.v('p'), pg_temp.v('doc'), 'stored', 'info', 'Saved the PDF.');
reset role;
insert into public.documents (doc_code, profile_code, storage_path, original_filename, sha256, size_bytes, source)
values (pg_temp.v('doc'), pg_temp.v('p'), 'x/a.pdf', 'a.pdf', encode(sha256('t22'::bytea), 'hex'), 100, 'upload');
set local role service_role;
select public.log_document_event(pg_temp.v('p'), pg_temp.v('doc'), 'queued', 'info', 'Waiting to be read.');
select throws_ok($$ select public.log_document_event(pg_temp.v('p2'), pg_temp.v('doc'), 'queued', 'info', 'x') $$,
                 '42501', null, 'an event cannot be filed under another profile''s document');

-- ── worker path: parsing → (parsed by the worker) → ingested ────────────────
select ok((public.begin_document_parse(pg_temp.v('doc'), 1))->>'skip' is null, 'the worker claims the document');
select public.log_document_event(pg_temp.v('p'), pg_temp.v('doc'), 'parsed', 'info',
                                 'Read the FAB statement: 1 statement, 3 lines.', '{"lines":3}');
select public.ingest_parsed_document(pg_temp.v('doc'), pg_temp.payload('2026-09-28', 3));
reset role;
select is(pg_temp.events(pg_temp.v('doc')), array['received', 'stored', 'queued', 'parsing', 'parsed', 'ingested'],
          'the timeline runs received → stored → queued → parsing → parsed → ingested');
select is((select message from public.document_events where doc_code = pg_temp.v('doc') and stage = 'ingested'),
          'Imported 1 statement: 3 new lines, 0 already known, 0 withdrawn; 3 new transactions, 0 matched to existing ones. New card ending 5151 added.',
          'the ingested message is a sentence with the counts');
select is((select detail->>'lines_new' || '/' || (detail->>'transactions_created') from public.document_events
           where doc_code = pg_temp.v('doc') and stage = 'ingested'), '3/3', 'the ingested detail carries the counts');
select ok((select message !~* 'shop' and detail::text !~* 'shop' from public.document_events
           where doc_code = pg_temp.v('doc') and stage = 'ingested'), 'no line text reaches the event');

-- A re-parse: lines unchanged, one withdrawn.
update public.documents set parse_status = 'queued' where doc_code = pg_temp.v('doc');
select public.ingest_parsed_document(pg_temp.v('doc'), pg_temp.payload('2026-09-28', 2));
select is((select detail->>'lines_unchanged' || '/' || (detail->>'lines_withdrawn') || '/' || (detail->>'lines_new')
           from public.document_events where doc_code = pg_temp.v('doc') and stage = 'ingested'
           order by created_at desc, event_code desc limit 1), '2/1/0', 'a re-parse reports unchanged and withdrawn lines');

-- ── failures and retries ────────────────────────────────────────────────────
select pg_temp.set('doc2', public.gen_code('doc'));
insert into public.documents (doc_code, profile_code, storage_path, original_filename, sha256, size_bytes, source)
values (pg_temp.v('doc2'), pg_temp.v('p'), 'x/b.pdf', 'b.pdf', encode(sha256('t22b'::bytea), 'hex'), 100, 'upload');
select public.fail_document(pg_temp.v('doc2'), 'PARSER_HTTP_503', 'parser returned HTTP 503', false);
select public.fail_document(pg_temp.v('doc2'), 'PDF_DECRYPT_FAILED', 'Unable to open/decrypt: wrong password secret123', true);
select is(pg_temp.events(pg_temp.v('doc2')), array['retry', 'failed'], 'a transient failure is a retry, a permanent one failed');
select is((select level || ': ' || message from public.document_events where doc_code = pg_temp.v('doc2') and stage = 'failed'),
          'error: We couldn''t open this PDF: its password is missing or wrong. Check the statement password for this bank, then upload it again.',
          'a wrong PDF password reads as a friendly sentence');
select ok(not exists (select 1 from public.document_events where doc_code = pg_temp.v('doc2')
                      and (message ~* 'secret123' or detail::text ~* 'secret123')),
          'the raw error text (which could hold anything) never reaches the event');
select is((select detail->>'error_code' from public.document_events where doc_code = pg_temp.v('doc2') and stage = 'failed'),
          'PDF_DECRYPT_FAILED', 'the error code is in detail');
select is(private.document_failure_message('INGEST_22023'),
          'The statement was read, but its contents didn''t pass our checks, so nothing was imported.',
          'an ingest rejection has its own sentence');
select is((public.resubmit_document(pg_temp.v('p'), pg_temp.v('doc2')))->>'requeued', 'true', 'resubmit requeues');
select is((pg_temp.events(pg_temp.v('doc2')))[3], 'retry', 'resubmit_document logs a retry');
select pg_temp.as_user('uid');
set local role authenticated;
select is(public.requeue_documents(pg_temp.v('p'), array[pg_temp.v('doc2')]), 1, 'the owner requeues');
select is(cardinality(pg_temp.events(pg_temp.v('doc2'))), 4, 'requeue_documents logs a retry');

-- ── reads: members only ─────────────────────────────────────────────────────
select ok((select count(*) from public.document_events where doc_code = pg_temp.v('doc')) >= 6,
          'a member reads the timeline');
select throws_ok($$ insert into public.document_events (profile_code, doc_code, stage, message)
                    values (pg_temp.v('p'), pg_temp.v('doc'), 'queued', 'x') $$, '42501', null,
                 'clients cannot write events');
select throws_ok($$ select public.log_document_event(pg_temp.v('p'), pg_temp.v('doc'), 'queued', 'info', 'x') $$,
                 '42501', null, 'clients cannot call log_document_event');
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select is((select count(*)::int from public.document_events where profile_code = pg_temp.v('p')), 0,
          'another user sees none of the profile''s events');
reset role;
select set_config('request.jwt.claims', '', true);

-- ── retention ───────────────────────────────────────────────────────────────
update public.document_events set created_at = now() - interval '91 days'
where doc_code = pg_temp.v('doc2') and stage = 'retry';
select ok(private.purge_document_events() >= 3, 'events older than 90 days are purged');
select is(pg_temp.events(pg_temp.v('doc2')), array['failed'], 'newer events stay');
select ok((private.nightly(pg_temp.v('p'))) is not null, 'nightly still runs');

select * from finish();
rollback;

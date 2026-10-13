-- review_context (20261013001856_review_context.sql, audit WEB-10r): one call returns the
-- context of every review on a page (statement line, SMS without its body, transaction,
-- statement, candidates in order, proposed template without examples), in the order asked,
-- for members only, and never anything from another profile.
-- Runs on a non-empty DB: every key is unique to this run and every assertion is scoped to this
-- run's profiles.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.new_user(p_key text) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          email_confirmed_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't43-' || p_key || '-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now(), now())
  returning pg_temp.set(p_key, id::text) $$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.txn(p_profile text, p_acc text, p_desc text, p_aed numeric) returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source)
  values (p_profile, p_acc, 'posted', 'purchase', 'debit', '2026-09-02', p_desc, p_aed, 'AED', p_aed, 'manual')
  returning txn_code $$;
create function pg_temp.review(p_profile text, p_type text, p_subject text, p_reason text, p_candidates jsonb)
returns text language sql as $$
  insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
  values (p_profile, p_type, p_subject, p_reason, p_candidates) returning review_code $$;

-- ── setup: owner, viewer, outsider with their own profile ──────────────────
select pg_temp.new_user('owner');
select pg_temp.new_user('viewer');
select pg_temp.new_user('other');
select pg_temp.as_user('owner');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t43-' || left(pg_temp.v('owner'), 8), 'Review context'));
reset role;
insert into public.profile_members (profile_code, user_id, role) values (pg_temp.v('p'), pg_temp.v('viewer')::uuid, 'viewer');
select pg_temp.as_user('other');
set local role authenticated;
select pg_temp.set('q', public.create_profile('t43o-' || left(pg_temp.v('other'), 8), 'Other'));
reset role;
select set_config('request.jwt.claims', '', true);

-- A statement with one line, through the real ingest path.
insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 't43.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload');
select public.ingest_parsed_document(
  (select doc_code from public.documents where profile_code = pg_temp.v('p') order by created_at desc limit 1),
  jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB', 'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'ADCB', 'statement_reference', 'T43-1', 'reference_source', 'explicit',
      'statement_date', '2026-09-30', 'period_start', '2026-09-01', 'period_end', '2026-09-30', 'due_date', '2026-10-25',
      'primary_card_last4', '4343', 'card_holder', 'TEST', 'card_type', 'VISA', 'totals', '{}'::jsonb,
      'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
      'lines', jsonb_build_array(jsonb_build_object('line_no', 1, 'txn_date', '2026-09-03', 'txn_time', null,
        'posting_date', '2026-09-03', 'description_raw', 'T43 LINE CAFE', 'merchant_normalized', 'T43 LINE CAFE',
        'amount_original', '42.00', 'currency_original', 'AED', 'amount_aed', '42.00', 'fx_rate', null,
        'direction', 'debit', 'kind', 'purchase', 'country_code', 'AE', 'card_last4', '4343', 'card_holder', null,
        'legacy_fingerprint', md5('t43-line'))))))
);
select pg_temp.set('acc', (select account_code from public.accounts where profile_code = pg_temp.v('p') limit 1));
select pg_temp.set('stmt', (select stmt_code from public.statements where profile_code = pg_temp.v('p') limit 1));
select pg_temp.set('line', (select line_code from public.statement_lines where profile_code = pg_temp.v('p') limit 1));

-- Transactions here and in the other profile; an SMS; a template the review proposes.
select pg_temp.set('t1', pg_temp.txn(pg_temp.v('p'), pg_temp.v('acc'), 'T43 FIRST', 10));
select pg_temp.set('t2', pg_temp.txn(pg_temp.v('p'), pg_temp.v('acc'), 'T43 SECOND', 20));
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('q'), 'FAB') returning account_code)
select pg_temp.set('qtxn', pg_temp.txn(pg_temp.v('q'), a.account_code, 'T43 OTHER', 30)) from a;
select pg_temp.set('sms', (public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
  'client_msg_id', gen_random_uuid(), 'received_at', '2026-09-01T08:00:00Z', 'sender', 'ADCBAlert',
  'body', 'T43 nothing any template knows'))) -> 0)->>'sms_code');
select pg_temp.set('tpl', (select template_code from public.sms_templates where source <> 'llm' order by template_code limit 1));

-- Reviews: one per subject type, plus one in the other profile.
select pg_temp.set('r_line', pg_temp.review(pg_temp.v('p'), 'statement_line', pg_temp.v('line'), 'ambiguous',
  jsonb_build_array(jsonb_build_object('txn_code', pg_temp.v('t2'), 'score', 70),
                    jsonb_build_object('txn_code', 'txn_gone', 'score', 60),
                    jsonb_build_object('txn_code', pg_temp.v('qtxn'), 'score', 55),
                    jsonb_build_object('txn_code', pg_temp.v('t1'), 'score', 50))));
select pg_temp.set('r_sms', pg_temp.review(pg_temp.v('p'), 'sms', pg_temp.v('sms'), 'unparsed_sms',
  jsonb_build_array(jsonb_build_object('template_code', pg_temp.v('tpl')))));
select pg_temp.set('r_txn', pg_temp.review(pg_temp.v('p'), 'transaction', pg_temp.v('t1'), 'orphaned', '[]'::jsonb));
select pg_temp.set('r_stmt', pg_temp.review(pg_temp.v('p'), 'statement', pg_temp.v('stmt'), 'period_overlap', '[]'::jsonb));
select pg_temp.set('r_q', pg_temp.review(pg_temp.v('q'), 'transaction', pg_temp.v('qtxn'), 'orphaned', '[]'::jsonb));

-- ═══ a member reads every context in one call ══════════════════════════════
select pg_temp.as_user('viewer');
set local role authenticated;
select results_eq(
  $$ select review_code from public.review_context(pg_temp.v('p'),
       array[pg_temp.v('r_stmt'), pg_temp.v('r_line'), pg_temp.v('r_txn'), pg_temp.v('r_sms')]) $$,
  $$ values (pg_temp.v('r_stmt')), (pg_temp.v('r_line')), (pg_temp.v('r_txn')), (pg_temp.v('r_sms')) $$,
  'one row per review, in the order asked');

select is((select line->>'line_code' || ':' || (line->>'description_raw')
           from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_line')])),
          pg_temp.v('line') || ':T43 LINE CAFE', 'a statement-line review carries its line');
select is((select (sms is null and txn is null and statement is null and template is null)
           from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_line')])), true,
          'and nothing it isn''t about');
select is((select string_agg(c->>'txn_code', ',' order by o)
           from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_line')]) x,
                jsonb_array_elements(x.candidates) with ordinality e(c, o)),
          pg_temp.v('t2') || ',' || pg_temp.v('t1'),
          'candidates come in the review''s order; gone codes and other profiles'' transactions are left out');
select is((select candidates->0->>'description' from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_line')])),
          'T43 SECOND', 'a candidate is a v_transactions row');

select is((select sms->>'sms_code' from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_sms')])),
          pg_temp.v('sms'), 'an SMS review carries its message');
select ok((select not (sms ? 'body') from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_sms')])),
          'without its body');
select is((select template->>'template_code' from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_sms')])),
          pg_temp.v('tpl'), 'an unparsed-SMS review carries its proposed format');
select ok((select not (template ? 'examples') and not (template ? 'scope_profile_code')
           from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_sms')])),
          'without the columns clients cannot read');
select is((select candidates from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_sms')])), '[]'::jsonb,
          'no candidate transactions is an empty list');

select is((select txn->>'txn_code' from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_txn')])),
          pg_temp.v('t1'), 'a transaction review carries its transaction');
select is((select statement->>'stmt_code' from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_stmt')])),
          pg_temp.v('stmt'), 'a statement review carries its statement');

-- ═══ tenant isolation ═════════════════════════════════════════════════════
select is((select count(*)::int from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_q'), 'rev_unknown'])), 0,
          'another profile''s review, or an unknown code, returns nothing');
select throws_ok($$ select * from public.review_context(pg_temp.v('q'), array[pg_temp.v('r_q')]) $$, '42501', null,
                 'a member of one profile cannot read another profile''s review contexts');
reset role;
select pg_temp.as_user('other');
set local role authenticated;
select throws_ok($$ select * from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_line')]) $$, '42501', null,
                 'a non-member is refused');
select is((select txn->>'txn_code' from public.review_context(pg_temp.v('q'), array[pg_temp.v('r_q')])),
          pg_temp.v('qtxn'), 'the other profile''s own member reads its review');
reset role;
select set_config('request.jwt.claims', '', true);
grant select on k to anon;  -- so only review_context itself can refuse
set local role anon;
select throws_ok($$ select * from public.review_context(pg_temp.v('p'), array[pg_temp.v('r_line')]) $$, '42501',
                 'not a member of profile ' || pg_temp.v('p'), 'anon is refused by the member check');
reset role;

-- ═══ limits and shape ══════════════════════════════════════════════════════
select pg_temp.as_user('owner');
set local role authenticated;
select throws_ok($$ select * from public.review_context(pg_temp.v('p'), array_fill('rev_x'::text, array[2001])) $$,
                 '22023', null, 'at most 2000 codes');
select is((select count(*)::int from public.review_context(pg_temp.v('p'), '{}'::text[])), 0, 'no codes, no rows');
reset role;
select ok((select p.prosecdef and 'search_path=""' = any (p.proconfig)
           from pg_proc p where p.oid = 'public.review_context(text, text[])'::regprocedure),
          'review_context is SECURITY DEFINER with an empty search_path');

select * from finish();
rollback;

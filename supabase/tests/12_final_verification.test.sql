-- Final-verification regressions (docs/audit/07-final-verification.md FV-02, FV-03).
-- Runs on a non-empty DB: every assertion is scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ── helpers (same shapes as 09_ingest_robustness) ───────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;

create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric) returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date + 1,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', 'AED', 'amount_aed', p_amount::text, 'fx_rate', null, 'direction', 'debit',
    'kind', 'purchase', 'country_code', 'AE', 'card_last4', '9208', 'card_holder', null,
    'legacy_fingerprint', md5(p_desc || p_date || p_amount))
$$;

create function pg_temp.payload(p_date date, p_lines jsonb, p_period_start date default null) returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB',
    'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'ADCB', 'statement_reference', 'REF' || p_date, 'reference_source', 'explicit',
      'statement_date', p_date, 'period_start', coalesce(p_period_start, p_date - 30), 'period_end', p_date,
      'due_date', p_date + 25, 'primary_card_last4', '9208', 'card_holder', 'TEST', 'card_type', 'VISA',
      'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb, 'lines', p_lines)))
$$;

create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
  returning doc_code $$;

create function pg_temp.ingest(p_payload jsonb, p_doc text) returns jsonb language sql as $$
  select public.ingest_parsed_document(p_doc, p_payload) $$;

create function pg_temp.stmt(p_date date) returns text language sql as $$
  select stmt_code from public.statements
  where profile_code = pg_temp.v('p') and statement_date = p_date and status = 'active' $$;

create function pg_temp.txn_on(p_date date, p_amount numeric) returns text language sql as $$
  select txn_code from public.transactions
  where profile_code = pg_temp.v('p') and txn_date = p_date and amount_original = p_amount $$;

-- the statement line a transaction is currently evidenced by
create function pg_temp.evidence_line(p_txn text) returns text language sql as $$
  select e.line_code from public.transaction_evidence e
  where e.txn_code = p_txn and e.is_active and e.evidence_type = 'statement_line' $$;

create function pg_temp.open_reviews(p_reason text) returns int language sql as $$
  select count(*)::int from public.match_reviews
  where profile_code = pg_temp.v('p') and reason = p_reason and status = 'open' $$;

-- ── setup ───────────────────────────────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't12-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t12-' || left(pg_temp.v('uid'), 8), 'Final verification'));
reset role;
select set_config('request.jwt.claims', '', true);

-- ═══ FV-02 / FV-03: a re-parse moves a document's lines to a new statement ═══
-- The reported pattern: a bad-year statement (2026-12-28 instead of
-- 2025-12-28) holds two same-merchant, same-amount purchases on consecutive
-- days. Another statement overlaps the bad-year period, so it carries a
-- period_overlap review naming the bad-year statement.
select pg_temp.set('doc_a', pg_temp.new_doc());
select pg_temp.ingest(pg_temp.payload('2026-12-28', jsonb_build_array(
  pg_temp.line(1, '2025-12-10', 'Blue Bottle Cafe', 32.50),
  pg_temp.line(2, '2025-12-11', 'Blue Bottle Cafe', 32.50),
  pg_temp.line(3, '2025-12-12', 'Corner Grocery', 18.00))), pg_temp.v('doc_a'));
select pg_temp.set('stmt_bad', pg_temp.stmt('2026-12-28'));
select pg_temp.set('t1', pg_temp.txn_on('2025-12-10', 32.50));
select pg_temp.set('t2', pg_temp.txn_on('2025-12-11', 32.50));
select isnt(pg_temp.v('t1'), null, 'the first purchase has a transaction');
select isnt(pg_temp.v('t2'), null, 'the second purchase has a transaction');

select pg_temp.ingest(pg_temp.payload('2026-12-20', jsonb_build_array(
  pg_temp.line(1, '2026-12-01', 'Other Shop', 10.00))), pg_temp.new_doc());
select pg_temp.set('stmt_other', pg_temp.stmt('2026-12-20'));
select is((select count(*)::int from public.match_reviews
           where profile_code = pg_temp.v('p') and subject_code = pg_temp.v('stmt_other')
             and reason = 'period_overlap' and status = 'open'
             and candidates @> jsonb_build_array(jsonb_build_object('stmt_code', pg_temp.v('stmt_bad')))),
          1, 'the overlapping statement has a period_overlap review naming the bad-year statement');

-- Re-parse of document A with the corrected year.
select pg_temp.set('txns_before', (select count(*)::text from public.transactions where profile_code = pg_temp.v('p')));
select pg_temp.ingest(pg_temp.payload('2025-12-28', jsonb_build_array(
  pg_temp.line(1, '2025-12-10', 'Blue Bottle Cafe', 32.50),
  pg_temp.line(2, '2025-12-11', 'Blue Bottle Cafe', 32.50),
  pg_temp.line(3, '2025-12-12', 'Corner Grocery', 18.00))), pg_temp.v('doc_a'));
select pg_temp.set('stmt_fixed', pg_temp.stmt('2025-12-28'));

select is((select status from public.statements where stmt_code = pg_temp.v('stmt_bad')), 'superseded',
          'the bad-year statement is superseded by the re-parse');
select is(pg_temp.open_reviews('ambiguous'), 0, 'FV-02: no line is held as ambiguous after the re-parse');
select is(pg_temp.open_reviews('orphaned'), 0, 'FV-02: no transaction is left orphaned');
select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p') and status = 'orphaned'), 0,
          'FV-02: every transaction is evidenced again');
select is((select count(*)::text from public.transactions where profile_code = pg_temp.v('p')), pg_temp.v('txns_before'),
          'FV-02: the re-parse creates no new transactions');
select is((select l.stmt_code || '|' || l.txn_date from public.statement_lines l where l.line_code = pg_temp.evidence_line(pg_temp.v('t1'))),
          pg_temp.v('stmt_fixed') || '|2025-12-10', 'FV-02: the first purchase relinks to its own line on the new statement');
select is((select l.stmt_code || '|' || l.txn_date from public.statement_lines l where l.line_code = pg_temp.evidence_line(pg_temp.v('t2'))),
          pg_temp.v('stmt_fixed') || '|2025-12-11', 'FV-02: the second purchase relinks to its own line on the new statement');
select is((select count(*)::int from public.statement_lines l where l.stmt_code = pg_temp.v('stmt_fixed') and l.is_current
             and not exists (select 1 from public.transaction_evidence e where e.line_code = l.line_code and e.is_active)),
          0, 'FV-02: every line of the corrected statement is linked');

select is((select status || '|' || (resolution->>'auto') from public.match_reviews
           where profile_code = pg_temp.v('p') and subject_code = pg_temp.v('stmt_other') and reason = 'period_overlap'),
          'dismissed|overlap_candidates_superseded',
          'FV-03: the overlap review naming the superseded statement is dismissed automatically');
select is(pg_temp.open_reviews('period_overlap'), 0, 'FV-03: no stale period_overlap review is left open');

-- ═══ FV-02: consecutive-day repeat purchases resolve by date proximity ═════
-- No lineage here: two existing transactions (from SMS) one day apart, and a
-- new statement with one line on each of those days.
select is((public.ingest_sms(pg_temp.v('p'), jsonb_build_array(
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'received_at', '2026-01-05 08:00:00+00', 'sender', 'ADCBAlert',
    'body', 'Your Cr.Card XXX9208 was used for AED45.00 on 05/01/2026 12:00:00 at Coffee Planet. Avl. Cr.limit is AED26953.75'),
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'received_at', '2026-01-06 08:00:00+00', 'sender', 'ADCBAlert',
    'body', 'Your Cr.Card XXX9208 was used for AED45.00 on 06/01/2026 12:00:00 at Coffee Planet. Avl. Cr.limit is AED26953.75')
)) -> 1 ->> 'status'), 'created', 'two SMS purchases one day apart create two transactions');
select pg_temp.set('s1', pg_temp.txn_on('2026-01-05', 45.00));
select pg_temp.set('s2', pg_temp.txn_on('2026-01-06', 45.00));

select pg_temp.ingest(pg_temp.payload('2026-01-28', jsonb_build_array(
  pg_temp.line(1, '2026-01-05', 'Coffee Planet', 45.00),
  pg_temp.line(2, '2026-01-06', 'Coffee Planet', 45.00)), '2025-12-29'), pg_temp.new_doc());
select is(pg_temp.open_reviews('ambiguous'), 0, 'FV-02: consecutive-day same-amount lines are not ambiguous');
select is((select l.txn_date::text from public.statement_lines l where l.line_code = pg_temp.evidence_line(pg_temp.v('s1'))),
          '2026-01-05', 'FV-02: the earlier purchase links to the same-day line');
select is((select l.txn_date::text from public.statement_lines l where l.line_code = pg_temp.evidence_line(pg_temp.v('s2'))),
          '2026-01-06', 'FV-02: the later purchase links to the same-day line');

-- A genuinely ambiguous line (no same-day partner for the rival) is still held.
select pg_temp.set('doc_amb', pg_temp.new_doc());
select is((public.ingest_sms(pg_temp.v('p'), jsonb_build_array(
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'received_at', '2026-02-10 08:00:00+00', 'sender', 'ADCBAlert',
    'body', 'Your Cr.Card XXX9208 was used for AED60.00 on 10/02/2026 12:00:00 at Tea Room. Avl. Cr.limit is AED26953.75'),
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'received_at', '2026-02-12 08:00:00+00', 'sender', 'ADCBAlert',
    'body', 'Your Cr.Card XXX9208 was used for AED60.00 on 12/02/2026 12:00:00 at Tea Room. Avl. Cr.limit is AED26953.75')
)) -> 1 ->> 'status'), 'created', 'two SMS purchases two days apart');
select pg_temp.ingest(pg_temp.payload('2026-02-28', jsonb_build_array(
  pg_temp.line(1, '2026-02-11', 'Tea Room', 60.00)), '2026-01-29'), pg_temp.v('doc_amb'));
select is((select count(*)::int from public.match_reviews r join public.statement_lines l on l.line_code = r.subject_code
           where r.profile_code = pg_temp.v('p') and r.reason = 'ambiguous' and r.status = 'open'
             and l.stmt_code = pg_temp.stmt('2026-02-28')),
          1, 'a line between two equally likely transactions is still held as ambiguous');

select * from finish();
rollback;

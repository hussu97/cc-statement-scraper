-- Audit regressions for ingestion, matching and reconciliation
-- (docs/audit/01-database.md DB-06..DB-10, DB-13, DB-15..DB-17, X-08;
--  docs/audit/02-data-parity.md DP-01, DP-02, DP-06, DP-08).
-- Runs on a non-empty DB: every id and key is unique to this run and every
-- assertion is scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
-- Fixed statement dates run up to 2027; pin "today" for the DP-04r future-date guard.
set local ledger.test_today = '2027-06-30';

-- ── helpers ─────────────────────────────────────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;

create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric, p_cur text default 'AED',
                             p_aed numeric default null, p_fx numeric default null, p_last4 text default '3687')
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date + 1,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', p_cur, 'amount_aed', coalesce(p_aed, case when p_cur = 'AED' then p_amount end)::text,
    'fx_rate', p_fx::text, 'direction', 'debit', 'kind', 'purchase', 'country_code', 'AE', 'card_last4', p_last4,
    'card_holder', null, 'legacy_fingerprint', md5(p_desc || p_date || p_amount))
$$;

create function pg_temp.payload(p_date date, p_lines jsonb, p_kind text default 'statement',
                                p_totals jsonb default '{}'::jsonb, p_last4 text default '3687',
                                p_ref text default null)
returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB',
    'document_kind', case when p_kind = 'statement' then 'statement_pdf' else 'history_pdf' end,
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', p_kind, 'bank_code', 'ADCB', 'statement_reference', coalesce(p_ref, 'REF' || p_date),
      'reference_source', 'explicit',
      'statement_date', p_date, 'period_start', (p_date - 30), 'period_end', p_date, 'due_date', p_date + 25,
      'primary_card_last4', p_last4, 'card_holder', 'TEST', 'card_type', 'VISA',
      'totals', p_totals, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb, 'lines', p_lines)))
$$;

create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
  returning doc_code $$;

create function pg_temp.ingest(p_payload jsonb, p_doc text default null) returns jsonb language sql as $$
  select public.ingest_parsed_document(coalesce(p_doc, pg_temp.new_doc()), p_payload) $$;

create function pg_temp.sms_batch(p_msgs jsonb) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), p_msgs) $$;

create function pg_temp.adcb(p_amount text, p_date text, p_time text, p_merchant text, p_avl text default '26953.75')
returns text language sql as $$
  select format('Your Cr.Card XXX3687 was used for AED%s on %s %s at %s. Avl. Cr.limit is AED%s',
                p_amount, p_date, p_time, p_merchant, p_avl) $$;

create function pg_temp.msg(p_body text, p_at timestamptz) returns jsonb language sql as $$
  select jsonb_build_object('client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', 'ADCBAlert', 'body', p_body) $$;

create function pg_temp.n_lines(p_stmt text) returns int language sql as $$
  select count(*)::int from public.statement_lines where profile_code = pg_temp.v('p') and stmt_code = p_stmt and is_current $$;
create function pg_temp.txns() returns int language sql as $$
  select count(*)::int from public.transactions where profile_code = pg_temp.v('p') and status in ('pending', 'posted') $$;
create function pg_temp.accounts() returns int language sql as $$
  select count(*)::int from public.accounts where profile_code = pg_temp.v('p') $$;

-- ── setup ───────────────────────────────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't09-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
create function pg_temp.as_system() returns text language sql as $$
  select set_config('request.jwt.claims', '', true) $$;
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t09-' || left(pg_temp.v('uid'), 8), 'Robustness'));
reset role;
select pg_temp.as_system();

-- ═══ DB-13: no function relies on a function-level statement_timeout ══════
select is(
  (select array_agg(p.oid::regprocedure::text) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'statement_timeout=%')),
  null, 'no public/private function sets statement_timeout (it never applied)');
select throws_ok($$ insert into public.category_rules (profile_code, category_code, match_type, pattern)
                    select pg_temp.v('p'), category_code, 'regex', '(A)\1' from public.categories
                    where profile_code = pg_temp.v('p') limit 1 $$,
                 '22023', null, 'a regex rule with a back-reference is rejected');
select throws_ok($$ insert into public.category_rules (profile_code, category_code, match_type, pattern)
                    select pg_temp.v('p'), category_code, 'contains', repeat('A', 201) from public.categories
                    where profile_code = pg_temp.v('p') limit 1 $$,
                 '22023', null, 'an over-long rule pattern is rejected');
select throws_ok($$ insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind)
                    values ('ADCB', 't09 backref', '^ADCB', '(X)\1 ([0-9.]+)', '{"amount":2}', 'purchase') $$,
                 '22023', null, 'an SMS template with a back-reference is rejected');
select throws_ok($$ insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind)
                    values ('ADCB', 't09 groups', '^ADCB', 'paid ([0-9.]+)', '{"amount":"x"}', 'purchase') $$,
                 '22023', null, 'an SMS template whose field group is not a group number is rejected');

-- ═══ DB-09: rule conditions are validated on write ════════════════════════
select pg_temp.set('dining', (select category_code from public.categories where profile_code = pg_temp.v('p') and name = 'Dining'));
select pg_temp.as_owner();
set local role authenticated;
select throws_ok($$ insert into public.category_rules (profile_code, category_code, match_type, pattern, conditions)
                    values (pg_temp.v('p'), pg_temp.v('dining'), 'contains', 'ZZQQ', '{"amount_min":"100 AED"}') $$,
                 '22023', null, 'a non-numeric amount_min is rejected (E9)');
select throws_ok($$ insert into public.category_rules (profile_code, category_code, match_type, pattern, conditions)
                    values (pg_temp.v('p'), pg_temp.v('dining'), 'contains', 'ZZQQ', '{"colour":"red"}') $$,
                 '22023', null, 'an unknown condition key is rejected');
select throws_ok($$ insert into public.category_rules (profile_code, category_code, match_type, pattern, conditions)
                    values (pg_temp.v('p'), pg_temp.v('dining'), 'contains', 'ZZQQ', '{"kind":"lunch"}') $$,
                 '22023', null, 'an unknown kind is rejected');
select throws_ok($$ select public.preview_rule(pg_temp.v('p'), 'contains', 'ZZQQ', pg_temp.v('dining'), '{"amount_max":"abc"}') $$,
                 '22023', null, 'preview_rule validates conditions the same way');
select lives_ok($$ insert into public.category_rules (profile_code, category_code, match_type, pattern, conditions)
                   values (pg_temp.v('p'), pg_temp.v('dining'), 'contains', 'ZZQQ',
                           '{"amount_min":10,"amount_max":"500","bank_code":"ADCB","currency":"AED","kind":"purchase","direction":"debit"}') $$,
                'well-formed conditions are accepted');
reset role;
-- A row that predates validation (inserted with the trigger off) can no longer break ingestion.
alter table public.category_rules disable trigger category_rules_validate;
insert into public.category_rules (profile_code, category_code, match_type, pattern, conditions, priority)
values (pg_temp.v('p'), pg_temp.v('dining'), 'contains', 'ZZQQ', '{"amount_min":"100 AED"}', 1);
alter table public.category_rules enable trigger category_rules_validate;
select lives_ok($$ select pg_temp.ingest(pg_temp.payload('2026-01-31', jsonb_build_array(pg_temp.line(1, '2026-01-10', 'ZZQQ SHOP', 150)))) $$,
                'a stored rule with a bad amount does not fail the ingest');

-- ═══ X-08: ingestion takes the per-profile advisory lock ═══════════════════
select ok(exists (select 1 from pg_locks l
                  where l.locktype = 'advisory' and l.pid = pg_backend_pid()
                    and l.objid::bigint = (hashtext(pg_temp.v('p'))::bigint & 4294967295)),
          'ingest_parsed_document holds pg_advisory_xact_lock(hashtext(profile_code))');

-- ═══ DB-08: one bad SMS never fails the batch ══════════════════════════════
select pg_temp.set('batch', pg_temp.sms_batch(jsonb_build_array(
  jsonb_build_object('received_at', '2026-02-01T08:00:00Z', 'sender', 'ADCBAlert', 'body', 'no id'),
  jsonb_build_object('client_msg_id', 'not-a-uuid', 'sender', 'ADCBAlert', 'body', 'bad id'),
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'sender', 'ADCBAlert', 'body', null),
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'received_at', '2026-13-45', 'sender', 'ADCBAlert', 'body', 'bad date'),
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'sender', 'ADCBAlert', 'body', repeat('x', 2001)),
  '"just a string"'::jsonb,
  pg_temp.msg(pg_temp.adcb('46.00', '31/02/2026', '13:43:40', 'Vox Cinemas'), '2026-02-01 09:00:00+00'),
  pg_temp.msg(pg_temp.adcb('46.00', '01/02/2026', '13:43:40', 'Vox Cinemas'), '2026-02-01 09:45:00+00')
))::text);
select is((select array_agg(e->>'status' order by o) from jsonb_array_elements(pg_temp.v('batch')::jsonb) with ordinality x(e, o)),
          array['invalid', 'invalid', 'invalid', 'invalid', 'invalid', 'invalid', 'unparsed', 'created'],
          'each message gets its own status; nothing raises');
select is((select array_agg(e->>'reason' order by o) from jsonb_array_elements(pg_temp.v('batch')::jsonb) with ordinality x(e, o)
           where e->>'status' = 'invalid'),
          array['invalid_client_msg_id', 'invalid_client_msg_id', 'missing_body', 'invalid_received_at', 'body_too_long', 'not_an_object'],
          'invalid messages say why');
select is((select count(*)::int from public.sms_messages where profile_code = pg_temp.v('p')), 2,
          'only the two well-formed messages are stored');

-- a processing error is isolated to its message ('failed', kept for retry)
alter table public.category_rules disable trigger user;
insert into public.category_rules (profile_code, category_code, match_type, pattern, priority)
values (pg_temp.v('p'), pg_temp.v('dining'), 'regex', '(', 1);
alter table public.category_rules enable trigger user;
-- the ADCB card exists since the January statement
select pg_temp.set('batch2', pg_temp.sms_batch(jsonb_build_array(
  pg_temp.msg(pg_temp.adcb('12.00', '02/02/2026', '10:00:00', 'KIOSK'), '2026-02-02 06:00:00+00'),
  pg_temp.msg('Hello, not a bank format', '2026-02-02 06:01:00+00')
))::text);
select is(pg_temp.v('batch2')::jsonb->0->>'status', 'failed', 'a message whose processing errors is marked failed');
select is(pg_temp.v('batch2')::jsonb->1->>'status', 'unparsed', 'and the next message in the batch is still processed');
select is((select parse_status from public.sms_messages where sms_code = pg_temp.v('batch2')::jsonb->0->>'sms_code'), 'failed',
          'the failed message is stored as failed');
delete from public.category_rules where profile_code = pg_temp.v('p') and pattern in ('(', 'ZZQQ');

-- ═══ DB-06 / DP-06: a re-parse with a corrected date supersedes, no duplicates ═
select pg_temp.set('d6', pg_temp.new_doc());
select pg_temp.ingest(pg_temp.payload('2026-07-31', jsonb_build_array(
  pg_temp.line(1, '2026-07-05', 'STARBUCKS MALL', 18), pg_temp.line(2, '2026-07-05', 'STARBUCKS MALL', 18),
  pg_temp.line(3, '2026-07-09', 'NOON.COM', 99))), pg_temp.v('d6'));
select pg_temp.set('txns6', pg_temp.txns()::text);
select pg_temp.ingest(pg_temp.payload('2026-08-01', jsonb_build_array(
  pg_temp.line(1, '2026-07-05', 'STARBUCKS MALL', 18), pg_temp.line(2, '2026-07-05', 'STARBUCKS MALL', 18),
  pg_temp.line(3, '2026-07-09', 'NOON.COM', 99))), pg_temp.v('d6'));
select is((select array_agg(statement_date::text || ':' || status order by statement_date) from public.statements
           where profile_code = pg_temp.v('p') and doc_code = pg_temp.v('d6') or
                 (profile_code = pg_temp.v('p') and statement_date in ('2026-07-31', '2026-08-01'))),
          array['2026-07-31:superseded', '2026-08-01:active'], 'the old identity is superseded, the new one active (E17)');
select is(pg_temp.txns(), pg_temp.v('txns6')::int, 'no transaction is duplicated');
select is((select sum(spend_aed) from public.v_spend where profile_code = pg_temp.v('p') and txn_date between '2026-07-01' and '2026-07-31'),
          135.00::numeric, 'July spend is 18 + 18 + 99, not doubled');
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p') and reason = 'orphaned'), 0,
          'the transient orphans of the re-parse leave no review behind (DP-06)');
-- and back again: the retired statement is revived with its codes
select pg_temp.ingest(pg_temp.payload('2026-07-31', jsonb_build_array(
  pg_temp.line(1, '2026-07-05', 'STARBUCKS MALL', 18), pg_temp.line(2, '2026-07-05', 'STARBUCKS MALL', 18),
  pg_temp.line(3, '2026-07-09', 'NOON.COM', 99))), pg_temp.v('d6'));
select is((select count(*)::int from public.statements where profile_code = pg_temp.v('p')
           and statement_date in ('2026-07-31', '2026-08-01')), 2, 'reverting the date revives the original statement');
select is(pg_temp.txns(), pg_temp.v('txns6')::int, 'still no duplicate');

-- ═══ DB-07: no card number never invents an account ══════════════════════
-- a second ADCB card/account
select pg_temp.set('d7b', (pg_temp.ingest(pg_temp.payload('2026-07-25', jsonb_build_array(
  pg_temp.line(1, '2026-07-02', 'SHOP B', 10, 'AED', null, null, '1111')), 'statement', '{}', '1111', 'REF-B')))->>'doc_code');
select pg_temp.set('acc_b', (select account_code from public.cards where profile_code = pg_temp.v('p') and last4 = '1111'));
select is(pg_temp.accounts(), 2, 'two ADCB accounts');
select pg_temp.set('txns7', pg_temp.txns()::text);
select lives_ok($$ select pg_temp.ingest(pg_temp.payload('2026-07-25', jsonb_build_array(
  pg_temp.line(1, '2026-07-02', 'SHOP B', 10, 'AED', null, null, null)), 'statement', '{}', null, 'REF-B'), pg_temp.v('d7b')) $$,
  're-parsing a document that lost its card number');
select is(pg_temp.accounts(), 2, 'keeps the document''s account (no new account)');
select is((select count(*)::int from public.statements where profile_code = pg_temp.v('p') and doc_code = pg_temp.v('d7b')
           and account_code = pg_temp.v('acc_b') and status = 'active'), 1, 'on the same statement');
select lives_ok($$ select pg_temp.ingest(pg_temp.payload('2026-08-25', jsonb_build_array(
  pg_temp.line(1, '2026-08-02', 'SHOP B2', 11, 'AED', null, null, null)), 'statement', '{}', null, 'REF-B')) $$,
  'a new card-less document with a known explicit reference');
select is((select account_code from public.statements where profile_code = pg_temp.v('p') and statement_date = '2026-08-25'),
          pg_temp.v('acc_b'), 'lands on the account that reference belongs to');
select throws_ok($$ select pg_temp.ingest(pg_temp.payload('2026-09-25', jsonb_build_array(
  pg_temp.line(1, '2026-09-02', 'SHOP X', 12, 'AED', null, null, null)), 'statement', '{}', null, 'REF-UNKNOWN')) $$,
  '22023', null, 'an ambiguous card-less statement with rows is a permanent ingest error (E12)');
select is(pg_temp.accounts(), 2, 'and no account was created');
select pg_temp.set('skip', pg_temp.ingest(pg_temp.payload('2026-09-25', '[]'::jsonb, 'statement', '{}', null, 'REF-UNKNOWN'))::text);
select is(jsonb_array_length(pg_temp.v('skip')::jsonb->'statements'), 0, 'a card-less statement without rows is skipped');
select ok((select parse_status = 'parsed' and parse_warnings::text like '%skipped: no card number and no transaction rows%'
           from public.documents where doc_code = pg_temp.v('skip')::jsonb->>'doc_code'),
          'and its document is parsed with a warning (DP-01)');

-- ═══ DP-01: a second, empty document for the same statement drops nothing ══
select pg_temp.set('r1', (pg_temp.ingest(pg_temp.payload('2026-10-31', jsonb_build_array(
  pg_temp.line(1, '2026-10-03', 'CINEMA', 46), pg_temp.line(2, '2026-10-04', 'GROCER', 120),
  pg_temp.line(3, '2026-10-05', 'PHARMACY', 30)), 'statement',
  '{"opening_balance":"0.00","closing_balance":"196.00"}')))::text);
select pg_temp.set('s1', pg_temp.v('r1')::jsonb->'statements'->0->>'stmt_code');
select pg_temp.set('e1', (pg_temp.ingest(pg_temp.payload('2026-10-31', '[]'::jsonb, 'statement',
  '{"opening_balance":"500.00","closing_balance":"500.00"}')))->>'doc_code');
select is(pg_temp.n_lines(pg_temp.v('s1')), 3, 'an empty document with the same identity supersedes no line');
select is((select closing_balance::text || '|' || doc_code from public.statements where stmt_code = pg_temp.v('s1')),
          '196.00|' || (pg_temp.v('r1')::jsonb->>'doc_code'), 'nor touches the header or the statement''s document');
select ok((select parse_warnings::text like '%no transaction rows%' from public.documents where doc_code = pg_temp.v('e1')),
          'the empty document is parsed with a warning');
select is((select status from public.statement_recon where stmt_code = pg_temp.v('s1')), 'ok', 'recon still ok');
-- the opposite order: the empty document first, the real one second
select pg_temp.set('e2', (pg_temp.ingest(pg_temp.payload('2026-11-30', '[]'::jsonb, 'statement',
  '{"opening_balance":"500.00","closing_balance":"500.00"}')))->>'doc_code');
select pg_temp.set('r2', (pg_temp.ingest(pg_temp.payload('2026-11-30', jsonb_build_array(
  pg_temp.line(1, '2026-11-03', 'CINEMA', 46), pg_temp.line(2, '2026-11-04', 'GROCER', 120)), 'statement',
  '{"opening_balance":"196.00","closing_balance":"362.00"}')))::text);
select is((select closing_balance::text || '|' || doc_code from public.statements
           where stmt_code = pg_temp.v('r2')::jsonb->'statements'->0->>'stmt_code'),
          '362.00|' || (pg_temp.v('r2')::jsonb->>'doc_code'), 'a document with rows takes the header over from an empty one');
-- the same statement received twice (another document with the same rows plus one)
select pg_temp.set('r1b', (pg_temp.ingest(pg_temp.payload('2026-10-31', jsonb_build_array(
  pg_temp.line(1, '2026-10-03', 'CINEMA', 46), pg_temp.line(2, '2026-10-04', 'GROCER', 120),
  pg_temp.line(3, '2026-10-05', 'PHARMACY', 30), pg_temp.line(4, '2026-10-06', 'BAKERY', 9)))))->>'doc_code');
select is(pg_temp.n_lines(pg_temp.v('s1')), 4, 'a second copy adds only its genuinely new line');
-- re-parsing the first copy without a row keeps the row the second copy still evidences
select pg_temp.ingest(pg_temp.payload('2026-10-31', jsonb_build_array(
  pg_temp.line(1, '2026-10-03', 'CINEMA', 46), pg_temp.line(2, '2026-10-04', 'GROCER', 120)), 'statement',
  '{"opening_balance":"0.00","closing_balance":"196.00"}'), pg_temp.v('r1')::jsonb->>'doc_code');
select is(pg_temp.n_lines(pg_temp.v('s1')), 4, 'a re-parse only withdraws its own evidence');

-- ═══ DP-02: history extracts are windows, not replacements ═════════════════
select pg_temp.set('h1', (pg_temp.ingest(pg_temp.payload('2026-12-15', jsonb_build_array(
  pg_temp.line(1, '2026-12-01', 'H-A', 1), pg_temp.line(2, '2026-12-02', 'H-B', 2), pg_temp.line(3, '2026-12-03', 'H-C', 3)),
  'history_extract')))::text);
select pg_temp.set('hs', pg_temp.v('h1')::jsonb->'statements'->0->>'stmt_code');
select pg_temp.set('h2', (pg_temp.ingest(pg_temp.payload('2026-12-15', jsonb_build_array(
  pg_temp.line(1, '2026-12-03', 'H-C', 3), pg_temp.line(2, '2026-12-04', 'H-D', 4)), 'history_extract')))->>'doc_code');
select is(pg_temp.n_lines(pg_temp.v('hs')), 4, 'a newer, narrower extract adds lines and supersedes none');
select pg_temp.ingest(pg_temp.payload('2026-12-15', jsonb_build_array(pg_temp.line(1, '2026-12-04', 'H-D', 4)), 'history_extract'),
                      pg_temp.v('h2'));
select is(pg_temp.n_lines(pg_temp.v('hs')), 4, 'H-C stays: the older extract still evidences it');
select pg_temp.ingest(pg_temp.payload('2026-12-15', jsonb_build_array(
  pg_temp.line(1, '2026-12-02', 'H-B', 2), pg_temp.line(2, '2026-12-03', 'H-C', 3)), 'history_extract'),
  pg_temp.v('h1')::jsonb->>'doc_code');
select is(pg_temp.n_lines(pg_temp.v('hs')), 3, 'only a re-parse of the same extract drops its own line');

-- ═══ DP-08: reconciliation ═════════════════════════════════════════════════
select is((select status from public.statement_recon where stmt_code = pg_temp.v('hs')), 'n/a',
          'history extracts are not reconciled');
select pg_temp.set('empty_active', (pg_temp.ingest(pg_temp.payload('2027-01-31', '[]'::jsonb, 'statement',
  '{"closing_balance":"250.00"}')))->'statements'->0->>'stmt_code');
select is((select status || ':' || (checks->>'no_lines') from public.statement_recon where stmt_code = pg_temp.v('empty_active')),
          'warn:true', 'an empty statement whose header shows activity is not ok');

-- ═══ DB-16: a line without an AED amount ═══════════════════════════════════
select pg_temp.set('eur', (pg_temp.ingest(pg_temp.payload('2027-02-28', jsonb_build_array(
  pg_temp.line(1, '2027-02-03', 'CAFE PARIS', 20, 'EUR', null, null), pg_temp.line(2, '2027-02-04', 'SHOP', 100)),
  'statement', '{"total_debits":"181.00","total_credits":"0.00"}')))->'statements'->0->>'stmt_code');
select is((select status || ':' || (checks->>'unpriced_lines') from public.statement_recon where stmt_code = pg_temp.v('eur')),
          'warn:1', 'a mismatch explained by a line without AED is a warn, not a fail');

-- ═══ DB-10 / DB-17: same amount, same day, different merchants ═════════════
select pg_temp.set('b10', pg_temp.sms_batch(jsonb_build_array(
  pg_temp.msg(pg_temp.adcb('100.00', '05/03/2026', '09:00:00', 'ENOC'), '2026-03-05 05:00:05+00'),
  pg_temp.msg(pg_temp.adcb('100.00', '05/03/2026', '19:00:00', 'CARREFOUR'), '2026-03-05 15:00:05+00')
))::text);
select is((select array_agg(e->>'status') from jsonb_array_elements(pg_temp.v('b10')::jsonb) e), array['created', 'created'],
          'two pending AED 100 purchases');
select pg_temp.set('m10', (pg_temp.ingest(pg_temp.payload('2026-03-31', jsonb_build_array(
  pg_temp.line(1, '2026-03-05', 'ENOC STATION 1021 DUBAI', 100), pg_temp.line(2, '2026-03-05', 'CARREFOUR MOE DUBAI', 100)))))
  ->'statements'->0->>'match');
select is(pg_temp.v('m10')::jsonb, '{"held": 0, "linked": 2, "created": 0}'::jsonb, 'both lines link to their SMS (E6)');
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p') and status = 'open'
           and reason in ('ambiguous', 'missing_from_statement')), 0, 'no ambiguous or missing_from_statement reviews');
select ok((select bool_and(t.description like split_part(s.description, ' ', 1) || '%')
           from public.transactions t
           join public.transaction_evidence e on e.txn_code = t.txn_code and e.evidence_type = 'sms' and e.is_active
           join public.sms_messages s on s.sms_code = e.sms_code
           where t.profile_code = pg_temp.v('p') and t.txn_date = '2026-03-05'),
          'each SMS is paired with the line of its own merchant');

-- DB-17: a missing_from_statement review closes once the transaction posts
select pg_temp.set('b17', pg_temp.sms_batch(jsonb_build_array(
  pg_temp.msg(pg_temp.adcb('77.00', '10/04/2026', '12:00:00', 'BOOKSHOP'), '2026-04-10 08:00:05+00')))::text);
select pg_temp.ingest(pg_temp.payload('2026-04-30', '[]'::jsonb, 'statement', '{}'));
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p') and status = 'open'
           and reason = 'missing_from_statement'), 1, 'a pending SMS missing from a closed statement is flagged');
select pg_temp.ingest(pg_temp.payload('2026-04-30', jsonb_build_array(pg_temp.line(1, '2026-04-10', 'BOOKSHOP', 77))));
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p') and status = 'open'
           and reason = 'missing_from_statement'), 0, 'and the review resolves when the line arrives');

-- ═══ DB-15: different available limits prove two alerts are two purchases ══
select pg_temp.set('b15', pg_temp.sms_batch(jsonb_build_array(
  pg_temp.msg(pg_temp.adcb('18.00', '01/05/2026', '08:00:00', 'COFFEE CART', '5000.00'), '2026-05-01 04:00:05+00'),
  pg_temp.msg(pg_temp.adcb('18.00', '01/05/2026', '08:02:00', 'COFFEE CART', '4982.00'), '2026-05-01 04:02:05+00')
))::text);
select is((select array_agg(e->>'status') from jsonb_array_elements(pg_temp.v('b15')::jsonb) e), array['created', 'created'],
          'two coffees 2 minutes apart with different available limits are both kept (E5)');

select * from finish();
rollback;

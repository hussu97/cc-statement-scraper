-- Outstanding balance (20261012043206): v_account_balances anchors, overview totals, orphaned
-- rows out of activity_summary's net, dismissing an orphan voids it, void_orphan_duplicates.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local ledger.test_today = '2026-10-12';

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric, p_dir text default 'debit',
                             p_kind text default 'purchase', p_last4 text default '1111')
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date + 1,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', 'AED', 'amount_aed', p_amount::text, 'fx_rate', null, 'direction', p_dir,
    'kind', p_kind, 'country_code', 'AE', 'card_last4', p_last4, 'card_holder', null,
    'legacy_fingerprint', md5(p_desc || p_date || p_amount || p_dir))
$$;
-- A FAB statement with printed opening and closing balances.
create function pg_temp.statement(p_date date, p_open numeric, p_close numeric, p_lines jsonb) returns jsonb
language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'FAB',
    'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'FAB', 'statement_reference', 'RFAB' || p_date,
      'reference_source', 'explicit', 'statement_date', p_date, 'period_start', (p_date - 30),
      'period_end', p_date, 'due_date', p_date + 25, 'primary_card_last4', '1111', 'card_holder', 'TEST',
      'card_type', 'VISA',
      'totals', jsonb_build_object('opening_balance', p_open::text, 'closing_balance', p_close::text),
      'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb, 'lines', p_lines)))
$$;
-- A SIB transaction history (no balances): one history_extract per 12th-of-month cycle.
create function pg_temp.history(p_last4 text, p_rows jsonb) returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'SIB',
    'document_kind', 'history_pdf',
    'statements', (
      select jsonb_agg(jsonb_build_object(
        'kind', 'history_extract', 'bank_code', 'SIB', 'statement_reference', 'SIB-H-' || p_last4 || '-' || c.stmt_date,
        'reference_source', 'fallback', 'statement_date', c.stmt_date, 'period_start', c.stmt_date - 30,
        'period_end', c.stmt_date, 'due_date', null, 'primary_card_last4', p_last4, 'card_holder', 'JANE Q SAMPLE',
        'card_type', 'SIB MC CASHBACK', 'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
        'lines', c.lines) order by c.stmt_date)
      from (
        select (case when extract(day from (r->>'d')::date) <= 12
                     then date_trunc('month', (r->>'d')::date) + interval '11 days'
                     else date_trunc('month', (r->>'d')::date) + interval '1 month 11 days' end)::date as stmt_date,
               jsonb_agg(pg_temp.line(o::int, (r->>'d')::date, r->>'m', (r->>'a')::numeric,
                                      coalesce(r->>'dir', 'debit'), coalesce(r->>'k', 'purchase'), p_last4) order by o)
                 as lines
        from jsonb_array_elements(p_rows) with ordinality x(r, o)
        group by 1
      ) c))
$$;
create function pg_temp.ingest(p_payload jsonb) returns jsonb language sql as $$
  with d as (
    insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
    values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'doc.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'),
            100, 'upload')
    returning doc_code)
  select public.ingest_parsed_document((select doc_code from d), p_payload) $$;
-- A transaction with no statement behind it yet (as an SMS would leave it).
create function pg_temp.loose(p_date date, p_desc text, p_amount numeric, p_dir text default 'debit',
                              p_status text default 'pending', p_kind text default 'purchase',
                              p_aed boolean default true, p_stmt text default null) returns text
language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source, stmt_code)
  values (pg_temp.v('p'), pg_temp.v('fab'), p_status, p_kind, p_dir, p_date, p_desc, p_amount,
          case when p_aed then 'AED' else 'USD' end, case when p_aed then p_amount end, 'sms', p_stmt)
  returning txn_code $$;
create function pg_temp.bal(p_account text) returns public.v_account_balances language sql as $$
  select * from public.v_account_balances where account_code = p_account $$;

-- ── setup ───────────────────────────────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't31-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t31-' || left(pg_temp.v('uid'), 8), 'Cards'));
reset role;
select set_config('request.jwt.claims', '', true);

-- FAB: two statements. The first opens at 64.38: debt from before the first document, which no
-- sum of transactions can know.
select pg_temp.ingest(pg_temp.statement('2026-08-28', 64.38, 1000.00, jsonb_build_array(
  pg_temp.line(1, '2026-08-05', 'GROCERY MART', 1335.62),
  pg_temp.line(2, '2026-08-10', 'CARD PAYMENT', 400.00, 'credit', 'payment'))));
select pg_temp.ingest(pg_temp.statement('2026-09-28', 1000.00, 1500.00, jsonb_build_array(
  pg_temp.line(1, '2026-09-03', 'CINEMA CITY', 900.00),
  pg_temp.line(2, '2026-09-15', 'CARD PAYMENT', 400.00, 'credit', 'payment'))));
select pg_temp.set('fab', (select account_code from public.accounts where profile_code = pg_temp.v('p') and bank_code = 'FAB'));
select pg_temp.set('sep', (select stmt_code from public.statements where account_code = pg_temp.v('fab')
                           and statement_date = '2026-09-28'));

-- ── statement anchor ────────────────────────────────────────────────────────
select is((pg_temp.bal(pg_temp.v('fab'))).anchor_kind, 'statement', 'FAB is anchored on its statements');
select is((pg_temp.bal(pg_temp.v('fab'))).anchor_stmt_code, pg_temp.v('sep'), 'the anchor is the latest statement');
select is((pg_temp.bal(pg_temp.v('fab'))).outstanding_aed, 1500.00::numeric(14,2),
          'no activity since: outstanding is the closing balance, carried-in debt included');
select is((select sum(case when direction = 'debit' then amount_aed else -amount_aed end) from public.transactions
           where account_code = pg_temp.v('fab')), 1435.62::numeric, '(the transactions alone sum to 64.38 less)');

select pg_temp.loose('2026-09-27', 'LATE POSTING CAFE', 50.00);            -- dated before the close, not on it
select pg_temp.loose('2026-10-02', 'PETROL STATION', 25.50);
select pg_temp.loose('2026-10-03', 'RETURNED SHOES', 10.00, 'credit', 'pending', 'refund');
select pg_temp.loose('2026-10-04', 'RELEASED HOLD', 999.00, 'debit', 'void');
select pg_temp.set('orphan', pg_temp.loose('2026-10-05', 'LOST EVIDENCE', 777.00, 'debit', 'orphaned'));
select is((pg_temp.bal(pg_temp.v('fab'))).activity_aed, 65.50::numeric(14,2),
          'activity since: loose pending rows (even one dated before the close), void and orphaned left out');
select is((pg_temp.bal(pg_temp.v('fab'))).outstanding_aed, 1565.50::numeric(14,2), 'outstanding = closing + activity since');
select is((pg_temp.bal(pg_temp.v('fab'))).unpriced_count, 0, 'nothing unpriced yet');

select pg_temp.loose('2026-10-06', 'FOREIGN SHOP', 10.00, 'debit', 'pending', 'purchase', false);
select is((pg_temp.bal(pg_temp.v('fab'))).unpriced_count, 1, 'a pending foreign charge without a rate is counted as unpriced');
select is((pg_temp.bal(pg_temp.v('fab'))).outstanding_aed, 1565.50::numeric(14,2), '...and left out of the sum');

-- ── SIB: no balances until a balance migration ──────────────────────────────
select pg_temp.ingest(pg_temp.history('6774', '[
  {"d":"2026-06-20","m":"CORNER GROCERY","a":"500.00"},
  {"d":"2026-07-10","m":"CREDIT CARD PAYMENT","a":"800.00","dir":"credit","k":"payment"}]'::jsonb));
select pg_temp.set('sib', (select account_code from public.accounts where profile_code = pg_temp.v('p') and bank_code = 'SIB'));
select is((pg_temp.bal(pg_temp.v('sib'))).anchor_kind, 'none', 'a history without balances has no anchor');
select ok((pg_temp.bal(pg_temp.v('sib'))).outstanding_aed is null, 'no anchor: outstanding is unknown, not a guess');

select pg_temp.ingest(pg_temp.history('5052', '[
  {"d":"2026-09-15","m":"BALANCE MIGRATION - RETAIL POS","a":"1395.13","k":"adjustment"},
  {"d":"2026-09-15","m":"CREDIT CARD PAYMENT","a":"1800.00","dir":"credit","k":"payment"},
  {"d":"2026-09-20","m":"PAY DU","a":"100.00"}]'::jsonb));
select is((select count(*)::int from public.accounts where profile_code = pg_temp.v('p') and bank_code = 'SIB'), 1,
          '(the replacement card is on the same account)');
select is((pg_temp.bal(pg_temp.v('sib'))).anchor_kind, 'balance_migration', 'the replacement card''s balance migration anchors SIB');
select is((pg_temp.bal(pg_temp.v('sib'))).anchor_date, '2026-09-15'::date, 'anchored on the migration date');
select is((pg_temp.bal(pg_temp.v('sib'))).outstanding_aed, -304.87::numeric(14,2),
          'outstanding = migrated balance + activity since; the old card''s rows are inside the migration');

-- ── overview ────────────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('ov', public.overview(pg_temp.v('p'), '2026-10-01')::text);
select is((select a->>'outstanding_aed' from jsonb_array_elements(pg_temp.v('ov')::jsonb->'accounts') a
           where a->>'bank_code' = 'FAB'), '1565.50', 'overview: per-account outstanding');
select is((select a->>'balance_anchor' from jsonb_array_elements(pg_temp.v('ov')::jsonb->'accounts') a
           where a->>'bank_code' = 'SIB'), 'balance_migration', 'overview: per-account anchor');
select is(pg_temp.v('ov')::jsonb->>'outstanding', '1260.63', 'overview: total outstanding over active accounts');
select is(pg_temp.v('ov')::jsonb->>'outstanding_complete', 'false', 'incomplete while a charge has no AED amount');

-- ── activity_summary: orphaned rows are not money ──────────────────────────
select is(public.activity_summary(pg_temp.v('p'), p_status => 'orphaned')->>'txn_count', '1', 'the orphan is listed');
select is(public.activity_summary(pg_temp.v('p'), p_status => 'orphaned')->>'net_aed', '0.00', '...but not in the net');
select is(public.activity_summary(pg_temp.v('p'), p_account_code => pg_temp.v('fab'))->>'net_aed', '1501.12',
          'FAB net: pending and posted rows only');
reset role;

-- ── dismissing an orphaned review voids the transaction ─────────────────────
insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason)
values (pg_temp.v('p'), pg_temp.v('fab'), 'transaction', pg_temp.v('orphan'), 'orphaned');
select pg_temp.as_user('uid');
set local role authenticated;
select is(public.resolve_review((select review_code from public.match_reviews where subject_code = pg_temp.v('orphan')),
                                '{"dismiss": true}')->>'outcome', 'dismissed', 'the orphan review is dismissed');
reset role;
select is((select status || '/' || void_reason from public.transactions where txn_code = pg_temp.v('orphan')),
          'void/orphan_dismissed', '...and its transaction is void');

-- ── void_orphan_duplicates ─────────────────────────────────────────────────
-- As a re-parse leaves them: an orphaned copy of a statement row, beside the live row.
select pg_temp.set('dup', pg_temp.loose('2026-09-03', 'CINEMA CITY', 900.00, 'debit', 'orphaned', 'purchase', true, pg_temp.v('sep')));
select pg_temp.set('dup2', pg_temp.loose('2026-09-03', 'CINEMA CITY', 900.00, 'debit', 'orphaned', 'purchase', true, pg_temp.v('sep')));
select pg_temp.set('noted', pg_temp.loose('2026-09-15', 'CARD PAYMENT', 400.00, 'credit', 'orphaned', 'payment', true, pg_temp.v('sep')));
update public.transactions set notes = 'keep me' where txn_code = pg_temp.v('noted');
select pg_temp.set('alone', pg_temp.loose('2026-09-04', 'NO TWIN', 12.00, 'debit', 'orphaned', 'purchase', true, pg_temp.v('sep')));
insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason)
select pg_temp.v('p'), pg_temp.v('fab'), 'transaction', x, 'orphaned' from unnest(array[pg_temp.v('dup'), pg_temp.v('dup2')]) x;

select is(private.void_orphan_duplicates(), 1, 'one live twin voids one of two orphaned copies');
select is((select array_agg(status order by txn_code) from public.transactions
           where txn_code in (pg_temp.v('dup'), pg_temp.v('dup2'))), array['void', 'orphaned'],
          'pairs one to one, lowest code first');
select is((select status || '/' || void_reason from public.transactions where txn_code = pg_temp.v('dup')),
          'void/orphan_duplicate', 'the voided copy says why');
select is((select status from public.match_reviews where subject_code = pg_temp.v('dup')), 'resolved',
          'its open review is resolved');
select is((select status from public.match_reviews where subject_code = pg_temp.v('dup2')), 'open',
          'the unpaired copy keeps its review');
select is((select status from public.transactions where txn_code = pg_temp.v('noted')), 'orphaned',
          'an orphan the user annotated is left alone');
select is((select status from public.transactions where txn_code = pg_temp.v('alone')), 'orphaned',
          'an orphan without a live twin is left alone');
select is(private.void_orphan_duplicates(), 0, 'idempotent');
select is((pg_temp.bal(pg_temp.v('fab'))).outstanding_aed, 1565.50::numeric(14,2), 'orphans never moved the balance');

-- ── tenant isolation ───────────────────────────────────────────────────────
select pg_temp.as_user('uid2');
set local role authenticated;
select is((select count(*)::int from public.v_account_balances where profile_code = pg_temp.v('p')), 0,
          'another user sees none of these balances');
reset role;

select * from finish();
rollback;

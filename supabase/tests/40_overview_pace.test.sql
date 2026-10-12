-- Overview pace (20261012215047_overview_pace.sql, audit WEB-26): month_to_date_end windows,
-- spend_pace's spend_avg_3m_to_date and projected_month_end on pinned days (month start,
-- 30 Oct vs 31 Aug, 31 Oct vs 30 Sep, February), and overview's new fields beside the old ones.
-- Runs on a non-empty DB: every key is unique to this run and every assertion is scoped to this
-- run's profile.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric, p_dir text default 'debit',
                             p_kind text default 'purchase')
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', 'AED', 'amount_aed', p_amount::text, 'fx_rate', null, 'direction', p_dir,
    'kind', p_kind, 'country_code', 'AE', 'card_last4', '3939', 'card_holder', null,
    'legacy_fingerprint', md5(p_desc || p_date || p_amount || p_dir))
$$;
-- One statement per calendar month: period 1st..last day, dated the last day.
create function pg_temp.month_statement(p_month date, p_lines jsonb) returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB',
    'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'ADCB', 'statement_reference', 'T39-' || p_month,
      'reference_source', 'explicit', 'statement_date', (p_month + interval '1 month')::date - 1,
      'period_start', p_month, 'period_end', (p_month + interval '1 month')::date - 1,
      'due_date', (p_month + interval '1 month')::date + 24, 'primary_card_last4', '3939', 'card_holder', 'TEST',
      'card_type', 'VISA', 'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
      'lines', p_lines)))
$$;
create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
  returning doc_code $$;
create function pg_temp.ingest(p_payload jsonb) returns jsonb language sql as $$
  select public.ingest_parsed_document(pg_temp.new_doc(), p_payload) $$;
create function pg_temp.pace(p_month date, p_today date, p_key text) returns text language sql as $$
  select public.spend_pace(pg_temp.v('p'), p_month, p_today)->>p_key $$;

-- ── setup: one owner, one profile ───────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't39-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t39-' || left(pg_temp.v('uid'), 8), 'Overview pace'));
reset role;
select set_config('request.jwt.claims', '', true);

-- ═══ month_to_date_end: the "same day of the month" window ════════════════
select is(public.month_to_date_end('2025-09-01', '2025-10-01', '2025-10-01'), '2025-09-02'::date,
          '1 Oct (month start) covers 1 September only');
select is(public.month_to_date_end('2025-08-01', '2025-10-01', '2025-10-30'), '2025-08-31'::date,
          '30 Oct covers 1-30 August, not the 31st');
select is(public.month_to_date_end('2025-09-01', '2025-10-01', '2025-10-30'), '2025-10-01'::date,
          '30 Oct covers all of September');
select is(public.month_to_date_end('2025-09-01', '2025-10-01', '2025-10-31'), '2025-10-01'::date,
          '31 Oct covers all of a 30-day September, never 1 October');
select is(public.month_to_date_end('2025-08-01', '2025-09-01', '2025-09-30'), '2025-09-01'::date,
          '30 Sep (its last day) covers all 31 days of August');
select is(public.month_to_date_end('2027-01-01', '2027-02-01', '2027-02-28'), '2027-02-01'::date,
          '28 Feb (non-leap, last day) covers all of January');
select is(public.month_to_date_end('2028-01-01', '2028-02-01', '2028-02-28'), '2028-01-29'::date,
          '28 Feb in a leap year is not the last day: 1-28 January');
select is(public.month_to_date_end('2027-02-01', '2027-03-01', '2027-03-30'), '2027-03-01'::date,
          '30 Mar covers a 28-day February and stops there');
select is(public.month_to_date_end('2027-02-01', '2027-03-01', '2027-03-15'), '2027-02-16'::date,
          '15 Mar covers 1-15 February');
select is(public.month_to_date_end('2025-07-01', '2025-08-01', '2025-10-13'), '2025-08-01'::date,
          'a past viewed month compares whole months');
select is(public.month_to_date_end('2025-09-01', '2025-10-01', '2025-09-20'), '2025-09-01'::date,
          'a viewed month that has not started compares nothing');

-- ═══ spend history: Jul 400, Aug 850, Sep 1200 (2025), Oct 60 so far ═════
-- Jul: 1st 100, 10th 300. Aug: 1st 200, 30th 50, 31st 600. Sep: 1st 300, 30th 900. Oct: 1st 60.
-- A refund (credit) counts negative in v_spend; a payment does not count at all.
select pg_temp.ingest(pg_temp.month_statement('2025-07-01', jsonb_build_array(
  pg_temp.line(1, '2025-07-01', 'T39 GROCER JUL', 100), pg_temp.line(2, '2025-07-10', 'T39 GROCER JUL', 300),
  pg_temp.line(3, '2025-07-20', 'T39 PAYMENT THANK YOU', 5000, 'credit', 'payment'))));
select pg_temp.ingest(pg_temp.month_statement('2025-08-01', jsonb_build_array(
  pg_temp.line(1, '2025-08-01', 'T39 GROCER AUG', 200), pg_temp.line(2, '2025-08-30', 'T39 GROCER AUG', 70),
  pg_temp.line(3, '2025-08-30', 'T39 GROCER AUG REFUND', 20, 'credit', 'refund'),
  pg_temp.line(4, '2025-08-31', 'T39 GROCER AUG', 600))));
select pg_temp.ingest(pg_temp.month_statement('2025-09-01', jsonb_build_array(
  pg_temp.line(1, '2025-09-01', 'T39 GROCER SEP', 300), pg_temp.line(2, '2025-09-30', 'T39 GROCER SEP', 900))));
select pg_temp.ingest(pg_temp.month_statement('2025-10-01', jsonb_build_array(
  pg_temp.line(1, '2025-10-01', 'T39 GROCER OCT', 60))));

select is((select sum(spend_aed) from public.v_spend where profile_code = pg_temp.v('p')
           and txn_date >= '2025-07-01' and txn_date < '2025-10-01'), 2450.00::numeric,
          'fixture: 2450.00 of spend in July-September (refund netted, payment excluded)');

-- Mid-month: days 1-15 of each earlier month.
select is(pg_temp.pace('2025-10-01', '2025-10-15', 'spend_avg_3m_to_date'), '300.00',
          '15 Oct: (400 + 200 + 300) / 3 to the 15th');

-- Month start: only the 1st of each earlier month.
select is(pg_temp.pace('2025-10-01', '2025-10-01', 'spend_avg_3m_to_date'), '200.00',
          '1 Oct: (100 + 200 + 300) / 3, the 1st of each month');
select is(pg_temp.pace('2025-10-01', '2025-10-01', 'projected_month_end'), '676.67',
          '1 Oct: projected = 60 + (816.67 - 200.00)');

-- 30 Oct: August stops at the 30th (its 31st, 600, is not "to date"); September is whole.
select is(pg_temp.pace('2025-10-01', '2025-10-30', 'spend_avg_3m_to_date'), '616.67',
          '30 Oct: (400 + 250 + 1200) / 3, August without the 31st');
select is(pg_temp.pace('2025-10-01', '2025-10-30', 'projected_month_end'), '260.00',
          '30 Oct: projected = 60 + (816.67 - 616.67)');

-- 31 Oct, the last day: every earlier month in full, and the projection is the spend itself.
select is(pg_temp.pace('2025-10-01', '2025-10-31', 'spend_avg_3m_to_date'), '816.67',
          '31 Oct: the to-date average is the full 3-month average (September has 30 days)');
select is(pg_temp.pace('2025-10-01', '2025-10-31', 'projected_month_end'), '60.00',
          '31 Oct: projected month end = spend');

-- 30 Sep is September's last day: June-August in full (June is empty).
select is(pg_temp.pace('2025-09-01', '2025-09-30', 'spend_avg_3m_to_date'), '416.67',
          '30 Sep: (0 + 400 + 850) / 3, August''s 31st included');
-- 29 Sep: August to the 29th only.
select is(pg_temp.pace('2025-09-01', '2025-09-29', 'spend_avg_3m_to_date'), '200.00',
          '29 Sep: (0 + 400 + 200) / 3 to the 29th');
select is(pg_temp.pace('2025-09-01', '2025-09-29', 'projected_month_end'), '1525.00',
          '29 Sep: only July and August have spend, so the rest of the month is averaged over 2: 1200 + (1250 - 600) / 2');
-- 5 Aug: only July has history. The to-date average still divides by 3 (like spend_avg_3m),
-- but the projection averages the rest of the month over the one month that has data.
select is(pg_temp.pace('2025-08-01', '2025-08-05', 'spend_avg_3m_to_date'), '33.33',
          '5 Aug: 100 / 3 to the 5th');
select is(pg_temp.pace('2025-08-01', '2025-08-05', 'projected_month_end'), '1150.00',
          '5 Aug: one month of history: 850 + (400 - 100) / 1, not / 3');

-- A completed month and a future month.
select is(pg_temp.pace('2025-10-01', '2025-11-13', 'spend_avg_3m_to_date'), '816.67',
          'a past month compares whole months');
select is(pg_temp.pace('2025-10-01', '2025-11-13', 'projected_month_end'), '60.00',
          'a past month projects to what it spent');
select is(pg_temp.pace('2025-11-01', '2025-10-13', 'spend_avg_3m_to_date'), '0.00',
          'a future month has nothing to date');
select is(pg_temp.pace('2025-11-01', '2025-10-13', 'projected_month_end'), null,
          'a future month has no projection');

-- No spend in the 3 months before: the run rate. July 15th, 400 spent: 400 / 15 * 31.
select is(pg_temp.pace('2025-07-01', '2025-07-15', 'spend_avg_3m_to_date'), '0.00',
          'a ledger''s first month has no history to date');
select is(pg_temp.pace('2025-07-01', '2025-07-15', 'projected_month_end'), '826.67',
          'and projects its run rate: 400 / 15 x 31');

-- ═══ overview: the new fields, beside the unchanged ones ═══════════════════
select is((select array_agg(k order by k) from jsonb_object_keys(public.overview(pg_temp.v('p'))) k
           where k in ('spend', 'spend_prev_month', 'spend_prev_month_to_date', 'spend_avg_3m',
                       'change_vs_prev_month_to_date', 'change_vs_avg_3m', 'spend_avg_3m_to_date',
                       'projected_month_end')),
          array['change_vs_avg_3m', 'change_vs_prev_month_to_date', 'projected_month_end', 'spend',
                'spend_avg_3m', 'spend_avg_3m_to_date', 'spend_prev_month', 'spend_prev_month_to_date'],
          'overview keeps its spend fields and adds spend_avg_3m_to_date and projected_month_end');
select is(public.overview(pg_temp.v('p'), '2025-10-01') - array['recent', 'accounts', 'top_categories', 'last_sms_at',
                                                                  'open_reviews', 'outstanding', 'outstanding_complete',
                                                                  'outstanding_has_estimate', 'pending_count',
                                                                  'pending_amount', 'pending_unpriced_count',
                                                                  'uncategorized_count', 'payments'],
          jsonb_build_object('month', '2025-10-01', 'spend', '60.00', 'spend_prev_month', '1200.00',
                             'spend_prev_month_to_date', '300.00', 'spend_avg_3m', '816.67',
                             'spend_avg_3m_to_date', '816.67', 'projected_month_end', '60.00',
                             'change_vs_prev_month_to_date', '-0.9500', 'change_vs_avg_3m', '-0.9265'),
          'overview of a past month: whole-month baseline, projection = spend, decimal strings');
select is(public.overview(pg_temp.v('p')) -> 'spend_avg_3m_to_date',
          public.spend_pace(pg_temp.v('p')) -> 'spend_avg_3m_to_date',
          'overview''s current month uses today''s Dubai date');
select is(jsonb_typeof(public.overview(pg_temp.v('p')) -> 'projected_month_end'), 'string',
          'projected_month_end is a decimal string for the current month');

-- ═══ tenant isolation: RLS scopes spend_pace to the caller ════════════════
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('uid2')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't39b-' || pg_temp.v('uid2') || '@test.dev', '{}', '{}', now(), now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid2'), 'role', 'authenticated')::text, true);
set local role authenticated;
select is(public.spend_pace(pg_temp.v('p'), '2025-10-01', '2025-10-30'),
          '{"spend_avg_3m_to_date": "0.00", "projected_month_end": "0.00"}'::jsonb,
          'another user sees none of the profile''s spend through spend_pace');
reset role;
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select is(public.spend_pace(pg_temp.v('p'), '2025-10-01', '2025-10-30')->>'spend_avg_3m_to_date', '616.67',
          'the owner sees it as the caller');
reset role;

select * from finish();
rollback;

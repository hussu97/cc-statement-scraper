-- Ledger fixes from the audit backlog (20261009000100_db_ledger_fixes.sql):
-- DB-17r, DB-18, DB-19r, DB-20, DB-32r, DB-34, DB-36, DB-39, DB-44, DB-45, DP-04r, X-33.
-- Runs on a non-empty DB: every key is unique to this run and every assertion is
-- scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ── helpers ─────────────────────────────────────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;

create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric, p_cur text default 'AED',
                             p_aed numeric default null, p_fx text default null, p_last4 text default '3687')
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date + 1,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', p_cur, 'amount_aed', coalesce(p_aed, case when p_cur = 'AED' then p_amount end)::text,
    'fx_rate', p_fx, 'direction', 'debit', 'kind', 'purchase', 'country_code', 'AE', 'card_last4', p_last4,
    'card_holder', null, 'legacy_fingerprint', null)
$$;
create function pg_temp.payload(p_date date, p_lines jsonb, p_totals jsonb default '{}'::jsonb,
                                p_last4 text default '3687')
returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB',
    'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'ADCB', 'statement_reference', 'T13-' || p_date,
      'reference_source', 'explicit', 'statement_date', p_date, 'period_start', (p_date - 30), 'period_end', p_date,
      'due_date', p_date + 25, 'primary_card_last4', p_last4, 'card_holder', 'TEST', 'card_type', 'VISA',
      'totals', p_totals, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb, 'lines', p_lines)))
$$;
create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
  returning doc_code $$;
create function pg_temp.ingest(p_payload jsonb) returns jsonb language sql as $$
  select public.ingest_parsed_document(pg_temp.new_doc(), p_payload) $$;
create function pg_temp.sms(p_sender text, p_body text, p_at timestamptz) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', p_sender, 'body', p_body)))->0 $$;
create function pg_temp.adcb(p_last4 text, p_amount text, p_date text, p_merchant text) returns text language sql as $$
  select format('Your Cr.Card XXX%s was used for AED%s on %s 10:00:00 at %s. Avl. Cr.limit is AED20000.00',
                p_last4, p_amount, p_date, p_merchant) $$;

-- ── setup: one owner, one profile ───────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't13-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t13-' || left(pg_temp.v('uid'), 8), 'Ledger fixes'));
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.set('d0', (current_date - 60)::text);   -- a statement date safely in the past

-- ═══ DB-18: previous month to date never runs into the viewed month ═══════
select is(public.prev_month_to_date_end('2027-03-01', '2027-03-30'), '2027-03-01'::date,
          '30 Mar compares with all of February, not 1-2 March');
select is(public.prev_month_to_date_end('2026-12-01', '2026-12-31'), '2026-12-01'::date,
          '31 Dec compares with all of November, not 1 December');
select is(public.prev_month_to_date_end('2026-10-01', '2026-10-08'), '2026-09-09'::date,
          '8 Oct compares with 1-8 September');
select is(public.prev_month_to_date_end('2026-03-01', '2026-03-28'), '2026-03-01'::date,
          '28 Mar after a 28-day February is the whole of February');

-- ═══ statement with a card in credit (DB-39) ══════════════════════════════
select pg_temp.set('r1', pg_temp.ingest(pg_temp.payload(pg_temp.v('d0')::date, jsonb_build_array(
  pg_temp.line(1, pg_temp.v('d0')::date - 5, 'T13 COFFEE HOUSE', 25)),
  '{"opening_balance":"0.00","closing_balance":"-150.00","credit_limit":"10000.00"}'))::text);
select pg_temp.set('acc', (select account_code from public.cards where profile_code = pg_temp.v('p') and last4 = '3687'));
select is((select utilisation from public.statement_cycles(pg_temp.v('p')) limit 1), 0.0000::numeric,
          'statement_cycles: a card in credit has 0 utilisation, not negative (DB-39)');
select is((public.overview(pg_temp.v('p'))->'accounts'->0->>'utilisation'), '0.0000',
          'overview: utilisation is 0 for a card in credit (DB-39)');

-- ═══ DB-44: a new statement transaction starts with its merchant ══════════
select ok((select merchant_code is not null and rules_version > 0 from public.transactions
           where profile_code = pg_temp.v('p') and description like 'T13 COFFEE HOUSE%'),
          'a transaction created from a line has its merchant and is categorised (DB-44)');
select is((select count(*)::int from public.transactions t
           where t.profile_code = pg_temp.v('p') and t.merchant_code is distinct from private.resolve_merchant(t.description)),
          0, 'every transaction''s merchant is the one refresh_transaction derives');

-- ═══ DB-17r: an unknown_card SMS is processed once a statement registers it ═
select pg_temp.set('u', pg_temp.sms('ADCBAlert', pg_temp.adcb('5555', '77.00',
  to_char(pg_temp.v('d0')::date - 3, 'DD/MM/YYYY'), 'T13 BOOKSHOP'),
  (pg_temp.v('d0')::date - 3 + time '06:00') at time zone 'Asia/Dubai')::text);
select is(pg_temp.v('u')::jsonb->>'status', 'unknown_card', 'an SMS for an unregistered card is held');
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p')
           and reason = 'unknown_card' and status = 'open'), 1, 'with an open unknown_card review');
-- the next statement lists a supplementary card 5555 on the same account
select pg_temp.set('r2', pg_temp.ingest(pg_temp.payload(pg_temp.v('d0')::date + 30, jsonb_build_array(
  pg_temp.line(1, pg_temp.v('d0')::date + 10, 'T13 GROCER', 40),
  pg_temp.line(2, pg_temp.v('d0')::date + 12, 'T13 PHARMACY', 12, 'AED', null, null, '5555'))))::text);
select is((pg_temp.v('r2')::jsonb->>'sms_card_registered')::int, 1, 'ingest reports one SMS bound to its card');
select is((select account_code from public.sms_messages where sms_code = pg_temp.v('u')::jsonb->>'sms_code'),
          pg_temp.v('acc'), 'the held SMS now has the card''s account');
select is((select status || ':' || (resolution->>'auto') from public.match_reviews where profile_code = pg_temp.v('p')
           and reason = 'unknown_card'), 'resolved:card_registered', 'and its review resolved itself');
select ok(exists (select 1 from public.transaction_evidence e where e.sms_code = pg_temp.v('u')::jsonb->>'sms_code'
                  and e.is_active), 'the SMS is now evidence of a transaction');

-- ═══ DB-20: v_transactions flags equal the evidence ═══════════════════════
select is((select count(*)::int from public.v_transactions v where v.profile_code = pg_temp.v('p')
           and (v.has_sms <> exists (select 1 from public.transaction_evidence e where e.txn_code = v.txn_code
                                     and e.is_active and e.evidence_type = 'sms')
                or v.has_statement <> exists (select 1 from public.transaction_evidence e where e.txn_code = v.txn_code
                                              and e.is_active and e.evidence_type in ('statement_line', 'history_line')))),
          0, 'has_sms / has_statement match the active evidence (DB-20)');
select ok((select bool_or(has_sms) from public.v_transactions where profile_code = pg_temp.v('p')),
          'and at least one transaction has an SMS');
select ok(coalesce((select option_value = 'true' from pg_options_to_table(
                     (select reloptions from pg_class where oid = 'public.v_transactions'::regclass))
                    where option_name = 'security_invoker'), false),
          'v_transactions is still security_invoker');

-- ═══ DB-19r: an existing merchant is not rewritten ════════════════════════
select pg_temp.set('mxmin', (select xmin::text from public.merchants where merchant_key = public.merchant_key('T13 GROCER')));
select is(private.resolve_merchant('T13 GROCER'),
          (select merchant_code from public.merchants where merchant_key = public.merchant_key('T13 GROCER')),
          'resolve_merchant returns the existing merchant');
select is((select xmin::text from public.merchants where merchant_key = public.merchant_key('T13 GROCER')),
          pg_temp.v('mxmin'), 'without writing its row (DB-19r)');
select ok(private.resolve_merchant('T13 BRAND NEW MERCHANT ' || pg_temp.v('uid')) is not null,
          'a new key still creates a merchant');

-- ═══ DB-34: declined alerts are ignored ═══════════════════════════════════
select pg_temp.set('dec', pg_temp.sms('SIB',
  'A txn on your Covered Card XXXX5052 at Tesla Motors Netherlan for AED 1.00 on ' || to_char(current_date, 'DD-MM-YYYY')
  || ' 12:19 is declined. Your available balance is AED 7,459.22', now())::text);
select is(pg_temp.v('dec')::jsonb->>'status', 'ignored', 'a declined alert is reported ignored');
select is((select parse_status || ':' || ignore_reason from public.sms_messages where sms_code = pg_temp.v('dec')::jsonb->>'sms_code'),
          'ignored:declined', 'and stored ignored with reason declined (DB-34)');

-- ═══ DB-36: a template date far from arrival falls back to received_at ════
select pg_temp.set('far', pg_temp.sms('ADCBAlert', pg_temp.adcb('3687', '15.00',
  to_char(pg_temp.v('d0')::date + 20 + 90, 'DD/MM/YYYY'), 'T13 FAR DATE'),
  (pg_temp.v('d0')::date + 20 + time '06:00') at time zone 'Asia/Dubai')::text);
select is((select event_at = received_at from public.sms_messages where sms_code = pg_temp.v('far')::jsonb->>'sms_code'),
          true, 'an SMS dated 90 days from its arrival uses the arrival time (DB-36)');
select ok((select parsed_fields ? 'event_at_rejected' from public.sms_messages where sms_code = pg_temp.v('far')::jsonb->>'sms_code'),
          'and records the rejected date');
select pg_temp.set('near', pg_temp.sms('ADCBAlert', pg_temp.adcb('3687', '16.00',
  to_char(pg_temp.v('d0')::date + 21, 'DD/MM/YYYY'), 'T13 NEAR DATE'),
  (pg_temp.v('d0')::date + 22 + time '06:00') at time zone 'Asia/Dubai')::text);
select is((select public.dubai_date(event_at) from public.sms_messages where sms_code = pg_temp.v('near')::jsonb->>'sms_code'),
          pg_temp.v('d0')::date + 21, 'a date a day before arrival is kept');

-- ═══ DB-45: unpriced pending transactions are reported ════════════════════
insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description, amount_original,
                                 currency_original, amount_source, status)
values (pg_temp.v('p'), pg_temp.v('acc'), 'purchase', 'debit', current_date, 'T13 UNPRICED', 10, 'QQQ', 'sms', 'pending');
select is((public.overview(pg_temp.v('p'))->>'pending_unpriced_count')::int, 1,
          'overview counts pending transactions with no AED amount (DB-45)');

-- ═══ DP-04r: a statement far in the future is rejected ════════════════════
select throws_ok($$ select pg_temp.ingest(pg_temp.payload(current_date + 40, jsonb_build_array(
                      pg_temp.line(1, current_date, 'T13 FUTURE', 5)))) $$,
                 '22023', null, 'a statement dated 40 days ahead is a permanent ingest error (DP-04r)');
select lives_ok($$ select pg_temp.ingest(pg_temp.payload(current_date + 20, jsonb_build_array(
                     pg_temp.line(1, current_date, 'T13 NEAR FUTURE', 5)))) $$,
                'a statement dated 20 days ahead is accepted');

-- ═══ X-33: fx_rate normalisation ══════════════════════════════════════════
select lives_ok($$ select pg_temp.ingest(pg_temp.payload(pg_temp.v('d0')::date + 60, jsonb_build_array(
                     pg_temp.line(1, pg_temp.v('d0')::date + 40, 'T13 TINY RATE', 1000000, 'IRR', 0.05, '0.000000001'),
                     pg_temp.line(2, pg_temp.v('d0')::date + 41, 'T13 AED RATE ONE', 30, 'AED', 30, '1')))) $$,
                'a line whose fx_rate rounds to 0 does not fail the ingest');
select is((select fx_rate from public.statement_lines where profile_code = pg_temp.v('p') and description like 'T13 TINY RATE%'),
          null::numeric, 'and its rate is stored as unknown');
select is((select fx_rate from public.transactions where profile_code = pg_temp.v('p') and description like 'T13 AED RATE ONE%'),
          null::numeric, 'an AED transaction has no fx_rate even when its line says 1');
select is((select count(*)::int from public.transactions where currency_original = 'AED' and fx_rate is not null), 0,
          'no AED transaction carries an fx_rate');

-- ═══ DB-32r: the estimate_fx index exists ═════════════════════════════════
select has_index('public', 'statement_lines', 'statement_lines_fx_estimate_idx', 'estimate_fx has an index (DB-32r)');
select lives_ok($$ select * from public.anomalies(pg_temp.v('p'), current_date - 365, current_date) $$,
                'anomalies runs on the window-function form');

select * from finish();
rollback;

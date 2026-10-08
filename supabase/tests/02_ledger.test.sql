-- Ledger behaviour: statement ingestion, re-ingestion, SMS capture, matching,
-- dedup, categorisation precedence and reconciliation.
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
                             p_aed numeric default null, p_fx numeric default null, p_dir text default 'debit',
                             p_kind text default 'purchase', p_last4 text default '3687')
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date + 1,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', p_cur, 'amount_aed', coalesce(p_aed, case when p_cur = 'AED' then p_amount end)::text,
    'fx_rate', p_fx::text, 'direction', p_dir, 'kind', p_kind, 'country_code', 'AE', 'card_last4', p_last4,
    'card_holder', null, 'legacy_fingerprint', md5(p_desc || p_date || p_amount))
$$;

create function pg_temp.payload(p_date date, p_lines jsonb, p_kind text default 'statement',
                                p_totals jsonb default '{}'::jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB',
    'document_kind', case when p_kind = 'statement' then 'statement_pdf' else 'history_pdf' end,
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', p_kind, 'bank_code', 'ADCB', 'statement_reference', 'REF' || p_date, 'reference_source', 'explicit',
      'statement_date', p_date, 'period_start', (p_date - 30), 'period_end', p_date, 'due_date', p_date + 25,
      'primary_card_last4', '3687', 'card_holder', 'TEST', 'card_type', 'VISA',
      'totals', jsonb_build_object('opening_balance', p_totals->>'opening_balance', 'closing_balance', p_totals->>'closing_balance',
        'total_debits', p_totals->>'total_debits', 'total_credits', p_totals->>'total_credits',
        'min_due', null, 'credit_limit', '27000.00'),
      'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb, 'lines', p_lines)))
$$;

-- A new document per call, or a re-parse of an existing one (p_doc).
create function pg_temp.ingest(p_payload jsonb, p_doc text default null) returns jsonb language plpgsql as $$
declare v_doc text := p_doc;
begin
  if v_doc is null then
    insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
    values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'test.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload')
    returning doc_code into v_doc;
  end if;
  return public.ingest_parsed_document(v_doc, p_payload);
end $$;

create function pg_temp.sms(p_body text, p_at timestamptz, p_id uuid default gen_random_uuid()) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', p_id, 'received_at', p_at, 'sender', 'ADCBAlert', 'body', p_body))) -> 0
$$;

create function pg_temp.txns() returns bigint language sql as $$
  select count(*) from public.transactions where profile_code = pg_temp.v('p') and status <> 'void' $$;

-- ── setup: a user, a profile, an ADCB SMS template ─────────────────────────
-- The local DB may hold other data: every id, email and profile key here is
-- unique to this run and every assertion is scoped to this profile.
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'owner-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t02-' || left(pg_temp.v('uid'), 8), 'Owner'));
reset role;

select throws_ok($$
  insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, examples)
  values ('ADCB', 'bad', 'ADCB', 'used for ([A-Z]{3}) ([0-9,.]+)', '{"currency":1,"amount":2}', null, 'purchase',
          '[{"sender":"ADCBAlert","body":"Card used for AED 10.00","expect":{"amount":"99.00"}}]')
$$, '22023', null, 'a template whose example does not parse to its expectation is rejected');

insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, examples)
values
 ('ADCB', 'purchase', '^ADCB',
  'Cr\.Card XXX([0-9]{4}) was used for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on ([0-9]{2}/[0-9]{2}/[0-9]{4}) ([0-9]{2}:[0-9]{2}:[0-9]{2}) at (.*?)\. Avl',
  '{"last4":1,"currency":2,"amount":3,"date":4,"time":5,"merchant":6}', 'DD/MM/YYYY', 'purchase',
  '[{"sender":"ADCBAlert","body":"Your Cr.Card XXX3687 was used for AED52.25 on 03/07/2026 14:22:11 at CARREFOUR,DUBAI. Avl Cr. limit is AED 100.00","expect":{"amount":"52.25","currency":"AED","last4":"3687","merchant":"CARREFOUR,DUBAI","date":"2026-07-03"}}]'),
 ('ADCB', 'reversal', '^ADCB',
  'Reversal of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on Cr\.Card XXX([0-9]{4}) at (.*?) on ([0-9]{2}/[0-9]{2}/[0-9]{4})',
  '{"currency":1,"amount":2,"last4":3,"merchant":4,"date":5}', 'DD/MM/YYYY', 'reversal', '[]');

-- ── 1. first statement creates the account + card ──────────────────────────
select pg_temp.ingest(pg_temp.payload('2026-06-30', jsonb_build_array(pg_temp.line(1, '2026-06-10', 'STARBUCKS DXB MALL', 21))));
select is((select count(*)::int from public.accounts where profile_code = pg_temp.v('p')), 1, 'statement creates one account');
select is((select last4 from public.cards where profile_code = pg_temp.v('p')), '3687', 'and its card');
select is(pg_temp.txns(), 1::bigint, 'one posted transaction');
select is((select c.name from public.v_transactions v join public.categories c on c.category_code = v.category_code
           where v.profile_code = pg_temp.v('p')), 'Dining', 'seed rules categorise STARBUCKS as Dining immediately');

-- ── 2. realtime SMS: two identical coffees, a USD purchase, an unknown card ─
select is(pg_temp.sms('Your Cr.Card XXX3687 was used for AED18.00 on 03/07/2026 08:00:00 at STARBUCKS DXB MALL. Avl Cr. limit is AED 1.00',
                      '2026-07-03 04:00:05+00')->>'status', 'created', 'SMS creates a pending transaction');
select is(pg_temp.sms('Your Cr.Card XXX3687 was used for AED18.00 on 03/07/2026 08:05:00 at STARBUCKS DXB MALL. Avl Cr. limit is AED 1.00',
                      '2026-07-03 04:05:05+00')->>'status', 'created', 'a second identical coffee 5 minutes later is a new purchase');
select pg_temp.set('netflix_sms', pg_temp.sms('Your Cr.Card XXX3687 was used for USD10.00 on 05/07/2026 10:00:00 at NETFLIX.COM. Avl Cr. limit is AED 1.00',
                      '2026-07-05 06:00:05+00', 'aaaaaaaa-0000-0000-0000-000000000001')->>'txn_code');
select is((select amount_aed from public.transactions where txn_code = pg_temp.v('netflix_sms')), 36.73::numeric(14,2),
          'USD SMS gets an AED estimate from the peg');
select ok((select amount_aed_is_estimate and status = 'pending' from public.transactions where txn_code = pg_temp.v('netflix_sms')),
          'flagged as estimate and pending');
select is(pg_temp.sms('Your Cr.Card XXX3687 was used for USD10.00 on 05/07/2026 10:00:00 at NETFLIX.COM. Avl Cr. limit is AED 1.00',
                      '2026-07-05 06:00:05+00', 'aaaaaaaa-0000-0000-0000-000000000001')->>'status', 'duplicate_delivery',
          'the same client_msg_id is idempotent');
select is(pg_temp.sms('Your Cr.Card XXX3687 was used for USD10.00 on 05/07/2026 10:00:00 at NETFLIX.COM. Avl Cr. limit is AED 1.00',
                      '2026-07-05 06:01:00+00')->>'status', 'duplicate', 'the same alert delivered twice links as a duplicate');
select is(pg_temp.sms('Your OTP for purchase is 123456', now())->>'status', 'rejected_otp', 'OTPs are rejected and never stored');
select is((select count(*)::int from public.sms_messages where profile_code = pg_temp.v('p') and body like '%OTP%'), 0, 'no OTP row exists');
select is(pg_temp.sms('Your Cr.Card XXX9999 was used for AED5.00 on 06/07/2026 10:00:00 at KIOSK. Avl Cr. limit is AED 1.00',
                      '2026-07-06 06:00:00+00')->>'status', 'unknown_card', 'an unknown card is held for review');
select is(pg_temp.sms('Hello, this is not a bank format', now())->>'status', 'unparsed', 'an unknown format is kept as unparsed');
select is(pg_temp.txns(), 4::bigint, '1 posted + 3 pending (2 coffees, netflix)');

-- ── 3. the July statement posts them ───────────────────────────────────────
select pg_temp.set('july', pg_temp.payload('2026-07-31', jsonb_build_array(
  pg_temp.line(1, '2026-07-03', 'STARBUCKS DXB MALL DUBAI AE', 18),
  pg_temp.line(2, '2026-07-03', 'STARBUCKS DXB MALL DUBAI AE', 18),
  pg_temp.line(3, '2026-07-05', 'NETFLIX.COM AMSTERDAM NL', 10, 'USD', 37.10, 3.71),
  pg_temp.line(4, '2026-07-10', 'CARREFOUR CITY CENTRE', 100)
), 'statement', '{"total_debits":"173.10","total_credits":"0.00"}')::text);
select pg_temp.set('july_result', pg_temp.ingest(pg_temp.v('july')::jsonb)::text);
select is(pg_temp.txns(), 5::bigint, 'statement links 3 SMS transactions and adds 1 new one (no double counting)');
select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p') and status = 'pending'), 0,
          'nothing is left pending');
select is((select count(*)::int from public.transaction_evidence where profile_code = pg_temp.v('p') and method = 'tie' and is_active), 2,
          'identical coffees pair as interchangeable ties');
select is((select amount_aed from public.transactions where txn_code = pg_temp.v('netflix_sms')), 37.10::numeric(14,2),
          'statement AED amount replaces the SMS estimate');
select ok((select txn_at is not null and not amount_aed_is_estimate and status = 'posted' from public.transactions
           where txn_code = pg_temp.v('netflix_sms')), 'and the exact SMS time is kept');
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p') and status = 'open'
           and reason in ('ambiguous', 'low_score')), 0, 'no ambiguous matches');
select is((select r.status from public.statement_recon r join public.statements s using (stmt_code)
           where s.profile_code = pg_temp.v('p') and s.statement_date = '2026-07-31'), 'ok', 'statement totals reconcile');

-- ── 4. re-ingesting the same statement changes nothing ─────────────────────
create temp table before_codes as select txn_code from public.transactions where profile_code = pg_temp.v('p');
select pg_temp.ingest(pg_temp.v('july')::jsonb, pg_temp.v('july_result')::jsonb->>'doc_code');
select is(pg_temp.txns(), 5::bigint, 're-ingest creates no transactions');
select is((select count(*)::int from public.transactions t where profile_code = pg_temp.v('p')
           and not exists (select 1 from before_codes b where b.txn_code = t.txn_code)), 0, 'and keeps every code');

-- ── 5. manual category survives rules, re-ingest and a parser fix ──────────
select pg_temp.set('carrefour', (select txn_code from public.transactions where profile_code = pg_temp.v('p') and description like 'CARREFOUR%'));
select pg_temp.set('travel', (select category_code from public.categories where profile_code = pg_temp.v('p') and name = 'Travel'));
select pg_temp.as_owner();
set local role authenticated;
select public.set_transaction_category(pg_temp.v('carrefour'), pg_temp.v('travel'));
insert into public.category_rules (profile_code, category_code, match_type, pattern, priority)
select pg_temp.v('p'), category_code, 'contains', 'CARREFOUR', 1 from public.categories
where profile_code = pg_temp.v('p') and name = 'Shopping';
reset role;
select is((select effective_category_code from public.transactions where txn_code = pg_temp.v('carrefour')), pg_temp.v('travel'),
          'a manual category beats a higher-priority rule');
select is((select count(*)::int from public.transactions t join public.profile_state s using (profile_code)
           where t.profile_code = pg_temp.v('p') and t.rules_version <> s.rules_version), 0,
          'a rule change recategorises the whole profile synchronously');

-- the parser fix re-parses the same document
select pg_temp.ingest(pg_temp.payload('2026-07-31', jsonb_build_array(
  pg_temp.line(1, '2026-07-03', 'STARBUCKS DXB MALL DUBAI AE', 18),
  pg_temp.line(2, '2026-07-03', 'STARBUCKS DXB MALL DUBAI AE', 18),
  pg_temp.line(3, '2026-07-05', 'NETFLIX.COM AMSTERDAM NL', 10, 'USD', 37.10, 3.71),
  pg_temp.line(4, '2026-07-10', 'CARREFOUR CITY CENTRE MOE', 100)
), 'statement', '{"total_debits":"173.10","total_credits":"0.00"}'), pg_temp.v('july_result')::jsonb->>'doc_code');
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p') and reason = 'orphaned'), 0,
          'the re-parse leaves no orphaned review behind (DP-06)');
select is(pg_temp.txns(), 5::bigint, 'a parser fix that changes a description creates no new transaction');
select is((select status || ':' || description from public.transactions where txn_code = pg_temp.v('carrefour')),
          'posted:CARREFOUR CITY CENTRE MOE', 'the orphaned transaction re-attaches to the corrected line');
select is((select effective_category_code from public.transactions where txn_code = pg_temp.v('carrefour')), pg_temp.v('travel'),
          'and keeps its manual category');

-- ── 6. history export of the same period never double counts ───────────────
select pg_temp.ingest(pg_temp.payload('2026-07-12', jsonb_build_array(
  pg_temp.line(1, '2026-07-03', 'STARBUCKS DXB MALL DUBAI AE', 18),
  pg_temp.line(2, '2026-07-03', 'STARBUCKS DXB MALL DUBAI AE', 18),
  pg_temp.line(3, '2026-07-05', 'NETFLIX.COM AMSTERDAM NL', 10, 'USD', 37.10, 3.71),
  pg_temp.line(4, '2026-07-10', 'CARREFOUR CITY CENTRE MOE', 100)
), 'history_extract'));
select is(pg_temp.txns(), 5::bigint, 'history lines attach to the existing transactions');
select is((select count(*)::int from public.transaction_evidence where profile_code = pg_temp.v('p') and evidence_type = 'history_line' and is_active), 4,
          'as history evidence');

-- ── 7. reversal pairs with its purchase and both void after the statement ──
select pg_temp.set('hotel', pg_temp.sms('Your Cr.Card XXX3687 was used for AED500.00 on 20/07/2026 12:00:00 at GRAND HOTEL. Avl Cr. limit is AED 1.00',
                    '2026-07-20 08:00:00+00')->>'txn_code');
select pg_temp.set('hotel_rev', pg_temp.sms('Reversal of AED500.00 on Cr.Card XXX3687 at GRAND HOTEL on 22/07/2026',
                    '2026-07-22 08:00:00+00')->>'txn_code');
select is((select related_txn_code from public.transactions where txn_code = pg_temp.v('hotel_rev')), pg_temp.v('hotel'),
          'a reversal links to the purchase it reverses');
select pg_temp.ingest(pg_temp.payload('2026-08-31', jsonb_build_array(pg_temp.line(1, '2026-08-02', 'NOON.COM', 50))));
select ok(private.void_released_authorisations() >= 2, 'released authorisations are voided');
select is((select string_agg(status, ',' order by txn_code) from public.transactions
           where txn_code in (pg_temp.v('hotel'), pg_temp.v('hotel_rev'))), 'void,void', 'both sides are void');

-- ── 8. unknown card resolves and processes waiting SMS ─────────────────────
select pg_temp.as_owner();
set local role authenticated;
select is((public.resolve_review(
  (select review_code from public.match_reviews where profile_code = pg_temp.v('p') and reason = 'unknown_card' and status = 'open'),
  jsonb_build_object('card', jsonb_build_object('account_code', (select account_code from public.accounts where profile_code = pg_temp.v('p') limit 1)))
))->>'outcome', 'card_registered', 'registering the card resolves the review');
reset role;
select is((select count(*)::int from public.transactions t join public.transaction_evidence e using (txn_code)
           join public.sms_messages s using (sms_code) where t.profile_code = pg_temp.v('p') and s.card_last4 = '9999'), 1, 'the waiting SMS becomes a transaction');

-- ── 9. analytics see one spend definition ──────────────────────────────────
select is((select sum(spend_aed) from public.v_spend where profile_code = pg_temp.v('p')
           and txn_date between '2026-07-01' and '2026-07-31'), 178.10::numeric,
          'July spend = statement debits 173.10 + pending AED 5 on the newly registered card; void hotel pair excluded');
select pg_temp.as_owner();
set local role authenticated;
select is((public.overview(pg_temp.v('p'), '2026-07-01'))->>'spend', '178.10', 'overview RPC reports the same number');
select is((select count(*)::int from public.spend_series(pg_temp.v('p'), '2026-06-01', '2026-08-31', 'month', 'category')) > 0,
          true, 'spend_series returns rows');
select lives_ok($$ select * from public.anomalies(pg_temp.v('p'), '2026-01-01', '2026-12-31') $$, 'anomalies runs');
select lives_ok($$ select * from public.statement_cycles(pg_temp.v('p')) $$, 'statement_cycles runs');
select lives_ok($$ select public.filter_meta(pg_temp.v('p')) $$, 'filter_meta runs');
select lives_ok($$ select public.preview_rule(pg_temp.v('p'), 'contains', 'STARBUCKS',
                   (select category_code from public.categories where name = 'Travel' and profile_code = pg_temp.v('p'))) $$,
                'preview_rule runs');
reset role;
select lives_ok($$ select private.nightly(pg_temp.v('p')) $$, 'nightly housekeeping runs');

select * from finish();
rollback;

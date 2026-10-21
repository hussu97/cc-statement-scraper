-- ADCB consolidated statement of accounts (20261021115816, parse-v1 `account_statement_pdf`).
-- A debit-card alert for an account the ledger lacks waits; the statement then creates the
-- savings and current accounts, the alert becomes a transaction and the statement's purchase
-- line matches it; the closing balances become checkpoints; the deposit becomes a holding valued
-- from the statement; a card summary refreshes a known card's limit. Re-ingesting is a no-op.
begin;
create extension if not exists pgtap with schema extensions;
set local client_min_messages = warning;
select no_plan();
set local ledger.test_today = '2026-12-10';

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'consolidated.pdf',
          encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'outlook')
  returning doc_code $$;
create function pg_temp.line(p_no int, p_date date, p_posted date, p_desc text, p_merchant text, p_amount text,
                             p_direction text, p_kind text, p_card text)
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_posted,
    'description_raw', p_desc, 'merchant_normalized', p_merchant, 'amount_original', p_amount,
    'currency_original', 'AED', 'amount_aed', p_amount, 'fx_rate', '1', 'direction', p_direction,
    'kind', p_kind, 'country_code', null, 'card_last4', p_card, 'card_holder', null,
    'legacy_fingerprint', repeat('0', 64))
$$;
create function pg_temp.stmt(p_number text, p_kind text, p_product text, p_end date, p_open text, p_close text,
                             p_debits text, p_credits text, p_lines jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('kind', 'statement', 'bank_code', 'ADCB',
    'statement_reference', p_number || '-' || to_char(p_end, 'YYYYMMDD'), 'reference_source', 'fallback',
    'statement_date', p_end, 'period_start', date_trunc('month', p_end)::date, 'period_end', p_end,
    'due_date', null, 'primary_card_last4', null, 'card_holder', 'JANE Q SAMPLE', 'card_type', null,
    'account', jsonb_build_object('kind', p_kind, 'number', p_number, 'ref', right(p_number, 6),
                                  'iban', 'AE0000300' || p_number, 'product', p_product, 'currency', 'AED'),
    'totals', jsonb_build_object('opening_balance', p_open, 'closing_balance', p_close, 'total_debits', p_debits,
                                 'total_credits', p_credits, 'min_due', null, 'credit_limit', null),
    'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb, 'lines', p_lines)
$$;
create function pg_temp.deposit(p_amount text, p_maturity date, p_as_of date) returns jsonb language sql as $$
  select jsonb_build_object('number', '99990001340001', 'product', 'ADCB Online Century Deposit', 'currency', 'AED',
                            'rate_pct', '2.00', 'maturity_on', p_maturity, 'amount', p_amount, 'as_of', p_as_of)
$$;
create function pg_temp.payload(p_statements jsonb, p_deposits jsonb, p_cards jsonb) returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB',
    'document_kind', 'account_statement_pdf', 'statements', p_statements, 'deposits', p_deposits,
    'card_summaries', p_cards)
$$;
create function pg_temp.acc(p_ref text) returns text language sql as $$
  select account_code from public.accounts where profile_code = pg_temp.v('p') and account_ref = p_ref $$;
create function pg_temp.dep() returns public.holdings language sql as $$
  select * from public.holdings where profile_code = pg_temp.v('p') and external_ref = '99990001340001' $$;

-- ── setup: a ledger with an ADCB credit card (•9208, no limit known) ───────
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't69-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't69-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t69-' || left(pg_temp.v('uid'), 8), 'Consolidated'));
reset role;
insert into public.accounts (profile_code, bank_code, nickname)
values (pg_temp.v('p'), 'ADCB', 'ADCB card') returning pg_temp.set('card_acc', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4)
values (pg_temp.v('p'), pg_temp.v('card_acc'), 'ADCB', '9208');

-- ── a debit-card alert for …320001, before the ledger has that account ─────
select pg_temp.set('alert', 'Debit card XXX9211 linked to acc. XXX320001 used for AED3.50 (+2.49% foreign txn fee) on '
  || 'Sep 11 2026  4:33PM at GOOGLEYOUTUBE M,US. Avl.Bal AED 51.54.');
select is((public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
            'client_msg_id', gen_random_uuid(), 'received_at', '2026-09-11 16:34:00+04', 'sender', 'ADCBAlert',
            'body', pg_temp.v('alert')))) -> 0)->>'status',
          'no_bank_account', 'the alert waits for its account');

-- ── the September statement ─────────────────────────────────────────────────
select pg_temp.set('sep', pg_temp.payload(jsonb_build_array(
  pg_temp.stmt('99990001310001', 'savings', 'Islamic Active Saver Account', '2026-09-30', '0.00', '0.00', '0.00',
               '0.00', '[]'::jsonb),
  pg_temp.stmt('99990001320001', 'current', 'Islamic Current Account Personal', '2026-09-30', '1305.04', '51.46',
               '1253.58', '0.00', jsonb_build_array(
    pg_temp.line(1, '2026-09-11', '2026-09-14', 'FOREIGN TRANSACTION FEE 11/09 0 784 GOOGLE*YOU9211',
                 'FOREIGN TRANSACTION FEE', '0.08', 'debit', 'fee', '9211'),
    pg_temp.line(2, '2026-09-11', '2026-09-14', 'PUR 11/09 GOOGLE*YOU MOUNTAIN VIEW 9211',
                 'GOOGLE*YOU MOUNTAIN VIEW', '3.50', 'debit', 'purchase', '9211'),
    pg_temp.line(3, '2026-09-20', '2026-09-20', 'IPP TRANSFER TO J SAMPLE', 'IPP TRANSFER TO J SAMPLE', '1250.00',
                 'debit', 'transfer_out', null)))),
  jsonb_build_array(pg_temp.deposit('100000.00', '2027-04-01', '2026-09-30')),
  '[{"last4": "9208", "credit_limit": "27000.00", "current_balance": "-0.84", "min_due": "0.00",
     "last_statement_balance": "-0.84", "last_statement_date": "2026-09-24", "due_date": "2026-10-19",
     "as_of": "2026-09-30"},
    {"last4": "6617", "credit_limit": "3000.00", "current_balance": "-0.27", "min_due": "0.00",
     "last_statement_balance": "-0.27", "last_statement_date": "2026-09-24", "due_date": "2026-10-19",
     "as_of": "2026-09-30"}]'::jsonb)::text);
select pg_temp.set('doc', pg_temp.new_doc());
select pg_temp.set('res', public.ingest_parsed_document(pg_temp.v('doc'), pg_temp.v('sep')::jsonb)::text);

select results_eq(
  $$ select kind, account_ref, account_number, iban, product_name, currency, credit_limit is null
     from public.accounts where profile_code = pg_temp.v('p') and kind <> 'credit_card' order by account_ref $$,
  $$ values ('savings'::text, '310001'::text, '99990001310001'::text, 'AE000030099990001310001'::text,
             'Islamic Active Saver Account'::text, 'AED'::text, true),
            ('current', '320001', '99990001320001', 'AE000030099990001320001',
             'Islamic Current Account Personal', 'AED', true) $$,
  'the statement creates both bank accounts with their number, IBAN and product');
select is((select kind from public.documents where doc_code = pg_temp.v('doc')), 'account_statement_pdf',
          'the document is an account statement');
select is((select count(*)::int from public.statements where doc_code = pg_temp.v('doc') and status = 'active'), 2,
          'one statement per account, the empty savings one included');
select is((select (c.account_code, c.is_supplementary)::text from public.cards c
           where c.profile_code = pg_temp.v('p') and c.last4 = '9211'),
          (pg_temp.acc('320001'), false)::text,
          'the debit card its lines name is the current account''s primary card');

-- The waiting alert became the purchase; the statement line is its posting evidence.
select results_eq(
  $$ select s.parse_status, s.account_code from public.sms_messages s
     where s.profile_code = pg_temp.v('p') and s.body = pg_temp.v('alert') $$,
  $$ values ('parsed'::text, pg_temp.acc('320001')) $$,
  'the alert that waited is now on the current account');
select results_eq(
  $$ select t.kind, t.amount_aed, t.status, t.description,
            (select array_agg(e.evidence_type order by e.evidence_type) from public.transaction_evidence e
             where e.txn_code = t.txn_code and e.is_active)
     from public.transactions t
     where t.account_code = pg_temp.acc('320001') and t.status <> 'void' order by t.txn_date, t.amount_aed $$,
  $$ values ('fee'::text, 0.08::numeric, 'posted'::text, 'FOREIGN TRANSACTION FEE'::text, array['statement_line']),
            ('purchase', 3.50, 'posted', 'GOOGLE*YOU MOUNTAIN VIEW', array['sms', 'statement_line']),
            ('transfer_out', 1250.00, 'posted', 'IPP TRANSFER TO J SAMPLE', array['statement_line']) $$,
  'the purchase matches the alert; the fee and the transfer are new; nothing is doubled');

-- Balances: the closing balance as of the end of 30 September in Dubai.
select results_eq(
  $$ select a.account_ref, c.balance, c.source, c.as_of = '2026-09-30 23:59:59.999+04'::timestamptz,
            c.stmt_code is not null
     from public.balance_checkpoints c join public.accounts a on a.account_code = c.account_code
     where c.profile_code = pg_temp.v('p') and c.source = 'statement' order by a.account_ref $$,
  $$ values ('310001'::text, 0.00::numeric, 'statement'::text, true, true),
            ('320001', 51.46, 'statement', true, true) $$,
  'each closing balance is a statement checkpoint');
select results_eq(
  $$ select balance, anchor_source from public.v_bank_balances where account_code = pg_temp.acc('320001') $$,
  $$ values (51.46::numeric, 'statement'::text) $$,
  'the current account''s balance is the statement''s (newer than the alert''s)');
select results_eq(
  $$ select r.status from public.statement_recon r join public.statements s on s.stmt_code = r.stmt_code
     where s.doc_code = pg_temp.v('doc') order by s.account_code = pg_temp.acc('320001') $$,
  $$ values ('ok'::text), ('ok'::text) $$,
  'both statements reconcile: opening − debits + credits = closing on a bank account');

-- A bank account's statements are its ledger: not card cycles, never "unpaid".
select is((select count(*)::int from public.statement_cycles(pg_temp.v('p'), 100) c
           where c.account_code in (pg_temp.acc('310001'), pg_temp.acc('320001'))), 0,
          'statement_cycles lists card statements only');
select is((select count(*)::int from public.v_statement_payments sp join public.statements s using (stmt_code)
           where s.doc_code = pg_temp.v('doc')), 0, 'and a bank statement has no payment status');

-- The card summary: a known card's limit, an unknown card is a warning.
select is((select credit_limit from public.accounts where account_code = pg_temp.v('card_acc')), 27000.00::numeric,
          'the card summary sets the card''s credit limit');
select ok((pg_temp.v('res')::jsonb->'warnings') @> '["Card ending 6617 is in the statement but not in this ledger"]',
          'a card the ledger lacks is a warning, not a new card');
select is(jsonb_array_length(pg_temp.v('res')::jsonb->'warnings'), 1,
          'and the only one: an account with no activity is not a warning');
select is((select count(*)::int from public.cards where profile_code = pg_temp.v('p') and last4 = '6617'), 0,
          'and no card is created for it');

-- The deposit: a holding keyed by its number, valued from the statement.
select results_eq(
  $$ select kind, name, institution, currency, principal, rate_pct, acquired_on, maturity_on, status
     from pg_temp.dep() $$,
  $$ values ('deposit'::text, 'ADCB Online Century Deposit'::text, 'ADCB'::text, 'AED'::text, 100000.00::numeric,
             2.000::numeric, '2026-09-30'::date, '2027-04-01'::date, 'active'::text) $$,
  'the deposit becomes a holding: principal and start are the statement''s until the owner corrects them');
select results_eq(
  $$ select as_of, value, source from public.holding_valuations where holding_code = (pg_temp.dep()).holding_code $$,
  $$ values ('2026-09-30'::date, 100000.00::numeric, 'import'::text) $$,
  'with the statement''s value as an import');
select is((select count(*)::int from public.holding_flows
           where holding_code = (pg_temp.dep()).holding_code and source = 'holding_cost' and removed_at is null), 1,
          'its principal is its contribution');

-- The owner corrects the principal and start (100,000 from November 2021).
update public.holdings set principal = 100000, acquired_on = '2021-11-21' where holding_code = (pg_temp.dep()).holding_code;
select private.sync_holding_cost_flow((pg_temp.dep()).holding_code);
select results_eq(
  $$ select value, value_as_of, is_estimate from private.holding_values(pg_temp.v('p'), '2026-09-30 12:00+04')
     where holding_code = (pg_temp.dep()).holding_code $$,
  $$ values (100000.00::numeric, '2026-09-30'::date, false) $$,
  'on the statement day it is worth the statement''s value');
select results_eq(
  $$ select value, value_as_of, is_estimate from private.holding_values(pg_temp.v('p'), '2026-10-31 12:00+04')
     where holding_code = (pg_temp.dep()).holding_code $$,
  $$ values (round(100000.00 * (1 + 0.02 * 31 / 365.0), 2), '2026-10-31'::date, true) $$,
  'after it, the statement''s value plus simple profit since');
select results_eq(
  $$ select value from private.holding_values(pg_temp.v('p'), '2027-06-01 12:00+04')
     where holding_code = (pg_temp.dep()).holding_code $$,
  $$ values (round(100000.00 * (1 + 0.02 * 183 / 365.0), 2)) $$,
  'profit stops at maturity');
select results_eq(
  $$ select value from private.holding_values(pg_temp.v('p'), '2026-09-29 12:00+04')
     where holding_code = (pg_temp.dep()).holding_code $$,
  $$ values (round(100000 * (1 + 0.02 * ('2026-09-29'::date - '2021-11-21'::date) / 365.0), 2)) $$,
  'before the first statement, the principal formula from the start date');

-- ── the same document again: nothing new ────────────────────────────────────
select pg_temp.set('n_before', (select format('%s/%s/%s/%s',
  (select count(*) from public.transactions where profile_code = pg_temp.v('p')),
  (select count(*) from public.balance_checkpoints where profile_code = pg_temp.v('p')),
  (select count(*) from public.holding_valuations where profile_code = pg_temp.v('p')),
  (select count(*) from public.accounts where profile_code = pg_temp.v('p')))));
select public.ingest_parsed_document(pg_temp.v('doc'), pg_temp.v('sep')::jsonb);
select is((select format('%s/%s/%s/%s',
  (select count(*) from public.transactions where profile_code = pg_temp.v('p')),
  (select count(*) from public.balance_checkpoints where profile_code = pg_temp.v('p')),
  (select count(*) from public.holding_valuations where profile_code = pg_temp.v('p')),
  (select count(*) from public.accounts where profile_code = pg_temp.v('p')))), pg_temp.v('n_before'),
  're-ingesting the statement adds no transaction, checkpoint, value or account');
select is((select (principal, acquired_on)::text from pg_temp.dep()), '(100000.00,2021-11-21)',
          'and keeps the owner''s principal and start');

-- ── October: the deposit rolled over (new maturity) ─────────────────────────
select public.ingest_parsed_document(pg_temp.new_doc(), pg_temp.payload(jsonb_build_array(
  pg_temp.stmt('99990001310001', 'savings', 'Islamic Active Saver Account', '2026-10-31', '0.00', '0.00', '0.00',
               '0.00', '[]'::jsonb)),
  jsonb_build_array(pg_temp.deposit('109905.00', '2027-10-01', '2026-10-31')), '[]'::jsonb));
select results_eq(
  $$ select maturity_on, (select value from public.holding_valuations v where v.holding_code = h.holding_code
                          order by as_of desc limit 1) from pg_temp.dep() h $$,
  $$ values ('2027-10-01'::date, 109905.00::numeric) $$,
  'a newer statement sets the new maturity and adds its value');
-- An older statement arriving late doesn't roll the terms back.
select public.ingest_parsed_document(pg_temp.new_doc(), pg_temp.payload(jsonb_build_array(
  pg_temp.stmt('99990001310001', 'savings', 'Islamic Active Saver Account', '2026-08-31', '0.00', '0.00', '0.00',
               '0.00', '[]'::jsonb)),
  jsonb_build_array(pg_temp.deposit('109530.00', '2027-04-01', '2026-08-31')), '[]'::jsonb));
select is((pg_temp.dep()).maturity_on, '2027-10-01'::date, 'an older statement leaves the newer terms');

-- ── November: the deposit is gone from the statement ────────────────────────
select pg_temp.set('nov', public.ingest_parsed_document(pg_temp.new_doc(), pg_temp.payload(jsonb_build_array(
  pg_temp.stmt('99990001310001', 'savings', 'Islamic Active Saver Account', '2026-11-30', '0.00', '0.00', '0.00',
               '0.00', '[]'::jsonb)), '[]'::jsonb, '[]'::jsonb))::text);
select ok(pg_temp.v('nov')::jsonb->'warnings' @> to_jsonb(array[
  'Deposit ending 0001 is not in this statement: it may have matured or been closed. Close it in Wealth if so.']),
  'a deposit missing from a later statement is flagged');
select is((pg_temp.dep()).status, 'active', 'but not closed for the owner');

-- ── contract shape ──────────────────────────────────────────────────────────
select throws_ok(
  format($$ select public.ingest_parsed_document(%L, %L::jsonb) $$, pg_temp.new_doc(),
         (pg_temp.v('sep')::jsonb #- '{statements,0,account}')::text),
  '22023', null, 'every statement of an account_statement_pdf names its account');
select throws_ok(
  format($$ select public.ingest_parsed_document(%L, %L::jsonb) $$, pg_temp.new_doc(),
         jsonb_set(pg_temp.v('sep')::jsonb, '{statements,1,account,ref}', '"999999"')::text),
  '22023', null, 'an account ref must end its number');

select * from finish();
rollback;

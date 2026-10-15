-- Statements from a statement-summary SMS (20261015091207): SIB's monthly "payment is due"
-- SMS becomes a header-only statement for the cycle that closed before it arrived, merged
-- with that cycle's history export, checked against the ledger, and anchoring the balance.
-- Runs on a non-empty DB: every assertion is scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
set local client_min_messages = warning;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.sms(p_body text, p_at timestamptz) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', 'SIB', 'body', p_body))) -> 0
$$;
create function pg_temp.summary(p_last4 text, p_due text, p_outstanding text, p_min text) returns text language sql as $$
  select 'Covered Card ending with XXXX' || p_last4 || ' payment is due on ' || p_due || ', outstanding amount is AED '
         || p_outstanding || ', minimum payment due is AED ' || p_min
         || '. Ensure paying before ' || p_due || ' to avoid deducting any amount under commitment to donate clause.' $$;
create function pg_temp.txn(p_date date, p_aed numeric, p_direction text, p_status text, p_stmt text default null,
                            p_kind text default 'purchase') returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source, stmt_code)
  values (pg_temp.v('p'), pg_temp.v('acc'), p_status, p_kind, p_direction, p_date, 'T51 SPEND',
          p_aed, 'AED', p_aed, 'manual', p_stmt)
  returning txn_code $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't51-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't51-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t51-' || left(pg_temp.v('uid'), 8), 'SMS statements'));
reset role;

-- ── template ───────────────────────────────────────────────────────────────
select is(m.msg_kind, 'statement_summary', 'the real SIB summary is a statement_summary')
from private.match_sms_template('SIB', pg_temp.summary('5052', '30-10-2026', '4,396.67', '219.83')) m;
select is(m.fields, '{"last4":"5052","due_date":"2026-10-30","currency":"AED","amount":"4396.67","min_due":"219.83"}'::jsonb,
          'its fields: last4, due date, outstanding (amount) and minimum due')
from private.match_sms_template('SIB', pg_temp.summary('5052', '30-10-2026', '4,396.67', '219.83')) m;
select is((select count(*)::int from private.match_sms_template('SIB',
  'Covered Card ending with XXXX5052 payment is due on 31-02-2026, outstanding amount is AED 10.00, minimum payment due is AED 1.00')),
  0, 'an impossible due date matches nothing');
select throws_ok($$
  insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind, examples, source)
  values ('SIB', 'T51 summary without due date', '^SIB', 'outstanding amount is AED ([0-9.]+)', '{"amount":1}',
          'statement_summary', '[{"sender":"SIB","body":"outstanding amount is AED 1.00"}]', 'manual') $$,
  '22023', null, 'a statement_summary template must map amount and due_date');

-- ── a SIB card with a history export for the cycle closing on the 12th ─────
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'SIB') returning account_code)
select pg_temp.set('acc', account_code) from a;
insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), pg_temp.v('acc'), 'SIB', '5052');
with s as (
  insert into public.statements (profile_code, account_code, kind, statement_date, closing_balance, due_date, min_due)
  values (pg_temp.v('p'), pg_temp.v('acc'), 'statement', '2026-09-12', 1000, '2026-09-30', 50) returning stmt_code)
select pg_temp.set('prev', stmt_code) from s;
with s as (
  insert into public.statements (profile_code, account_code, kind, statement_date, period_start, period_end)
  values (pg_temp.v('p'), pg_temp.v('acc'), 'history_extract', '2026-10-12', '2026-09-13', '2026-10-12') returning stmt_code)
select pg_temp.set('hist', stmt_code) from s;
insert into public.statement_lines (stmt_code, profile_code, account_code, evidence_type, line_no, line_key, txn_date,
                                    description_raw, description, amount_original, currency_original, amount_aed, direction, kind)
values (pg_temp.v('hist'), pg_temp.v('p'), pg_temp.v('acc'), 'history_line', 1, 't51-1', '2026-10-01',
        'T51 SPEND', 'T51 SPEND', 100, 'AED', 100, 'debit', 'purchase');
select pg_temp.txn('2026-09-20', 200, 'credit', 'posted', pg_temp.v('hist'), 'payment');
select pg_temp.txn('2026-10-01', 100, 'debit', 'posted', pg_temp.v('hist'));
select pg_temp.txn('2026-10-11', 50, 'debit', 'pending');   -- by SMS, before the close: inside the closing
select pg_temp.txn('2026-10-12', 30, 'debit', 'pending');   -- on the close day, not posted: next cycle
select pg_temp.txn('2026-10-14', 25, 'debit', 'pending');   -- after the close

-- 1000 + 100 + 50 − 200 = 950. Arrives 00:03 Dubai on the 15th (20:03 UTC on the 14th).
select pg_temp.set('r1', pg_temp.sms(pg_temp.summary('5052', '30-10-2026', '950.00', '47.50'), '2026-10-14 20:03:51+00')::text);
select is(pg_temp.v('r1')::jsonb->>'status', 'statement', 'the summary SMS makes a statement');
select pg_temp.set('stmt', (select stmt_code from public.statements
                            where account_code = pg_temp.v('acc') and kind = 'statement' and statement_date = '2026-10-12'));
select isnt(pg_temp.v('stmt'), null, 'the statement is for the cycle closing on the 12th (the history export''s close day)');
select is((select (period_start, period_end, due_date, closing_balance, min_due, primary_card_last4, doc_code, status)::text
           from public.statements where stmt_code = pg_temp.v('stmt')),
          '(2026-09-13,2026-10-12,2026-10-30,950.00,47.50,5052,,active)', 'its header comes from the SMS');
select is((select (parse_status, msg_kind, parsed_fields->>'stmt_code')::text from public.sms_messages
           where sms_code = pg_temp.v('r1')::jsonb->>'sms_code'),
          '(parsed,statement_summary,' || pg_temp.v('stmt') || ')', 'the SMS is parsed and names its statement');
select is((select statements.sms_code from public.statements where stmt_code = pg_temp.v('stmt')),
          pg_temp.v('r1')::jsonb->>'sms_code', 'the statement names its SMS');
select is((select count(*)::int from public.transaction_evidence e where e.sms_code = pg_temp.v('r1')::jsonb->>'sms_code'),
          0, 'a summary is not a transaction');

-- ── the check: the ledger against the SMS closing balance ──────────────────
select is((select (history_stmt_code, opening_basis, expected_closing, ledger_gap, recon_status)::text
           from public.v_sms_statements where stmt_code = pg_temp.v('stmt')),
          '(' || pg_temp.v('hist') || ',statement,950.00,0.00,ok)',
          'previous closing + the cycle''s transactions (pending included) = the SMS closing');
select is((select status from public.statement_recon where stmt_code = pg_temp.v('stmt')), 'ok',
          'reconcile_statement stores the same check');
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p') and reason = 'missing_from_statement'),
          0, 'an SMS statement raises no missing_from_statement reviews');

select pg_temp.set('late', pg_temp.txn('2026-10-05', 10, 'debit', 'pending'));
select is((select (recon_status, recon_checks->>'ledger_gap', recon_checks->>'balance_equation')::text
           from public.statement_cycles(pg_temp.v('p')) where stmt_code = pg_temp.v('stmt')),
          '(warn,-10.00,false)', 'a spend the bank does not have shows as a gap, live');
update public.transactions set status = 'void', voided_at = now(), void_reason = 'test' where txn_code = pg_temp.v('late');

-- ── one row per cycle ──────────────────────────────────────────────────────
select is((select (from_sms, kind, line_count, debits, closing_balance, due_date)::text
           from public.statement_cycles(pg_temp.v('p')) where stmt_code = pg_temp.v('stmt')),
          '(t,statement,1,100.00,950.00,2026-10-30)', 'statement_cycles: the SMS statement carries the export''s lines');
select is((select count(*)::int from public.statement_cycles(pg_temp.v('p')) where stmt_code = pg_temp.v('hist')),
          0, 'statement_cycles: the merged history export is not listed again');
select is((select from_sms from public.statement_cycles(pg_temp.v('p')) where stmt_code = pg_temp.v('prev')),
          false, 'statement_cycles: a statement from a PDF is not from_sms');

select pg_temp.set('d', public.statement_detail(pg_temp.v('p'), pg_temp.v('hist'))::text);
select is(pg_temp.v('d')::jsonb#>>'{statement,stmt_code}', pg_temp.v('stmt'), 'statement_detail of the export opens the SMS statement');
select is((pg_temp.v('d')::jsonb#>>'{statement,from_sms}', pg_temp.v('d')::jsonb#>>'{statement,history_stmt_code}',
           pg_temp.v('d')::jsonb#>>'{debits,count}', pg_temp.v('d')::jsonb#>>'{statement,recon_status}')::text,
          '(true,' || pg_temp.v('hist') || ',1,ok)', 'statement_detail: from_sms, the export''s lines and the check');

-- ── the balance and the payment status anchor on it ────────────────────────
select is((select (anchor_stmt_code, outstanding_aed)::text from public.v_account_balances where account_code = pg_temp.v('acc')),
          '(' || pg_temp.v('stmt') || ',1005.00)',
          'outstanding = SMS closing + spends after the close + the close day''s pending charge (the 11th''s is inside it)');
select is((select payment_status from public.v_statement_payments where stmt_code = pg_temp.v('stmt')), 'unpaid',
          'the SMS statement has a payment status');

-- ── reminders, unknown cycles, month ends ──────────────────────────────────
select is(pg_temp.sms(pg_temp.summary('5052', '30-10-2026', '700.00', '35.00'), '2026-10-15 05:00:00+00')->>'status',
          'statement_exists', 'a later summary for the same cycle leaves the statement alone');
select is((select closing_balance from public.statements where stmt_code = pg_temp.v('stmt')), 950.00::numeric(14,2),
          'the first summary of a cycle wins');

with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'SIB') returning account_code)
insert into public.cards (profile_code, account_code, bank_code, last4) select pg_temp.v('p'), account_code, 'SIB', '1111' from a;
select is(pg_temp.sms(pg_temp.summary('1111', '30-10-2026', '10.00', '1.00'), '2026-10-15 05:30:00+00')->>'status',
          'cycle_unknown', 'no cycle_close_day and no history export: no statement');

with a as (insert into public.accounts (profile_code, bank_code, cycle_close_day) values (pg_temp.v('p'), 'SIB', 31)
           returning account_code)
insert into public.cards (profile_code, account_code, bank_code, last4) select pg_temp.v('p'), account_code, 'SIB', '2222' from a;
select is(pg_temp.sms(pg_temp.summary('2222', '20-03-2026', '10.00', '1.00'), '2026-03-03 06:00:00+00')->>'status',
          'statement', 'cycle_close_day 31');
select is((select (statement_date, period_start)::text from public.statements s join public.cards c using (account_code)
           where c.last4 = '2222' and c.profile_code = pg_temp.v('p') and s.kind = 'statement'),
          '(2026-02-28,2026-02-01)', 'day 31 closes at month end: 28 Feb, after 31 Jan');

select * from finish();
rollback;

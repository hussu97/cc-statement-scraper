-- Statement payment status (20261013180516, audit UX-1r / WEB-36): public.v_statement_payments says
-- whether card repayments after a statement covered it, and overview, statement_cycles and
-- statement_detail carry payment_status ('paid' | 'part_paid' | 'unpaid' | 'overdue' | null) and
-- amount_paid (a decimal string).
-- Runs on a non-empty DB: every assertion is scoped to this run's profile. Fixed dates are in the
-- past; the due-today / overdue edges are relative to today (Asia/Dubai).
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.acc(p_name text, p_bank text) returns text language sql as $$
  with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), p_bank) returning account_code)
  select pg_temp.set(p_name, account_code) from a $$;
create function pg_temp.stmt(p_name text, p_acc text, p_date date, p_due date, p_closing numeric, p_min numeric,
                             p_kind text default 'statement') returns text language sql as $$
  with s as (insert into public.statements (profile_code, account_code, kind, statement_date, due_date, closing_balance, min_due)
             values (pg_temp.v('p'), pg_temp.v(p_acc), p_kind, p_date, p_due, p_closing, p_min) returning stmt_code)
  select pg_temp.set(p_name, stmt_code) from s $$;
create function pg_temp.txn(p_acc text, p_date date, p_aed numeric, p_kind text default 'payment',
                            p_direction text default 'credit', p_status text default 'posted') returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source)
  values (pg_temp.v('p'), pg_temp.v(p_acc), p_status, p_kind, p_direction, p_date, 'T48 PAYMENT THANK YOU',
          p_aed, 'AED', p_aed, 'manual')
  returning txn_code $$;
create function pg_temp.status(p_stmt text) returns text language sql as $$
  select payment_status from public.v_statement_payments where stmt_code = pg_temp.v(p_stmt) $$;
create function pg_temp.paid(p_stmt text) returns text language sql as $$
  select amount_paid::text from public.v_statement_payments where stmt_code = pg_temp.v(p_stmt) $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't48-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now()),
       (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't48o-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't48-%' order by created_at desc limit 1));
select pg_temp.set('other', (select id::text from auth.users where email like 't48o-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t48-' || left(pg_temp.v('uid'), 8), 'Payments'));
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.set('today', public.dubai_date(now())::text);

-- ── A: month-end cycles (31 Jan → 28 Feb → 31 Mar), fixed past dates ───────
select pg_temp.acc('a', 'FAB');
select pg_temp.stmt('a1', 'a', '2025-01-31', '2025-02-25', 1000, 50);
select pg_temp.stmt('a2', 'a', '2025-02-28', '2025-03-25', 2000, 100);
select pg_temp.stmt('a3', 'a', '2025-03-31', '2025-04-25', 500, 25);
select pg_temp.txn('a', '2025-01-31', 999);   -- on a1's statement date: already inside a1's balance
select pg_temp.txn('a', '2025-02-28', 1000);  -- on a2's statement date: still a1's window, late
select pg_temp.txn('a', '2025-03-01', 40);    -- a2, before its due date
select pg_temp.txn('a', '2025-03-25', 60);    -- a2, on its due date: 100 by the due date = the minimum
select pg_temp.txn('a', '2025-04-26', 25);    -- a3, the day after its due date

select is(pg_temp.paid('a1'), '1000.00', 'a payment on the statement date is not counted; one on the next statement date is');
select is(pg_temp.status('a1'), 'paid', 'paid in full after the due date (before the next statement) is paid');
select is(pg_temp.paid('a2'), '100.00', 'the window starts the day after the statement date (28 Feb → 1 Mar)');
select is(pg_temp.status('a2'), 'part_paid', 'the minimum paid by the due date, inclusive, is part paid once the due date has passed');
select is(pg_temp.paid('a3'), '25.00', 'the latest cycle has an open window');
select is(pg_temp.status('a3'), 'overdue', 'the minimum paid only after the due date is overdue');

-- ── B: due today is not overdue; due yesterday is ─────────────────────────
select pg_temp.acc('b', 'ADCB');
select pg_temp.stmt('b1', 'b', pg_temp.v('today')::date - 20, pg_temp.v('today')::date, 800, 40);
select is(pg_temp.status('b1'), 'unpaid', 'nothing paid, due today (Asia/Dubai): unpaid');
select is(pg_temp.paid('b1'), '0.00', 'amount_paid is 0.00, not null');

select pg_temp.acc('c', 'ENBD');
select pg_temp.stmt('c1', 'c', pg_temp.v('today')::date - 21, pg_temp.v('today')::date - 1, 800, 40);
select is(pg_temp.status('c1'), 'overdue', 'nothing paid, due yesterday: overdue');
select pg_temp.txn('c', pg_temp.v('today')::date, 800, 'payment', 'credit', 'pending');
select is(pg_temp.status('c1'), 'paid', 'a pending payment of the whole balance, even late, is paid');

-- ── D: part paid before the due date; non-payments are ignored ─────────────
select pg_temp.acc('d', 'SIB');
select pg_temp.stmt('d1', 'd', pg_temp.v('today')::date - 10, pg_temp.v('today')::date + 10, 800, 40);
select pg_temp.txn('d', pg_temp.v('today')::date - 5, 300);
select pg_temp.txn('d', pg_temp.v('today')::date - 5, 500, 'payment', 'credit', 'void');
select pg_temp.txn('d', pg_temp.v('today')::date - 5, 500, 'refund', 'credit');
select pg_temp.txn('d', pg_temp.v('today')::date - 5, 500, 'purchase', 'debit');
select is(pg_temp.paid('d1'), '300.00', 'only live card repayments count: void payments, refunds and purchases do not');
select is(pg_temp.status('d1'), 'part_paid', 'something paid before the due date: part paid');

-- ── E: credit balance, no balance, no minimum, history extract ─────────────
select pg_temp.acc('e', 'MASHREQ');
select pg_temp.stmt('e1', 'e', '2025-05-31', '2025-06-25', -50, 0);
select pg_temp.stmt('e2', 'e', '2025-06-30', '2025-07-25', null, null);
select pg_temp.stmt('e3', 'e', '2025-07-31', '2025-08-25', 300, null);
select pg_temp.stmt('e4', 'e', '2025-09-30', '2025-10-25', 300, 15, 'history_extract');
select pg_temp.txn('e', '2025-08-25', 10);
select is(pg_temp.status('e1'), 'paid', 'a statement in credit owes nothing: paid');
select is(pg_temp.status('e2'), null, 'no closing balance: unknown (null)');
select is(pg_temp.status('e3'), 'part_paid', 'no minimum on the statement: any payment by the due date avoids overdue');
select is(pg_temp.status('e4'), null, 'a history extract has no payment status');

select is((select count(*)::int from public.v_statement_payments
           where profile_code = pg_temp.v('p') and payment_status not in ('paid', 'part_paid', 'unpaid', 'overdue')),
          0, 'payment_status is one of the four values or null');

-- ── what the clients read ───────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;

select results_eq(
  format($$ select payment_status, amount_paid from public.statement_cycles(%L, 100) where account_code = %L
            order by statement_date $$, pg_temp.v('p'), pg_temp.v('a')),
  $$ values ('paid'::text, '1000.00'::text), ('part_paid', '100.00'), ('overdue', '25.00') $$,
  'statement_cycles carries payment_status and amount_paid as text');
select is((select array[payment_status, amount_paid] from public.statement_cycles(pg_temp.v('p'), 100)
           where stmt_code = pg_temp.v('e4')), array[null, null]::text[], 'statement_cycles: null for a history extract');

select pg_temp.set('ov', public.overview(pg_temp.v('p'))::text);
select is((select x->'latest_statement'->>'payment_status' from jsonb_array_elements(pg_temp.v('ov')::jsonb->'accounts') x
           where x->>'account_code' = pg_temp.v('a')), 'overdue', 'overview: the latest statement''s status');
select is((select x->'latest_statement'->'amount_paid' from jsonb_array_elements(pg_temp.v('ov')::jsonb->'accounts') x
           where x->>'account_code' = pg_temp.v('a')), '"25.00"'::jsonb, 'overview: amount_paid is a decimal string');
select is((select x->'latest_statement'->>'payment_status' from jsonb_array_elements(pg_temp.v('ov')::jsonb->'accounts') x
           where x->>'account_code' = pg_temp.v('b')), 'unpaid', 'overview: due today and unpaid');
select is((select x->'latest_statement'->>'payment_status' from jsonb_array_elements(pg_temp.v('ov')::jsonb->'accounts') x
           where x->>'account_code' = pg_temp.v('d')), 'part_paid', 'overview: part paid');

select is(public.statement_detail(pg_temp.v('p'), pg_temp.v('a1'))->'statement'->>'payment_status', 'paid',
          'statement_detail carries payment_status');
select is(public.statement_detail(pg_temp.v('p'), pg_temp.v('a2'))->'statement'->'amount_paid', '"100.00"'::jsonb,
          'statement_detail carries amount_paid as a decimal string');

-- ── tenant isolation ───────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('other'), 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.v_statement_payments where profile_code = pg_temp.v('p')), 0,
          'another user sees none of this ledger''s payment statuses');
select is((select count(*)::int from public.statement_cycles(pg_temp.v('p'), 100)), 0,
          'nor its statement cycles');
reset role;
select set_config('request.jwt.claims', '', true);

select * from finish();
rollback;

-- Wio Credit statement and SMS together (20261030131029): a transfer out of the credit line waits
-- for its statement line, which posts it once (still paired with the card it paid); an SMS the
-- statement does not print is flagged; a statement autopay line gets its current-account leg,
-- and the autopay SMS arriving after it adds no second leg.
-- Runs on a non-empty DB: every assertion is scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.at(p_day int, p_time time) returns timestamptz language sql as $$
  select ((pg_temp.v('b')::date + p_day) + p_time) at time zone 'Asia/Dubai' $$;
create function pg_temp.sms(p_body text, p_at timestamptz) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', 'WioPersonal', 'body', p_body))) -> 0
$$;
create function pg_temp.line(p_no int, p_day int, p_desc text, p_amount numeric, p_kind text, p_direction text)
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', pg_temp.v('b')::date + p_day, 'txn_time', null,
    'posting_date', pg_temp.v('b')::date + p_day, 'description_raw', p_desc, 'merchant_normalized', upper(p_desc),
    'amount_original', p_amount::text, 'currency_original', 'AED', 'amount_aed', p_amount::text, 'fx_rate', null,
    'direction', p_direction, 'kind', p_kind, 'country_code', 'AE', 'card_last4', '9207', 'card_holder', null,
    'legacy_fingerprint', null)
$$;
create function pg_temp.live(p_account text, p_amount numeric) returns setof public.transactions language sql as $$
  select * from public.transactions
  where profile_code = pg_temp.v('p') and account_code = pg_temp.v(p_account) and amount_aed = p_amount
    and status <> 'void' $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't80-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't80-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t80-' || left(pg_temp.v('uid'), 8), 'Wio statement'));
select pg_temp.set('debit', public.create_bank_account(pg_temp.v('p'), 'WIO', 'current', '9204', 'Wio'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code, nickname, account_ref) values (pg_temp.v('p'), 'WIO', 'Wio Credit', '9214')
returning pg_temp.set('credit', account_code);
insert into public.cards (profile_code, account_code, bank_code, last4) values (pg_temp.v('p'), pg_temp.v('credit'), 'WIO', '9207');
insert into public.accounts (profile_code, bank_code, nickname) values (pg_temp.v('p'), 'FAB', 'FAB card')
returning pg_temp.set('fab', account_code);
select pg_temp.set('b', (public.dubai_date(now()) - 20)::text);

-- ── before the statement: two transfers out of Wio Credit by SMS ────────────
select pg_temp.sms('Your local transfer of AED 517 to John Quincy Public from your account number 39XXXX9214 was processed.',
                   pg_temp.at(3, '12:30'));
select results_eq(
  $$ select kind, direction, status, amount_source from pg_temp.live('credit', 517) $$,
  $$ values ('transfer_out'::text, 'debit'::text, 'pending'::text, 'sms'::text) $$,
  'a transfer out of the credit line waits for its statement (no longer posted on arrival)');
insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                 amount_original, currency_original, amount_aed, amount_source)
values (pg_temp.v('p'), pg_temp.v('fab'), 'posted', 'payment', 'credit', pg_temp.v('b')::date + 3,
        'PAYMENT RECEIVED', 517, 'AED', 517, 'manual')
returning pg_temp.set('fab_payment', txn_code);
select pg_temp.set('xfer', (select txn_code from pg_temp.live('credit', 517)));
select results_eq(
  $$ select from_txn_code, to_txn_code from public.card_transfers where profile_code = pg_temp.v('p') $$,
  $$ values (pg_temp.v('xfer'), pg_temp.v('fab_payment')) $$,
  'pending, it still pairs with the card payment it made');

select pg_temp.sms('Your local transfer of AED 288 to Richard Sample from your account number 39XXXX9214 was processed.',
                   pg_temp.at(5, '09:15'));
select pg_temp.set('stray', (select txn_code from pg_temp.live('credit', 288)));

-- ── the statement: the 517 transfer, and an autopay with no SMS yet ─────────
with d as (
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'wio-credit.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'),
          100, 'upload')
  returning doc_code
)
select pg_temp.set('doc', doc_code) from d;
select public.ingest_parsed_document(pg_temp.v('doc'), jsonb_build_object(
  'contract_version', 1, 'parser_version', 'test', 'bank_code', 'WIO', 'document_kind', 'statement_pdf',
  'statements', jsonb_build_array(jsonb_build_object(
    'kind', 'statement', 'bank_code', 'WIO', 'statement_reference', 'T80-' || pg_temp.v('p'),
    'reference_source', 'explicit', 'statement_date', pg_temp.v('b')::date + 10,
    'period_start', pg_temp.v('b')::date - 5, 'period_end', pg_temp.v('b')::date + 10,
    'due_date', pg_temp.v('b')::date + 10, 'primary_card_last4', '9207', 'card_holder', 'TEST', 'card_type', 'Wio Credit',
    'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
    'lines', jsonb_build_array(
      pg_temp.line(1, 3, 'Alice FAB payment', 517, 'payment', 'debit'),
      pg_temp.line(2, 10, 'Credit Repayment Autopay', 1234.56, 'payment', 'credit'))))));

select results_eq(
  $$ select txn_code, kind, status, amount_source from pg_temp.live('credit', 517) $$,
  $$ values (pg_temp.v('xfer'), 'payment'::text, 'posted'::text, 'statement_line'::text) $$,
  'the statement line posts the SMS transfer: one 517 debit on Wio Credit, not two');
select results_eq(
  $$ select from_txn_code, to_txn_code from public.card_transfers
     where profile_code = pg_temp.v('p') and to_txn_code = pg_temp.v('fab_payment') $$,
  $$ values (pg_temp.v('xfer'), pg_temp.v('fab_payment')) $$,
  'and keeps its pair with the FAB payment');

select is((select status from public.transactions where txn_code = pg_temp.v('stray')), 'pending',
          'an SMS transfer the statement does not print stays pending');
select ok(exists (select 1 from public.match_reviews
                  where profile_code = pg_temp.v('p') and subject_type = 'transaction'
                    and subject_code = pg_temp.v('stray') and reason = 'missing_from_statement' and status = 'open'),
          'and is flagged as missing from the statement');

-- ── the autopay line's other leg ────────────────────────────────────────────
select pg_temp.set('autopay', (select txn_code from pg_temp.live('credit', 1234.56)));
select results_eq(
  $$ select kind, direction, status, leg_of_txn_code from pg_temp.live('debit', 1234.56) $$,
  $$ values ('transfer_out'::text, 'debit'::text, 'posted'::text, pg_temp.v('autopay')) $$,
  'the statement autopay line takes its money out of the current account');
select results_eq(
  $$ select f.account_code from public.card_transfers ct join public.transactions f on f.txn_code = ct.from_txn_code
     where ct.to_txn_code = pg_temp.v('autopay') $$,
  $$ values (pg_temp.v('debit')) $$,
  'paired with the autopay: a repayment from the current account, counted once');

select pg_temp.sms('You''ve made an autopay of AED 1,234.56 towards your Wio Credit balance.', pg_temp.at(10, '21:25'));
select is((select count(*)::int from pg_temp.live('credit', 1234.56)), 1, 'the autopay SMS after the statement joins its payment');
select is((select count(*)::int from pg_temp.live('debit', 1234.56)), 1, 'and adds no second leg');

-- A manual repayment is not an autopay: no leg is guessed for it.
insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                 amount_original, currency_original, amount_aed, amount_source)
values (pg_temp.v('p'), pg_temp.v('credit'), 'posted', 'payment', 'credit', pg_temp.v('b')::date + 8,
        'Credit Repayment', 640, 'AED', 640, 'manual');
select is((select count(*)::int from pg_temp.live('debit', 640)), 0, 'a manual repayment gets no current-account leg');

select * from finish();
rollback;

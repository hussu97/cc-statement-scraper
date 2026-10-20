-- Cash withdrawals ingested as purchases become cash advances (20261020120340_cash_advance_backfill.sql):
-- the purchase a CASH ADVANCE FEE follows (same card, same date, only fee/VAT lines between).
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
create function pg_temp.line(p_no int, p_desc text, p_kind text, p_amount text, p_date text default '2026-09-24',
                             p_last4 text default '2777', p_currency text default 'AED', p_aed text default null)
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', '2026-09-25',
    'description_raw', p_desc, 'merchant_normalized', p_desc, 'amount_original', p_amount,
    'currency_original', p_currency, 'amount_aed', coalesce(p_aed, p_amount), 'fx_rate', null,
    'direction', 'debit', 'kind', p_kind, 'country_code', null, 'card_last4', p_last4,
    'card_holder', null, 'legacy_fingerprint', null) $$;
-- What parser 2026.10.15.1 sent for FAB's 2026-10 statement: the Nairobi ATM as a purchase.
create function pg_temp.statement() returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'FAB',
    'document_kind', 'statement_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'FAB', 'statement_reference', null, 'reference_source', null,
      'statement_date', '2026-10-05', 'period_start', '2026-09-06', 'period_end', '2026-10-05',
      'due_date', null, 'primary_card_last4', '2777', 'card_holder', 'TEST', 'card_type', null,
      'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
      'lines', jsonb_build_array(
        pg_temp.line(1, 'JAVA HOUSE NAIROBI KEN', 'purchase', '20.00'),
        pg_temp.line(2, 'DTBKEN NAIROBI KEN', 'purchase', '5000.00', p_currency => 'KES', p_aed => '147.45'),
        pg_temp.line(3, 'VAT ON SERVICE CHARGES', 'fee', '0.27'),
        pg_temp.line(4, 'CASH ADVANCE FEE', 'fee', '150.00'),
        pg_temp.line(5, 'VAT ON SERVICE CHARGES', 'fee', '7.50'),
        -- not a pair: another date, then another card
        pg_temp.line(6, 'EQUITY BANK NAIROBI KEN', 'purchase', '300.00', '2026-09-26'),
        pg_temp.line(7, 'CASH ADVANCE FEE', 'fee', '99.00', '2026-09-27'),
        pg_temp.line(8, 'KCB NAIROBI KEN', 'purchase', '300.00', '2026-09-28', '1111'),
        pg_temp.line(9, 'CASH ADVANCE FEE', 'fee', '99.00', '2026-09-28'))))) $$;
create function pg_temp.kind_of(p_desc text) returns text language sql as $$
  select kind from public.transactions where profile_code = pg_temp.v('p') and description = p_desc $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't55-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't55-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t55-' || left(pg_temp.v('uid'), 8), 'Cash advance'));
reset role;
select set_config('request.jwt.claims', '', true);

insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'fab.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload');
select pg_temp.set('doc', (select doc_code from public.documents where profile_code = pg_temp.v('p')));
select public.ingest_parsed_document(pg_temp.v('doc'), pg_temp.statement());
select is(pg_temp.kind_of('DTBKEN NAIROBI KEN'), 'purchase', 'before the backfill the Nairobi ATM is a purchase');

-- ═══ the backfill ═══
select is(private.mark_paired_cash_advances(), 1, 'one transaction is re-derived');
select is(pg_temp.kind_of('DTBKEN NAIROBI KEN'), 'cash_advance', 'the withdrawal the fee follows is a cash advance');
select is((select kind from public.statement_lines where profile_code = pg_temp.v('p') and description = 'DTBKEN NAIROBI KEN'),
          'cash_advance', 'its statement line says so too');
select is(pg_temp.kind_of('JAVA HOUSE NAIROBI KEN'), 'purchase', 'the purchase before it is untouched');
select is(pg_temp.kind_of('EQUITY BANK NAIROBI KEN'), 'purchase', 'a fee on another date pairs with nothing');
select is(pg_temp.kind_of('KCB NAIROBI KEN'), 'purchase', 'a fee on another card pairs with nothing');
select is((select array_agg(distinct kind) from public.transactions
           where profile_code = pg_temp.v('p') and (description like '%CHARGES' or description = 'CASH ADVANCE FEE')),
          array['fee'], 'fee and VAT lines stay fees');
select is((select spend_aed from public.v_spend where profile_code = pg_temp.v('p') and description = 'DTBKEN NAIROBI KEN'),
          147.45::numeric, 'a cash advance still counts as spend');
select is(private.mark_paired_cash_advances(), 0, 'running it again changes nothing');

-- ═══ re-ingesting the old parse keeps the corrected kind (a revived line is not rewritten) ═══
select public.ingest_parsed_document(pg_temp.v('doc'), pg_temp.statement());
select is(pg_temp.kind_of('DTBKEN NAIROBI KEN'), 'cash_advance', 're-ingesting the same document keeps the cash advance');

select * from finish();
rollback;

-- A line's identity ignores letter case (20261015095636): SIB's two history exports print one
-- row as 'INTEGRATED GAS SERVICEDubai' and 'INTEGRATED GAS SERVICEDUBAI'.
-- Runs on a non-empty DB: every assertion is scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
set local client_min_messages = warning;
select no_plan();
set local ledger.test_today = '2026-10-20';

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.export(p_desc text, p_last4 text default '9213', p_amount text default '105.75') returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'SIB',
    'document_kind', 'history_pdf',
    'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'history_extract', 'bank_code', 'SIB', 'statement_reference', null, 'reference_source', null,
      'statement_date', '2026-10-12', 'period_start', '2026-09-13', 'period_end', '2026-10-12',
      'due_date', null, 'primary_card_last4', p_last4, 'card_holder', 'TEST', 'card_type', 'Covered Card',
      'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
      'lines', jsonb_build_array(jsonb_build_object('line_no', 1, 'txn_date', '2026-10-08', 'txn_time', null,
        'posting_date', '2026-10-08', 'description_raw', p_desc, 'merchant_normalized', upper(p_desc),
        'amount_original', p_amount, 'currency_original', 'AED', 'amount_aed', p_amount, 'fx_rate', null,
        'direction', 'debit', 'kind', 'purchase', 'country_code', 'AE', 'card_last4', p_last4,
        'card_holder', null, 'legacy_fingerprint', null)))))
$$;
create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'history.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'),
          100, 'upload')
  returning doc_code $$;
create function pg_temp.lines() returns int language sql as $$
  select count(*)::int from public.statement_lines where profile_code = pg_temp.v('p') and is_current $$;
create function pg_temp.live() returns text[] language sql as $$
  select array_agg(txn_code order by txn_code) from public.transactions
  where profile_code = pg_temp.v('p') and status in ('pending', 'posted') $$;
-- The key as ingest hashed it before this migration (case-sensitive).
create function pg_temp.old_key(l public.statement_lines) returns text language sql as $$
  select encode(sha256(convert_to(concat_ws('|', l.account_code, l.txn_date::text, l.posting_date::text,
    l.amount_original::numeric(14,2), l.currency_original, l.amount_aed::numeric(14,2), l.direction,
    regexp_replace(btrim(l.description_raw), '\s+', ' ', 'g')), 'UTF8')), 'hex') $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't53-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't53-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t53-' || left(pg_temp.v('uid'), 8), 'Line key case'));
reset role;
select set_config('request.jwt.claims', '', true);

-- ═══ 1. New ingests: a case variant of a known row is the same line ═══
select pg_temp.set('docA', pg_temp.new_doc());
select public.ingest_parsed_document(pg_temp.v('docA'), pg_temp.export('INTEGRATED GAS SERVICEDubai'));
select pg_temp.set('txnA', (select txn_code from public.transactions where profile_code = pg_temp.v('p')));
select pg_temp.set('docB', pg_temp.new_doc());
select public.ingest_parsed_document(pg_temp.v('docB'), pg_temp.export('INTEGRATED GAS  SERVICEDUBAI'));
select is(pg_temp.lines(), 1, 'a case and spacing variant joins the existing line');
select is(pg_temp.live(), array[pg_temp.v('txnA')], 'and makes no second transaction');
select is((select source_doc_codes from public.statement_lines where profile_code = pg_temp.v('p') and is_current),
          array[pg_temp.v('docA'), pg_temp.v('docB')], 'the line is evidenced by both exports');
select is((select line_key from public.statement_lines where profile_code = pg_temp.v('p') and is_current),
          (select private.statement_line_key(account_code, '2026-10-08', '2026-10-08', 105.75, 'AED', 105.75, 'debit',
                                             'integrated gas servicedubai')
           from public.statements where profile_code = pg_temp.v('p') limit 1),
          'ingest hashes through private.statement_line_key');

-- ═══ 2. Backfill: lines stored under the old case-sensitive keys (the production state) ═══
-- Another row (a second card of the account), keys rewritten to the pre-migration hash, then a duplicate as production has it.
select pg_temp.set('docC', pg_temp.new_doc());
select public.ingest_parsed_document(pg_temp.v('docC'), pg_temp.export('INTEGRATED GAS SERVICEDubai', '7003', '64.20'));
update public.statement_lines l set line_key = pg_temp.old_key(l)
where l.profile_code = pg_temp.v('p') and l.card_last4 = '7003';
select pg_temp.set('txnC', (select t.txn_code from public.transactions t join public.cards c on c.card_code = t.card_code
                            where t.profile_code = pg_temp.v('p') and c.last4 = '7003'));
update public.transactions set notes = 'gas bill' where txn_code = pg_temp.v('txnC');
-- The second export's line: the old ingest would have keyed it apart and made a new transaction.
with l as (
  insert into public.statement_lines (stmt_code, profile_code, account_code, card_code, evidence_type, line_no, line_key,
    occurrence, txn_date, posting_date, description_raw, description, amount_original, currency_original, amount_aed,
    direction, kind, card_last4, raw, source_doc_codes)
  select o.stmt_code, o.profile_code, o.account_code, o.card_code, o.evidence_type, 2,
         pg_temp.old_key(o) || 'x', 1, o.txn_date, o.posting_date, 'INTEGRATED GAS SERVICEDUBAI', o.description,
         o.amount_original, o.currency_original, o.amount_aed, o.direction, o.kind, o.card_last4, o.raw,
         array[pg_temp.new_doc()]
  from public.statement_lines o where o.profile_code = pg_temp.v('p') and o.card_last4 = '7003'
  returning line_code)
select pg_temp.set('lineD', line_code) from l;
update public.statement_lines l set line_key = pg_temp.old_key(l)
where l.profile_code = pg_temp.v('p') and l.description_raw = 'INTEGRATED GAS SERVICEDUBAI';
select pg_temp.set('txnD', private.new_transaction_from_line(pg_temp.v('lineD')));
update public.transactions set manual_category_code = (select category_code from public.categories
                                                       where profile_code = pg_temp.v('p') limit 1)
where txn_code = pg_temp.v('txnD');
select is(array_length(pg_temp.live(), 1), 3, 'before: the duplicate is a third live transaction');

select pg_temp.set('res', private.rekey_statement_lines(pg_temp.v('p'))::text);
select is(pg_temp.v('res')::jsonb - 'rekeyed', '{"merged": 1, "voided": 1}'::jsonb, 'one line merged, one transaction voided');
select is(pg_temp.lines(), 2, 'after: one current line per row');
select is(pg_temp.live(), (select array_agg(x order by x) from unnest(array[pg_temp.v('txnA'), pg_temp.v('txnC')]) x),
          'the older transaction survives; the duplicate is gone');
select is((select (status, void_reason) from public.transactions where txn_code = pg_temp.v('txnD'))::text,
          '(void,duplicate_line)', 'the duplicate is voided as duplicate_line');
select is((select notes from public.transactions where txn_code = pg_temp.v('txnC')), 'gas bill', 'survivor keeps its notes');
select isnt((select manual_category_code from public.transactions where txn_code = pg_temp.v('txnC')), null,
            'survivor takes the manual category it lacked');
select is((select cardinality(source_doc_codes) from public.statement_lines
           where profile_code = pg_temp.v('p') and is_current and card_last4 = '7003'),
          2, 'the surviving line is evidenced by both documents');
select is((select count(*)::int from public.statement_lines l
           where l.profile_code = pg_temp.v('p') and l.is_current
             and l.line_key <> private.statement_line_key(l.account_code, l.txn_date, l.posting_date, l.amount_original,
                                   l.currency_original, l.amount_aed, l.direction, l.description_raw)),
          0, 'every current line carries the new key');
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p') and status = 'open'),
          0, 'no review is left open');
select is(private.rekey_statement_lines(pg_temp.v('p')), '{"rekeyed": 0, "merged": 0, "voided": 0}'::jsonb,
          'a second run changes nothing');

-- A later re-parse of the first export finds its line.
select public.ingest_parsed_document(pg_temp.v('docC'), pg_temp.export('INTEGRATED GAS SERVICEDubai', '7003', '64.20'));
select is(pg_temp.live(), (select array_agg(x order by x) from unnest(array[pg_temp.v('txnA'), pg_temp.v('txnC')]) x),
          're-parsing after the backfill keeps the same transactions');

select * from finish();
rollback;

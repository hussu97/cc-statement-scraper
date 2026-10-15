-- History rows that move to another cycle keep their transaction (20261015094610).
-- SIB's exports were bucketed into cycles closing on the 12th; they now close on the 14th.
-- The same rows then arrive on statements with other dates: they must move, not duplicate.
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

create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric, p_last4 text)
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', 'AED', 'amount_aed', p_amount::text, 'fx_rate', null, 'direction', 'debit',
    'kind', 'purchase', 'country_code', 'AE', 'card_last4', p_last4, 'card_holder', null,
    'legacy_fingerprint', null)
$$;
-- One history export: p_rows is [[date, desc, amount], …]; cycles close on p_close_day.
create function pg_temp.export(p_rows jsonb, p_close_day int, p_last4 text) returns jsonb language sql as $$
  with r as (
    select (x->>0)::date as d, x->>1 as descr, (x->>2)::numeric as amt, o as no
    from jsonb_array_elements(p_rows) with ordinality as t(x, o)
  ), b as (
    select r.*, case when extract(day from d) <= p_close_day
                     then make_date(extract(year from d)::int, extract(month from d)::int, p_close_day)
                     else (make_date(extract(year from d)::int, extract(month from d)::int, p_close_day)
                           + interval '1 month')::date end as close
    from r
  )
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'SIB',
    'document_kind', 'history_pdf',
    'statements', (select jsonb_agg(jsonb_build_object(
      'kind', 'history_extract', 'bank_code', 'SIB', 'statement_reference', null, 'reference_source', null,
      'statement_date', close, 'period_start', (close - interval '1 month')::date + 1, 'period_end', close,
      'due_date', null, 'primary_card_last4', p_last4, 'card_holder', 'TEST', 'card_type', 'Covered Card',
      'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
      'lines', (select jsonb_agg(pg_temp.line(b2.no::int, b2.d, b2.descr, b2.amt, p_last4) order by b2.no)
                from b b2 where b2.close = b1.close)) order by close)
      from (select distinct close from b) b1))
$$;
create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'history.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'),
          100, 'upload')
  returning doc_code $$;
create function pg_temp.acc(p_last4 text) returns text language sql as $$
  select c.account_code from public.cards c where c.profile_code = pg_temp.v('p') and c.last4 = p_last4 $$;
create function pg_temp.live_txns(p_last4 text) returns int language sql as $$
  select count(*)::int from public.transactions
  where profile_code = pg_temp.v('p') and account_code = pg_temp.acc(p_last4) and status in ('pending', 'posted') $$;
create function pg_temp.txn_codes(p_last4 text) returns text[] language sql as $$
  select array_agg(txn_code order by txn_code) from public.transactions
  where profile_code = pg_temp.v('p') and account_code = pg_temp.acc(p_last4) and status in ('pending', 'posted') $$;
create function pg_temp.active_dates(p_last4 text) returns date[] language sql as $$
  select array_agg(statement_date order by statement_date) from public.statements
  where profile_code = pg_temp.v('p') and account_code = pg_temp.acc(p_last4)
    and kind = 'history_extract' and status = 'active' $$;
create function pg_temp.stmt(p_last4 text, p_date date) returns text language sql as $$
  select stmt_code from public.statements
  where profile_code = pg_temp.v('p') and account_code = pg_temp.acc(p_last4)
    and kind = 'history_extract' and statement_date = p_date and status = 'active' $$;
create function pg_temp.open_reviews() returns int language sql as $$
  select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p') and status = 'open' $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't52-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't52-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t52-' || left(pg_temp.v('uid'), 8), 'History rebucket'));
reset role;
select set_config('request.jwt.claims', '', true);

-- The same six rows: closing on the 12th they fall in Sep/Oct/Nov 12; on the 14th in Sep/Oct 14.
select pg_temp.set('rows', '[["2026-08-20","T52 ALPHA",10],["2026-09-10","T52 BRAVO",20],["2026-09-13","T52 CHARLIE",30],
                             ["2026-09-20","T52 DELTA",40],["2026-10-10","T52 ECHO",50],["2026-10-13","T52 FOXTROT",60]]');

-- ═══ 1. A new export bucketed on the 14th, while the 12th-dated statements are active ═══
select pg_temp.set('docA', pg_temp.new_doc());
select public.ingest_parsed_document(pg_temp.v('docA'), pg_temp.export(pg_temp.v('rows')::jsonb, 12, '5052'));
select is(pg_temp.active_dates('5052'), array['2026-09-12', '2026-10-12', '2026-11-12']::date[],
          'old export: three cycles closing on the 12th');
select is(pg_temp.live_txns('5052'), 6, 'old export: six transactions');
select pg_temp.set('codes', pg_temp.txn_codes('5052')::text);
update public.transactions set notes = 'kept', exclude_from_spend = true
where profile_code = pg_temp.v('p') and account_code = pg_temp.acc('5052') and description = 'T52 CHARLIE';
update public.accounts set cycle_close_day = 14 where account_code = pg_temp.acc('5052');

select pg_temp.set('docB', pg_temp.new_doc());
select pg_temp.set('resB', public.ingest_parsed_document(pg_temp.v('docB'),
                                                         pg_temp.export(pg_temp.v('rows')::jsonb, 14, '5052'))::text);
select is(pg_temp.live_txns('5052'), 6, 'new export: still six transactions, no duplicates');
select is(pg_temp.txn_codes('5052')::text, pg_temp.v('codes'), 'every transaction keeps its code');
select is(pg_temp.active_dates('5052'), array['2026-09-14', '2026-10-14']::date[],
          'the 12th-dated statements are superseded; the 14th-dated ones are active');
select is((select count(*)::int from public.statements
           where profile_code = pg_temp.v('p') and account_code = pg_temp.acc('5052') and kind = 'history_extract'
             and status = 'superseded' and superseded_by in (pg_temp.stmt('5052', '2026-09-14'),
                                                             pg_temp.stmt('5052', '2026-10-14'))),
          3, 'each old statement points at a statement that took its rows');
select is((select sum((s->>'lines_moved')::int)::int from jsonb_array_elements(pg_temp.v('resB')::jsonb->'statements') s),
          6, 'ingest reports six moved lines');
select is((select stmt_code from public.transactions
           where profile_code = pg_temp.v('p') and account_code = pg_temp.acc('5052') and description = 'T52 CHARLIE'),
          pg_temp.stmt('5052', '2026-09-14'), 'the 13 Sep row now belongs to the cycle closing 14 Sep');
select is((select stmt_code from public.transactions
           where profile_code = pg_temp.v('p') and account_code = pg_temp.acc('5052') and description = 'T52 FOXTROT'),
          pg_temp.stmt('5052', '2026-10-14'), 'the 13 Oct row now belongs to the cycle closing 14 Oct');
select is((select (notes, exclude_from_spend)::text from public.transactions
           where profile_code = pg_temp.v('p') and account_code = pg_temp.acc('5052') and description = 'T52 CHARLIE'),
          '(kept,t)', 'user fields survive the move');
select is((select count(*)::int from public.statement_lines l
           where l.profile_code = pg_temp.v('p') and l.account_code = pg_temp.acc('5052') and l.is_current
             and l.source_doc_codes @> array[pg_temp.v('docA'), pg_temp.v('docB')]),
          6, 'each current row is evidenced by both exports');
select is((select count(*)::int from public.transaction_evidence e
           join public.transactions t on t.txn_code = e.txn_code
           where t.profile_code = pg_temp.v('p') and t.account_code = pg_temp.acc('5052') and e.is_active),
          6, 'one active history line per transaction');
select is(pg_temp.open_reviews(), 0, 'no review is left open');
select is((select count(*)::int from jsonb_array_elements_text(pg_temp.v('resB')::jsonb->'warnings') w
           where w like '%close on day%'), 0, 'an export that closes on the account''s day does not warn');

-- Re-parsing the old export with the new cutoff is then a no-op for the ledger.
select public.ingest_parsed_document(pg_temp.v('docA'), pg_temp.export(pg_temp.v('rows')::jsonb, 14, '5052'));
select is(pg_temp.txn_codes('5052')::text, pg_temp.v('codes'), 're-parsing the old export keeps every transaction');
select is(pg_temp.active_dates('5052'), array['2026-09-14', '2026-10-14']::date[], 'and the cycles closing on the 14th');

-- ═══ 2. Re-parsing the only export behind the rows (the re-parse withdraws, then re-links) ═══
select pg_temp.set('docC', pg_temp.new_doc());
select public.ingest_parsed_document(pg_temp.v('docC'), pg_temp.export(replace(pg_temp.v('rows'), 'T52', 'T52C')::jsonb, 12, '7001'));
select pg_temp.set('codesC', pg_temp.txn_codes('7001')::text);
select public.ingest_parsed_document(pg_temp.v('docC'), pg_temp.export(replace(pg_temp.v('rows'), 'T52', 'T52C')::jsonb, 14, '7001'));
select is(pg_temp.live_txns('7001'), 6, 're-parse: still six transactions');
select is(pg_temp.txn_codes('7001')::text, pg_temp.v('codesC'), 're-parse: every transaction keeps its code');
select is(pg_temp.active_dates('7001'), array['2026-09-14', '2026-10-14']::date[], 're-parse: only the 14th-dated cycles are active');
select is(pg_temp.open_reviews(), 0, 're-parse: no review is left open');

-- ═══ 3. A new export that covers only part of the old cycles ═══
select pg_temp.set('docD', pg_temp.new_doc());
select public.ingest_parsed_document(pg_temp.v('docD'), pg_temp.export(replace(pg_temp.v('rows'), 'T52', 'T52D')::jsonb, 12, '7002'));
select pg_temp.set('codesD', pg_temp.txn_codes('7002')::text);
-- Only 20 Sep to 13 Oct: the cycle closing 14 Oct.
select public.ingest_parsed_document(pg_temp.new_doc(), pg_temp.export(
  (select jsonb_agg(x) from jsonb_array_elements(replace(pg_temp.v('rows'), 'T52', 'T52D')::jsonb) x
   where (x->>0)::date >= '2026-09-20'), 14, '7002'));
select is(pg_temp.txn_codes('7002')::text, pg_temp.v('codesD'), 'partial export: no duplicates, every code kept');
select is(pg_temp.active_dates('7002'), array['2026-09-12', '2026-10-12', '2026-10-14']::date[],
          'partial export: a 12th-dated statement keeps the rows nobody re-bucketed; the emptied one is superseded');
select is((select array_agg(l.txn_date order by l.txn_date) from public.statement_lines l
           where l.stmt_code = pg_temp.stmt('7002', '2026-10-12') and l.is_current),
          array['2026-09-13']::date[], 'partial export: the 12 Oct statement keeps only the 13 Sep row');
select is(pg_temp.open_reviews(), 0, 'partial export: no review is left open');

-- ═══ 4. An export bucketed on another day than the account's cycle warns ═══
select pg_temp.set('resE', public.ingest_parsed_document(pg_temp.new_doc(), pg_temp.export(
  '[["2026-10-01","T52 LATE",5]]'::jsonb, 12, '5052'))::text);
select ok((select count(*) from jsonb_array_elements_text(pg_temp.v('resE')::jsonb->'warnings') w
    where w like '%close on day 12; the account''s cycle closes on day 14%') = 1,
   'a 12th-dated export for an account closing on the 14th warns');

select * from finish();
rollback;

-- Replacement cards (20261010000400): a re-issued SIB card lands on the SAME account as a
-- second card, old transactions keep the old card, SMS for the new number match; a second
-- live card of another product (or with overlapping activity) still gets its own account.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
set local ledger.test_today = '2026-12-31';

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
-- A SIB transaction-history document: one history_extract per 12th-of-month cycle.
create function pg_temp.history(p_last4 text, p_type text, p_rows jsonb) returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'SIB',
    'document_kind', 'history_pdf',
    'statements', (
      select jsonb_agg(jsonb_build_object(
        'kind', 'history_extract', 'bank_code', 'SIB', 'statement_reference', 'SIB-H-' || p_last4 || '-' || c.stmt_date,
        'reference_source', 'fallback', 'statement_date', c.stmt_date, 'period_start', c.stmt_date - 30,
        'period_end', c.stmt_date, 'due_date', null, 'primary_card_last4', p_last4, 'card_holder', 'JANE Q SAMPLE',
        'card_type', p_type, 'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
        'lines', c.lines) order by c.stmt_date)
      from (
        select (case when extract(day from (r->>'d')::date) <= 12
                     then date_trunc('month', (r->>'d')::date) + interval '11 days'
                     else date_trunc('month', (r->>'d')::date) + interval '1 month 11 days' end)::date as stmt_date,
               jsonb_agg(jsonb_build_object('line_no', o, 'txn_date', r->>'d', 'txn_time', null, 'posting_date', r->>'d',
                 'description_raw', r->>'m', 'merchant_normalized', r->>'m', 'amount_original', r->>'a',
                 'currency_original', 'AED', 'amount_aed', r->>'a', 'fx_rate', '1', 'direction', 'debit',
                 'kind', 'purchase', 'country_code', null, 'card_last4', p_last4, 'card_holder', 'JANE Q SAMPLE',
                 'legacy_fingerprint', md5(p_last4 || (r->>'d') || (r->>'m') || (r->>'a'))) order by o) as lines
        from jsonb_array_elements(p_rows) with ordinality x(r, o)
        group by 1
      ) c))
$$;
create function pg_temp.ingest(p_payload jsonb) returns jsonb language sql as $$
  with d as (
    insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
    values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'history.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'),
            100, 'scraper')
    returning doc_code)
  select public.ingest_parsed_document((select doc_code from d), p_payload) $$;
create function pg_temp.sib_accounts() returns int language sql as $$
  select count(*)::int from public.accounts where profile_code = pg_temp.v('p') and bank_code = 'SIB' $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't23-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t23-' || left(pg_temp.v('uid'), 8), 'Cards'));
reset role;
select set_config('request.jwt.claims', '', true);

-- The old card's history: activity up to 10 Aug.
select pg_temp.ingest(pg_temp.history('9218', 'SIB MC CASHBACK', '[
  {"d":"2026-06-20","m":"CORNER GROCERY SHARJAH","a":"150.00"},
  {"d":"2026-07-15","m":"BOOK SHOP DUBAI","a":"45.50"},
  {"d":"2026-08-10","m":"CAFE SHARJAH","a":"20.00"}]'::jsonb));
select pg_temp.set('acc', (select account_code from public.accounts where profile_code = pg_temp.v('p') and bank_code = 'SIB'));
select pg_temp.set('old', (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '9218'));
select is(pg_temp.sib_accounts(), 1, 'one SIB account after the old card''s history');

-- An SMS for the new number before its history arrives: held as unknown_card.
select is((public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
          'client_msg_id', gen_random_uuid(), 'received_at', '2026-08-25 08:00:00+00', 'sender', 'SIB',
          'body', 'A txn on your Covered Card XXXX4821 at FUEL STATION SHARJAH for AED 33.00 on 25-08-2026 12:00 is approved. Your available balance is AED 9,000.00'))
       )->0->>'status'), 'unknown_card', 'an SMS for the not-yet-known new card waits (unknown_card)');

-- The new card's history: a new number, activity from 18 Aug.
select pg_temp.set('ing', pg_temp.ingest(pg_temp.history('4821', 'SIB MC CASHBACK', '[
  {"d":"2026-08-18","m":"PHARMACY SHARJAH","a":"60.00"},
  {"d":"2026-09-02","m":"FUEL STATION SHARJAH","a":"120.25"}]'::jsonb))::text);

select is(pg_temp.sib_accounts(), 1, 'the new card''s history lands on the SAME SIB account');
select is((select account_code from public.cards where profile_code = pg_temp.v('p') and last4 = '4821'), pg_temp.v('acc'),
          'the new card is a second card on that account');
select is((select status from public.cards where card_code = pg_temp.v('old')), 'replaced', 'the old card is marked replaced');
select is((select status from public.cards where profile_code = pg_temp.v('p') and last4 = '4821'), 'active',
          'the new card is active');
select is((select count(*)::int from public.transactions t join public.cards c on c.card_code = t.card_code
           where t.profile_code = pg_temp.v('p') and c.last4 = '9218'), 3, 'old transactions keep the old card');
select is((select count(*)::int from public.transactions t join public.cards c on c.card_code = t.card_code
           where t.profile_code = pg_temp.v('p') and c.last4 = '4821' and t.amount_source = 'history_line'), 2,
          'new transactions carry the new card');
select is((select account_code from public.sms_messages where profile_code = pg_temp.v('p') and card_last4 = '4821'),
          pg_temp.v('acc'), 'the waiting SMS is re-processed onto the account');
select is((select count(*)::int from public.match_reviews where profile_code = pg_temp.v('p')
           and reason = 'unknown_card' and status = 'open'), 0, 'its unknown_card review is resolved');
select ok((select message ~ 'New card ending 4821 added as the replacement of the card ending 9218'
           from public.document_events where profile_code = pg_temp.v('p') and stage = 'ingested'
           order by created_at desc limit 1), 'the timeline says which card was replaced');

-- A later SMS for the new card matches straight away.
select is((public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
          'client_msg_id', gen_random_uuid(), 'received_at', '2026-09-20 08:00:00+00', 'sender', 'SIB',
          'body', 'A txn on your Covered Card XXXX4821 at CAFE SHARJAH for AED 12.00 on 20-09-2026 12:00 is approved. Your available balance is AED 8,900.00'))
       )->0->>'status'), 'created', 'an SMS for the new card creates a transaction on the account');

-- Re-ingesting the old card's history keeps everything where it is.
select pg_temp.ingest(pg_temp.history('9218', 'SIB MC CASHBACK', '[
  {"d":"2026-06-20","m":"CORNER GROCERY SHARJAH","a":"150.00"}]'::jsonb));
select is(pg_temp.sib_accounts(), 1, 'a known card never creates an account');

-- ── guards: a different product, or overlapping activity, is a separate account ──
select pg_temp.ingest(pg_temp.history('9090', 'SIB PLATINUM', '[
  {"d":"2026-09-05","m":"HOTEL DUBAI","a":"900.00"}]'::jsonb));
select is(pg_temp.sib_accounts(), 2, 'a card of another product gets its own account');
select is((select status from public.cards where profile_code = pg_temp.v('p') and last4 = '4821'), 'active',
          'and does not retire the existing card');

-- ── owner RPC: register a replacement by hand ──────────────────────────────
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('rep', public.add_replacement_card(pg_temp.v('p'),
  (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '4821'), '5555')::text);
select is((pg_temp.v('rep')::jsonb)->>'account_code', pg_temp.v('acc'), 'add_replacement_card registers on the same account');
select is((select status from public.cards where profile_code = pg_temp.v('p') and last4 = '4821'), 'replaced',
          'and retires the card it replaces');
select throws_ok($$ select public.add_replacement_card(pg_temp.v('p'),
                      (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '5555'), '9090') $$,
                 '23505', null, 'a number that belongs to another account is refused');
select throws_ok($$ select public.add_replacement_card(pg_temp.v('p'), pg_temp.v('old'), 'abcd') $$,
                 '22023', null, 'the new number must be 4 digits');
reset role;

-- ── statement kind 'statement' never auto-merges ────────────────────────────
select is(private.successor_card_account(pg_temp.v('p'), 'SIB', null, '2026-12-01'), null,
          'with two active SIB accounts there is no single successor account');

select * from finish();
rollback;

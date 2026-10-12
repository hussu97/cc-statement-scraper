-- Wallet transaction capture (20261012211020_wallet_transactions.sql): card payments logged
-- by the Shortcuts "Transaction" automation through public.ingest_wallet_transactions become
-- sms_messages rows with source 'wallet', matched to a card by cards.wallet_name, deduped
-- against the bank's SMS for the same purchase, and later posted by the statement line.
-- Runs on a non-empty DB: every assertion is scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
set local client_min_messages = warning;
select no_plan();

-- ── helpers ─────────────────────────────────────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.new_user(p_key text, p_email text) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          email_confirmed_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_email,
          '{}', '{}', now(), now(), now());
  select pg_temp.set(p_key, (select id::text from auth.users where email = p_email));
$$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
-- A Wallet item at a Dubai wall-clock time on day b + p_day (b = 40 days ago).
create function pg_temp.item(p_amount text, p_merchant text, p_pass text, p_day int, p_time time,
                             p_id uuid default gen_random_uuid(), p_currency text default 'AED')
returns jsonb language sql as $$
  select jsonb_build_object('client_msg_id', p_id,
    'occurred_at', ((pg_temp.v('b')::date + p_day) + p_time) at time zone 'Asia/Dubai',
    'amount', p_amount, 'currency', p_currency, 'merchant', p_merchant, 'pass_name', p_pass) $$;
create function pg_temp.wallet(p_item jsonb) returns jsonb language sql as $$
  select public.ingest_wallet_transactions(pg_temp.v('p'), jsonb_build_array(p_item)) -> 0 $$;
create function pg_temp.wio_sms(p_amount text, p_merchant text, p_day int, p_time time) returns jsonb language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(),
    'received_at', ((pg_temp.v('b')::date + p_day) + p_time) at time zone 'Asia/Dubai', 'sender', 'WioPersonal',
    'body', format('Payment of AED %s was done at %s using your Wio Personal card 9202 with Credit money',
                   p_amount, p_merchant)))) -> 0 $$;
create function pg_temp.evidence(p_txn text) returns int language sql as $$
  select count(*)::int from public.transaction_evidence where txn_code = p_txn and is_active $$;
create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric) returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date + 1,
    'description_raw', p_desc, 'merchant_normalized', upper(p_desc), 'amount_original', p_amount::text,
    'currency_original', 'AED', 'amount_aed', p_amount::text, 'fx_rate', null, 'direction', 'debit',
    'kind', 'purchase', 'country_code', 'AE', 'card_last4', '9202', 'card_holder', null, 'legacy_fingerprint', null)
$$;

-- ── setup: owner, viewer, one profile with a Wio and an EIB card ────────────
select pg_temp.set('b', (current_date - 40)::text);
select pg_temp.set('tag', left(gen_random_uuid()::text, 8));
select pg_temp.new_user('owner', 't37-owner-' || pg_temp.v('tag') || '@test.dev');
select pg_temp.new_user('viewer', 't37-viewer-' || pg_temp.v('tag') || '@test.dev');
select pg_temp.as_user('owner');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t37-' || pg_temp.v('tag'), 'Wallet capture'));
select is(public.add_profile_member(pg_temp.v('p'), 't37-viewer-' || pg_temp.v('tag') || '@test.dev', 'viewer'), 'added',
          'a viewer joins the profile');
reset role;

with a as (
  insert into public.accounts (profile_code, bank_code, product_name)
  values (pg_temp.v('p'), 'WIO', 'Wio credit'), (pg_temp.v('p'), 'EIB', 'EIB card')
  returning account_code, profile_code, bank_code
)
insert into public.cards (profile_code, account_code, bank_code, last4)
select profile_code, account_code, bank_code, case bank_code when 'WIO' then '9202' else '9212' end from a;
select pg_temp.set('wio_card', (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '9202'));
select pg_temp.set('wio_acc', (select account_code from public.cards where card_code = pg_temp.v('wio_card')));
select pg_temp.set('eib_card', (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '9212'));
select pg_temp.set('eib_acc', (select account_code from public.cards where card_code = pg_temp.v('eib_card')));

-- ═══ schema ═════════════════════════════════════════════════════════════════
select has_column('public', 'sms_messages', 'source', 'sms_messages.source exists');
select col_default_is('public', 'sms_messages', 'source', 'sms'::text, 'an SMS is source ''sms'' by default');
select has_column('public', 'sms_messages', 'wallet_pass_name', 'sms_messages.wallet_pass_name exists');
select has_column('public', 'cards', 'wallet_name', 'cards.wallet_name exists');
select ok(has_column_privilege('authenticated', 'public.cards', 'wallet_name', 'UPDATE'),
          'owners may set a card''s Wallet name');
select is((select count(*)::int from public.sms_messages where source = 'sms' and wallet_pass_name is not null), 0,
          'existing SMS rows have no pass name');

-- The owner names the Wio card (through RLS and the column grant).
select pg_temp.as_user('owner');
set local role authenticated;
update public.cards set wallet_name = 'Wio Personal' where card_code = pg_temp.v('wio_card');
reset role;
select is((select wallet_name from public.cards where card_code = pg_temp.v('wio_card')), 'Wio Personal',
          'the owner set the Wio card''s Wallet name');

-- ═══ ingest → parsed → pending transaction ═════════════════════════════════
select pg_temp.set('id1', gen_random_uuid()::text);
select pg_temp.as_user('owner');
set local role authenticated;
select pg_temp.set('w1', pg_temp.wallet(pg_temp.item('18.50', '  Starbucks   Mall ', 'Wio Personal', 0, '10:00',
                                                     pg_temp.v('id1')::uuid))::text);
reset role;
select pg_temp.set('w1_sms', pg_temp.v('w1')::jsonb->>'sms_code');
select pg_temp.set('w1_txn', pg_temp.v('w1')::jsonb->>'txn_code');
select is(pg_temp.v('w1')::jsonb->>'status', 'created', 'a Wallet payment on a named card creates a transaction');
select is(pg_temp.v('w1')::jsonb->>'client_msg_id', pg_temp.v('id1'), 'the result echoes client_msg_id');
select ok(pg_temp.v('w1_txn') is not null, 'and returns its txn_code');
select is((select source || '|' || wallet_pass_name || '|' || sender || '|' || body || '|' || parse_status || '|' || msg_kind
           from public.sms_messages where sms_code = pg_temp.v('w1_sms')),
          'wallet|Wio Personal|Wallet|AED 18.50 at Starbucks Mall (Wio Personal)|parsed|purchase',
          'stored as a Wallet row with the synthetic sender and body');
select is((select body_hash from public.sms_messages where sms_code = pg_temp.v('w1_sms')),
          encode(sha256(convert_to('Wallet|AED 18.50 at Starbucks Mall (Wio Personal)', 'UTF8')), 'hex'),
          'body_hash hashes sender|body like an SMS');
select is((select card_code || '|' || account_code || '|' || bank_code || '|' || card_last4 || '|' || amount || '|'
                  || currency || '|' || description
           from public.sms_messages where sms_code = pg_temp.v('w1_sms')),
          pg_temp.v('wio_card') || '|' || pg_temp.v('wio_acc') || '|WIO|9202|18.50|AED|STARBUCKS MALL',
          'the card comes from its Wallet name; the fields from the item');
select is((select event_at from public.sms_messages where sms_code = pg_temp.v('w1_sms')),
          (pg_temp.v('b')::date + time '10:00') at time zone 'Asia/Dubai', 'event_at is occurred_at');
select is((select status || '|' || amount_source || '|' || card_code || '|' || amount_aed || '|' || txn_date
           from public.transactions where txn_code = pg_temp.v('w1_txn')),
          'pending|sms|' || pg_temp.v('wio_card') || '|18.50|' || pg_temp.v('b'),
          'the transaction is pending on the Wio card, dated in Dubai');

-- ═══ idempotent redelivery ══════════════════════════════════════════════════
select pg_temp.set('w1b', pg_temp.wallet(pg_temp.item('18.50', 'Starbucks Mall', 'Wio Personal', 0, '10:00',
                                                      pg_temp.v('id1')::uuid))::text);
select is(pg_temp.v('w1b')::jsonb->>'status', 'duplicate_delivery', 'the same client_msg_id again is a duplicate delivery');
select is(pg_temp.v('w1b')::jsonb->>'sms_code', pg_temp.v('w1_sms'), 'pointing at the stored row');
select is((select count(*)::int from public.sms_messages
           where profile_code = pg_temp.v('p') and client_msg_id = pg_temp.v('id1')::uuid), 1, 'nothing new is stored');

-- Two genuine identical taps (same card, amount, merchant, pass name) are two payments: a
-- Wallet row is never a duplicate of another Wallet row (redelivery is deduped by client_msg_id).
select pg_temp.set('w1c', pg_temp.wallet(pg_temp.item('18.50', 'Starbucks Mall', 'Wio Personal', 0, '10:00:40'))::text);
select is(pg_temp.v('w1c')::jsonb->>'status', 'created', 'an identical Wallet payment 40 s later is a new transaction');
select isnt(pg_temp.v('w1c')::jsonb->>'txn_code', pg_temp.v('w1_txn'), 'not the first one');
select pg_temp.set('w1d', pg_temp.wallet(pg_temp.item('18.50', 'Starbucks Mall', 'Wio Personal', 0, '10:10'))::text);
select is(pg_temp.v('w1d')::jsonb->>'status', 'created', 'an identical Wallet payment 10 minutes later is a new transaction');
select is((select count(distinct e.txn_code)::int from public.transaction_evidence e
           where e.is_active and e.sms_code in (pg_temp.v('w1_sms'), pg_temp.v('w1c')::jsonb->>'sms_code',
                                                pg_temp.v('w1d')::jsonb->>'sms_code')), 3,
          'three identical taps are three transactions');
select is((select count(*)::int from public.transaction_evidence e
           where e.is_active and e.role = 'duplicate' and e.sms_code in (pg_temp.v('w1_sms'),
             pg_temp.v('w1c')::jsonb->>'sms_code', pg_temp.v('w1d')::jsonb->>'sms_code')), 0,
          'none of them is duplicate evidence');

-- SMS↔SMS duplicate detection is unchanged: the same bank alert twice is still a duplicate.
select pg_temp.set('sd1', pg_temp.wio_sms('33.00', 'Zoom Market', 7, '18:00')::text);
select pg_temp.set('sd2', pg_temp.wio_sms('33.00', 'Zoom Market', 7, '18:01')::text);
select is(pg_temp.v('sd2')::jsonb->>'status', 'duplicate', 'a resent bank SMS is still a duplicate');
select is(pg_temp.v('sd2')::jsonb->>'txn_code', pg_temp.v('sd1')::jsonb->>'txn_code', 'of the first SMS''s transaction');

-- ═══ the name match ignores case ════════════════════════════════════════════
select pg_temp.set('w2', pg_temp.wallet(pg_temp.item('77.00', 'Noon', 'WIO PERSONAL', 3, '19:30'))::text);
select is(pg_temp.v('w2')::jsonb->>'status', 'created', 'a pass name in another case still finds the card');
select is((select card_code from public.sms_messages where sms_code = pg_temp.v('w2')::jsonb->>'sms_code'),
          pg_temp.v('wio_card'), 'the Wio card');

-- ═══ unknown pass name → review; naming the card re-processes it ═══════════
select pg_temp.set('u', pg_temp.wallet(pg_temp.item('42.00', 'Spinneys', 'Emirates Islamic Card', 4, '08:15'))::text);
select pg_temp.set('u_sms', pg_temp.v('u')::jsonb->>'sms_code');
select is(pg_temp.v('u')::jsonb->>'status', 'unknown_card', 'a pass name no card carries is held as unknown_card');
select ok(pg_temp.v('u')::jsonb->>'txn_code' is null, 'with no transaction');
select is((select parse_status || '|' || coalesce(account_code, '-') || '|' || amount from public.sms_messages
           where sms_code = pg_temp.v('u_sms')), 'parsed|-|42.00', 'the row is parsed but has no account');
select pg_temp.set('u_rev', (select review_code from public.match_reviews where profile_code = pg_temp.v('p')
                             and subject_type = 'sms' and subject_code = pg_temp.v('u_sms')
                             and reason = 'unknown_card' and status = 'open'));
select ok(pg_temp.v('u_rev') is not null, 'an open unknown_card review is raised');
select is((select candidates from public.match_reviews where review_code = pg_temp.v('u_rev')),
          '[{"wallet_name": "Emirates Islamic Card"}]'::jsonb, 'its candidates carry the pass name');

-- The register-card action needs a card number, which a Wallet event lacks.
select pg_temp.as_user('owner');
set local role authenticated;
select throws_ok(format('select public.resolve_review(%L, %L::jsonb)', pg_temp.v('u_rev'),
                        jsonb_build_object('card', jsonb_build_object('account_code', pg_temp.v('eib_acc')))),
                 '22023', null, 'resolve_review card action refuses a Wallet row (set the Wallet name instead)');
select is((select status from public.match_reviews where review_code = pg_temp.v('u_rev')), 'open',
          'and the review stays open');

-- Wallet names are unique per profile, ignoring case.
select throws_ok(format('update public.cards set wallet_name = %L where card_code = %L', 'wio personal',
                        pg_temp.v('eib_card')),
                 '23505', null, 'two cards cannot share a Wallet name (case-insensitive)');
select throws_ok(format('update public.cards set wallet_name = %L where card_code = %L', ' padded ', pg_temp.v('eib_card')),
                 '23514', null, 'a Wallet name is stored trimmed');

-- Naming the EIB card (in another case) binds the waiting row and resolves its review.
update public.cards set wallet_name = 'emirates islamic card' where card_code = pg_temp.v('eib_card');
reset role;
select is((select account_code || '|' || card_code || '|' || bank_code from public.sms_messages
           where sms_code = pg_temp.v('u_sms')),
          pg_temp.v('eib_acc') || '|' || pg_temp.v('eib_card') || '|EIB', 'the waiting row now has the EIB card');
select is((select status || '|' || (resolution->>'auto') from public.match_reviews where review_code = pg_temp.v('u_rev')),
          'resolved|card_registered', 'its unknown_card review resolved itself');
select ok(exists (select 1 from public.transaction_evidence e join public.transactions t using (txn_code)
                  where e.sms_code = pg_temp.v('u_sms') and e.is_active and t.status = 'pending'
                    and t.account_code = pg_temp.v('eib_acc') and t.amount_original = 42.00),
          'and it is now evidence of a pending EIB transaction');

-- A rename that is only a change of case does not re-process anything (and does not fail).
select pg_temp.as_user('owner');
set local role authenticated;
select lives_ok(format('update public.cards set wallet_name = %L where card_code = %L', 'Emirates Islamic Card',
                       pg_temp.v('eib_card')), 'renaming in another case is fine');
reset role;

-- ═══ a Wio SMS, then the Wallet event for the same purchase ═════════════════
select pg_temp.set('s3', pg_temp.wio_sms('593.03', 'Dubai Electricity', 1, '09:00')::text);
select is(pg_temp.v('s3')::jsonb->>'status', 'created', 'the Wio SMS creates the transaction');
select pg_temp.set('t3', pg_temp.v('s3')::jsonb->>'txn_code');
select pg_temp.set('w3', pg_temp.wallet(pg_temp.item('593.03', 'DEWA', 'Wio Personal', 1, '08:58:40'))::text);
select is(pg_temp.v('w3')::jsonb->>'status', 'duplicate', 'the Wallet event for the same purchase is linked, not new');
select is(pg_temp.v('w3')::jsonb->>'txn_code', pg_temp.v('t3'), 'to the SMS''s transaction');
select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p') and amount_original = 593.03),
          1, 'one transaction');
select is(pg_temp.evidence(pg_temp.v('t3')), 2, 'with two evidence rows');
select is((select description from public.transactions where txn_code = pg_temp.v('t3')), 'DUBAI ELECTRICITY',
          'the bank''s merchant text still describes it');

-- ═══ the Wallet event first, then the Wio SMS ═══════════════════════════════
select pg_temp.set('w4', pg_temp.wallet(pg_temp.item('245.10', 'Carrefour', 'Wio Personal', 2, '12:00'))::text);
select is(pg_temp.v('w4')::jsonb->>'status', 'created', 'a Wallet event first creates the transaction');
select pg_temp.set('t4', pg_temp.v('w4')::jsonb->>'txn_code');
select pg_temp.set('s4', pg_temp.wio_sms('245.10', 'CARREFOUR MOE DUBAI', 2, '12:01')::text);
select is(pg_temp.v('s4')::jsonb->>'status', 'duplicate', 'the later SMS joins it');
select is(pg_temp.v('s4')::jsonb->>'txn_code', pg_temp.v('t4'), 'the same transaction');
select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p') and amount_original = 245.10),
          1, 'still one transaction');
select is(pg_temp.evidence(pg_temp.v('t4')), 2, 'with two evidence rows');

-- ═══ the statement line later supersedes both ═══════════════════════════════
with d as (
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'wio.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100,
          'upload')
  returning doc_code
)
select pg_temp.set('doc', doc_code) from d;
select pg_temp.set('ing', public.ingest_parsed_document(pg_temp.v('doc'), jsonb_build_object(
  'contract_version', 1, 'parser_version', 'test', 'bank_code', 'WIO', 'document_kind', 'statement_pdf',
  'statements', jsonb_build_array(jsonb_build_object(
    'kind', 'statement', 'bank_code', 'WIO', 'statement_reference', 'T37-' || pg_temp.v('tag'),
    'reference_source', 'explicit', 'statement_date', pg_temp.v('b')::date + 10,
    'period_start', pg_temp.v('b')::date - 20, 'period_end', pg_temp.v('b')::date + 10,
    'due_date', pg_temp.v('b')::date + 35, 'primary_card_last4', '9202', 'card_holder', 'TEST', 'card_type', 'VISA',
    'totals', '{}'::jsonb, 'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb,
    'lines', jsonb_build_array(
      pg_temp.line(1, pg_temp.v('b')::date + 1, 'DUBAI ELECTRICITY & WATER', 593.03),
      pg_temp.line(2, pg_temp.v('b')::date + 2, 'CARREFOUR MOE', 245.10))))))::text);
select is((select status || '|' || amount_source from public.transactions where txn_code = pg_temp.v('t3')),
          'posted|statement_line', 'SMS-then-Wallet: the statement line posts the transaction');
select is((select status || '|' || amount_source from public.transactions where txn_code = pg_temp.v('t4')),
          'posted|statement_line', 'Wallet-then-SMS: the statement line posts the transaction');
select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p')
           and amount_original = 593.03 and status <> 'void'), 1, 'still one 593.03 transaction');
select is((select string_agg(evidence_type, ',' order by evidence_type) from public.transaction_evidence
           where txn_code = pg_temp.v('t3') and is_active), 'sms,sms,statement_line',
          'the line joins the SMS and the Wallet event as evidence');

-- Two same-amount purchases pair one to one: a second Wallet event finds no unpaired twin.
select pg_temp.set('w5', pg_temp.wallet(pg_temp.item('245.10', 'Carrefour Express', 'Wio Personal', 2, '12:20'))::text);
select is(pg_temp.v('w5')::jsonb->>'status', 'created', 'a second same-amount Wallet purchase (after its twin paired) is its own transaction');

-- A twin more than 30 minutes away is not the same purchase.
select pg_temp.set('s6', pg_temp.wio_sms('61.00', 'ENOC', 5, '07:00')::text);
select pg_temp.set('w6', pg_temp.wallet(pg_temp.item('61.00', 'ENOC Station', 'Wio Personal', 5, '09:00'))::text);
select isnt(pg_temp.v('w6')::jsonb->>'txn_code', pg_temp.v('s6')::jsonb->>'txn_code',
            'a Wallet event two hours after the SMS is not paired with it');

-- ═══ a viewer cannot ingest ═════════════════════════════════════════════════
select pg_temp.as_user('viewer');
set local role authenticated;
select throws_ok(format('select public.ingest_wallet_transactions(%L, %L::jsonb)', pg_temp.v('p'),
                        jsonb_build_array(pg_temp.item('5.00', 'Kiosk', 'Wio Personal', 6, '10:00'))),
                 '42501', null, 'a viewer cannot log Wallet payments');
update public.cards set wallet_name = 'Hijacked' where card_code = pg_temp.v('wio_card');
reset role;
select is((select wallet_name from public.cards where card_code = pg_temp.v('wio_card')), 'Wio Personal',
          'and cannot rename a card');

-- ═══ invalid items are rejected one by one ══════════════════════════════════
select pg_temp.set('bad', public.ingest_wallet_transactions(pg_temp.v('p'), jsonb_build_array(
  pg_temp.item('9.99', 'Valid Cafe', 'Wio Personal', 6, '11:00'),
  pg_temp.item('9.99', 'Number Cafe', 'Wio Personal', 6, '11:01') || '{"amount": 9.99}',
  pg_temp.item('0.00', 'Zero Cafe', 'Wio Personal', 6, '11:02'),
  pg_temp.item('-4.00', 'Negative Cafe', 'Wio Personal', 6, '11:03'),
  pg_temp.item('1,000.00', 'Comma Cafe', 'Wio Personal', 6, '11:04'),
  pg_temp.item('9.99', 'Lower Cafe', 'Wio Personal', 6, '11:05', gen_random_uuid(), 'aed'),
  pg_temp.item('9.99', 'Long Code Cafe', 'Wio Personal', 6, '11:06', gen_random_uuid(), 'DIRHAM'),
  pg_temp.item('9.99', '   ', 'Wio Personal', 6, '11:07'),
  pg_temp.item('9.99', 'No Pass Cafe', '', 6, '11:08'),
  pg_temp.item('9.99', 'Long Pass Cafe', repeat('x', 65), 6, '11:09'),
  pg_temp.item('9.99', 'Bad Id Cafe', 'Wio Personal', 6, '11:10') || '{"client_msg_id": "not-a-uuid"}',
  pg_temp.item('9.99', 'Future Cafe', 'Wio Personal', 6, '11:11') || jsonb_build_object('occurred_at', now() + interval '3 days'),
  '"just a string"'::jsonb))::text);
select is((select string_agg(coalesce(x->>'reason', x->>'status'), ',' order by n)
           from jsonb_array_elements(pg_temp.v('bad')::jsonb) with ordinality as a(x, n)),
          'created,invalid_amount,invalid_amount,invalid_amount,invalid_amount,invalid_currency,invalid_currency,'
          || 'invalid_merchant,invalid_pass_name,invalid_pass_name,invalid_client_msg_id,invalid_occurred_at,not_an_object',
          'each bad item gets its own reason; the good one is stored');
select is((select count(*)::int from jsonb_array_elements(pg_temp.v('bad')::jsonb) x where x->>'status' = 'invalid'), 12,
          'twelve items are invalid');
select is((select count(*)::int from public.sms_messages where profile_code = pg_temp.v('p') and body like '%Cafe%'), 1,
          'only the valid item is stored');
select throws_ok(format('select public.ingest_wallet_transactions(%L, %L::jsonb)', pg_temp.v('p'),
                        (select jsonb_agg(pg_temp.item('1.00', 'Bulk', 'Wio Personal', 6, '12:00')) from generate_series(1, 201))),
                 '22023', null, 'more than 200 items is refused');
select throws_ok(format('select public.ingest_wallet_transactions(%L, %L::jsonb)', pg_temp.v('p'), '{}'),
                 '22023', null, 'p_items must be an array');

-- ═══ the source invariant ═══════════════════════════════════════════════════
select throws_ok(format($q$update public.sms_messages set wallet_pass_name = null where sms_code = %L$q$, pg_temp.v('w1_sms')),
                 '23514', null, 'a Wallet row must keep its pass name');
select is((select count(*)::int from public.sms_messages where (source = 'wallet') <> (wallet_pass_name is not null)), 0,
          'source = wallet exactly when there is a pass name');

select * from finish();
rollback;

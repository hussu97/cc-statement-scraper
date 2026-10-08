-- DB-28r: dedicated regressions for DB-27 (a line displaced by a manual link stays
-- in the ledger) and DB-43 (an unknown_card SMS without a card number).
-- Runs on a non-empty DB: every key is unique to this run.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
create function pg_temp.as_system() returns text language sql as $$
  select set_config('request.jwt.claims', '', true) $$;
create function pg_temp.line(p_no int, p_desc text, p_amount numeric) returns text language sql as $$
  insert into public.statement_lines (stmt_code, profile_code, account_code, evidence_type, line_no, line_key, occurrence,
    txn_date, description_raw, description, amount_original, currency_original, amount_aed, direction, kind, raw,
    source_doc_codes)
  values (pg_temp.v('stmt'), pg_temp.v('p'), pg_temp.v('acc'), 'statement_line', p_no, 'k' || p_no || '-' || pg_temp.v('uid'), 1,
          current_date - 20, p_desc, p_desc, p_amount, 'AED', p_amount, 'debit', 'purchase', '{}', '{}')
  returning line_code $$;
create function pg_temp.txn_of(p_line text) returns text language sql as $$
  select txn_code from public.transaction_evidence where line_code = p_line and is_active $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't18-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now(), now());
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t18-' || left(pg_temp.v('uid'), 8), 'Review regressions'));
reset role;
select pg_temp.as_system();
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'FAB'), (pg_temp.v('p'), 'FAB');
select pg_temp.set('acc', (select min(account_code) from public.accounts where profile_code = pg_temp.v('p')));
select pg_temp.set('acc2', (select max(account_code) from public.accounts where profile_code = pg_temp.v('p')));
insert into public.statements (profile_code, account_code, kind, statement_date)
values (pg_temp.v('p'), pg_temp.v('acc'), 'statement', current_date - 5);
select pg_temp.set('stmt', (select stmt_code from public.statements where profile_code = pg_temp.v('p')));

-- ═══ DB-27: linking a held line onto a transaction keeps the displaced line ═
select pg_temp.set('l1', pg_temp.line(1, 'T18 SHOP ONE', 40));
select pg_temp.set('l2', pg_temp.line(2, 'T18 SHOP TWO', 55));
select pg_temp.set('l3', pg_temp.line(3, 'T18 SHOP ONE', 40));
select pg_temp.set('t1', private.new_transaction_from_line(pg_temp.v('l1')));
select private.new_transaction_from_line(pg_temp.v('l2'));
insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
values (pg_temp.v('p'), pg_temp.v('acc'), 'statement_line', pg_temp.v('l3'), 'ambiguous',
        jsonb_build_array(jsonb_build_object('txn_code', pg_temp.v('t1'))));
select pg_temp.set('rev', (select review_code from public.match_reviews where profile_code = pg_temp.v('p')
                          and subject_code = pg_temp.v('l3')));
select pg_temp.as_owner();
set local role authenticated;
select is(public.resolve_review(pg_temp.v('rev'), jsonb_build_object('link', pg_temp.v('t1')))->>'outcome', 'linked',
          'the owner links the held line to the transaction');
reset role;
select pg_temp.as_system();
select is(pg_temp.txn_of(pg_temp.v('l3')), pg_temp.v('t1'), 'the held line now evidences that transaction');
select ok(pg_temp.txn_of(pg_temp.v('l1')) is not null and pg_temp.txn_of(pg_temp.v('l1')) <> pg_temp.v('t1'),
          'the displaced line has its own transaction (DB-27)');
select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p') and status = 'posted'), 3,
          'three lines, three posted transactions: nothing dropped out of spend');
select is((select sum(spend_aed) from public.v_spend where profile_code = pg_temp.v('p')), 135.00::numeric,
          'spend still counts every line (40 + 55 + 40)');

-- ═══ DB-43: an unknown_card SMS with no card number ══════════════════════
insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, msg_kind, examples)
values ('FAB', 't18 no last4', '^T18FAB', 'T18 spent ([A-Z]{3}) ([0-9.]+) at (.+)$',
        '{"currency":1,"amount":2,"merchant":3}', 'purchase',
        '[{"sender":"T18FAB","body":"T18 spent AED 12.00 at SOMEWHERE","expect":{"amount":"12.00"}}]');
select pg_temp.set('sms', (public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
  'client_msg_id', gen_random_uuid(), 'received_at', now(), 'sender', 'T18FAB', 'body', 'T18 spent AED 33.00 at T18 KIOSK')))->0)::text);
select is(pg_temp.v('sms')::jsonb->>'status', 'unknown_card',
          'with two FAB accounts and no card number the SMS is held as unknown_card');
select is((select card_last4 from public.sms_messages where sms_code = pg_temp.v('sms')::jsonb->>'sms_code'), null,
          'it has no card number');
select pg_temp.set('rev2', (select review_code from public.match_reviews where profile_code = pg_temp.v('p')
                           and reason = 'unknown_card' and status = 'open'));
select pg_temp.as_owner();
set local role authenticated;
select is(public.resolve_review(pg_temp.v('rev2'), jsonb_build_object('card', jsonb_build_object('account_code', pg_temp.v('acc2'))))->>'outcome',
          'card_registered', 'the owner picks the account');
reset role;
select pg_temp.as_system();
select is((select account_code from public.sms_messages where sms_code = pg_temp.v('sms')::jsonb->>'sms_code'), pg_temp.v('acc2'),
          'the message is bound to that account (DB-43)');
select ok(exists (select 1 from public.transaction_evidence e join public.transactions t on t.txn_code = e.txn_code
                  where e.sms_code = pg_temp.v('sms')::jsonb->>'sms_code' and e.is_active and t.account_code = pg_temp.v('acc2')),
          'and becomes a transaction on it');
select is((select count(*)::int from public.cards where profile_code = pg_temp.v('p')), 0, 'no card was invented');
select is((select status from public.match_reviews where review_code = pg_temp.v('rev2')), 'resolved', 'the review is resolved');

select * from finish();
rollback;

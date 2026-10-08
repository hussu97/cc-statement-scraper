-- Tenant isolation (docs/audit/01-database.md DB-01..DB-05, DB-14): every RPC
-- that takes a code refuses another profile's code, composite FKs make a
-- cross-profile child row impossible, and global tables are not readable by
-- strangers. Runs on a non-empty DB: ids and keys are unique to this run.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ── helpers ─────────────────────────────────────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.new_user(p_key text) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't08-' || p_key || '-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now())
  returning pg_temp.set(p_key, id::text) $$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.as_system() returns text language sql as $$ select set_config('request.jwt.claims', '', true) $$;

create function pg_temp.line(p_no int, p_date date, p_desc text, p_amount numeric, p_last4 text)
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'posting_date', p_date + 1,
    'description_raw', p_desc, 'merchant_normalized', p_desc, 'amount_original', p_amount::text,
    'currency_original', 'AED', 'amount_aed', p_amount::text, 'direction', 'debit', 'kind', 'purchase',
    'card_last4', p_last4) $$;
create function pg_temp.ingest(p_profile text, p_date date, p_last4 text, p_lines jsonb) returns jsonb language plpgsql as $$
declare v_doc text;
begin
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (p_profile, 'x/' || gen_random_uuid(), 't.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 1, 'upload')
  returning doc_code into v_doc;
  return public.ingest_parsed_document(v_doc, jsonb_build_object('contract_version', 1, 'parser_version', 'test',
    'bank_code', 'ADCB', 'document_kind', 'statement_pdf', 'statements', jsonb_build_array(jsonb_build_object(
      'kind', 'statement', 'bank_code', 'ADCB', 'statement_date', p_date, 'period_start', p_date - 30,
      'period_end', p_date, 'primary_card_last4', p_last4, 'totals', '{}'::jsonb, 'lines', p_lines))));
end $$;
create function pg_temp.sms(p_profile text, p_body text, p_at timestamptz) returns jsonb language sql as $$
  select public.ingest_sms(p_profile, jsonb_build_array(jsonb_build_object(
    'client_msg_id', gen_random_uuid(), 'received_at', p_at, 'sender', 'ADCBAlert', 'body', p_body))) -> 0 $$;

-- ── setup: alice (attacker, profile A), bob (victim, profile B), carol (stranger)
select pg_temp.new_user('ua'), pg_temp.new_user('ub'), pg_temp.new_user('uc');
select pg_temp.as_user('ua');
set local role authenticated;
select pg_temp.set('pa', public.create_profile('t08a-' || left(md5(random()::text), 8), 'A'));
reset role;
select pg_temp.as_user('ub');
set local role authenticated;
select pg_temp.set('pb', public.create_profile('t08b-' || left(md5(random()::text), 8), 'B'));
reset role;
select pg_temp.as_system();

-- B's real card 1111 with a statement and a mailbox
select pg_temp.set('b_stmt_result', pg_temp.ingest(pg_temp.v('pb'), '2026-08-31', '1111',
  jsonb_build_array(pg_temp.line(1, '2026-08-10', 'NETFLIX.COM AMSTERDAM', 55, '1111')))::text);
select pg_temp.set('acc_b', pg_temp.v('b_stmt_result')::jsonb->'statements'->0->>'account_code');
select pg_temp.set('stm_b', pg_temp.v('b_stmt_result')::jsonb->'statements'->0->>'stmt_code');
select pg_temp.set('doc_b', pg_temp.v('b_stmt_result')::jsonb->>'doc_code');
select pg_temp.set('txn_b', (select txn_code from public.transactions where profile_code = pg_temp.v('pb') limit 1));
select pg_temp.set('line_b', (select line_code from public.statement_lines where profile_code = pg_temp.v('pb') limit 1));
select pg_temp.set('card_b', (select card_code from public.cards where profile_code = pg_temp.v('pb')));
select pg_temp.set('cat_b', (select category_code from public.categories where profile_code = pg_temp.v('pb') and name = 'Dining'));
insert into public.email_mailboxes (profile_code, provider, mailbox_email) values (pg_temp.v('pb'), 'gmail', 'b@example.com');
select pg_temp.set('mbx_b', (select mailbox_code from public.email_mailboxes where profile_code = pg_temp.v('pb')));

-- A has its own ADCB account (card 2222) and two overlapping statements
select pg_temp.set('a1', pg_temp.ingest(pg_temp.v('pa'), '2026-08-31', '2222',
  jsonb_build_array(pg_temp.line(1, '2026-08-11', 'SHOP A', 10, '2222')))::text);
select pg_temp.set('acc_a', pg_temp.v('a1')::jsonb->'statements'->0->>'account_code');
select pg_temp.set('stm_a1', pg_temp.v('a1')::jsonb->'statements'->0->>'stmt_code');
select pg_temp.set('a2', pg_temp.ingest(pg_temp.v('pa'), '2026-09-05', '2222',
  jsonb_build_array(pg_temp.line(1, '2026-09-01', 'SHOP A2', 12, '2222')))::text);
select pg_temp.set('rev_overlap', (select review_code from public.match_reviews
                                   where profile_code = pg_temp.v('pa') and reason = 'period_overlap' and status = 'open'));
select isnt(pg_temp.v('rev_overlap'), null, 'A has a period_overlap review');

-- ═══ DB-01: unknown_card cannot bind another profile's account ════════════
select pg_temp.as_user('ua');
set local role authenticated;
select is(pg_temp.sms(pg_temp.v('pa'),
  'Your Cr.Card XXX1111 was used for AED55.00 on 20/08/2026 10:00:00 at NETFLIX.COM. Avl. Cr.limit is AED1000.00',
  '2026-08-20 06:00:05+00')->>'status', 'unknown_card', 'A''s SMS on B''s card number is an unknown card in A');
select pg_temp.set('rev_card', (select review_code from public.match_reviews
                                where profile_code = pg_temp.v('pa') and reason = 'unknown_card' and status = 'open'));
select throws_ok($$ select public.resolve_review(pg_temp.v('rev_card'),
                      jsonb_build_object('card', jsonb_build_object('account_code', pg_temp.v('acc_b')))) $$,
                 'P0002', null, 'resolve_review {"card"} refuses another profile''s account (E2b)');
reset role;
select is((select count(*)::int from public.cards where profile_code = pg_temp.v('pa') and account_code = pg_temp.v('acc_b')), 0,
          'no card of A points at B''s account');
select pg_temp.as_user('ua');
set local role authenticated;
select is(public.resolve_review(pg_temp.v('rev_card'),
            jsonb_build_object('card', jsonb_build_object('account_code', pg_temp.v('acc_a'))))->>'outcome',
          'card_registered', 'registering the card on A''s own account works');

-- ═══ DB-02: supersede is limited to the review's own candidates ══════════
select throws_ok($$ select public.resolve_review(pg_temp.v('rev_overlap'), jsonb_build_object('supersede', pg_temp.v('stm_b'))) $$,
                 'P0002', null, 'resolve_review {"supersede"} refuses another profile''s statement (E3)');
select throws_ok($$ select public.resolve_review(pg_temp.v('rev_overlap'),
                      jsonb_build_object('supersede', (select subject_code from public.match_reviews where review_code = pg_temp.v('rev_overlap')))) $$,
                 'P0002', null, 'and refuses to supersede the review''s own subject (DB-33)');
reset role;
select is((select status from public.statements where stmt_code = pg_temp.v('stm_b')), 'active', 'B''s statement stays active');
select is((select count(*)::int from public.statement_lines where stmt_code = pg_temp.v('stm_b') and is_current), 1,
          'and its line stays current');
select is((select string_agg(status, ',') from public.transactions where profile_code = pg_temp.v('pb')), 'posted',
          'and B''s transaction stays posted');
select pg_temp.as_user('ua');
set local role authenticated;
select is(public.resolve_review(pg_temp.v('rev_overlap'), jsonb_build_object('supersede', pg_temp.v('stm_a1')))->>'outcome',
          'superseded', 'superseding a real candidate works');
reset role;

-- ═══ link / create_new never reach another profile's rows ════════════════
-- Reviews are system-written; forge ones in A that point at B's rows to prove the guards.
select pg_temp.as_system();
insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason)
values (pg_temp.v('pa'), pg_temp.v('acc_a'), 'statement_line', pg_temp.v('line_b'), 'low_score');
select pg_temp.set('rev_forged', (select review_code from public.match_reviews
                                  where profile_code = pg_temp.v('pa') and subject_code = pg_temp.v('line_b')));
insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason)
select pg_temp.v('pa'), pg_temp.v('acc_a'), 'statement_line', l.line_code, 'low_score'
from public.statement_lines l where l.profile_code = pg_temp.v('pa') and l.is_current limit 1;
select pg_temp.set('rev_own', (select review_code from public.match_reviews
                               where profile_code = pg_temp.v('pa') and reason = 'low_score' and subject_code <> pg_temp.v('line_b')));
select pg_temp.as_user('ua');
set local role authenticated;
select throws_ok($$ select public.resolve_review(pg_temp.v('rev_own'), jsonb_build_object('link', pg_temp.v('txn_b'))) $$,
                 'P0002', null, 'link refuses another profile''s transaction');
select throws_ok($$ select public.resolve_review(pg_temp.v('rev_forged'), jsonb_build_object('create_new', true)) $$,
                 'P0002', null, 'create_new refuses a subject of another profile');
select throws_ok($$ select public.resolve_review(pg_temp.v('rev_forged'), jsonb_build_object('link',
                      (select txn_code from public.transactions where profile_code = pg_temp.v('pa') limit 1))) $$,
                 'P0002', null, 'link refuses a subject of another profile');

-- ═══ other RPCs that take codes ════════════════════════════════════════════
select throws_ok($$ select public.set_transaction_category(pg_temp.v('txn_b'), null) $$, '42501', null,
                 'set_transaction_category refuses another profile''s transaction');
select throws_ok($$ select public.set_transactions_category(array[pg_temp.v('txn_b')], null) $$, '42501', null,
                 'set_transactions_category refuses another profile''s transaction');
select throws_ok($$ select public.preview_rule(pg_temp.v('pb'), 'contains', 'NETFLIX', null) $$, '42501', null,
                 'preview_rule refuses another profile');
select throws_ok($$ select public.requeue_documents(pg_temp.v('pb')) $$, '42501', null,
                 'requeue_documents refuses another profile');
select is(public.requeue_documents(pg_temp.v('pa'), array[pg_temp.v('doc_b')]), 0,
          'requeue_documents ignores another profile''s document codes');
select throws_ok($$ select public.ingest_sms(pg_temp.v('pb'), '[]'::jsonb) $$, '42501', null,
                 'ingest_sms refuses another profile');

-- ═══ DB-03 / DB-14: composite FKs ══════════════════════════════════════════
select throws_ok($$ insert into public.email_routes (profile_code, mailbox_code, bank_code, sender_allowlist)
                    values (pg_temp.v('pa'), pg_temp.v('mbx_b'), 'FAB', '{*}') $$,
                 '23503', null, 'an owner cannot route mail from another profile''s mailbox (E4)');
select throws_ok($$ insert into public.merchant_profile_category (profile_code, merchant_code, category_code, source)
                    values (pg_temp.v('pa'), (select merchant_code from public.transactions where profile_code = pg_temp.v('pa')
                                               and merchant_code is not null limit 1), pg_temp.v('cat_b'), 'manual') $$,
                 '23503', null, 'nor use another profile''s category');
select throws_ok($$ insert into public.category_rules (profile_code, category_code, match_type, pattern, conditions)
                    select pg_temp.v('pa'), category_code, 'contains', 'X', jsonb_build_object('card_code', pg_temp.v('card_b'))
                    from public.categories where profile_code = pg_temp.v('pa') limit 1 $$,
                 '22023', null, 'nor write a rule conditioned on another profile''s card');
reset role;
select throws_ok($$ insert into public.cards (profile_code, account_code, bank_code, last4)
                    values (pg_temp.v('pa'), pg_temp.v('acc_b'), 'ADCB', '9999') $$,
                 '23503', null, 'structurally, a card cannot point at another profile''s account');
select throws_ok($$ insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description,
                      amount_original, currency_original, amount_source)
                    values (pg_temp.v('pa'), pg_temp.v('acc_b'), 'purchase', 'debit', '2026-08-01', 'X', 1, 'AED', 'manual') $$,
                 '23503', null, 'nor a transaction');
select throws_ok($$ insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, method, is_active)
                    values ((select txn_code from public.transactions where profile_code = pg_temp.v('pa') limit 1),
                            pg_temp.v('pa'), 'statement_line', pg_temp.v('line_b'), 'manual', false) $$,
                 '23503', null, 'nor evidence linking A''s transaction to B''s line');
select throws_ok($$ update public.sms_messages set account_code = pg_temp.v('acc_b')
                    where profile_code = pg_temp.v('pa') $$,
                 '23503', null, 'nor an SMS bound to another profile''s account');

-- ═══ DB-04: global tables are not readable by strangers ═══════════════════
select pg_temp.as_user('uc');
set local role authenticated;
select is((select count(*)::int from public.merchants), 0, 'a stranger sees no merchants (E16)');
select is((select count(*)::int from public.merchant_aliases), 0, 'nor merchant aliases');
select is((select count(*)::int from public.sms_templates), 0, 'nor SMS templates');
reset role;
select pg_temp.as_user('ua');
set local role authenticated;
select is((select count(*)::int from public.merchants),
          (select count(distinct merchant_code)::int from public.transactions where merchant_code is not null),
          'a member sees exactly the merchants of their own transactions');
select ok((select count(*) > 0 from public.sms_templates where bank_code = 'ADCB'),
          'and the bank formats of their own banks');
select is((select count(*)::int from public.sms_templates where bank_code = 'FAB' and source <> 'llm'), 0,
          'but not formats of banks they have no account at');
select throws_ok($$ select examples from public.sms_templates $$, '42501', null,
                 'template examples (raw SMS bodies) are never client-readable');
select lives_ok($$ select template_code, name, body_pattern, field_groups from public.sms_templates $$,
                'the other template columns stay readable');
reset role;

-- ═══ set_sms_template_active: only for proposals made for the caller ══════
select pg_temp.as_system();
select pg_temp.set('sms_b', (pg_temp.sms(pg_temp.v('pb'), 'XYZ alert: something odd happened', '2026-08-21 06:00:00+00'))->>'sms_code');
select pg_temp.set('tpl', public.propose_sms_template(pg_temp.v('sms_b'), jsonb_build_object(
  'bank_code', 'ADCB', 'sender_pattern', '^ADCB', 'body_pattern', 'XYZ alert: (something) odd',
  'field_groups', jsonb_build_object('merchant', 1), 'msg_kind', 'other', 'expect', '{}'::jsonb)));
select pg_temp.as_user('ua');
set local role authenticated;
select throws_ok($$ select public.set_sms_template_active(pg_temp.v('tpl'), true) $$, '42501', null,
                 'A cannot activate a template proposed for B''s message');
select throws_ok($$ select public.set_sms_template_active(pg_temp.v('tpl'), false) $$, '42501', null,
                 'nor reject (delete) it');
reset role;
select pg_temp.as_user('ub');
set local role authenticated;
select lives_ok($$ select public.set_sms_template_active(pg_temp.v('tpl'), false) $$, 'B can reject it');
reset role;
select is((select count(*)::int from public.sms_templates where template_code = pg_temp.v('tpl')), 0,
          'a rejected proposal nobody else waits on is deleted');

-- ═══ profile deletion still cascades through the composite FKs ═══════════
select pg_temp.as_system();
select lives_ok($$ delete from public.profiles where profile_code = pg_temp.v('pb') $$,
                'deleting a profile cascades through the composite FKs');

select * from finish();
rollback;

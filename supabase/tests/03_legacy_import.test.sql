-- Legacy import: profiles, rules, category choices, email config, pending
-- members. The legacy tables are mocked with the columns the import reads.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create table legacy.profiles (id int primary key, key text, name text);
create table legacy.categories (id int primary key, name text);
create table legacy.category_rules (id int primary key, name text, category_name text, match_type text, pattern text, active boolean);
create table legacy.category_overrides (id int primary key, fingerprint text, category_name text);
create table legacy.statements (id int primary key, profile_id int, bank_code text);
create table legacy.statement_lines (id int primary key, statement_id int, fingerprint text, category text,
  category_override text, transaction_date date, amount_aed numeric);
create table legacy.email_mailboxes (id int primary key, profile_id int, provider text, mailbox_email text,
  is_active boolean, sync_state_json json);
create table legacy.email_bank_routes (id int primary key, profile_id int, bank_code text, mailbox_id int,
  sender_allowlist_json json, subject_keywords_json json, attachment_filename_regex text,
  gmail_label_filter_json json, is_active boolean);

insert into legacy.profiles values (1, 'lhussain', 'Hussain'), (2, 'ltejasvie', 'Tejasvie');
insert into legacy.categories values (1, 'Dining'), (2, 'Pets'), (3, 'Uncategorized');
insert into legacy.category_rules values
  (1, 'seed-0-KFC', 'Dining', 'contains', 'KFC', true),
  (2, 'my vet', 'Pets', 'contains', 'VETCARE', true);
insert into legacy.statements values (10, 1, 'ADCB');
insert into legacy.statement_lines values
  (100, 10, 'fp-vet', 'Pets', null, '2026-07-01', 200),
  (101, 10, 'fp-kfc', 'Travel', 'Travel', '2026-07-02', 30),
  (102, 10, 'fp-mall', 'Dining', null, '2026-07-03', 80);
insert into legacy.email_mailboxes values (5, 1, 'gmail', 'me@example.com', true, '{"historyId":"42"}');
insert into legacy.email_bank_routes values (7, 1, 'ADCB', 5, '["alerts@adcb.com"]', '["statement"]', '.*\.pdf', '["Banks"]', true);

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'hussain@example.com', '{}', '{}', now(), now());

select lives_ok($$ select private.import_legacy_metadata('{"lhussain":"hussain@example.com","ltejasvie":"tej@example.com"}') $$,
                'import runs');
select is((select count(*)::int from public.profiles where key in ('lhussain', 'ltejasvie')), 2, 'both profiles imported');
select is((select count(*)::int from public.profile_members m join public.profiles p using (profile_code)
           where p.key = 'lhussain' and m.user_id = '22222222-2222-2222-2222-222222222222'), 1,
          'an existing user becomes owner immediately');
select is((select count(*)::int from private.pending_members pm join public.profiles p using (profile_code)
           where p.key = 'ltejasvie'), 1, 'a user who has not signed up yet is a pending member');
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'tej@example.com', '{}', '{}', now(), now());
select is((select role from public.profile_members m join public.profiles p using (profile_code)
           where p.key = 'ltejasvie' and m.user_id = '33333333-3333-3333-3333-333333333333'), 'owner',
          'signing up claims the pending membership');

select is((select count(*)::int from public.categories c join public.profiles p using (profile_code)
           where p.key = 'lhussain' and c.name = 'Pets'), 1, 'legacy-only categories are created');
select is((select count(*)::int from public.category_rules r join public.profiles p using (profile_code)
           where p.key = 'lhussain' and r.source = 'legacy'), 1, 'user rules import; seed rules do not duplicate');
select is((select count(*)::int from public.email_routes r join public.profiles p using (profile_code)
           where p.key = 'lhussain' and r.sender_allowlist = array['alerts@adcb.com']), 1, 'email routes import');
select lives_ok($$ select private.import_legacy_metadata('{}') $$, 'import is idempotent');
select is((select count(*)::int from public.profiles where key = 'lhussain'), 1, 'no duplicate profile on re-run');

-- Re-parse the legacy statement through v2, then apply the staged choices.
create temp table k as select profile_code from public.profiles where key = 'lhussain';
insert into public.documents (doc_code, profile_code, storage_path, original_filename, sha256, size_bytes, source)
select 'doc_00000000000000000000000001', profile_code, 'x', 'legacy.pdf', repeat('b', 64), 1, 'legacy' from k;
select public.ingest_parsed_document('doc_00000000000000000000000001', jsonb_build_object(
  'contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB', 'document_kind', 'statement_pdf',
  'statements', jsonb_build_array(jsonb_build_object(
    'kind', 'statement', 'bank_code', 'ADCB', 'statement_date', '2026-07-31', 'period_start', '2026-07-01',
    'period_end', '2026-07-31', 'primary_card_last4', '1111', 'totals', '{}'::jsonb, 'lines', jsonb_build_array(
      jsonb_build_object('line_no', 1, 'txn_date', '2026-07-01', 'description_raw', 'VETCARE CLINIC', 'amount_original', '200.00',
        'currency_original', 'AED', 'amount_aed', '200.00', 'direction', 'debit', 'kind', 'purchase', 'card_last4', '1111',
        'legacy_fingerprint', 'fp-vet'),
      jsonb_build_object('line_no', 2, 'txn_date', '2026-07-02', 'description_raw', 'KFC DUBAI', 'amount_original', '30.00',
        'currency_original', 'AED', 'amount_aed', '30.00', 'direction', 'debit', 'kind', 'purchase', 'card_last4', '1111',
        'legacy_fingerprint', 'fp-kfc'),
      jsonb_build_object('line_no', 3, 'txn_date', '2026-07-03', 'description_raw', 'MALL OF THE EMIRATES', 'amount_original', '80.00',
        'currency_original', 'AED', 'amount_aed', '80.00', 'direction', 'debit', 'kind', 'purchase', 'card_last4', '1111',
        'legacy_fingerprint', 'fp-mall')
    )))));

select is(private.apply_legacy_category_choices(), 2, 'override + edited line category applied; agreeing line skipped');
select is((select c.name from public.transactions t join public.categories c on c.category_code = t.effective_category_code
           where t.description = 'KFC DUBAI'), 'Travel', 'a legacy override beats the KFC→Dining rule');
select is((select c.name from public.transactions t join public.categories c on c.category_code = t.effective_category_code
           where t.description = 'VETCARE CLINIC'), 'Pets', 'the imported legacy rule categorises VETCARE');
select ok((select manual_category_code is null from public.transactions where description = 'VETCARE CLINIC'),
          'a legacy category that v2 rules already agree with is not frozen as manual');
select is((select c.name from public.transactions t join public.categories c on c.category_code = t.effective_category_code
           where t.description = 'MALL OF THE EMIRATES'), 'Dining', 'an edited legacy line category is kept');
select is(private.apply_legacy_category_choices(), 0, 'applying again changes nothing');
select ok((select count(*) > 0 from private.legacy_parity_report()), 'parity report runs');

select * from finish();
rollback;

-- Legacy import: profiles, rules, category choices, email config, pending
-- members, parity. The legacy tables are mocked in a test-only schema with the
-- real legacy column types (varchar, enums), so the suite runs on a DB that
-- already holds a real `legacy` schema and imported profiles.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create schema t03_legacy;
create type t03_legacy.direction as enum ('debit', 'credit');
create type t03_legacy.matchtype as enum ('exact', 'prefix', 'contains', 'regex');
create type t03_legacy.provider as enum ('gmail', 'microsoft');
create table t03_legacy.profiles (id int primary key, key varchar(64) not null, name varchar(128) not null);
create table t03_legacy.categories (id int primary key, name varchar(128));
create table t03_legacy.category_rules (id int primary key, name varchar(128), category_name varchar(128),
  match_type t03_legacy.matchtype, pattern varchar(256), active boolean);
create table t03_legacy.category_overrides (id int primary key, fingerprint varchar(64), category_name varchar(128));
create table t03_legacy.statements (id int primary key, profile_id int, bank_code varchar(16), statement_date date);
create table t03_legacy.statement_lines (id int primary key, statement_id int, fingerprint varchar(64),
  category varchar(128), category_override varchar(128), transaction_date date, amount_aed numeric(14,2),
  direction t03_legacy.direction);
create table t03_legacy.email_mailboxes (id int primary key, profile_id int, provider t03_legacy.provider,
  mailbox_email varchar(256), is_active boolean, sync_state_json json);
create table t03_legacy.email_bank_routes (id int primary key, profile_id int, bank_code varchar(16), mailbox_id int,
  sender_allowlist_json json, subject_keywords_json json, attachment_filename_regex varchar(256),
  gmail_label_filter_json json, is_active boolean);

-- Unique keys per run (the shared DB may already hold real profiles).
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
insert into k values ('h', 't03h' || left(md5(random()::text), 8)), ('t', 't03t' || left(md5(random()::text), 8)),
                     ('sq', 't03s' || left(md5(random()::text), 8)),
                     ('uh', gen_random_uuid()::text), ('ut', gen_random_uuid()::text), ('us', gen_random_uuid()::text);

insert into t03_legacy.profiles values (1, pg_temp.v('h'), 'Hussain'), (2, pg_temp.v('t'), 'Tejasvie');
insert into t03_legacy.categories values (1, 'Dining'), (2, 'Pets'), (3, 'Uncategorized');
insert into t03_legacy.category_rules values
  (1, 'seed-0-KFC', 'Dining', 'contains', 'KFC', true),
  (2, 'my vet', 'Pets', 'contains', 'VETCARE', true);
insert into t03_legacy.statements values (10, 1, 'ADCB', '2026-07-31');
insert into t03_legacy.statement_lines values
  (100, 10, 't03-fp-vet', 'Pets', null, '2026-07-01', 200, 'debit'),
  (101, 10, 't03-fp-kfc', 'Travel', 'Travel', '2026-07-02', 30, 'debit'),
  (102, 10, 't03-fp-mall', 'Dining', null, '2026-07-03', 80, 'debit'),
  (103, 10, 't03-fp-lost', 'Dining', null, '2026-07-04', 45, 'debit');
insert into t03_legacy.email_mailboxes values (5, 1, 'gmail', 'me@example.com', true, '{"historyId":"42"}');
insert into t03_legacy.email_bank_routes values (7, 1, 'ADCB', 5, '["alerts@adcb.com"]', '["statement"]', '.*\.pdf', '["Banks"]', true);

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('uh')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', pg_temp.v('h') || '@example.com', '{}', '{}', now(), now(), now());

select lives_ok(format($$ select private.import_legacy_metadata(%L::jsonb, 't03_legacy') $$,
                       jsonb_build_object(pg_temp.v('h'), pg_temp.v('h') || '@example.com',
                                          pg_temp.v('t'), pg_temp.v('t') || '@example.com')),
                'import runs against varchar/enum legacy columns');
select is((select count(*)::int from public.profiles where key in (pg_temp.v('h'), pg_temp.v('t'))), 2, 'both profiles imported');
select is((select count(*)::int from private.legacy_import_profiles where legacy_key in (pg_temp.v('h'), pg_temp.v('t'))), 2,
          'and recorded as created by the import');
select is((select count(*)::int from public.profile_members m join public.profiles p using (profile_code)
           where p.key = pg_temp.v('h') and m.user_id = pg_temp.v('uh')::uuid), 1,
          'an existing user becomes owner immediately');
select is((select count(*)::int from private.pending_members pm join public.profiles p using (profile_code)
           where p.key = pg_temp.v('t')), 1, 'a user who has not signed up yet is a pending member');
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('ut')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', pg_temp.v('t') || '@example.com', '{}', '{}', now(), now(), now());
select is((select role from public.profile_members m join public.profiles p using (profile_code)
           where p.key = pg_temp.v('t') and m.user_id = pg_temp.v('ut')::uuid), 'owner',
          'signing up claims the pending membership');

select is((select count(*)::int from public.categories c join public.profiles p using (profile_code)
           where p.key = pg_temp.v('h') and c.name = 'Pets'), 1, 'legacy-only categories are created');
select is((select count(*)::int from public.category_rules r join public.profiles p using (profile_code)
           where p.key = pg_temp.v('h') and r.source = 'legacy'), 1, 'user rules import; seed rules do not duplicate');
select is((select count(*)::int from public.email_routes r join public.profiles p using (profile_code)
           where p.key = pg_temp.v('h') and r.sender_allowlist = array['alerts@adcb.com']), 1, 'email routes import');
select lives_ok($$ select private.import_legacy_metadata('{}', 't03_legacy') $$, 'import is idempotent');
select is((select count(*)::int from public.profiles where key = pg_temp.v('h')), 1, 'no duplicate profile on re-run');
select is((select count(*)::int from cron.job where jobname = 'ledger-legacy-choices'), 1,
          'the import (re)schedules the nightly choices job');

-- ── DB-05: a squatted key is never adopted ─────────────────────────────────
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('us')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', pg_temp.v('sq') || '@stranger.dev', '{}', '{}', now(), now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('us'), 'role', 'authenticated')::text, true);
set local role authenticated;
select public.create_profile(pg_temp.v('sq'), 'Squatter');
reset role;
select set_config('request.jwt.claims', '', true);
insert into t03_legacy.profiles values (3, pg_temp.v('sq'), 'Real owner');
select throws_ok($$ select private.import_legacy_metadata('{}', 't03_legacy') $$, '23505', null,
                 'the import refuses a key someone created before it ran');
select is((select count(*)::int from public.profile_members m join public.profiles p using (profile_code)
           where p.key = pg_temp.v('sq')), 1, 'the squatter''s profile gained no members');
delete from t03_legacy.profiles where id = 3;

-- ── re-parse the legacy statement through v2, then apply the staged choices ─
create temp table kp as select profile_code from public.profiles where key = pg_temp.v('h');
grant all on kp to authenticated;
insert into public.documents (doc_code, profile_code, storage_path, original_filename, sha256, size_bytes, source)
select 'doc_00000000000000000000t03001', profile_code, 'x', 'legacy.pdf', repeat('b', 64), 1, 'legacy' from kp;
select public.ingest_parsed_document('doc_00000000000000000000t03001', jsonb_build_object(
  'contract_version', 1, 'parser_version', 'test', 'bank_code', 'ADCB', 'document_kind', 'statement_pdf',
  'statements', jsonb_build_array(jsonb_build_object(
    'kind', 'statement', 'bank_code', 'ADCB', 'statement_date', '2026-07-31', 'period_start', '2026-07-01',
    'period_end', '2026-07-31', 'primary_card_last4', '1111', 'totals', '{}'::jsonb, 'lines', jsonb_build_array(
      jsonb_build_object('line_no', 1, 'txn_date', '2026-07-01', 'description_raw', 'VETCARE CLINIC', 'amount_original', '200.00',
        'currency_original', 'AED', 'amount_aed', '200.00', 'direction', 'debit', 'kind', 'purchase', 'card_last4', '1111',
        'legacy_fingerprint', 't03-fp-vet'),
      jsonb_build_object('line_no', 2, 'txn_date', '2026-07-02', 'description_raw', 'KFC DUBAI', 'amount_original', '30.00',
        'currency_original', 'AED', 'amount_aed', '30.00', 'direction', 'debit', 'kind', 'purchase', 'card_last4', '1111',
        'legacy_fingerprint', 't03-fp-kfc'),
      jsonb_build_object('line_no', 3, 'txn_date', '2026-07-03', 'description_raw', 'MALL OF THE EMIRATES', 'amount_original', '80.00',
        'currency_original', 'AED', 'amount_aed', '80.00', 'direction', 'debit', 'kind', 'purchase', 'card_last4', '1111',
        'legacy_fingerprint', 't03-fp-mall')
    )))));

create function pg_temp.cat(p_desc text) returns text language sql as $$
  select c.name from public.transactions t join public.categories c on c.category_code = t.effective_category_code
  where t.profile_code = (select profile_code from kp) and t.description = p_desc $$;

select is(private.apply_legacy_category_choices(), 2, 'override + edited line category applied; agreeing line skipped');
select is(pg_temp.cat('KFC DUBAI'), 'Travel', 'a legacy override beats the KFC→Dining rule');
select is(pg_temp.cat('VETCARE CLINIC'), 'Pets', 'the imported legacy rule categorises VETCARE');
select ok((select manual_category_code is null from public.transactions
           where profile_code = (select profile_code from kp) and description = 'VETCARE CLINIC'),
          'a legacy category that v2 rules already agree with is not frozen as manual');
select is(pg_temp.cat('MALL OF THE EMIRATES'), 'Dining', 'an edited legacy line category is kept');
select is(private.apply_legacy_category_choices(), 0, 'applying again changes nothing');

-- ── DB-12: a later user edit is never overwritten ──────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uh'), 'role', 'authenticated')::text, true);
set local role authenticated;
select public.set_transaction_category(
  (select txn_code from public.transactions where profile_code = (select profile_code from kp) and description = 'KFC DUBAI'),
  (select category_code from public.categories where profile_code = (select profile_code from kp) and name = 'Grocery'),
  true);
reset role;
select set_config('request.jwt.claims', '', true);
select is(pg_temp.cat('KFC DUBAI'), 'Grocery', 'the owner applies Grocery to the merchant (manual cleared)');
select is(private.apply_legacy_category_choices(), 0, 'the next run applies nothing');
select is(pg_temp.cat('KFC DUBAI'), 'Grocery', 'and the user''s edit survives');
select is((select count(*)::int from private.legacy_choice_applications where profile_code = (select profile_code from kp)), 3,
          'each matched transaction was evaluated exactly once');
select is((select array_agg(legacy_fingerprint order by legacy_fingerprint) from private.legacy_unmatched_choices()
           where profile_key = pg_temp.v('h')), array['t03-fp-lost'],
          'a choice whose line never re-parsed is reported as unmatched');

-- the cron wrapper stops itself once nothing is pending or 30 days have passed
update private.legacy_category_choices set staged_at = now() - interval '31 days';
select lives_ok($$ select private.legacy_choices_cron() $$, 'the nightly job runs');
select is((select count(*)::int from cron.job where jobname = 'ledger-legacy-choices'), 0,
          'and unschedules itself 30 days after staging');

-- ── DB-11 / DP-05: parity on varchar legacy columns, with line-level loss ──
select lives_ok($$ select * from private.legacy_parity_report('t03_legacy') $$,
                'the parity report runs against varchar/enum legacy columns');
select results_eq(
  format($$ select legacy_lines, v2_lines, legacy_lines_missing, legacy_aed_missing
            from private.legacy_parity_report('t03_legacy') where profile_key = %L and bank_code = 'ADCB' $$, pg_temp.v('h')),
  $$ values (4::bigint, 3::bigint, 1::bigint, 45.00::numeric) $$,
  'month sums plus the one legacy line with no current v2 line');
select results_eq(
  format($$ select legacy_fingerprint, amount_aed from private.legacy_missing_lines('t03_legacy') where profile_key = %L $$,
         pg_temp.v('h')),
  $$ values ('t03-fp-lost'::text, 45.00::numeric) $$,
  'legacy_missing_lines lists the lost line');

select * from finish();
rollback;

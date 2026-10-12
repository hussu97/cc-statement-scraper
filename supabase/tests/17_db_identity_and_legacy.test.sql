-- Identity and legacy (20261009000500_db_identity_and_legacy.sql): DB-21, DB-23, X-23, DP-19.
-- Runs on a non-empty DB: every key is unique to this run.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.user(p_email text, p_confirmed boolean default true) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          email_confirmed_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_email,
          '{}', '{}', now(), now(), case when p_confirmed then now() end)
  returning id::text $$;
create function pg_temp.as_user(p_uid text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true) $$;
create function pg_temp.as_system() returns text language sql as $$
  select set_config('request.jwt.claims', '', true) $$;

select pg_temp.set('run', left(gen_random_uuid()::text, 8));
select pg_temp.set('uo', pg_temp.user('t17-owner-' || pg_temp.v('run') || '@test.dev'));
select pg_temp.set('uv', pg_temp.user('t17-viewer-' || pg_temp.v('run') || '@test.dev'));
select pg_temp.as_user(pg_temp.v('uo'));
set local role authenticated;
select pg_temp.set('p', public.create_profile('t17-' || pg_temp.v('run'), 'Identity'));
select is(public.add_profile_member(pg_temp.v('p'), 't17-viewer-' || pg_temp.v('run') || '@test.dev', 'viewer'), 'added',
          'a confirmed account is added');

-- ═══ DB-23: invites attach to confirmed emails only ═══════════════════════
select is(public.add_profile_member(pg_temp.v('p'), 't17-new-' || pg_temp.v('run') || '@test.dev', 'viewer'), 'invited',
          'an unknown email is invited');
reset role;
select pg_temp.as_system();
select pg_temp.set('un', pg_temp.user('t17-new-' || pg_temp.v('run') || '@test.dev', false));
select is((select count(*)::int from public.profile_members where profile_code = pg_temp.v('p')
           and user_id = pg_temp.v('un')::uuid), 0, 'signing up with the invited email does not attach before confirmation (DB-23)');
update auth.users set email_confirmed_at = now() where id = pg_temp.v('un')::uuid;
select is((select role from public.profile_members where profile_code = pg_temp.v('p') and user_id = pg_temp.v('un')::uuid),
          'viewer', 'confirming the email attaches the invite');
select pg_temp.set('uu', pg_temp.user('t17-unconfirmed-' || pg_temp.v('run') || '@test.dev', false));
select pg_temp.as_user(pg_temp.v('uo'));
set local role authenticated;
select is(public.add_profile_member(pg_temp.v('p'), 't17-unconfirmed-' || pg_temp.v('run') || '@test.dev', 'owner'), 'invited',
          'an existing but unconfirmed account is invited, not added');
reset role;
select pg_temp.as_system();
select is((select count(*)::int from public.profile_members where profile_code = pg_temp.v('p')
           and user_id = pg_temp.v('uu')::uuid), 0, 'and is not a member yet');
select pg_temp.set('uchg', pg_temp.user('t17-changer-' || pg_temp.v('run') || '@test.dev'));
insert into private.pending_members (profile_code, email, role)
values (pg_temp.v('p'), 't17-target-' || pg_temp.v('run') || '@test.dev', 'viewer');
update auth.users set email = 't17-target-' || pg_temp.v('run') || '@test.dev' where id = pg_temp.v('uchg')::uuid;
select is((select role from public.profile_members where profile_code = pg_temp.v('p') and user_id = pg_temp.v('uchg')::uuid),
          'viewer', 'a confirmed email change to an invited address attaches the invite');

-- ═══ DP-19: legacy category aliases ═══════════════════════════════════════
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'FAB');
select pg_temp.set('acc', (select account_code from public.accounts where profile_code = pg_temp.v('p')));
insert into public.statements (profile_code, account_code, kind, statement_date)
values (pg_temp.v('p'), pg_temp.v('acc'), 'statement', current_date - 30);
select pg_temp.set('stmt', (select stmt_code from public.statements where profile_code = pg_temp.v('p')));
insert into public.statement_lines (stmt_code, profile_code, account_code, evidence_type, line_no, line_key, occurrence,
  txn_date, description_raw, description, amount_original, currency_original, amount_aed, direction, kind,
  legacy_fingerprint, raw, source_doc_codes)
values (pg_temp.v('stmt'), pg_temp.v('p'), pg_temp.v('acc'), 'statement_line', 1, 'k1-' || pg_temp.v('run'), 1,
        current_date - 40, 'T17 ZQX PLACE', 'T17 ZQX PLACE', 60, 'AED', 60, 'debit', 'purchase', 'fp-' || pg_temp.v('run'),
        '{}', '{}');
select private.new_transaction_from_line((select line_code from public.statement_lines where profile_code = pg_temp.v('p')));
insert into private.legacy_category_choices (profile_code, legacy_fingerprint, category_name, source)
values (pg_temp.v('p'), 'fp-' || pg_temp.v('run'), 'Entretainment', 'override'),
       (pg_temp.v('p'), 'fp-missing-' || pg_temp.v('run'), 'No Such Category', 'line');
select private.apply_legacy_category_choices();
select is((select c.name from public.transactions t join public.categories c on c.category_code = t.manual_category_code
           where t.profile_code = pg_temp.v('p') and t.description = 'T17 ZQX PLACE'),
          'Entertainment', 'a choice on the legacy typo category applies through its alias (DP-19)');
select is((select array_agg(category_name) from private.legacy_unresolved_category_names()
           where profile_key = 't17-' || pg_temp.v('run')),
          array['No Such Category'], 'an unresolvable legacy category name is reported for finalize');

-- ═══ X-23: no client grants on legacy tables ══════════════════════════════
select is((select count(*)::int from information_schema.role_table_grants
           where table_schema = 'legacy' and grantee in ('anon', 'authenticated')), 0,
          'anon / authenticated hold no grant on any legacy table (X-23)');

-- ═══ DB-21: delete_profile archives ════════════════════════════════════════════════
insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
values (pg_temp.v('p'), pg_temp.v('p') || '/t17.pdf', 't17.pdf', encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'upload');
insert into public.email_mailboxes (profile_code, provider, mailbox_email)
values (pg_temp.v('p'), 'gmail', 't17-' || pg_temp.v('run') || '@mail.dev');
select pg_temp.set('mbx', (select mailbox_code from public.email_mailboxes where profile_code = pg_temp.v('p')));
select pg_temp.as_user(pg_temp.v('uo'));
set local role authenticated;
select public.set_profile_secret(pg_temp.v('p'), 'ADCB_PDF_PASSWORD', 'secret-' || pg_temp.v('run'));
select public.set_mailbox_secret(pg_temp.v('mbx'), 'refresh_token', 'token-' || pg_temp.v('run'));
-- user-made rows whose cascade used to fail on trg_audit's FK
insert into public.budgets (profile_code, amount_aed, effective_from) values (pg_temp.v('p'), 1000, date_trunc('month', current_date));
reset role;
select pg_temp.as_system();
select is((select count(*)::int from vault.secrets where name like 'profile:' || pg_temp.v('p') || ':%'
           or name like 'mailbox:' || pg_temp.v('mbx') || ':%'), 2, 'the profile has two Vault secrets');

select pg_temp.as_user(pg_temp.v('uv'));
set local role authenticated;
select throws_ok($$ select public.delete_profile(pg_temp.v('p'), 't17-' || pg_temp.v('run')) $$, '42501', null,
                 'a viewer cannot delete the profile');
reset role;
select pg_temp.as_user(pg_temp.v('uo'));
set local role authenticated;
select throws_ok($$ select public.delete_profile(pg_temp.v('p'), 'wrong-key') $$, '22023', null,
                 'the confirmation must be the profile key');
select pg_temp.set('del', public.delete_profile(pg_temp.v('p'), 't17-' || pg_temp.v('run'))::text);
reset role;
select pg_temp.as_system();
select is((pg_temp.v('del')::jsonb->>'mailboxes_disabled')::int, 1, 'an owner archives the profile with a user JWT (DB-21)');
select ok((select archived_at is not null from public.profiles where profile_code = pg_temp.v('p')),
          'the profile is archived, not deleted');
select is((select count(*)::int from public.documents where profile_code = pg_temp.v('p')), 1, 'its documents are kept');
select is((select count(*)::int from public.budgets where profile_code = pg_temp.v('p')), 1, 'and its user rows');
select is((select count(*)::int from vault.secrets where name like 'profile:' || pg_temp.v('p') || ':%'
           or name like 'mailbox:' || pg_temp.v('mbx') || ':%'), 2, 'and its Vault secrets');
select ok(not exists (select 1 from pgmq.q_storage_cleanup where message->'paths' ? (pg_temp.v('p') || '/t17.pdf')),
          'its PDFs are not queued for Storage cleanup');
select ok(not (select enabled from public.email_mailboxes where mailbox_code = pg_temp.v('mbx')), 'its mailbox is disabled');

select pg_temp.as_user(pg_temp.v('uo'));
set local role authenticated;
select is((select count(*)::int from public.profiles where profile_code = pg_temp.v('p')), 0,
          'an archived profile is invisible to its owner');
select throws_ok($$ select public.list_profile_members(pg_temp.v('p')) $$, '42501', null,
                 'and its RPCs refuse');
select throws_ok($$ select public.delete_profile(pg_temp.v('p'), 't17-' || pg_temp.v('run')) $$, '42501', null,
                 'it cannot be archived twice');
select throws_ok($$ select public.restore_profile(pg_temp.v('p')) $$, '42501', null,
                 'a user cannot restore a profile');
reset role;
select pg_temp.as_system();
select is((public.restore_profile(pg_temp.v('p'))->>'mailboxes_enabled')::int, 1, 'the service role restores it');
select ok((select archived_at is null and archive_state is null from public.profiles where profile_code = pg_temp.v('p')),
          'the profile is active again');
select ok((select enabled from public.email_mailboxes where mailbox_code = pg_temp.v('mbx')), 'and its mailbox re-enabled');
select throws_ok($$ select public.restore_profile(pg_temp.v('p')) $$, 'P0002', null, 'only an archived profile is restored');

select * from finish();
rollback;

-- Legacy → v2 import, run once at cutover (see PRODUCTION.md "Cutover").
--
-- Data that moves by SQL (here): profiles, categories, user rules, category
-- choices (overrides and per-line categories), email mailboxes and routes.
-- Data that moves by script (scripts/migrate_legacy.py): PDFs from GCS into
-- Storage as documents(source='legacy') — the worker re-parses them through the
-- v2 pipeline — and PDF passwords / OAuth tokens (Fernet-encrypted in legacy)
-- into Vault.
-- The legacy schema itself is kept untouched as the historical record.

-- ── pending invites (also used by add_profile_member for not-yet-signed-up users)
create table private.pending_members (
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  email text not null,
  role text not null default 'owner' check (role in ('owner', 'viewer')),
  created_at timestamptz not null default now(),
  primary key (profile_code, email)
);

create or replace function private.attach_pending_members()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profile_members (profile_code, user_id, role)
  select p.profile_code, new.id, p.role
  from private.pending_members p
  where lower(p.email) = lower(new.email)
  on conflict (profile_code, user_id) do nothing;
  delete from private.pending_members where lower(email) = lower(new.email);
  return new;
end;
$$;
create trigger ledger_attach_pending_members
  after insert on auth.users
  for each row execute function private.attach_pending_members();

-- add_profile_member: invite by email even before the person signs up.
drop function public.add_profile_member(text, text, text);
create or replace function public.add_profile_member(p_profile_code text, p_email text, p_role text default 'viewer')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  perform private.assert_member(p_profile_code, true);
  if p_role not in ('owner', 'viewer') then
    raise exception 'invalid role %', p_role using errcode = '22023';
  end if;
  select id into v_user from auth.users where lower(email) = lower(p_email);
  if v_user is null then
    insert into private.pending_members (profile_code, email, role) values (p_profile_code, lower(p_email), p_role)
    on conflict (profile_code, email) do update set role = excluded.role;
    return 'invited';
  end if;
  insert into public.profile_members (profile_code, user_id, role) values (p_profile_code, v_user, p_role)
  on conflict (profile_code, user_id) do update set role = excluded.role;
  return 'added';
end;
$$;

-- ── staged category choices from legacy, applied once lines are re-parsed ──
create table private.legacy_category_choices (
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  legacy_fingerprint text not null,
  category_name text not null,
  source text not null check (source in ('override', 'line')),
  applied_at timestamptz,
  primary key (profile_code, legacy_fingerprint, source)
);

-- p_member_emails: {"alice": "someone@example.com", ...} maps legacy profile
-- keys to the people who should own them in v2.
create or replace function private.import_legacy_metadata(p_member_emails jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_profile text;
  v_out jsonb := '{}'::jsonb;
  v_n int;
begin
  if to_regclass('legacy.profiles') is null then
    return jsonb_build_object('skipped', 'no legacy schema');
  end if;

  for r in execute 'select id, key, name from legacy.profiles order by id' loop
    insert into public.profiles (key, name) values (r.key, r.name)
    on conflict (key) do nothing;
    select profile_code into v_profile from public.profiles where key = r.key;
    insert into public.profile_state (profile_code) values (v_profile) on conflict do nothing;
    perform private.seed_profile_defaults(v_profile);

    if p_member_emails ? r.key then
      insert into private.pending_members (profile_code, email, role)
      values (v_profile, lower(p_member_emails->>r.key), 'owner')
      on conflict (profile_code, email) do nothing;
      insert into public.profile_members (profile_code, user_id, role)
      select v_profile, u.id, 'owner' from auth.users u where lower(u.email) = lower(p_member_emails->>r.key)
      on conflict do nothing;
      delete from private.pending_members pm
      where pm.profile_code = v_profile
        and exists (select 1 from auth.users u where lower(u.email) = lower(pm.email));
    end if;

    -- Categories that exist in legacy but not in the v2 defaults.
    execute $q$
      insert into public.categories (profile_code, name, kind, sort_order, color_token)
      select $1, c.name, 'spend', 500, 'cat-12'
      from legacy.categories c
      where c.name <> 'Uncategorized'
        and not exists (select 1 from public.categories x where x.profile_code = $1 and lower(x.name) = lower(c.name))
      on conflict do nothing $q$ using v_profile;

    -- User-created legacy rules (seed-* rules are already the v2 defaults).
    execute $q$
      insert into public.category_rules (profile_code, category_code, name, match_type, pattern, active, source)
      select $1, c.category_code, lr.name, lr.match_type::text, lr.pattern, lr.active, 'legacy'
      from legacy.category_rules lr
      join public.categories c on c.profile_code = $1 and lower(c.name) = lower(lr.category_name)
      where lr.name not like 'seed-%'
        and not exists (select 1 from public.category_rules x
                        where x.profile_code = $1 and x.pattern = lr.pattern and x.match_type = lr.match_type::text) $q$
      using v_profile;
    get diagnostics v_n = row_count;

    -- Category choices to re-apply once the PDFs are re-parsed. Fingerprints are
    -- global in legacy; scope them through the line's statement → profile.
    execute $q$
      insert into private.legacy_category_choices (profile_code, legacy_fingerprint, category_name, source)
      select distinct $1, l.fingerprint, coalesce(o.category_name, l.category_override), 'override'
      from legacy.statement_lines l
      join legacy.statements s on s.id = l.statement_id
      left join legacy.category_overrides o on o.fingerprint = l.fingerprint
      where s.profile_id = $2 and l.fingerprint is not null
        and coalesce(o.category_name, l.category_override) is not null
      on conflict do nothing $q$ using v_profile, r.id;
    execute $q$
      insert into private.legacy_category_choices (profile_code, legacy_fingerprint, category_name, source)
      select distinct on (l.fingerprint) $1, l.fingerprint, l.category, 'line'
      from legacy.statement_lines l
      join legacy.statements s on s.id = l.statement_id
      where s.profile_id = $2 and l.fingerprint is not null
        and l.category is not null and l.category <> 'Uncategorized'
      order by l.fingerprint, l.id desc
      on conflict do nothing $q$ using v_profile, r.id;

    -- Email ingestion config (OAuth refresh tokens move to Vault via the script).
    execute $q$
      insert into public.email_mailboxes (profile_code, provider, mailbox_email, enabled, sync_state)
      select $1, case m.provider::text when 'microsoft' then 'outlook' else m.provider::text end, m.mailbox_email, m.is_active, coalesce(m.sync_state_json::jsonb, '{}'::jsonb)
      from legacy.email_mailboxes m where m.profile_id = $2
      on conflict (profile_code, provider, mailbox_email) do nothing $q$ using v_profile, r.id;
    execute $q$
      insert into public.email_routes (profile_code, mailbox_code, bank_code, enabled, sender_allowlist,
        subject_keywords, attachment_filename_regex, gmail_label_filter)
      select $1, nm.mailbox_code, rt.bank_code, rt.is_active,
             coalesce(array(select jsonb_array_elements_text(coalesce(rt.sender_allowlist_json::jsonb, '[]'))), '{}'),
             coalesce(array(select jsonb_array_elements_text(coalesce(rt.subject_keywords_json::jsonb, '[]'))), '{}'),
             rt.attachment_filename_regex,
             coalesce(array(select jsonb_array_elements_text(
               case jsonb_typeof(rt.gmail_label_filter_json::jsonb)
                 when 'array' then rt.gmail_label_filter_json::jsonb
                 when 'object' then coalesce(rt.gmail_label_filter_json::jsonb->'labels', '[]')
                 else '[]' end)), '{}')
      from legacy.email_bank_routes rt
      join legacy.email_mailboxes lm on lm.id = rt.mailbox_id
      join public.email_mailboxes nm on nm.profile_code = $1
                                     and nm.provider = case lm.provider::text when 'microsoft' then 'outlook' else lm.provider::text end
                                     and nm.mailbox_email = lm.mailbox_email
      where rt.profile_id = $2
      on conflict (profile_code, bank_code) do nothing $q$ using v_profile, r.id;

    v_out := v_out || jsonb_build_object(r.key, jsonb_build_object(
      'profile_code', v_profile,
      'legacy_rules_imported', v_n,
      'category_choices', (select count(*) from private.legacy_category_choices where profile_code = v_profile)
    ));
  end loop;
  return v_out;
end;
$$;

-- Apply staged legacy category choices to re-parsed transactions. An override
-- always applies; a plain legacy line category applies only where v2's rules
-- disagree (i.e. the person had edited it). Idempotent; run after re-parsing.
create or replace function private.apply_legacy_category_choices()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  with choice as (
    select distinct on (t.txn_code) t.txn_code, c.category_code, ch.profile_code, ch.legacy_fingerprint, ch.source
    from private.legacy_category_choices ch
    join public.statement_lines l on l.profile_code = ch.profile_code and l.legacy_fingerprint = ch.legacy_fingerprint
                                 and l.is_current
    join public.transaction_evidence e on e.line_code = l.line_code and e.is_active
    join public.transactions t on t.txn_code = e.txn_code
    join public.categories c on c.profile_code = ch.profile_code and lower(c.name) = lower(ch.category_name)
    where t.manual_category_code is null
      and (ch.source = 'override' or t.effective_category_code is distinct from c.category_code)
    order by t.txn_code, case ch.source when 'override' then 0 else 1 end
  ),
  upd as (
    update public.transactions t set manual_category_code = choice.category_code
    from choice where t.txn_code = choice.txn_code
      and t.effective_category_code is distinct from choice.category_code
    returning t.txn_code
  )
  select count(*) into v_count from upd;

  update private.legacy_category_choices ch set applied_at = now()
  where ch.applied_at is null
    and exists (select 1 from public.statement_lines l
                where l.profile_code = ch.profile_code and l.legacy_fingerprint = ch.legacy_fingerprint and l.is_current);
  return v_count;
end;
$$;

-- Parity report: legacy vs v2 per profile/bank/month (line count and AED sum).
-- Expected deltas: SIB history duplicates disappear (they were double counted),
-- Mashreq FX rows gain an AED estimate.
create or replace function private.legacy_parity_report()
returns table (profile_key text, bank_code text, month date, legacy_lines bigint, v2_lines bigint,
               legacy_aed numeric, v2_aed numeric, delta_aed numeric)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if to_regclass('legacy.statement_lines') is null then
    return;
  end if;
  return query execute $q$
    with l as (
      select p.key as profile_key, s.bank_code, date_trunc('month', sl.transaction_date)::date as month,
             count(*) as n, sum(coalesce(sl.amount_aed, 0)) as aed
      from legacy.statement_lines sl
      join legacy.statements s on s.id = sl.statement_id
      join legacy.profiles p on p.id = s.profile_id
      group by 1, 2, 3
    ),
    v as (
      select p.key as profile_key, a.bank_code, date_trunc('month', t.txn_date)::date as month,
             count(*) as n,
             sum(case when t.direction = 'debit' then coalesce(t.amount_aed, 0) else -coalesce(t.amount_aed, 0) end) as aed
      from public.transactions t
      join public.accounts a on a.account_code = t.account_code
      join public.profiles p on p.profile_code = t.profile_code
      where t.status = 'posted'
      group by 1, 2, 3
    )
    select coalesce(l.profile_key, v.profile_key), coalesce(l.bank_code, v.bank_code), coalesce(l.month, v.month),
           coalesce(l.n, 0), coalesce(v.n, 0), coalesce(l.aed, 0), coalesce(v.aed, 0),
           coalesce(v.aed, 0) - coalesce(l.aed, 0)
    from l full join v using (profile_key, bank_code, month)
    order by 1, 2, 3 $q$;
end;
$$;

-- Keep applying until every staged choice has met its line (nightly is cheap).
select cron.schedule('ledger-legacy-choices', '45 22 * * *',
  $$select private.apply_legacy_category_choices() where exists (select 1 from private.legacy_category_choices where applied_at is null)$$);

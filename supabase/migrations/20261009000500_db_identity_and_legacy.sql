-- Identity and legacy items from the audit backlog (docs/audit/BACKLOG.md):
--   DB-21   public.delete_profile: purges the profile's Vault secrets and queues its
--           Storage objects for removal; trg_audit skips rows of a vanished profile
--   DB-23   pending invites attach only to a confirmed email; add_profile_member
--           treats an unconfirmed account as not signed up yet
--   X-23    legacy.* keeps no table or sequence grants for anon / authenticated
--   DP-19   legacy category choices resolve through an alias table (legacy typos);
--           private.legacy_unresolved_category_names() reports what still does not

-- ── DB-21: audit trail during a profile delete ──────────────────────────────
create or replace function private.trg_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb := to_jsonb(coalesce(new, old));
  v_code text;
begin
  -- Only user actions are audited; system writes (seeding, ingestion) are not.
  if auth.uid() is null then
    return null;
  end if;
  -- The cascade of a profile delete: there is no profile left to audit (DB-21).
  if not exists (select 1 from public.profiles p where p.profile_code = v_row->>'profile_code') then
    return null;
  end if;
  v_code := coalesce(v_row->>'rule_code', v_row->>'txn_code', v_row->>'review_code', v_row->>'budget_code');
  if tg_table_name = 'transactions' and tg_op = 'UPDATE' then
    if (to_jsonb(new) -> 'manual_category_code', to_jsonb(new) -> 'notes', to_jsonb(new) -> 'exclude_from_spend')
       is not distinct from (to_jsonb(old) -> 'manual_category_code', to_jsonb(old) -> 'notes', to_jsonb(old) -> 'exclude_from_spend') then
      return null;
    end if;
  end if;
  insert into public.audit_events (profile_code, actor, action, entity, entity_code, payload)
  values (v_row->>'profile_code', auth.uid(), lower(tg_op), tg_table_name, v_code,
          case when tg_table_name = 'transactions'
               then jsonb_build_object('manual_category_code', v_row->>'manual_category_code',
                                       'exclude_from_spend', v_row->'exclude_from_spend')
               else v_row - 'pattern_upper' end);
  return null;
end;
$$;

-- ── DB-21: delete a profile and what it owns outside its tables ─────────────
-- Storage objects cannot be deleted from SQL (the Storage API owns them): their
-- paths go to the storage_cleanup queue as {bucket, paths[]} in batches of 100,
-- for the worker to remove.
select pgmq.create('storage_cleanup');

-- An owner deletes a whole profile (ledger). p_confirm_key must equal the
-- profile's key, so a stray call cannot do it. Returns what was removed.
create or replace function public.delete_profile(p_profile_code text, p_confirm_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
  v_secrets integer;
  v_paths text[];
  v_batches integer := 0;
  i integer;
begin
  perform private.assert_member(p_profile_code, true);
  select key into v_key from public.profiles where profile_code = p_profile_code for update;
  if not found then
    raise exception 'unknown profile %', p_profile_code using errcode = 'P0002';
  end if;
  if p_confirm_key is distinct from v_key then
    raise exception 'confirmation does not match the profile key' using errcode = '22023';
  end if;
  perform private.lock_profile(p_profile_code);

  with d as (
    delete from vault.secrets s
    where s.name like 'profile:' || p_profile_code || ':%'
       or exists (select 1 from public.email_mailboxes mb
                  where mb.profile_code = p_profile_code and s.name like 'mailbox:' || mb.mailbox_code || ':%')
    returning 1
  )
  select count(*) into v_secrets from d;

  select coalesce(array_agg(storage_path order by storage_path), '{}') into v_paths
  from public.documents where profile_code = p_profile_code;
  i := 1;
  while i <= coalesce(array_length(v_paths, 1), 0) loop
    perform pgmq.send('storage_cleanup', jsonb_build_object('bucket', 'statements', 'paths',
                                                            to_jsonb(v_paths[i:i + 99])));
    v_batches := v_batches + 1;
    i := i + 100;
  end loop;

  delete from public.profiles where profile_code = p_profile_code;
  return jsonb_build_object('profile_code', p_profile_code, 'vault_secrets', v_secrets,
                            'storage_objects', coalesce(array_length(v_paths, 1), 0),
                            'storage_cleanup_messages', v_batches);
end;
$$;

-- ── DB-23: invites attach to confirmed emails only ──────────────────────────
create or replace function private.attach_pending_members()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is null or new.email_confirmed_at is null then
    return new;
  end if;
  insert into public.profile_members (profile_code, user_id, role)
  select p.profile_code, new.id, p.role
  from private.pending_members p
  where lower(p.email) = lower(new.email)
  on conflict (profile_code, user_id) do nothing;
  delete from private.pending_members where lower(email) = lower(new.email);
  return new;
end;
$$;

drop trigger if exists ledger_attach_pending_members on auth.users;
create trigger ledger_attach_pending_members
  after insert on auth.users
  for each row when (new.email_confirmed_at is not null)
  execute function private.attach_pending_members();
create trigger ledger_attach_pending_members_confirmed
  after update of email, email_confirmed_at on auth.users
  for each row when (new.email_confirmed_at is not null
                     and (old.email_confirmed_at is null or old.email is distinct from new.email))
  execute function private.attach_pending_members();

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
  -- An account whose email is not confirmed is not that person yet (DB-23): invite.
  select id into v_user from auth.users where lower(email) = lower(p_email) and email_confirmed_at is not null;
  if v_user is null then
    insert into private.pending_members (profile_code, email, role) values (p_profile_code, lower(p_email), p_role)
    on conflict (profile_code, email) do update set role = excluded.role;
    return 'invited';
  end if;

  if p_role = 'viewer' then
    -- Serialise membership changes per profile (as remove_profile_member does) so
    -- two owners demoting each other concurrently cannot leave the ledger ownerless.
    perform 1 from public.profiles p where p.profile_code = p_profile_code for update;
    if exists (
      select 1 from public.profile_members m
      where m.profile_code = p_profile_code and m.user_id = v_user and m.role = 'owner'
    ) and not exists (
      select 1 from public.profile_members m
      where m.profile_code = p_profile_code and m.role = 'owner' and m.user_id <> v_user
    ) then
      raise exception 'cannot demote the last owner of profile %', p_profile_code using errcode = '22023';
    end if;
  end if;

  insert into public.profile_members (profile_code, user_id, role) values (p_profile_code, v_user, p_role)
  on conflict (profile_code, user_id) do update set role = excluded.role;
  return 'added';
end;
$$;

-- ── X-23: no client grants left on legacy tables ────────────────────────────
-- Schema USAGE is already revoked (…0000); this removes the table-level grants
-- production's old defaults left behind. Functions are not touched: revoking
-- EXECUTE segfaults Postgres 17.6.1.104 (CLAUDE.md §1.6).
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'legacy') then
    execute 'revoke all on all tables in schema legacy from anon, authenticated';
    execute 'revoke all on all sequences in schema legacy from anon, authenticated';
  end if;
end;
$$;

-- ── DP-19: legacy category aliases ──────────────────────────────────────────
create table private.legacy_category_aliases (
  legacy_name text primary key,       -- compared case-insensitively
  category_name text not null
);
revoke all on private.legacy_category_aliases from public, anon, authenticated;
insert into private.legacy_category_aliases (legacy_name, category_name) values
  ('Entretainment', 'Entertainment')
on conflict (legacy_name) do nothing;

create or replace function private.apply_legacy_category_choices()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  -- Lines first (materialized): joining choices to transactions on profile_code
  -- alone is a plan the planner otherwise likes, at ~10 s for 2.6k choices.
  -- Evidence and transactions share the line's profile by composite FK.
  with m as materialized (
    select ch.profile_code, ch.legacy_fingerprint, ch.source,
           coalesce(al.category_name, ch.category_name) as category_name, l.line_code
    from private.legacy_category_choices ch
    left join private.legacy_category_aliases al on lower(al.legacy_name) = lower(ch.category_name)
    join public.statement_lines l on l.profile_code = ch.profile_code and l.legacy_fingerprint = ch.legacy_fingerprint
                                 and l.is_current
  ),
  cand as (
    select distinct on (t.profile_code, t.txn_code)
           t.profile_code, t.txn_code, c.category_code, m.legacy_fingerprint, m.source,
           case when t.manual_category_code is not null then 'kept_manual'
                when t.effective_category_code is not distinct from c.category_code then 'agreed'
                else 'applied' end as outcome
    from m
    join public.transaction_evidence e on e.line_code = m.line_code and e.is_active
    join public.transactions t on t.txn_code = e.txn_code
    join public.categories c on c.profile_code = m.profile_code and lower(c.name) = lower(m.category_name)
    where not exists (select 1 from private.legacy_choice_applications a
                      where a.profile_code = t.profile_code and a.txn_code = t.txn_code)
    order by t.profile_code, t.txn_code, case m.source when 'override' then 0 else 1 end
  ),
  rec as (
    insert into private.legacy_choice_applications (profile_code, txn_code, legacy_fingerprint, source, outcome,
                                                    category_code)
    select profile_code, txn_code, legacy_fingerprint, source, outcome, category_code from cand
    returning txn_code
  ),
  upd as (
    update public.transactions t set manual_category_code = cand.category_code
    from cand
    where t.profile_code = cand.profile_code and t.txn_code = cand.txn_code and cand.outcome = 'applied'
    returning t.txn_code
  )
  select count(*) into v_count from upd;

  -- A choice is done once it has met its line.
  update private.legacy_category_choices ch set applied_at = now()
  where ch.applied_at is null
    and exists (select 1 from public.statement_lines l
                where l.profile_code = ch.profile_code and l.legacy_fingerprint = ch.legacy_fingerprint and l.is_current);
  return v_count;
end;
$$;

-- Finalize report: legacy category names (after aliases) that match no category
-- of the profile, so their choices were never applied.
create or replace function private.legacy_unresolved_category_names()
returns table(profile_key text, category_name text, choices bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select p.key, ch.category_name, count(*)
  from private.legacy_category_choices ch
  join public.profiles p on p.profile_code = ch.profile_code
  left join private.legacy_category_aliases al on lower(al.legacy_name) = lower(ch.category_name)
  where not exists (select 1 from public.categories c
                    where c.profile_code = ch.profile_code
                      and lower(c.name) = lower(coalesce(al.category_name, ch.category_name)))
  group by p.key, ch.category_name
  order by 1, 2
$$;

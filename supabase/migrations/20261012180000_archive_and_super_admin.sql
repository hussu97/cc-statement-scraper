-- Archive instead of delete, and a read-only super admin.
--
-- 1. Queue messages are archived (pgmq.archive → pgmq.a_<queue>), never deleted: the
--    worker's acknowledgements (queue_delete), dead-lettering (queue_to_dlq), requeue_dlq
--    and drain_dlq keep the message and its dlq_reason. Signatures are unchanged.
-- 2. delete_profile archives the profile: archived_at is set, nothing cascades, the PDFs
--    and Vault secrets stay. Its active service tokens are revoked and its mailboxes
--    disabled (both recorded in archive_state, so restore_profile undoes exactly that).
--    Archived profiles drop out of every membership check, so no client sees them.
--    restore_profile (service role only) brings one back.
-- 3. Super admins (private.super_admins, by confirmed email) can READ every active
--    profile: authz.my_profile_codes() and the non-owner branch of assert_member
--    include all of them. Writes still need membership as owner (my_owned_profile_codes,
--    assert_member(…, true)), so another user's ledger is view-only, enforced here.

-- ── 1. queues: archive, never delete ────────────────────────────────────────
create or replace function public.queue_delete(p_queue text, p_msg_id bigint)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
  select pgmq.archive(p_queue, p_msg_id) $$;

create or replace function public.queue_to_dlq(p_queue text, p_msg_id bigint, p_message jsonb, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  perform pgmq.send(p_queue || '_dlq', p_message || jsonb_build_object('dlq_reason', left(p_reason, 1000), 'dlq_at', now()));
  perform pgmq.archive(p_queue, p_msg_id);
end;
$$;

-- Archives every message in <p_queue>_dlq; returns how many.
create or replace function public.drain_dlq(p_queue text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids bigint[];
begin
  perform private.assert_service_role();
  perform private.assert_known_queue(p_queue);
  execute format('select coalesce(array_agg(msg_id), ''{}'') from pgmq.%I', 'q_' || p_queue || '_dlq') into v_ids;
  if cardinality(v_ids) = 0 then
    return 0;
  end if;
  return (select count(*) from pgmq.archive(p_queue || '_dlq', v_ids));
end;
$$;

-- Moves up to p_limit messages from <p_queue>_dlq back to <p_queue> with a fresh
-- attempt count; the dead-lettered copy is archived. A parse_document message re-opens
-- its failed document.
create or replace function public.requeue_dlq(p_queue text, p_limit integer default 100)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_msg jsonb;
  v_count integer := 0;
begin
  perform private.assert_service_role();
  perform private.assert_known_queue(p_queue);
  for r in select * from pgmq.read(p_queue || '_dlq', 60, least(greatest(coalesce(p_limit, 100), 1), 1000)) loop
    v_msg := r.message - 'dlq_reason' - 'dlq_at' - 'attempt';
    if p_queue = 'parse_document' then
      update public.documents set parse_status = 'queued', parse_error = null, parse_error_code = null,
        parse_attempts = 0
      where doc_code = v_msg->>'doc_code' and parse_status = 'failed';
    end if;
    perform pgmq.send(p_queue, v_msg);
    perform pgmq.archive(p_queue || '_dlq', r.msg_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ── 2. profiles are archived, not deleted ───────────────────────────────────
alter table public.profiles
  add column archived_at timestamptz,
  add column archived_by uuid,
  add column archive_state jsonb;

-- ── 3. super admins ─────────────────────────────────────────────────────────
-- Matched by confirmed email so the row works before the account exists (and locally).
-- private schema: client roles cannot reach it at all.
create table private.super_admins (
  email text primary key check (email = lower(btrim(email)) and email like '%@%'),
  added_at timestamptz not null default now()
);
insert into private.super_admins (email) values ('h_abbasi97@hotmail.com') on conflict do nothing;

create or replace function authz.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from auth.users u
    join private.super_admins s on s.email = lower(u.email)
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null
  )
$$;
grant execute on function authz.is_super_admin() to authenticated;

-- Readable profiles: active ones I'm a member of, or every active one for a super admin.
create or replace function authz.my_profile_codes()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(p.profile_code), '{}'::text[])
  from public.profiles p
  where p.archived_at is null
    and ((select authz.is_super_admin())
         or exists (select 1 from public.profile_members m
                    where m.profile_code = p.profile_code and m.user_id = (select auth.uid())))
$$;

-- Writable profiles: active ones I own. Super admin adds nothing here.
create or replace function authz.my_owned_profile_codes()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.profile_code), '{}'::text[])
  from public.profile_members m
  join public.profiles p on p.profile_code = m.profile_code and p.archived_at is null
  where m.user_id = (select auth.uid()) and m.role = 'owner'
$$;

create or replace function private.assert_member(p_profile_code text, p_need_owner boolean default false)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if private.caller_role() in ('service_role', 'none') then
    return;
  end if;
  if not exists (select 1 from public.profiles p where p.profile_code = p_profile_code and p.archived_at is null)
     or not (
       exists (select 1 from public.profile_members m
               where m.profile_code = p_profile_code
                 and m.user_id = (select auth.uid())
                 and (not p_need_owner or m.role = 'owner'))
       or (not p_need_owner and authz.is_super_admin())
     ) then
    raise exception 'not a % of profile %', case when p_need_owner then 'owner' else 'member' end, p_profile_code
      using errcode = '42501';
  end if;
end;
$$;

-- ── delete_profile archives ─────────────────────────────────────────────────
create or replace function public.delete_profile(p_profile_code text, p_confirm_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
  v_tokens text[];
  v_mailboxes text[];
  v_at timestamptz := now();
begin
  perform private.assert_member(p_profile_code, true);
  select key into v_key from public.profiles where profile_code = p_profile_code and archived_at is null for update;
  if not found then
    raise exception 'unknown profile %', p_profile_code using errcode = 'P0002';
  end if;
  if p_confirm_key is distinct from v_key then
    raise exception 'confirmation does not match the profile key' using errcode = '22023';
  end if;
  perform private.lock_profile(p_profile_code);

  with t as (
    update public.service_tokens set revoked_at = v_at
    where profile_code = p_profile_code and revoked_at is null
    returning token_code
  )
  select coalesce(array_agg(token_code order by token_code), '{}') into v_tokens from t;
  with mb as (
    update public.email_mailboxes set enabled = false
    where profile_code = p_profile_code and enabled
    returning mailbox_code
  )
  select coalesce(array_agg(mailbox_code order by mailbox_code), '{}') into v_mailboxes from mb;

  update public.profiles
  set archived_at = v_at,
      archived_by = (select auth.uid()),
      archive_state = jsonb_build_object('revoked_tokens', to_jsonb(v_tokens), 'disabled_mailboxes', to_jsonb(v_mailboxes))
  where profile_code = p_profile_code;

  return jsonb_build_object('profile_code', p_profile_code, 'archived_at', v_at,
                            'service_tokens_revoked', cardinality(v_tokens),
                            'mailboxes_disabled', cardinality(v_mailboxes));
end;
$$;

-- Service role only: un-archives a profile, re-enabling exactly what archiving turned off.
create or replace function public.restore_profile(p_profile_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb;
  v_tokens integer;
  v_mailboxes integer;
begin
  perform private.assert_service_role();
  select archive_state into v_state from public.profiles
  where profile_code = p_profile_code and archived_at is not null for update;
  if not found then
    raise exception 'profile % is not archived', p_profile_code using errcode = 'P0002';
  end if;
  perform private.lock_profile(p_profile_code);

  update public.service_tokens set revoked_at = null
  where profile_code = p_profile_code
    and token_code in (select jsonb_array_elements_text(coalesce(v_state->'revoked_tokens', '[]')));
  get diagnostics v_tokens = row_count;
  update public.email_mailboxes set enabled = true
  where profile_code = p_profile_code
    and mailbox_code in (select jsonb_array_elements_text(coalesce(v_state->'disabled_mailboxes', '[]')));
  get diagnostics v_mailboxes = row_count;

  update public.profiles set archived_at = null, archived_by = null, archive_state = null
  where profile_code = p_profile_code;
  return jsonb_build_object('profile_code', p_profile_code, 'service_tokens_restored', v_tokens,
                            'mailboxes_enabled', v_mailboxes);
end;
$$;

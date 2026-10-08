-- Identity & tenancy: profiles (one financial ledger per person), membership,
-- service tokens (scraper / automation), banks, accounts, cards.

-- ── profiles ────────────────────────────────────────────────────────────────
create table public.profiles (
  profile_code text primary key default public.gen_code('prf')
    check (profile_code ~ '^prf_[0-9a-z]{26}$'),
  key text not null unique check (key ~ '^[a-z0-9_-]{2,40}$'),  -- legacy X-Profile-Key
  name text not null check (length(name) between 1 and 80),
  base_currency text not null default 'AED' check (base_currency ~ '^[A-Z]{3}$'),
  timezone text not null default 'Asia/Dubai',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();

create table public.profile_members (
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner', 'viewer')),
  created_at timestamptz not null default now(),
  primary key (profile_code, user_id)
);
create index profile_members_user_idx on public.profile_members(user_id);

-- Per-profile counters used by background logic.
create table public.profile_state (
  profile_code text primary key references public.profiles(profile_code) on delete cascade,
  rules_version bigint not null default 1,
  updated_at timestamptz not null default now()
);

-- ── membership helpers (used by every RLS policy) ──────────────────────────
-- SECURITY DEFINER so policies don't recurse through profile_members' own RLS.
-- Policies call them as `(select authz.my_profile_codes())`, which Postgres
-- evaluates once per statement (initplan) rather than once per row.
create or replace function authz.my_profile_codes()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.profile_code), '{}'::text[])
  from public.profile_members m
  where m.user_id = (select auth.uid())
$$;

create or replace function authz.my_owned_profile_codes()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.profile_code), '{}'::text[])
  from public.profile_members m
  where m.user_id = (select auth.uid()) and m.role = 'owner'
$$;

grant execute on function authz.my_profile_codes() to authenticated;
grant execute on function authz.my_owned_profile_codes() to authenticated;

-- RPC guard: raise unless the caller may act on the profile. service_role
-- (Edge Functions after their own auth check) always passes.
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
  if not exists (
    select 1 from public.profile_members m
    where m.profile_code = p_profile_code
      and m.user_id = (select auth.uid())
      and (not p_need_owner or m.role = 'owner')
  ) then
    raise exception 'not a % of profile %', case when p_need_owner then 'owner' else 'member' end, p_profile_code
      using errcode = '42501';
  end if;
end;
$$;

alter table public.profiles enable row level security;
alter table public.profile_members enable row level security;
alter table public.profile_state enable row level security;

create policy profiles_member_read on public.profiles for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy profiles_owner_update on public.profiles for update to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));
create policy profile_members_member_read on public.profile_members for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy profile_state_member_read on public.profile_state for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));

grant select on public.profiles, public.profile_members, public.profile_state to authenticated;
grant update (name, base_currency) on public.profiles to authenticated;
grant all on public.profiles, public.profile_members, public.profile_state to service_role;

-- ── service tokens ──────────────────────────────────────────────────────────
-- Profile-scoped bearer tokens for the local scraper and automation. Only a
-- sha256 of the token is stored; the plaintext is returned once on creation.
create table public.service_tokens (
  token_code text primary key default public.gen_code('tok')
    check (token_code ~ '^tok_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  name text not null check (length(name) between 1 and 80),
  token_prefix text not null,
  token_hash text not null unique,
  scopes text[] not null check (scopes <@ array['statements:upload', 'sms:ingest']::text[] and cardinality(scopes) > 0),
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz,
  unique (profile_code, name)
);
alter table public.service_tokens enable row level security;
create policy service_tokens_member_read on public.service_tokens for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
-- token_hash is deliberately not readable by clients.
grant select (token_code, profile_code, name, token_prefix, scopes, created_at, last_used_at, revoked_at)
  on public.service_tokens to authenticated;
grant all on public.service_tokens to service_role;

create or replace function public.create_service_token(p_profile_code text, p_name text, p_scopes text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_code text;
begin
  perform private.assert_member(p_profile_code, true);
  v_token := 'ccs_' || encode(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()), 'hex');
  insert into public.service_tokens (profile_code, name, token_prefix, token_hash, scopes)
  values (p_profile_code, p_name, left(v_token, 12), encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), p_scopes)
  returning token_code into v_code;
  return jsonb_build_object('token_code', v_code, 'token', v_token);
end;
$$;

create or replace function public.revoke_service_token(p_token_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile text;
begin
  select profile_code into v_profile from public.service_tokens where token_code = p_token_code;
  if v_profile is null then
    raise exception 'unknown token %', p_token_code using errcode = 'P0002';
  end if;
  perform private.assert_member(v_profile, true);
  update public.service_tokens set revoked_at = now() where token_code = p_token_code and revoked_at is null;
end;
$$;

-- Called by Edge Functions (service_role) to authenticate a bearer token.
-- Returns the profile_code, or raises 28000. When p_profile_key is given, it
-- must name the token's own profile (kept for the scraper's X-Profile-Key contract).
create or replace function public.authenticate_service_token(p_token text, p_scope text, p_profile_key text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tok public.service_tokens%rowtype;
  v_key text;
begin
  perform private.assert_service_role();
  select * into v_tok from public.service_tokens
  where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex')
    and revoked_at is null;
  if not found or not (p_scope = any (v_tok.scopes)) then
    raise exception 'invalid service token or scope' using errcode = '28000';
  end if;
  if p_profile_key is not null then
    select key into v_key from public.profiles where profile_code = v_tok.profile_code;
    if v_key is distinct from p_profile_key then
      raise exception 'token does not belong to profile %', p_profile_key using errcode = '28000';
    end if;
  end if;
  update public.service_tokens set last_used_at = now() where token_code = v_tok.token_code;
  return v_tok.profile_code;
end;
$$;

grant execute on function public.create_service_token(text, text, text[]) to authenticated;
grant execute on function public.revoke_service_token(text) to authenticated;
grant execute on function public.authenticate_service_token(text, text, text) to service_role;

-- ── banks ───────────────────────────────────────────────────────────────────
create table public.banks (
  bank_code text primary key check (bank_code ~ '^[A-Z]{2,10}$'),
  name text not null,
  sms_senders text[] not null default '{}',
  created_at timestamptz not null default now()
);
alter table public.banks enable row level security;
create policy banks_read on public.banks for select to authenticated using (true);
grant select on public.banks to authenticated;
grant all on public.banks to service_role;

insert into public.banks (bank_code, name, sms_senders) values
  ('FAB', 'First Abu Dhabi Bank', array['FAB', 'FABBANK']),
  ('ADCB', 'Abu Dhabi Commercial Bank', array['ADCB', 'ADCBAlert']),
  ('ENBD', 'Emirates NBD', array['EmiratesNBD', 'ENBD']),
  ('EIB', 'Emirates Islamic', array['EI', 'EIBank', 'EmiratesIsl']),
  ('SIB', 'Sharjah Islamic Bank', array['SIB', 'SIBank']),
  ('MASHREQ', 'Mashreq', array['Mashreq', 'MASHREQ'])
on conflict (bank_code) do nothing;

-- ── accounts & cards ────────────────────────────────────────────────────────
create table public.accounts (
  account_code text primary key default public.gen_code('acc')
    check (account_code ~ '^acc_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  bank_code text not null references public.banks(bank_code),
  kind text not null default 'credit_card' check (kind in ('credit_card')),
  product_name text,
  nickname text,
  currency text not null default 'AED' check (currency ~ '^[A-Z]{3}$'),
  credit_limit numeric(14,2) check (credit_limit is null or credit_limit >= 0),
  cycle_close_day smallint check (cycle_close_day between 1 and 31),
  status text not null default 'active' check (status in ('active', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index accounts_profile_idx on public.accounts(profile_code);
create trigger accounts_touch before update on public.accounts
  for each row execute function private.touch_updated_at();

create table public.cards (
  card_code text primary key default public.gen_code('crd')
    check (card_code ~ '^crd_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null references public.accounts(account_code) on delete cascade,
  bank_code text not null references public.banks(bank_code),
  last4 text not null check (last4 ~ '^[0-9]{4}$'),
  holder_name text,
  is_supplementary boolean not null default false,
  status text not null default 'active' check (status in ('active', 'replaced', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_code, bank_code, last4)
);
create index cards_account_idx on public.cards(account_code);
create trigger cards_touch before update on public.cards
  for each row execute function private.touch_updated_at();

alter table public.accounts enable row level security;
alter table public.cards enable row level security;
create policy accounts_member_read on public.accounts for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy accounts_owner_update on public.accounts for update to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));
create policy cards_member_read on public.cards for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy cards_owner_update on public.cards for update to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));
grant select on public.accounts, public.cards to authenticated;
grant update (product_name, nickname, credit_limit, cycle_close_day, status) on public.accounts to authenticated;
grant update (holder_name, is_supplementary, status) on public.cards to authenticated;
grant all on public.accounts, public.cards to service_role;

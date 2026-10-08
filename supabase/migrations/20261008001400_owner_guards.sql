-- Owner guards and server-side category change:
--   • add_profile_member refuses to demote the last owner to viewer (22023),
--     matching remove_profile_member (20261008001300_web_followups.sql)
--   • category_breakdown also returns `change`: (amount − prev_amount) / prev_amount
--     as a 4dp decimal fraction, null when the previous period had no spend

-- ── add_profile_member ──────────────────────────────────────────────────────
-- Same signature and return as 20261008000950_legacy_import.sql: 'invited' when
-- the email has no account yet, 'added' otherwise.
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

grant execute on function public.add_profile_member(text, text, text) to authenticated, service_role;

-- ── category_breakdown ──────────────────────────────────────────────────────
-- A new OUT column changes the return type, so the function is dropped first.
drop function public.category_breakdown(text, date, date);
create function public.category_breakdown(p_profile_code text, p_from date, p_to date)
returns table (category_code text, name text, color_token text, amount numeric, txn_count bigint,
               share numeric, prev_amount numeric, change numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  with cur as (
    select s.category_code, sum(s.spend_aed) as amount, count(*) as n
    from public.v_spend s
    where s.profile_code = p_profile_code and s.txn_date between p_from and p_to
    group by s.category_code
  ),
  prev as (
    select s.category_code, sum(s.spend_aed) as amount
    from public.v_spend s
    where s.profile_code = p_profile_code
      and s.txn_date between p_from - (p_to - p_from + 1) and p_from - 1
    group by s.category_code
  ),
  tot as (select nullif(sum(amount), 0) as total from cur)
  select cur.category_code, coalesce(c.name, 'Uncategorized'), c.color_token, cur.amount, cur.n,
         round(cur.amount / tot.total, 4), coalesce(prev.amount, 0),
         round((cur.amount - prev.amount) / nullif(prev.amount, 0), 4)
  from cur
  cross join tot
  left join prev on prev.category_code is not distinct from cur.category_code
  left join public.categories c on c.category_code = cur.category_code
  order by cur.amount desc
$$;

grant execute on function public.category_breakdown(text, date, date) to authenticated, service_role;

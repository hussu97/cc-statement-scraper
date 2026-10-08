-- Dynamic categorisation.
--
-- Precedence (effective_category_code, a generated column on transactions):
--   transaction manual > merchant manual ("apply to merchant") > rule > LLM merchant suggestion
-- recategorize() only ever writes rule_* and merchant_* columns, so manual
-- choices can never be clobbered.
--
-- Triggers recompute:
--   • new transactions                         → those transactions
--   • transactions whose matchable facts change → those transactions
--   • any category_rules change                → the whole profile (bumps rules_version)
--   • merchant_profile_category change         → that merchant's transactions
-- pg_cron sweeps rows with a stale rules_version every 3 hours as a safety net.

create or replace function private.recategorize(p_profile text, p_txn_codes text[] default null)
returns integer
language plpgsql
security definer
set search_path = ''
set statement_timeout = '30s'
as $$
declare
  v_version bigint;
  v_count integer;
begin
  insert into public.profile_state (profile_code) values (p_profile)
  on conflict (profile_code) do nothing;
  select rules_version into v_version from public.profile_state where profile_code = p_profile;

  with targets as (
    select t.txn_code, t.description, t.kind, t.direction, t.amount_aed, t.currency_original,
           t.card_code, a.bank_code, t.merchant_code
    from public.transactions t
    join public.accounts a on a.account_code = t.account_code
    where t.profile_code = p_profile
      and (p_txn_codes is null or t.txn_code = any (p_txn_codes))
  ),
  computed as (
    select tg.txn_code, r.rule_code, r.category_code as rule_cat,
           mpc.category_code as m_cat, mpc.source as m_src
    from targets tg
    left join lateral (
      select r.rule_code, r.category_code
      from public.category_rules r
      where r.profile_code = p_profile
        and r.active
        and case r.match_type
              when 'exact' then tg.description = r.pattern_upper
              when 'prefix' then starts_with(tg.description, r.pattern_upper)
              when 'contains' then strpos(tg.description, r.pattern_upper) > 0
              else tg.description ~* r.pattern
            end
        and (not r.conditions ? 'amount_min' or tg.amount_aed >= (r.conditions->>'amount_min')::numeric)
        and (not r.conditions ? 'amount_max' or tg.amount_aed <= (r.conditions->>'amount_max')::numeric)
        and (not r.conditions ? 'bank_code' or tg.bank_code = r.conditions->>'bank_code')
        and (not r.conditions ? 'card_code' or tg.card_code = r.conditions->>'card_code')
        and (not r.conditions ? 'currency' or tg.currency_original = r.conditions->>'currency')
        and (not r.conditions ? 'kind' or tg.kind = r.conditions->>'kind')
        and (not r.conditions ? 'direction' or tg.direction = r.conditions->>'direction')
      order by r.priority,
               length(r.pattern_upper) desc,
               case r.match_type when 'exact' then 0 when 'prefix' then 1 when 'contains' then 2 else 3 end,
               r.rule_code
      limit 1
    ) r on true
    left join public.merchant_profile_category mpc
      on mpc.profile_code = p_profile and mpc.merchant_code = tg.merchant_code
  )
  update public.transactions t
  set rule_code = c.rule_code,
      rule_category_code = c.rule_cat,
      merchant_category_code = c.m_cat,
      merchant_category_source = c.m_src,
      rules_version = v_version
  from computed c
  where t.txn_code = c.txn_code
    and (t.rule_code, t.rule_category_code, t.merchant_category_code, t.merchant_category_source, t.rules_version)
        is distinct from (c.rule_code, c.rule_cat, c.m_cat, c.m_src, v_version);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ── transaction triggers ────────────────────────────────────────────────────
create or replace function private.trg_transactions_categorize_new()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in select profile_code, array_agg(txn_code) as codes from new_rows group by profile_code loop
    perform private.recategorize(r.profile_code, r.codes);
  end loop;
  return null;
end;
$$;
create trigger transactions_categorize_new
  after insert on public.transactions
  referencing new table as new_rows
  for each statement execute function private.trg_transactions_categorize_new();

create or replace function private.trg_transactions_categorize_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  -- recategorize()'s own UPDATE only touches category columns, so it finds no
  -- changed facts here and the trigger does not recurse.
  for r in
    select n.profile_code, array_agg(n.txn_code) as codes
    from new_rows n join old_rows o on o.txn_code = n.txn_code
    where (n.description, n.merchant_code, n.amount_aed, n.kind, n.direction, n.card_code, n.currency_original)
          is distinct from (o.description, o.merchant_code, o.amount_aed, o.kind, o.direction, o.card_code, o.currency_original)
    group by n.profile_code
  loop
    perform private.recategorize(r.profile_code, r.codes);
  end loop;
  return null;
end;
$$;
create trigger transactions_categorize_changed
  after update on public.transactions
  referencing new table as new_rows old table as old_rows
  for each statement execute function private.trg_transactions_categorize_changed();

-- ── rule triggers (one per event: transition tables allow a single event) ──
create or replace function private.bump_and_recategorize(p_profiles text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p text;
begin
  foreach p in array coalesce(p_profiles, '{}') loop
    insert into public.profile_state (profile_code, rules_version) values (p, 2)
    on conflict (profile_code) do update
      set rules_version = public.profile_state.rules_version + 1, updated_at = now();
    perform private.recategorize(p, null);
  end loop;
end;
$$;

create or replace function private.trg_rules_changed_new()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.bump_and_recategorize(array(select distinct profile_code from new_rows));
  return null;
end;
$$;
create or replace function private.trg_rules_changed_old()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.bump_and_recategorize(array(select distinct profile_code from old_rows));
  return null;
end;
$$;
create trigger category_rules_after_insert after insert on public.category_rules
  referencing new table as new_rows for each statement execute function private.trg_rules_changed_new();
create trigger category_rules_after_update after update on public.category_rules
  referencing new table as new_rows for each statement execute function private.trg_rules_changed_new();
create trigger category_rules_after_delete after delete on public.category_rules
  referencing old table as old_rows for each statement execute function private.trg_rules_changed_old();

-- ── merchant category trigger ───────────────────────────────────────────────
create or replace function private.trg_mpc_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile text := coalesce(new.profile_code, old.profile_code);
  v_merchant text := coalesce(new.merchant_code, old.merchant_code);
begin
  perform private.recategorize(
    v_profile,
    array(select txn_code from public.transactions where profile_code = v_profile and merchant_code = v_merchant)
  );
  return null;
end;
$$;
create trigger merchant_profile_category_changed
  after insert or update or delete on public.merchant_profile_category
  for each row execute function private.trg_mpc_changed();

-- ── cron sweep ──────────────────────────────────────────────────────────────
create or replace function private.recategorize_stale()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_total integer := 0;
begin
  for r in
    select distinct t.profile_code
    from public.transactions t
    join public.profile_state s on s.profile_code = t.profile_code
    where t.rules_version < s.rules_version
  loop
    v_total := v_total + private.recategorize(r.profile_code, null);
  end loop;
  return v_total;
end;
$$;

-- ── user-facing RPCs ────────────────────────────────────────────────────────
-- Set (or clear, with null) a transaction's category. With p_apply_to_merchant,
-- the choice becomes the merchant's manual category for the whole profile.
create or replace function public.set_transaction_category(
  p_txn_code text,
  p_category_code text,
  p_apply_to_merchant boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_txn public.transactions%rowtype;
begin
  select * into v_txn from public.transactions where txn_code = p_txn_code;
  if not found then
    raise exception 'unknown transaction %', p_txn_code using errcode = 'P0002';
  end if;
  perform private.assert_member(v_txn.profile_code, true);

  if p_apply_to_merchant and v_txn.merchant_code is not null then
    if p_category_code is null then
      delete from public.merchant_profile_category
      where profile_code = v_txn.profile_code and merchant_code = v_txn.merchant_code and source = 'manual';
    else
      insert into public.merchant_profile_category (profile_code, merchant_code, category_code, source)
      values (v_txn.profile_code, v_txn.merchant_code, p_category_code, 'manual')
      on conflict (profile_code, merchant_code) do update
        set category_code = excluded.category_code, source = 'manual', confidence = null, model = null;
    end if;
    -- The merchant rule now speaks for this transaction too.
    update public.transactions set manual_category_code = null where txn_code = p_txn_code;
  else
    update public.transactions set manual_category_code = p_category_code where txn_code = p_txn_code;
  end if;
end;
$$;

-- Bulk version used by the Activity screen.
create or replace function public.set_transactions_category(p_txn_codes text[], p_category_code text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profiles text[];
  p text;
  v_count integer;
begin
  select array_agg(distinct profile_code) into v_profiles from public.transactions where txn_code = any (p_txn_codes);
  foreach p in array coalesce(v_profiles, '{}') loop
    perform private.assert_member(p, true);
  end loop;
  update public.transactions set manual_category_code = p_category_code where txn_code = any (p_txn_codes);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- "This rule would change N transactions": evaluated without saving anything.
create or replace function public.preview_rule(
  p_profile_code text,
  p_match_type text,
  p_pattern text,
  p_category_code text,
  p_conditions jsonb default '{}'::jsonb,
  p_priority integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set statement_timeout = '10s'
as $$
declare
  v_pattern text := upper(btrim(p_pattern));
  v_matched integer;
  v_changed integer;
  v_sample jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_match_type = 'regex' then
    perform regexp_match('', p_pattern);
  end if;

  with m as (
    select t.txn_code, t.description, t.amount_aed, t.txn_date, t.effective_category_code,
           t.manual_category_code, t.merchant_category_source, t.rule_code,
           (select r.priority from public.category_rules r where r.rule_code = t.rule_code) as cur_priority
    from public.transactions t
    join public.accounts a on a.account_code = t.account_code
    where t.profile_code = p_profile_code
      and case p_match_type
            when 'exact' then t.description = v_pattern
            when 'prefix' then starts_with(t.description, v_pattern)
            when 'contains' then strpos(t.description, v_pattern) > 0
            else t.description ~* p_pattern
          end
      and (not p_conditions ? 'amount_min' or t.amount_aed >= (p_conditions->>'amount_min')::numeric)
      and (not p_conditions ? 'amount_max' or t.amount_aed <= (p_conditions->>'amount_max')::numeric)
      and (not p_conditions ? 'bank_code' or a.bank_code = p_conditions->>'bank_code')
      and (not p_conditions ? 'kind' or t.kind = p_conditions->>'kind')
      and (not p_conditions ? 'direction' or t.direction = p_conditions->>'direction')
  )
  select count(*),
         count(*) filter (
           where manual_category_code is null
             and coalesce(merchant_category_source, '') <> 'manual'
             and (rule_code is null or cur_priority >= p_priority)
             and effective_category_code is distinct from p_category_code
         ),
         coalesce(jsonb_agg(jsonb_build_object(
           'txn_code', txn_code, 'description', description, 'amount_aed', amount_aed::text,
           'txn_date', txn_date, 'current_category_code', effective_category_code
         ) order by txn_date desc) filter (where true), '[]'::jsonb)
  into v_matched, v_changed, v_sample
  from (select * from m order by txn_date desc limit 1000) m;

  return jsonb_build_object(
    'matched', v_matched,
    'would_change', v_changed,
    'sample', (select coalesce(jsonb_agg(e), '[]'::jsonb) from (select e from jsonb_array_elements(v_sample) e limit 20) s)
  );
end;
$$;

grant execute on function public.set_transaction_category(text, text, boolean) to authenticated, service_role;
grant execute on function public.set_transactions_category(text[], text) to authenticated, service_role;
grant execute on function public.preview_rule(text, text, text, text, jsonb, integer) to authenticated, service_role;

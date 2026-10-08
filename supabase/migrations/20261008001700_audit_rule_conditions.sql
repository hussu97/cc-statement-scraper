-- Audit fix DB-09 (docs/audit/01-database.md): category_rules.conditions is
-- validated on write, and evaluation can no longer raise on a bad value.
-- Also DB-13 for rules: bounded patterns instead of the no-op statement_timeout.
--
-- conditions: {amount_min, amount_max, bank_code, card_code, currency, kind, direction}
--   amount_min / amount_max  number (or numeric string), ≥ 0
--   bank_code                an existing bank
--   card_code                a card of the rule's own profile
--   currency                 ISO code ^[A-Z]{3}$
--   kind                     a transaction kind
--   direction                debit | credit

-- Why a rule pattern/conditions pair is unacceptable, or null. Shared by the
-- trigger and preview_rule so both accept exactly the same rules.
create or replace function private.rule_problem(
  p_profile_code text, p_match_type text, p_pattern text, p_conditions jsonb
)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  e record;
begin
  if p_pattern is null or length(p_pattern) > 200 then
    return 'pattern must be at most 200 characters';
  end if;
  if p_match_type = 'regex' then
    if p_pattern ~ '\\[1-9]' then
      return 'regex back-references are not allowed';
    end if;
    begin
      perform regexp_match('', p_pattern);
    exception when others then
      return 'invalid regex: ' || sqlerrm;
    end;
  end if;
  if p_conditions is null or jsonb_typeof(p_conditions) <> 'object' then
    return 'conditions must be an object';
  end if;
  for e in select key, value from jsonb_each(p_conditions) loop
    case e.key
      when 'amount_min', 'amount_max' then
        if jsonb_typeof(e.value) not in ('number', 'string')
           or private.safe_numeric(e.value #>> '{}') is null or private.safe_numeric(e.value #>> '{}') < 0 then
          return format('%s must be a non-negative number', e.key);
        end if;
      when 'bank_code' then
        if jsonb_typeof(e.value) <> 'string'
           or not exists (select 1 from public.banks b where b.bank_code = e.value #>> '{}') then
          return 'bank_code must be a known bank';
        end if;
      when 'card_code' then
        if jsonb_typeof(e.value) <> 'string'
           or not exists (select 1 from public.cards c
                          where c.card_code = e.value #>> '{}' and c.profile_code = p_profile_code) then
          return 'card_code must be a card of this profile';
        end if;
      when 'currency' then
        if jsonb_typeof(e.value) <> 'string' or (e.value #>> '{}') !~ '^[A-Z]{3}$' then
          return 'currency must be a 3-letter ISO code';
        end if;
      when 'kind' then
        if jsonb_typeof(e.value) <> 'string' or (e.value #>> '{}') not in
           ('purchase', 'refund', 'payment', 'fee', 'interest', 'cash_advance', 'adjustment') then
          return 'kind must be a transaction kind';
        end if;
      when 'direction' then
        if jsonb_typeof(e.value) <> 'string' or (e.value #>> '{}') not in ('debit', 'credit') then
          return 'direction must be debit or credit';
        end if;
      else
        return format('unknown condition %s', e.key);
    end case;
  end loop;
  if private.safe_numeric(p_conditions->>'amount_min') > private.safe_numeric(p_conditions->>'amount_max') then
    return 'amount_min must not exceed amount_max';
  end if;
  return null;
end;
$$;

-- SECURITY DEFINER: owners write rules through PostgREST and have no USAGE on
-- `private`, where rule_problem lives.
create or replace function private.validate_rule()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_problem text;
begin
  -- Only re-validate what changed, so an old row can still be toggled or deleted.
  if tg_op = 'UPDATE' and (new.match_type, new.pattern, new.conditions, new.profile_code)
       is not distinct from (old.match_type, old.pattern, old.conditions, old.profile_code) then
    return new;
  end if;
  v_problem := private.rule_problem(new.profile_code, new.match_type, new.pattern, new.conditions);
  if v_problem is not null then
    raise exception 'invalid rule: %', v_problem using errcode = '22023';
  end if;
  return new;
end;
$$;

-- Same as 20261008000600, but amount conditions go through safe_numeric (a bad
-- value disables the condition's match instead of failing every ingest), and
-- the ineffective statement_timeout is gone (DB-13).
create or replace function private.recategorize(p_profile text, p_txn_codes text[] default null)
returns integer
language plpgsql
security definer
set search_path = ''
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
    join public.accounts a on a.profile_code = t.profile_code and a.account_code = t.account_code
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
        and (not r.conditions ? 'amount_min'
             or tg.amount_aed >= private.safe_numeric(r.conditions->>'amount_min'))
        and (not r.conditions ? 'amount_max'
             or tg.amount_aed <= private.safe_numeric(r.conditions->>'amount_max'))
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

-- Same signature and result as 20261008001300. The rule is validated exactly
-- like a saved one (22023 on a bad pattern or condition), casts are safe, and
-- the ineffective statement_timeout is gone.
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
as $$
declare
  v_pattern text := upper(btrim(p_pattern));
  v_conditions jsonb := coalesce(p_conditions, '{}'::jsonb);
  v_problem text;
  v_matched integer;
  v_changed integer;
  v_sample jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_match_type not in ('exact', 'prefix', 'contains', 'regex') then
    raise exception 'invalid rule: unknown match type %', p_match_type using errcode = '22023';
  end if;
  v_problem := private.rule_problem(p_profile_code, p_match_type, p_pattern, v_conditions);
  if v_problem is not null then
    raise exception 'invalid rule: %', v_problem using errcode = '22023';
  end if;

  with m as (
    select t.txn_code, t.description, t.amount_aed, t.txn_date, t.effective_category_code,
           t.manual_category_code, t.merchant_category_source, t.rule_code,
           cr.priority as cur_priority
    from public.transactions t
    join public.accounts a on a.profile_code = t.profile_code and a.account_code = t.account_code
    left join public.category_rules cr on cr.profile_code = t.profile_code and cr.rule_code = t.rule_code
    where t.profile_code = p_profile_code
      and case p_match_type
            when 'exact' then t.description = v_pattern
            when 'prefix' then starts_with(t.description, v_pattern)
            when 'contains' then strpos(t.description, v_pattern) > 0
            else t.description ~* p_pattern
          end
      and (not v_conditions ? 'amount_min' or t.amount_aed >= private.safe_numeric(v_conditions->>'amount_min'))
      and (not v_conditions ? 'amount_max' or t.amount_aed <= private.safe_numeric(v_conditions->>'amount_max'))
      and (not v_conditions ? 'bank_code' or a.bank_code = v_conditions->>'bank_code')
      and (not v_conditions ? 'card_code' or t.card_code = v_conditions->>'card_code')
      and (not v_conditions ? 'currency' or t.currency_original = v_conditions->>'currency')
      and (not v_conditions ? 'kind' or t.kind = v_conditions->>'kind')
      and (not v_conditions ? 'direction' or t.direction = v_conditions->>'direction')
  ),
  totals as (
    select count(*)::int as matched,
           count(*) filter (
             where manual_category_code is null
               and coalesce(merchant_category_source, '') <> 'manual'
               and (rule_code is null or cur_priority >= p_priority)
               and effective_category_code is distinct from p_category_code
           )::int as would_change
    from m
  ),
  sample as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'txn_code', s.txn_code, 'description', s.description, 'amount_aed', s.amount_aed::text,
             'txn_date', s.txn_date, 'current_category_code', s.effective_category_code
           ) order by s.txn_date desc, s.txn_code desc), '[]'::jsonb) as rows
    from (select * from m order by txn_date desc, txn_code desc limit 20) s
  )
  select totals.matched, totals.would_change, sample.rows
  into v_matched, v_changed, v_sample
  from totals, sample;

  return jsonb_build_object('matched', v_matched, 'would_change', v_changed, 'sample', v_sample);
end;
$$;

grant execute on function public.preview_rule(text, text, text, text, jsonb, integer) to authenticated, service_role;

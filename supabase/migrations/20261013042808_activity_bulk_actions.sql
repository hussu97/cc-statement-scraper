-- Activity bulk actions (audit WEB-24): a server-computed selection total, Exclude / Include
-- from spend and Categorise for a selection, and the rows for an Export CSV.
--
-- A selection is either
--   * p_txn_codes: the transactions the person ticked (codes of another profile match nothing), or
--   * p_filter:    "select all matching": the Activity list's filters as a jsonb object, with the
--                  web URL's keys: from, to (txn_date), account, card, category (a code, or 'none'
--                  for uncategorised), status, source (sms | statement | both) and q (description
--                  OR merchant name, cleaned by private.activity_search_pattern). '{}' is every
--                  transaction of the profile.
-- Exactly one of the two must be given, so a forgotten argument can never mean "everything".
-- The filter semantics are public.activity_summary's, over the same view (v_transactions), so a
-- "select all matching" selection is exactly the rows the list shows.
--
--   public.activity_selection_summary(profile, codes | filter) -> jsonb   (member)
--     txn_count, net_aed (debits minus credits, pending and posted only, like activity_summary;
--     a decimal string), unpriced_count, has_estimate, excluded_count (rows with
--     exclude_from_spend, so a client can offer "Include" when every row is excluded).
--   public.bulk_update_transactions(profile, patch, codes | filter) -> integer   (owner)
--     patch keys: exclude_from_spend (boolean) and/or manual_category_code (a category code, or
--     null to clear the manual choice): the user fields a client may already update per column
--     (CLAUDE.md §1.10, §1.13). Returns how many rows changed.
--   public.activity_export(profile, codes | filter) -> jsonb array   (member)
--     one object per transaction in list order; money as decimal strings, net_aed signed
--     (debit +, credit -) as in the totals. A jsonb array, so PostgREST's max_rows (2000) does not
--     truncate an export.

create or replace function private.activity_selection(p_profile_code text, p_txn_codes text[], p_filter jsonb)
returns setof public.v_transactions
language plpgsql
stable
set search_path = ''
as $$
declare
  v_bad text;
  v_status text := p_filter->>'status';
  v_source text := p_filter->>'source';
  v_category text := p_filter->>'category';
  v_pattern text := private.activity_search_pattern(p_filter->>'q');
begin
  if (p_txn_codes is null) = (p_filter is null) then
    raise exception 'pass either p_txn_codes or p_filter' using errcode = '22023';
  end if;
  if p_txn_codes is not null then
    return query
      select t.* from public.v_transactions t
      where t.profile_code = p_profile_code and t.txn_code = any (p_txn_codes);
    return;
  end if;

  if jsonb_typeof(p_filter) <> 'object' then
    raise exception 'p_filter must be an object' using errcode = '22023';
  end if;
  select k into v_bad from jsonb_object_keys(p_filter) k
  where k not in ('from', 'to', 'account', 'card', 'category', 'status', 'source', 'q')
  limit 1;
  if v_bad is not null then
    raise exception 'unknown filter %', v_bad using errcode = '22023';
  end if;
  if v_status is not null and v_status not in ('pending', 'posted', 'void', 'orphaned') then
    raise exception 'status must be pending, posted, void or orphaned' using errcode = '22023';
  end if;
  if v_source is not null and v_source not in ('sms', 'statement', 'both') then
    raise exception 'source must be sms, statement or both' using errcode = '22023';
  end if;

  return query
    select t.* from public.v_transactions t
    where t.profile_code = p_profile_code
      and (p_filter->>'from' is null or t.txn_date >= (p_filter->>'from')::date)
      and (p_filter->>'to' is null or t.txn_date <= (p_filter->>'to')::date)
      and (p_filter->>'account' is null or t.account_code = p_filter->>'account')
      and (p_filter->>'card' is null or t.card_code = p_filter->>'card')
      and (case when v_category = 'none' then t.category_code is null
                else v_category is null or t.category_code = v_category end)
      and (v_status is null or t.status = v_status)
      and (v_source is null
           or (v_source = 'sms' and t.has_sms and not t.has_statement)
           or (v_source = 'statement' and t.has_statement and not t.has_sms)
           or (v_source = 'both' and t.has_sms and t.has_statement))
      and (v_pattern is null or t.description ilike v_pattern or t.merchant_name ilike v_pattern);
end;
$$;

create or replace function public.activity_selection_summary(
  p_profile_code text,
  p_txn_codes text[] default null,
  p_filter jsonb default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  select jsonb_build_object(
           'txn_count', count(*),
           'net_aed', coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)
                                 filter (where t.status in ('pending', 'posted')), 0)::numeric(14,2)::text,
           'unpriced_count', count(*) filter (where t.status in ('pending', 'posted') and t.amount_aed is null),
           'has_estimate', coalesce(bool_or(t.amount_aed_is_estimate) filter (where t.status in ('pending', 'posted')), false),
           'excluded_count', count(*) filter (where t.exclude_from_spend))
  into v_out
  from private.activity_selection(p_profile_code, p_txn_codes, p_filter) t;
  return v_out;
end;
$$;
grant execute on function public.activity_selection_summary(text, text[], jsonb) to authenticated, service_role;

create or replace function public.bulk_update_transactions(
  p_profile_code text,
  p_patch jsonb,
  p_txn_codes text[] default null,
  p_filter jsonb default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bad text;
  v_set_exclude boolean := p_patch ? 'exclude_from_spend';
  v_set_category boolean := p_patch ? 'manual_category_code';
  v_exclude boolean;
  v_category text;
  v_count integer;
begin
  perform private.assert_member(p_profile_code, true);
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must name exclude_from_spend and/or manual_category_code' using errcode = '22023';
  end if;
  select k into v_bad from jsonb_object_keys(p_patch) k
  where k not in ('exclude_from_spend', 'manual_category_code')
  limit 1;
  if v_bad is not null then
    raise exception 'cannot bulk-update %', v_bad using errcode = '22023';
  end if;
  if v_set_exclude then
    if jsonb_typeof(p_patch->'exclude_from_spend') <> 'boolean' then
      raise exception 'exclude_from_spend must be true or false' using errcode = '22023';
    end if;
    v_exclude := (p_patch->>'exclude_from_spend')::boolean;
  end if;
  if v_set_category then
    if jsonb_typeof(p_patch->'manual_category_code') not in ('string', 'null') then
      raise exception 'manual_category_code must be a category code or null' using errcode = '22023';
    end if;
    v_category := p_patch->>'manual_category_code';
    -- The composite FK refuses another profile's category too; this says so plainly.
    if v_category is not null and not exists (
      select 1 from public.categories c where c.profile_code = p_profile_code and c.category_code = v_category
    ) then
      raise exception 'unknown category %', v_category using errcode = 'P0002';
    end if;
  end if;

  update public.transactions x
  set exclude_from_spend = case when v_set_exclude then v_exclude else x.exclude_from_spend end,
      manual_category_code = case when v_set_category then v_category else x.manual_category_code end
  where x.profile_code = p_profile_code
    and x.txn_code in (select s.txn_code from private.activity_selection(p_profile_code, p_txn_codes, p_filter) s)
    and ((v_set_exclude and x.exclude_from_spend is distinct from v_exclude)
         or (v_set_category and x.manual_category_code is distinct from v_category));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
grant execute on function public.bulk_update_transactions(text, jsonb, text[], jsonb) to authenticated, service_role;

create or replace function public.activity_export(
  p_profile_code text,
  p_txn_codes text[] default null,
  p_filter jsonb default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  select coalesce(jsonb_agg(jsonb_build_object(
           'txn_code', t.txn_code,
           'txn_date', t.txn_date,
           'txn_time', to_char(t.txn_at at time zone 'Asia/Dubai', 'HH24:MI'),
           'description', t.description,
           'merchant_name', t.merchant_name,
           'category_name', t.category_name,
           'bank_code', t.bank_code,
           'card_last4', t.card_last4,
           'account_nickname', t.account_nickname,
           'direction', t.direction,
           'amount_original', t.amount_original::text,
           'currency_original', t.currency_original,
           'amount_aed', t.amount_aed::text,
           'net_aed', (case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)::numeric(14,2)::text,
           'amount_aed_is_estimate', t.amount_aed_is_estimate,
           'status', t.status,
           'source', case when t.has_sms and t.has_statement then 'both'
                          when t.has_sms then 'sms'
                          when t.has_statement then 'statement' end,
           'exclude_from_spend', t.exclude_from_spend,
           'notes', t.notes)
         order by t.txn_date desc, t.txn_at desc nulls last, t.txn_code desc), '[]'::jsonb)
  into v_out
  from private.activity_selection(p_profile_code, p_txn_codes, p_filter) t;
  return v_out;
end;
$$;
grant execute on function public.activity_export(text, text[], jsonb) to authenticated, service_role;

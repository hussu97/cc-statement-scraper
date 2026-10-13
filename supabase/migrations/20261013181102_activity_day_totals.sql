-- Per-day totals for the Activity date headers (audit MA-3, CLAUDE.md §2.2).
--
-- The Activity summary row (activity_summary) totals the whole filtered set; the date headers
-- showed only a date. activity_day_totals returns, for the days a page shows, each day's totals
-- over the WHOLE filtered set (not just the rows on the page, so a day split across two pages
-- reads the same on both):
--   {txn_date, txn_count, net_aed, unpriced_count, has_estimate}
-- net_aed is computed as activity_summary computes it: pending and posted only, debits minus
-- credits, a decimal string; txn_count counts every matching row, as the list shows them.
-- The filter is the web URL's filter object read by private.activity_selection
-- (20261013042808), the same reader as the bulk actions, so the headers and the list cannot
-- disagree about which rows match. The page's dates also bound the filter's from/to, so only
-- that span is read. One call per page: p_days is the page's distinct dates (at most 2000, the
-- largest page size). Days with no matching row are not returned.

create function public.activity_day_totals(p_profile_code text, p_filter jsonb default '{}'::jsonb,
                                           p_days date[] default '{}'::date[])
returns table (txn_date date, txn_count integer, net_aed text, unpriced_count integer, has_estimate boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_filter jsonb := coalesce(p_filter, '{}'::jsonb);
  v_min date;
  v_max date;
begin
  perform private.assert_member(p_profile_code, false);
  if coalesce(cardinality(p_days), 0) > 2000 then
    raise exception 'at most 2000 days' using errcode = '22023';
  end if;
  if jsonb_typeof(v_filter) <> 'object' then
    raise exception 'p_filter must be an object' using errcode = '22023';
  end if;
  select min(d), max(d) into v_min, v_max from unnest(p_days) d;
  if v_min is null then
    return;
  end if;
  -- Narrow the date range to the page's span (the filter's own bounds still apply).
  v_filter := v_filter || jsonb_build_object(
    'from', greatest(v_min, (v_filter->>'from')::date)::text,
    'to', least(v_max, (v_filter->>'to')::date)::text);

  return query
    select t.txn_date,
           count(*)::integer,
           coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)
                      filter (where t.status in ('pending', 'posted')), 0)::numeric(14,2)::text,
           (count(*) filter (where t.status in ('pending', 'posted') and t.amount_aed is null))::integer,
           coalesce(bool_or(t.amount_aed_is_estimate) filter (where t.status in ('pending', 'posted')), false)
    from private.activity_selection(p_profile_code, null, v_filter) t
    where t.txn_date = any (p_days)
    group by t.txn_date
    order by t.txn_date desc;
end;
$$;
grant execute on function public.activity_day_totals(text, jsonb, date[]) to authenticated, service_role;

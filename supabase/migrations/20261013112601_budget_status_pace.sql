-- budget_status says where a budget should be by today (audit WEB-38, CLAUDE.md §2.2).
--
-- A budget meter showed how much was used but not how much should have been by now, and "On pace
-- for" left the reader to work out the gap. Three new columns, all for the current month only
-- (null for a past or future month, where "by today" means nothing):
--   • expected_share  the share of the month gone, today included (elapsed days / days in month,
--                     4 dp): where the "expected by today" tick sits on the meter;
--   • expected_aed    the budget's even share by today: amount × expected_share, 2 dp;
--   • over_pace_aed   spent − expected_aed: positive is "AED X over pace", negative under pace.
-- Days elapsed are counted as projected_aed already counts them (Asia/Dubai, today included), so
-- over_pace_aed > 0 exactly when the month is on pace to overspend.
--
-- The columns are appended, so the iOS app, generate_insights and older web builds read the rows
-- as before. A new OUT column changes the return type, so the function is dropped first.

drop function public.budget_status(text, date, boolean);
create function public.budget_status(p_profile_code text, p_month date default null,
                                     p_include_inactive boolean default false)
returns table (budget_code text, category_code text, category_name text, color_token text,
               budget_aed numeric, spent_aed numeric, projected_aed numeric, share_used numeric,
               account_code text, account_name text, bank_code text, is_effective boolean,
               effective_from date, effective_to date,
               expected_share numeric, expected_aed numeric, over_pace_aed numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select private.assert_member(p_profile_code, false);

  with m as (
    select date_trunc('month', coalesce(p_month, public.dubai_date(now())))::date as start
  ),
  effective as (
    -- One budget per scope: the newest whose range covers the month.
    select distinct on (coalesce(bu.account_code, ''), coalesce(bu.category_code, '')) bu.budget_code
    from public.budgets bu, m
    where bu.profile_code = p_profile_code and bu.effective_from <= m.start
      and (bu.effective_to is null or bu.effective_to >= m.start)
    order by coalesce(bu.account_code, ''), coalesce(bu.category_code, ''), bu.effective_from desc
  ),
  b as (
    select bu.*, (e.budget_code is not null) as is_effective
    from public.budgets bu
    left join effective e on e.budget_code = bu.budget_code
    where bu.profile_code = p_profile_code
      and (e.budget_code is not null or p_include_inactive)
  ),
  spent as (
    select b.budget_code, coalesce(sum(s.spend_aed), 0) as amount
    from b cross join m
    left join public.v_spend s
      on s.profile_code = p_profile_code
     and s.txn_date >= m.start and s.txn_date < (m.start + interval '1 month')::date
     and (b.category_code is null or s.category_code = b.category_code)
     and (b.account_code is null or s.account_code = b.account_code)
    group by b.budget_code
  ),
  days as (
    select m.start,
           extract(day from ((m.start + interval '1 month')::date - 1))::numeric as in_month,
           least(greatest(public.dubai_date(now()) - m.start + 1, 1),
                 extract(day from ((m.start + interval '1 month')::date - 1))::int)::numeric as elapsed,
           m.start = date_trunc('month', public.dubai_date(now()))::date as is_current
    from m
  ),
  pace as (
    select days.*, case when days.is_current then round(days.elapsed / days.in_month, 4) end as share
    from days
  )
  select b.budget_code, b.category_code, coalesce(c.name, 'All spending'), c.color_token,
         b.amount_aed, sp.amount,
         round(sp.amount / pace.elapsed * pace.in_month, 2),
         round(sp.amount / b.amount_aed, 4),
         b.account_code,
         case when a.account_code is not null
              then coalesce(nullif(btrim(a.nickname), ''), concat_ws(' · ', a.bank_code, a.product_name)) end,
         a.bank_code,
         b.is_effective,
         b.effective_from,
         b.effective_to,
         pace.share,
         x.expected,
         sp.amount - x.expected
  from b
  join spent sp on sp.budget_code = b.budget_code
  cross join pace
  cross join lateral (
    select case when pace.is_current then round(b.amount_aed * pace.elapsed / pace.in_month, 2) end as expected
  ) x
  left join public.categories c on c.category_code = b.category_code
  left join public.accounts a on a.account_code = b.account_code
  order by b.is_effective desc, b.account_code nulls first, b.category_code nulls first, c.name,
           b.effective_from desc
$$;
grant execute on function public.budget_status(text, date, boolean) to authenticated, service_role;

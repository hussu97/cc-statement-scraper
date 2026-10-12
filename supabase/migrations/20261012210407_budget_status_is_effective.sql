-- budget_status says which budget counts (audit WEB-28, CLAUDE.md §2.2).
--
-- The month's budget for a scope (card × category) is the newest one whose range covers the
-- month; an older one of the same scope is "replaced". The web re-derived that choice to label
-- the budgets it didn't get back. Now the server says it:
--   • every row gains `is_effective` (true: this budget counts for the month), and the budget's
--     own `effective_from` / `effective_to`, so a client can say "Starts …" / "Ended …";
--   • `p_include_inactive => true` also returns the profile's other budgets (upcoming, ended,
--     replaced) with `is_effective = false`, and their figures against the same month.
-- Called as before (two arguments) it returns the same rows in the same order, plus the new
-- columns: generate_insights, the iOS app and older web builds keep working.
--
-- It also follows §1.6 now: a member check in the body (security definer, search_path '')
-- instead of relying on RLS, so a non-member gets 42501 rather than an empty list.

drop function public.budget_status(text, date);
create function public.budget_status(p_profile_code text, p_month date default null,
                                     p_include_inactive boolean default false)
returns table (budget_code text, category_code text, category_name text, color_token text,
               budget_aed numeric, spent_aed numeric, projected_aed numeric, share_used numeric,
               account_code text, account_name text, bank_code text, is_effective boolean,
               effective_from date, effective_to date)
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
                 extract(day from ((m.start + interval '1 month')::date - 1))::int)::numeric as elapsed
    from m
  )
  select b.budget_code, b.category_code, coalesce(c.name, 'All spending'), c.color_token,
         b.amount_aed, sp.amount,
         round(sp.amount / days.elapsed * days.in_month, 2),
         round(sp.amount / b.amount_aed, 4),
         b.account_code,
         case when a.account_code is not null
              then coalesce(nullif(btrim(a.nickname), ''), concat_ws(' · ', a.bank_code, a.product_name)) end,
         a.bank_code,
         b.is_effective,
         b.effective_from,
         b.effective_to
  from b
  join spent sp on sp.budget_code = b.budget_code
  cross join days
  left join public.categories c on c.category_code = b.category_code
  left join public.accounts a on a.account_code = b.account_code
  order by b.is_effective desc, b.account_code nulls first, b.category_code nulls first, c.name,
           b.effective_from desc
$$;
grant execute on function public.budget_status(text, date, boolean) to authenticated, service_role;

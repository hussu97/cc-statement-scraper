-- Recurring detection finds monthly billers whose amount varies (financial audit 2026-10-20).
--
-- private.detect_recurring kept a series only when its amounts were within 10% of each other
-- (cv < 0.10), so utility and telecom bills were never recurring:
--   FAB DEWA       one bill on the 1st of every month, AED 286–417 (cv ≈ 0.15)
--   FAB Etisalat   two bills on the 1st of every month (157.50–178.55 and 418.95), so the
--                  gaps alternated 0 and ~30 days and the median gap was not monthly
-- Now:
--   * charges to one merchant on one day are one billing event (their sum), so two bills on the
--     same day don't break the cadence;
--   * a monthly series whose gaps are steady (at least 4 events, 75% of gaps 26–35 days) is
--     recurring whatever the amount does; anything else still needs cv < 0.10.
-- Frequent purchases (Apple in-app, Tesla Supercharger, groceries) have no steady monthly gap
-- and stay out, as before.

create or replace function private.detect_recurring(p_profile_code text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_today date := public.dubai_date(now());
begin
  with events as (
    select s.merchant_code, s.txn_date, sum(s.spend_aed) as amount
    from public.v_spend s
    where s.profile_code = p_profile_code and s.merchant_code is not null and s.spend_aed > 0
      and s.txn_date >= v_today - 400
    group by s.merchant_code, s.txn_date
  ),
  charges as (
    select e.merchant_code, e.txn_date, e.amount,
           e.txn_date - lag(e.txn_date) over (partition by e.merchant_code order by e.txn_date) as gap
    from events e
  ),
  stats as (
    select merchant_code,
           count(*) as n,
           percentile_cont(0.5) within group (order by gap) as median_gap,
           avg((gap between 26 and 35)::int) as monthly_gap_share,
           avg(amount) as mean_amount,
           stddev_samp(amount) / nullif(avg(amount), 0) as cv,
           min(txn_date) as first_date,
           max(txn_date) as last_date,
           (array_agg(amount order by txn_date desc))[1] as last_amount
    from charges
    group by merchant_code
  ),
  classified as (
    select *,
           case
             when median_gap between 6 and 8 and n >= 4 then 'weekly'
             when median_gap between 26 and 35 and n >= 3 then 'monthly'
             when median_gap between 355 and 375 and n >= 2 then 'yearly'
           end as cadence
    from stats
  ),
  upserted as (
    insert into public.recurring_series (profile_code, merchant_code, cadence, expected_amount, last_amount,
      amount_cv, occurrences, first_date, last_date, next_expected)
    select p_profile_code, merchant_code, cadence, round(mean_amount, 2), last_amount, round(coalesce(cv, 0), 4), n,
           first_date, last_date,
           last_date + case cadence when 'weekly' then 7 when 'monthly' then 30 else 365 end
    from classified
    where cadence is not null
      and (coalesce(cv, 0) < 0.10
           or (cadence = 'monthly' and n >= 4 and monthly_gap_share >= 0.75))
    on conflict (profile_code, merchant_code) do update set
      cadence = excluded.cadence, expected_amount = excluded.expected_amount, last_amount = excluded.last_amount,
      amount_cv = excluded.amount_cv, occurrences = excluded.occurrences, last_date = excluded.last_date,
      next_expected = excluded.next_expected,
      status = case when public.recurring_series.status = 'dismissed' then 'dismissed' else 'active' end
    returning recurring_code, merchant_code
  )
  update public.transactions t set recurring_code = u.recurring_code
  from upserted u
  where t.profile_code = p_profile_code and t.merchant_code = u.merchant_code
    and t.recurring_code is distinct from u.recurring_code;
  get diagnostics v_count = row_count;

  -- A series that missed 1.5 cycles has ended.
  update public.recurring_series set status = 'ended'
  where profile_code = p_profile_code and status = 'active'
    and next_expected < v_today - case cadence when 'weekly' then 4 when 'monthly' then 15 else 60 end;
  return v_count;
end;
$$;

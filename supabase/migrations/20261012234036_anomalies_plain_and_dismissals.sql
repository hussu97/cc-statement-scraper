-- Anomalies in plain words, and a durable "This is fine" (audit WEB-16).
--
-- The Insights → Anomalies list showed raw statement descriptions ("BAYLEAF RESTAURANT,DUBAI"
-- beside "BAYLEAF RESTAURANT"), flagged "Large first purchase" on a charge *below* the category's
-- usual (the first-purchase rule had no comparison, and the baseline it printed was the
-- category's), and explained itself with "± one standard deviation". `anomalies` now:
--
--   * returns the merchant (`merchant_code`, `merchant_name`) and category (`category_code`,
--     `category_name`), so a client names the merchant the way Activity does;
--   * flags a first purchase (`new_merchant_large`) only when it is the first at a *known*
--     merchant AND above the threshold: at least AED 500 and, when the category has a usual
--     (≥ 5 purchases in the 365 days before), at least 2× that usual. A charge with no merchant
--     is never a "first purchase";
--   * says what it compared with: `baseline_scope` ('merchant' | 'category' | null) and
--     `baseline_mean` from that same scope (a category outlier at a merchant with history used to
--     print the merchant's mean), and `times_usual` = amount / baseline_mean, rounded for display
--     server-side (whole numbers from 3×, one decimal below), so "about 4× your usual Shopping
--     purchase" needs no client formula (CLAUDE.md §2.2);
--   * treats uncategorised spend as having no category usual (it is not one category);
--   * leaves out charges an owner dismissed with `dismiss_anomaly`.
--
-- Every earlier column is unchanged (txn_code, txn_date, description, amount, reason,
-- baseline_mean, baseline_sd), so private.generate_insights keeps working; it reads anomalies, so
-- a dismissed charge no longer becomes a `large_transaction` insight either. The function is now
-- SECURITY DEFINER with a member check in the body (§1.6–1.7), like budget_status, and filters by
-- profile itself.
--
-- "This is fine": public.dismiss_anomaly(profile, txn) records the charge in
-- public.anomaly_dismissals (owner only; members read) and dismisses the matching
-- `large_transaction` insight. The insight feed's rows expire after 14 days, so it can't be the
-- durable record. A dismissal goes with its transaction (FK, on delete cascade).

-- ── anomaly_dismissals ──────────────────────────────────────────────────────
create table public.anomaly_dismissals (
  dismissal_code text primary key default public.gen_code('dsm')
    check (dismissal_code ~ '^dsm_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  txn_code text not null,
  dismissed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint anomaly_dismissals_txn_uq unique (profile_code, txn_code),
  constraint anomaly_dismissals_txn_fkey foreign key (profile_code, txn_code)
    references public.transactions(profile_code, txn_code) on delete cascade
);
comment on table public.anomaly_dismissals is
  'Charges an owner marked "This is fine" on the Anomalies list (dismiss_anomaly); anomalies leaves them out.';

alter table public.anomaly_dismissals enable row level security;
create policy anomaly_dismissals_member_read on public.anomaly_dismissals for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.anomaly_dismissals to authenticated;
grant all on public.anomaly_dismissals to service_role;

-- ── anomalies ───────────────────────────────────────────────────────────────
drop function public.anomalies(text, date, date);
create function public.anomalies(p_profile_code text, p_from date, p_to date)
returns table(txn_code text, txn_date date, description text, amount numeric, reason text,
              baseline_mean numeric, baseline_sd numeric,
              merchant_code text, merchant_name text, category_code text, category_name text,
              baseline_scope text, times_usual numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select private.assert_member(p_profile_code, false);

  -- Baselines over the 365 days before each charge (its own day excluded), as window frames over
  -- one scan of v_spend (DB-32r).
  with hist as (
    select s.txn_code, s.txn_date, s.description, s.merchant_code, s.category_code, s.spend_aed
    from public.v_spend s
    where s.profile_code = p_profile_code and s.spend_aed > 0
      and s.txn_date >= p_from - 365 and s.txn_date <= p_to
  ),
  scored as (
    select h.txn_code, h.txn_date, h.description, h.merchant_code, h.category_code, h.spend_aed,
           case when h.merchant_code is null then 0 else count(*) over mw end as m_n,
           case when h.merchant_code is not null then avg(h.spend_aed) over mw end as m_mean,
           case when h.merchant_code is not null then stddev_samp(h.spend_aed) over mw end as m_sd,
           case when h.category_code is null then 0 else count(*) over cw end as c_n,
           case when h.category_code is not null then avg(h.spend_aed) over cw end as c_mean,
           case when h.category_code is not null then stddev_samp(h.spend_aed) over cw end as c_sd
    from hist h
    window mw as (partition by h.merchant_code order by h.txn_date
                  range between interval '365 days' preceding and interval '1 day' preceding),
           cw as (partition by h.category_code order by h.txn_date
                  range between interval '365 days' preceding and interval '1 day' preceding)
  ),
  flagged as (
    select s.*,
           case
             when s.m_n >= 5 and s.spend_aed > s.m_mean + 3 * coalesce(s.m_sd, 0)
                  and s.spend_aed > s.m_mean * 1.5 then 'merchant_outlier'
             when s.c_n >= 10 and s.spend_aed > s.c_mean + 3 * coalesce(s.c_sd, 0) then 'category_outlier'
             when s.merchant_code is not null and s.m_n = 0 and s.spend_aed >= 500
                  and (s.c_n < 5 or s.spend_aed >= 2 * s.c_mean) then 'new_merchant_large'
           end as reason
    from scored s
    where s.txn_date between p_from and p_to
  ),
  based as (
    select f.*,
           case
             when f.reason = 'merchant_outlier' then 'merchant'
             when f.reason = 'category_outlier' then 'category'
             when f.reason = 'new_merchant_large' and f.c_n >= 5 then 'category'
           end as scope
    from flagged f
    where f.reason is not null
      and not exists (select 1 from public.anomaly_dismissals d
                      where d.profile_code = p_profile_code and d.txn_code = f.txn_code)
  ),
  measured as (
    select b.*,
           case b.scope when 'merchant' then b.m_mean when 'category' then b.c_mean end as mean,
           case b.scope when 'merchant' then b.m_sd when 'category' then b.c_sd end as sd
    from based b
  )
  select x.txn_code, x.txn_date, x.description, x.spend_aed, x.reason,
         round(x.mean, 2), round(x.sd, 2),
         x.merchant_code, m.display_name, x.category_code, c.name,
         x.scope,
         case when x.mean > 0 then
           case when x.spend_aed / x.mean >= 3 then round(x.spend_aed / x.mean)
                else round(x.spend_aed / x.mean, 1) end
         end
  from measured x
  left join public.merchants m on m.merchant_code = x.merchant_code
  left join public.categories c on c.category_code = x.category_code
  order by x.spend_aed desc, x.txn_code
$$;
grant execute on function public.anomalies(text, date, date) to authenticated, service_role;

-- ── dismiss_anomaly ─────────────────────────────────────────────────────────
create function public.dismiss_anomaly(p_profile_code text, p_txn_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, true);
  if not exists (select 1 from public.transactions t
                 where t.profile_code = p_profile_code and t.txn_code = p_txn_code) then
    raise exception 'transaction % is not in profile %', p_txn_code, p_profile_code using errcode = 'P0002';
  end if;
  insert into public.anomaly_dismissals (profile_code, txn_code, dismissed_by)
  values (p_profile_code, p_txn_code, (select auth.uid()))
  on conflict (profile_code, txn_code) do nothing;
  update public.insights set dismissed_at = now()
  where profile_code = p_profile_code and kind = 'large_transaction' and dedupe_key = p_txn_code
    and dismissed_at is null;
end;
$$;
grant execute on function public.dismiss_anomaly(text, text) to authenticated, service_role;

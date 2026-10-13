-- Merchant context for the transaction drawer (audit MA-4, CLAUDE.md §1.12, §2.2).
--
-- "13 visits · avg AED 254 · AED 3,306 in 6 months · since Mar 2024": what a ledger has spent at a
-- merchant, from the one definition of spend (public.v_spend), so it agrees with the merchant
-- leaderboard and every other analytic. merchant_context(profile, merchant) returns
--   {merchant_code,
--    visit_count   purchases at the merchant, all time (v_spend rows with a positive amount;
--                  refunds are not visits),
--    avg_aed       their average, 2 dp (null with no visit),
--    total_6m_aed  net spend (refunds subtracted) dated within the last 6 months: after the same
--                  date 6 months ago (Asia/Dubai) up to today,
--    first_seen    the earliest v_spend date at the merchant (null when there is none)}
-- Money is a decimal string (§1.3). A merchant with no spend in the ledger returns zero visits,
-- not an error. Members only (SECURITY DEFINER with private.assert_member, filtered by profile).

create function public.merchant_context(p_profile_code text, p_merchant_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_since date := (public.dubai_date(now()) - interval '6 months')::date;
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  select jsonb_build_object(
           'merchant_code', p_merchant_code,
           'visit_count', count(*) filter (where s.spend_aed > 0),
           'avg_aed', (round(avg(s.spend_aed) filter (where s.spend_aed > 0), 2))::numeric(14,2)::text,
           'total_6m_aed', coalesce(sum(s.spend_aed) filter (where s.txn_date > v_since), 0)::numeric(14,2)::text,
           'first_seen', min(s.txn_date))
  into v_out
  from public.v_spend s
  where s.profile_code = p_profile_code and s.merchant_code = p_merchant_code;
  return v_out;
end;
$$;
grant execute on function public.merchant_context(text, text) to authenticated, service_role;

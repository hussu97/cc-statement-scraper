-- A share entered by hand (holdings.kind 'security' with a symbol and no broker behind it) is
-- valued at the latest Yahoo close (private.holding_values), but the stock-prices job only
-- fetched the shares a structured note follows. price_symbols now also
-- lists every such share, from a week before it was acquired (or added), so the daily job
-- backfills its history and keeps its value current. A broker-synced share (broker_positions:
-- Swissquote, Zerodha) keeps its broker's price and is not listed for it.

create or replace function public.price_symbols(p_profile_code text default null)
returns table (symbol text, from_date date, first_date date, last_date date)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  return query
  select s.symbol, min(s.from_date),
         (select min(sp.price_date) from public.security_prices sp where sp.symbol = s.symbol),
         (select max(sp.price_date) from public.security_prices sp where sp.symbol = s.symbol)
  from (
    select u.symbol, n.strike_date - 7 as from_date
    from public.structured_note_underlyings u
    join public.structured_notes n on n.note_code = u.note_code
    where n.status in ('live', 'autocalled', 'matured') and (n.ended_on is null or n.ended_on >= public.dubai_date(now()) - 7)
      and (p_profile_code is null or n.profile_code = p_profile_code)
    union all
    select h.symbol, h.acquired_on - 7
    from public.holdings h
    join public.structured_note_events e on e.delivered_holding_code = h.holding_code
    where h.status = 'active' and (p_profile_code is null or h.profile_code = p_profile_code)
    union all
    select upper(h.symbol), coalesce(h.acquired_on, public.dubai_date(h.created_at)) - 7
    from public.holdings h
    where h.kind = 'security' and h.symbol is not null and h.status = 'active'
      and not exists (select 1 from public.broker_positions bp where bp.holding_code = h.holding_code)
      and (p_profile_code is null or h.profile_code = p_profile_code)
  ) s
  group by s.symbol;
end;
$$;
grant execute on function public.price_symbols(text) to service_role;

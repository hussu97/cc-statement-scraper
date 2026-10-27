-- A note's shares on the broker account's positions (broker_portfolio, 20261027165732): each
-- share's initial level, latest close, % of initial and distance to the next autocall and coupon
-- levels, as the note screen shows them, so the positions list answers "how far from a call?".

create or replace function public.broker_portfolio(p_profile_code text, p_account_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.broker_connections;
  v_today date := public.dubai_date(now());
  v_as_of date;
  v_cash numeric;
  v_value numeric;
  v_positions jsonb;
  v_net numeric;
  v_income numeric;
  v_fees numeric;
  v_currency text;
begin
  perform private.assert_member(p_profile_code, false);
  select * into c from public.broker_connections where account_code = p_account_code and profile_code = p_profile_code;
  if not found then
    return null;
  end if;
  select a.currency into v_currency from public.accounts a where a.account_code = p_account_code;
  select max(bp.as_of) into v_as_of from public.broker_positions bp where bp.account_code = p_account_code;
  select b.balance into v_cash from public.v_bank_balances b where b.account_code = p_account_code;
  select coalesce(sum(bt.net_amount) filter (where bt.kind in ('deposit', 'withdrawal')), 0),
         coalesce(sum(bt.net_amount) filter (where bt.kind in ('coupon', 'dividend', 'interest')), 0),
         coalesce(-sum(bt.net_amount) filter (where bt.kind = 'fee'), 0)
    into v_net, v_income, v_fees
  from public.broker_transactions bt where bt.account_code = p_account_code;

  select coalesce(jsonb_agg(x.j order by x.value desc nulls last, x.j->>'name'), '[]'::jsonb), sum(x.value)
    into v_positions, v_value
  from (
    select bp.market_value as value, jsonb_build_object(
      'holding_code', h.holding_code, 'kind', h.kind, 'name', h.name, 'isin', bp.isin, 'security_name', bp.name,
      'symbol', bp.symbol, 'product_type', bp.product_type, 'quantity', bp.quantity, 'price', bp.price,
      'price_in_pct', bp.price_in_pct, 'currency', bp.currency, 'value', bp.market_value,
      'value_aed', private.to_aed(bp.market_value, bp.currency), 'as_of', bp.as_of,
      'cost', round(bp.quantity * bp.cost_price * case when bp.price_in_pct then 0.01 else 1 end, 2),
      'profit', bp.profit, 'invested', f.invested, 'income', f.income,
      -- Sold today: the bid value plus what it has paid so far, against what was invested.
      'sell_now', case when bp.market_value is not null and f.invested > 0 then jsonb_build_object(
        'total', bp.market_value + f.income, 'profit', bp.market_value + f.income - f.invested,
        'return_pct', round((bp.market_value + f.income) / f.invested * 100 - 100, 2)) end,
      'note', case when n.note_code is not null then jsonb_build_object(
        'status', ev.e->>'status', 'next', ev.e->'next', 'if_called_next', ev.e->'scenarios'->'autocall'->0,
        'if_ended_today', ev.e->'if_ended_today', 'worst_now', ev.e->'worst_now',
        'awaiting_prices', (ev.e->>'awaiting_prices')::boolean,
        -- Each share: its initial level, the latest close, % of initial, and how far it is from
        -- the next autocall and coupon levels (the note screen's table, on the position).
        'underlyings', ev.e->'underlyings') end) as j
    from public.broker_positions bp
    join public.holdings h on h.holding_code = bp.holding_code
    cross join lateral (
      select coalesce(sum(hf.amount) filter (where hf.kind = 'contribution'), 0) as invested,
             coalesce(sum(hf.amount) filter (where hf.kind = 'income'), 0) as income
      from public.holding_flows hf where hf.holding_code = h.holding_code and hf.removed_at is null
    ) f
    left join public.structured_notes n on n.holding_code = h.holding_code and n.status <> 'cancelled'
    left join lateral (select private.note_evaluate(n.note_code, v_today) as e where n.note_code is not null) ev on true
    where bp.account_code = p_account_code and bp.as_of = v_as_of
  ) x;

  return private.jsonb_decimal_strings(jsonb_build_object(
    'account_code', p_account_code, 'provider', c.provider, 'portfolio_ref', c.portfolio_ref, 'currency', v_currency,
    'sync', jsonb_build_object('last_synced_at', c.last_synced_at, 'last_attempt_at', c.last_attempt_at,
                               'status', c.last_status, 'error', c.last_error),
    'as_of', v_as_of,
    'cash', v_cash, 'positions_value', coalesce(v_value, 0), 'total', coalesce(v_cash, 0) + coalesce(v_value, 0),
    'total_aed', private.to_aed(coalesce(v_cash, 0) + coalesce(v_value, 0), v_currency),
    'net_deposits', v_net, 'profit', coalesce(v_cash, 0) + coalesce(v_value, 0) - v_net,
    'income', v_income, 'fees', v_fees,
    'positions', v_positions,
    'closed', coalesce((
      select jsonb_agg(jsonb_build_object(
               'holding_code', h.holding_code, 'kind', h.kind, 'name', h.name, 'isin', h.external_ref,
               'invested', f.invested, 'returned', f.returned, 'income', f.income,
               'profit', f.returned + f.income - f.invested,
               'return_pct', case when f.invested > 0 then round((f.returned + f.income) / f.invested * 100 - 100, 2) end,
               'annualised_pct', case when f.invested > 0 and f.closed_on > f.opened_on and f.returned + f.income > 0
                 then round((power((f.returned + f.income) / f.invested, 365.0 / (f.closed_on - f.opened_on)) - 1) * 100, 2) end,
               'opened_on', f.opened_on, 'closed_on', f.closed_on,
               'note_status', n.status) order by f.closed_on desc)
      from public.holdings h
      cross join lateral (
        select coalesce(sum(hf.amount) filter (where hf.kind = 'contribution'), 0) as invested,
               coalesce(sum(hf.amount) filter (where hf.kind = 'withdrawal'), 0) as returned,
               coalesce(sum(hf.amount) filter (where hf.kind = 'income'), 0) as income,
               min(hf.flow_date) as opened_on, max(hf.flow_date) as closed_on
        from public.holding_flows hf where hf.holding_code = h.holding_code and hf.removed_at is null
      ) f
      left join public.structured_notes n on n.holding_code = h.holding_code and n.status <> 'cancelled'
      where h.profile_code = p_profile_code and h.status = 'closed'
        and exists (select 1 from public.broker_transactions bt
                    where bt.account_code = p_account_code and bt.holding_code = h.holding_code)), '[]'::jsonb),
    'series', coalesce((
      select jsonb_agg(jsonb_build_object('as_of', s.as_of, 'total', s.total_value, 'cash', s.cash,
                                          'positions', s.positions_value, 'net_deposits', d.net,
                                          'estimated', s.estimated) order by s.as_of)
      from public.broker_snapshots s
      cross join lateral (
        select coalesce(sum(bt.net_amount), 0) as net from public.broker_transactions bt
        where bt.account_code = p_account_code and bt.kind in ('deposit', 'withdrawal')
          and public.dubai_date(bt.booked_at) <= s.as_of
      ) d
      where s.account_code = p_account_code), '[]'::jsonb)));
end;
$$;

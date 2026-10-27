-- Notes in one line (the screens' redesign, 27 Oct): a verdict per live note, what ended
-- positions came to, and a summary of each synced broker account for Investments.
--
-- private.note_verdict(evaluation, status) answers "what do I need to know?" from the
-- evaluator's levels (distance_pct > 0: the worst share must rise that much):
--   ended            the note is over
--   awaiting_prices  no close for every share yet
--   on_track         every share is at or above the next autocall trigger: called on `date`
--   coupon_at_risk   the worst share is below the next coupon barrier (`symbol`, `gap_pct` to it,
--                    `date`); `call_gap_pct` / `call_date` for the call
--   needs            the worst share must rise `gap_pct` by `date` for a call
--   to_maturity      no autocall left: `date` is the final valuation, `gap_pct` the worst share's
--                    distance to break-even (<= 0: at or above it)
-- The apps word it; they never work it out (CLAUDE.md §2.2).

create function private.note_verdict(e jsonb, p_status text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_status in ('autocalled', 'matured', 'cancelled') then jsonb_build_object('kind', 'ended')
    when coalesce((e->>'awaiting_prices')::boolean, false) or e->'worst_now' is null
      or jsonb_typeof(e->'worst_now') = 'null' then jsonb_build_object('kind', 'awaiting_prices')
    when ac.l is not null and (ac.l->>'distance_pct')::numeric <= 0
      then jsonb_build_object('kind', 'on_track', 'date', ac.l->>'date', 'symbol', e->'worst_now'->>'symbol',
                              'gap_pct', ac.l->>'distance_pct')
    when cp.l is not null and (cp.l->>'distance_pct')::numeric > 0
      then jsonb_build_object('kind', 'coupon_at_risk', 'symbol', e->'worst_now'->>'symbol',
                              'gap_pct', cp.l->>'distance_pct', 'date', cp.l->>'date',
                              'call_gap_pct', ac.l->>'distance_pct', 'call_date', ac.l->>'date')
    when ac.l is not null
      then jsonb_build_object('kind', 'needs', 'symbol', e->'worst_now'->>'symbol', 'gap_pct', ac.l->>'distance_pct',
                              'date', ac.l->>'date')
    else jsonb_build_object('kind', 'to_maturity', 'symbol', e->'worst_now'->>'symbol',
                            'date', coalesce(fin.d, e->'next'->>'obs_date'), 'gap_pct', be.l->>'distance_pct')
  end
  from (select (select l from jsonb_array_elements(coalesce(e->'levels', '[]'::jsonb)) l
                where l->>'kind' = 'autocall' limit 1)) ac(l)
  cross join (select (select l from jsonb_array_elements(coalesce(e->'levels', '[]'::jsonb)) l
                      where l->>'kind' = 'coupon' limit 1)) cp(l)
  cross join (select (select l from jsonb_array_elements(coalesce(e->'levels', '[]'::jsonb)) l
                      where l->>'kind' = 'break_even' limit 1)) be(l)
  cross join (select (select l->>'date' from jsonb_array_elements(coalesce(e->'levels', '[]'::jsonb)) l
                      where l->>'kind' in ('final', 'break_even') order by l->>'date' desc limit 1)) fin(d)
$$;
comment on function private.note_verdict(jsonb, text) is
  'A live note in one line from its evaluation: ended, awaiting_prices, on_track, coupon_at_risk, needs or to_maturity, with the share, gap and date it is about.';

-- note_summary (20261027165732): + verdict.
create or replace function private.note_summary(n public.structured_notes, e jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'note_code', n.note_code, 'holding_code', n.holding_code, 'name', h.name, 'institution', h.institution,
    'product_name', n.product_name, 'isin', n.isin, 'issuer', n.issuer, 'currency', n.currency,
    'status', case when n.status = 'cancelled' then 'cancelled' when b.by_broker then n.status else e->>'status' end,
    'awaiting_prices', case when b.by_broker then false else (e->>'awaiting_prices')::boolean end,
    'trade_date', n.trade_date, 'maturity_date', n.maturity_date, 'ended_on', coalesce(n.ended_on, (e->>'ended_on')::date),
    'invested', n.invested_amount::text, 'nominal', n.nominal::text, 'purchase_price_pct', n.purchase_price_pct::text,
    'funding_account_code', n.funding_account_code,
    'received', e->'received', 'due', e->'due',
    -- Ended by the broker before its closes could tell (a synced note): the result is what the
    -- broker paid back and paid out (20261027165732).
    'result', case when b.by_broker then jsonb_build_object(
                     'total', (f.returned + f.income)::numeric(14,2)::text,
                     'profit', (f.returned + f.income - n.invested_amount)::numeric(14,2)::text,
                     'return_pct', round((f.returned + f.income) / n.invested_amount * 100 - 100, 2)::text)
                   else e->'result' end,
    'worst_now', e->'worst_now', 'break_even_pct', e->>'break_even_pct',
    'next', case when not b.by_broker then e->'next' end,
    'if_ended_today', case when not b.by_broker then e->'if_ended_today' end,
    -- What it fetches sold today (the broker's bid on the latest mark) and what it pays if called
    -- at its next autocall date (20261027165732).
    'market', (select jsonb_build_object('price_pct', case when bp.price_in_pct then bp.price::numeric(12,4)::text end,
                                         'value', bp.market_value::text, 'as_of', bp.as_of,
                                         'profit', (bp.market_value + coalesce((e->'received'->>'coupons')::numeric, 0)
                                                    - n.invested_amount)::numeric(14,2)::text)
               from public.broker_positions bp
               where bp.holding_code = n.holding_code and bp.market_value is not null and n.status = 'live'
               order by bp.as_of desc limit 1),
    'if_called_next', case when not b.by_broker then e->'scenarios'->'autocall'->0 end,
    'verdict', private.note_verdict(e, case when n.status = 'cancelled' or b.by_broker then n.status else e->>'status' end),
    'symbols', (select jsonb_agg(u.symbol order by u.ordinal) from public.structured_note_underlyings u
                where u.note_code = n.note_code))
  from public.holdings h
  cross join lateral (
    select n.status in ('autocalled', 'matured') and coalesce(e->>'status', '') not in ('autocalled', 'matured') as by_broker
  ) b
  cross join lateral (
    select coalesce(sum(hf.amount) filter (where hf.kind = 'withdrawal'), 0) as returned,
           coalesce(sum(hf.amount) filter (where hf.kind = 'income'), 0) as income
    from public.holding_flows hf where hf.holding_code = n.holding_code and hf.removed_at is null
  ) f
  where h.holding_code = n.holding_code
$$;

-- broker_portfolio (20261027190028): + each note's verdict, + closed_total.
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
        'underlyings', ev.e->'underlyings',
        'verdict', private.note_verdict(ev.e, n.status)) end) as j
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
    -- What the ended positions came to, together.
    'closed_total', (
      select jsonb_build_object('count', count(*), 'invested', coalesce(sum(f.invested), 0),
                                'received', coalesce(sum(f.returned + f.income), 0),
                                'profit', coalesce(sum(f.returned + f.income - f.invested), 0))
      from public.holdings h
      cross join lateral (
        select coalesce(sum(hf.amount) filter (where hf.kind = 'contribution'), 0) as invested,
               coalesce(sum(hf.amount) filter (where hf.kind = 'withdrawal'), 0) as returned,
               coalesce(sum(hf.amount) filter (where hf.kind = 'income'), 0) as income
        from public.holding_flows hf where hf.holding_code = h.holding_code and hf.removed_at is null
      ) f
      where h.profile_code = p_profile_code and h.status = 'closed'
        and exists (select 1 from public.broker_transactions bt
                    where bt.account_code = p_account_code and bt.holding_code = h.holding_code)),
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

-- Member: each synced broker account in one line, for Investments (which then lists the
-- account instead of its positions one by one): value, cash, net deposits, profit, live notes
-- and the holdings it holds. Decimal strings.
create function public.broker_accounts_summary(p_profile_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, false);
  return private.jsonb_decimal_strings(coalesce((
    select jsonb_agg(jsonb_build_object(
             'account_code', c.account_code, 'provider', c.provider, 'bank_code', a.bank_code,
             'name', coalesce(b.name, c.provider), 'currency', a.currency,
             'cash', x.cash, 'positions_value', x.pv, 'total', x.cash + x.pv,
             'total_aed', private.to_aed(x.cash + x.pv, a.currency),
             'net_deposits', x.net, 'profit', x.cash + x.pv - x.net,
             'live_notes', x.live_notes, 'positions', x.positions,
             'last_synced_at', c.last_synced_at, 'sync_status', c.last_status,
             'holding_codes', coalesce(x.holdings, '[]'::jsonb)) order by c.created_at)
    from public.broker_connections c
    join public.accounts a on a.account_code = c.account_code
    left join public.banks b on b.bank_code = a.bank_code
    cross join lateral (
      select coalesce((select v.balance from public.v_bank_balances v where v.account_code = c.account_code), 0) as cash,
             coalesce((select sum(bp.market_value) from public.broker_positions bp
                       where bp.account_code = c.account_code
                         and bp.as_of = (select max(bp2.as_of) from public.broker_positions bp2
                                         where bp2.account_code = c.account_code)), 0) as pv,
             coalesce((select sum(bt.net_amount) from public.broker_transactions bt
                       where bt.account_code = c.account_code and bt.kind in ('deposit', 'withdrawal')), 0) as net,
             (select count(*) from public.structured_notes n
              where n.funding_account_code = c.account_code and n.status = 'live') as live_notes,
             (select count(*) from public.broker_positions bp
              where bp.account_code = c.account_code
                and bp.as_of = (select max(bp2.as_of) from public.broker_positions bp2
                                where bp2.account_code = c.account_code)) as positions,
             (select jsonb_agg(distinct bt.holding_code) from public.broker_transactions bt
              where bt.account_code = c.account_code and bt.holding_code is not null) as holdings
    ) x
    where c.profile_code = p_profile_code), '[]'::jsonb));
end;
$$;
comment on function public.broker_accounts_summary(text) is
  'Member: each synced broker account in one line (value, cash, net deposits, profit, live notes, its holdings) for Investments. Decimal strings.';
grant execute on function public.broker_accounts_summary(text) to authenticated, service_role;

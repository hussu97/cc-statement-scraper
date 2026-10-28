-- Zerodha sync: Kite (stocks, ETFs) and Coin (mutual funds) holdings, invested against current
-- value, and their value per day (tasks/todo.md §12).
--
-- The zerodha-sync Edge Function signs in to Kite Connect nightly (the free Personal plan: the
-- user's own app), reads /portfolio/holdings, /mf/holdings and /user/margins, and hands them to
-- public.import_zerodha_data:
-- 1. A broker connection (provider 'zerodha', portfolio_ref = the Kite user id) with an INR cash
--    account at Zerodha (bank ZRD): Funds' cash is a `broker` balance checkpoint.
-- 2. Each ISIN is a `security` holding (units × a unit price per day), with no symbol so the
--    Yahoo price job leaves it alone. broker_positions keeps each day's mark, with
--    product_type EQUITY (Kite) or MUTUAL_FUND (Coin) and the average price as cost.
-- 3. The free plan has no trade history, so the holding's flows are inferred from day to day:
--    the first sight of a position is a contribution at cost, more units add the cost added,
--    fewer units are a withdrawal at the day's price, and a position gone from a segment that was
--    read is closed at its last price. One flow per holding and day (`zerodha:<isin>:<day>`), so
--    a re-run replaces it.
-- 4. broker_snapshots: the account's value per day (cash + positions). A segment whose read
--    failed keeps its last marks for the day, so the day's value stays whole.
-- 5. broker_portfolio / broker_accounts_summary gain `invested` (the cost of the open positions)
--    and `basis`. A Zerodha account's `net_deposits` is invested + cash (basis 'cost'), so its
--    profit is the unrealised P&L and older apps still read it. Zerodha adds `segments`
--    (Kite and Coin), each position's `segment`, and each day's invested amount.
-- Money crosses the wire as decimal strings (§1.3); every figure is computed here (§2.2).

-- ── 1. Zerodha, INR ─────────────────────────────────────────────────────────
alter table public.broker_connections drop constraint broker_connections_provider_check;
alter table public.broker_connections add constraint broker_connections_provider_check
  check (provider in ('swissquote', 'zerodha'));

-- The logo is Zerodha's own icon (assets/banks/ZRD.png), uploaded with
-- scripts/brand/upload-bank-logos.sh.
insert into public.banks (bank_code, name, sms_senders, logo_path)
values ('ZRD', 'Zerodha', '{}', 'ZRD.png')
on conflict (bank_code) do nothing;

-- Every bank carries an FX markup (05_fx_rates). The Zerodha account holds INR and has no card,
-- so nothing is estimated with it.
insert into private.bank_fx_fees (bank_code, markup, note)
values ('ZRD', 0, 'no card in the ledger: INR cash only, no FX')
on conflict (bank_code) do nothing;

-- Kite or Coin, from a mark's product type.
create function private.zerodha_segment(p_product_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_product_type = 'MUTUAL_FUND' then 'coin' else 'kite' end
$$;

-- ── 2. import ───────────────────────────────────────────────────────────────
-- Service (zerodha-sync): one Kite user's holdings, idempotent per day. p_data (decimal strings):
-- {user_id, fetched_at, cash|null, segments_read: ['kite', 'coin'],
--  positions: [{segment: 'kite'|'coin', isin, name, symbol, quantity, price, cost_price}]}
-- A segment not in segments_read (its read failed) keeps its last marks for the day, copied, so
-- the day's value stays whole; nothing in it is closed.
create function public.import_zerodha_data(p_profile_code text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ref text := upper(btrim(coalesce(p_data->>'user_id', '')));
  v_fetched timestamptz := coalesce((p_data->>'fetched_at')::timestamptz, now());
  v_day date := public.dubai_date(coalesce((p_data->>'fetched_at')::timestamptz, now()));
  v_read text[] := array(select jsonb_array_elements_text(coalesce(p_data->'segments_read', '[]'::jsonb)));
  v_cash numeric := nullif(p_data->>'cash', '')::numeric;
  c public.broker_connections;
  v_account text;
  r record;
  v_holding text;
  v_kind text;
  v_prev public.broker_positions;
  v_opening boolean;
  v_cost numeric;
  v_value numeric;
  v_flow_kind text;
  v_flow numeric;
  v_ext text;
  v_balance numeric;
  v_checkpoint boolean := false;
  v_positions_value numeric;
  v_marks int := 0;
  v_flows int := 0;
  v_closed int := 0;
begin
  perform private.assert_service_role();
  if v_ref !~ '^[A-Z0-9]{4,12}$' then
    raise exception 'user_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_read) s where s not in ('kite', 'coin')) then
    raise exception 'segments_read takes kite and coin' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_data->'positions', '[]'::jsonb)) p
             where coalesce(p->>'segment', '') not in ('kite', 'coin')) then
    raise exception 'a position''s segment is kite or coin' using errcode = '22023';
  end if;

  -- The cash account: the connection's, else the ledger's unlinked INR account at Zerodha, else a
  -- new one.
  select * into c from public.broker_connections where provider = 'zerodha' and portfolio_ref = v_ref;
  if found and c.profile_code <> p_profile_code then
    raise exception 'this portfolio belongs to another ledger' using errcode = '42501';
  end if;
  if found then
    v_account := c.account_code;
  else
    select a.account_code into v_account from public.accounts a
    where a.profile_code = p_profile_code and a.bank_code = 'ZRD' and a.kind in ('current', 'savings')
      and a.currency = 'INR' and a.status = 'active'
      and not exists (select 1 from public.broker_connections x where x.account_code = a.account_code)
    order by a.created_at limit 1;
    if v_account is null then
      insert into public.accounts (profile_code, bank_code, kind, currency, product_name)
      values (p_profile_code, 'ZRD', 'current', 'INR', 'Trading account')
      returning account_code into v_account;
    end if;
    insert into public.broker_connections (profile_code, account_code, provider, portfolio_ref)
    values (p_profile_code, v_account, 'zerodha', v_ref)
    returning * into c;
  end if;

  -- Today's marks, one per ISIN (a fund in both lists is Coin's), and each holding's flow for the day.
  for r in
    select distinct on (p->>'isin') p->>'isin' as isin, p->>'segment' as segment,
           left(btrim(coalesce(nullif(btrim(p->>'name'), ''), p->>'symbol', p->>'isin')), 200) as name,
           left(nullif(btrim(p->>'symbol'), ''), 40) as symbol,
           (p->>'quantity')::numeric as quantity, nullif(p->>'price', '')::numeric as price,
           coalesce(nullif(p->>'cost_price', '')::numeric, 0) as cost_price
    from jsonb_array_elements(coalesce(p_data->'positions', '[]'::jsonb)) p
    where p->>'isin' ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$' and p->>'segment' = any (v_read)
      and (p->>'quantity')::numeric > 0
    order by p->>'isin', (p->>'segment' = 'coin') desc
  loop
    select h.holding_code, h.kind into v_holding, v_kind from public.holdings h
    where h.profile_code = p_profile_code and h.external_ref = r.isin;
    if v_holding is null then
      insert into public.holdings (profile_code, name, kind, currency, institution, units, notes, external_ref)
      values (p_profile_code, left(r.name, 80), 'security', 'INR',
              case r.segment when 'coin' then 'Zerodha Coin' else 'Zerodha Kite' end, r.quantity,
              'Synced from Zerodha; ISIN ' || r.isin, r.isin)
      returning holding_code, kind into v_holding, v_kind;
    end if;

    -- Seen again on a day a re-run had closed it: that close is taken back.
    v_ext := 'zerodha:' || r.isin || ':' || v_day;
    delete from public.holding_flows where holding_code = v_holding and external_ref = v_ext || ':closed';
    -- The day before's mark, unless the position was closed since (then this is a new opening).
    select * into v_prev from public.broker_positions bp
    where bp.account_code = v_account and bp.isin = r.isin and bp.as_of < v_day
    order by bp.as_of desc limit 1;
    v_opening := v_prev.position_code is null or exists (
      select 1 from public.holding_flows hf
      where hf.holding_code = v_holding and hf.removed_at is null and hf.flow_date > v_prev.as_of
        and hf.external_ref like 'zerodha:%:closed');
    v_cost := round(r.quantity * r.cost_price, 2);
    v_value := round(r.quantity * r.price, 2);
    v_flow_kind := null;
    v_flow := null;
    if v_opening then
      v_flow_kind := 'contribution';
      v_flow := v_cost;
    elsif r.quantity > v_prev.quantity then
      v_flow_kind := 'contribution';
      v_flow := v_cost - round(v_prev.quantity * coalesce(v_prev.cost_price, 0), 2);
    elsif r.quantity < v_prev.quantity then
      v_flow_kind := 'withdrawal';
      v_flow := round((v_prev.quantity - r.quantity) * coalesce(r.price, v_prev.price, 0), 2);
    end if;
    if v_flow > 0 and private.to_aed(v_flow, 'INR') > 0 then
      insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source,
                                        external_ref, notes)
      values (p_profile_code, v_holding, v_day, v_flow_kind, v_flow, private.to_aed(v_flow, 'INR'), 'import', v_ext,
              case v_flow_kind when 'contribution' then 'Zerodha: ' || r.quantity::text || ' units held, at cost'
                               else 'Zerodha: fewer units held, at the day''s price' end)
      on conflict (holding_code, external_ref) where external_ref is not null do update set
        kind = excluded.kind, amount = excluded.amount, amount_aed = excluded.amount_aed, notes = excluded.notes,
        removed_at = null;
      v_flows := v_flows + 1;
    else
      -- A re-run that no longer sees a change takes back the day's flow.
      delete from public.holding_flows where holding_code = v_holding and external_ref = v_ext;
    end if;

    insert into public.broker_positions (profile_code, account_code, holding_code, as_of, isin, name, symbol, product_type,
      quantity, price, price_in_pct, market_value, cost_price, profit, currency, fetched_at)
    values (p_profile_code, v_account, v_holding, v_day, r.isin, r.name, r.symbol,
      case r.segment when 'coin' then 'MUTUAL_FUND' else 'EQUITY' end, r.quantity, r.price, false, v_value,
      r.cost_price, v_value - v_cost, 'INR', v_fetched)
    on conflict (account_code, as_of, isin) do update set
      holding_code = excluded.holding_code, name = excluded.name, symbol = excluded.symbol,
      product_type = excluded.product_type, quantity = excluded.quantity, price = excluded.price,
      market_value = excluded.market_value, cost_price = excluded.cost_price, profit = excluded.profit,
      fetched_at = excluded.fetched_at;
    update public.holdings h set status = 'active',
      units = case when h.kind = 'security' then r.quantity else h.units end
    where h.holding_code = v_holding;
    -- The holding's value for the day: a security's unit price, anything else its market value.
    if v_kind = 'security' and r.price is not null then
      update public.holding_valuations set unit_price = r.price, value = null
      where holding_code = v_holding and as_of = v_day and source = 'import';
      if not found then
        insert into public.holding_valuations (profile_code, holding_code, as_of, unit_price, source)
        values (p_profile_code, v_holding, v_day, r.price, 'import');
      end if;
    elsif v_value is not null then
      update public.holding_valuations set value = v_value, unit_price = null
      where holding_code = v_holding and as_of = v_day and source = 'import';
      if not found then
        insert into public.holding_valuations (profile_code, holding_code, as_of, value, source)
        values (p_profile_code, v_holding, v_day, v_value, 'import');
      end if;
    end if;
    v_marks := v_marks + 1;
  end loop;

  -- A same-day re-run after a sale: today's mark of a position no longer held goes.
  delete from public.broker_positions bp
  where bp.account_code = v_account and bp.as_of = v_day and private.zerodha_segment(bp.product_type) = any (v_read)
    and not exists (select 1 from jsonb_array_elements(coalesce(p_data->'positions', '[]'::jsonb)) p
                    where p->>'isin' = bp.isin and (p->>'quantity')::numeric > 0);

  -- A position the segment no longer reports was sold or redeemed: closed at its last price. One
  -- closed since its last mark (a same-day re-run took back the day it was seen again) just closes.
  for r in
    select h.holding_code, h.external_ref as isin, lp.quantity, lp.price, lp.as_of
    from public.holdings h
    cross join lateral (
      select bp.quantity, bp.price, bp.product_type, bp.as_of from public.broker_positions bp
      where bp.account_code = v_account and bp.holding_code = h.holding_code
      order by bp.as_of desc limit 1
    ) lp
    where h.profile_code = p_profile_code and h.status = 'active'
      and private.zerodha_segment(lp.product_type) = any (v_read)
      and not exists (select 1 from jsonb_array_elements(coalesce(p_data->'positions', '[]'::jsonb)) p
                      where p->>'isin' = h.external_ref and (p->>'quantity')::numeric > 0)
  loop
    update public.holdings set status = 'closed' where holding_code = r.holding_code;
    delete from public.holding_flows where holding_code = r.holding_code and external_ref = 'zerodha:' || r.isin || ':' || v_day;
    v_flow := round(r.quantity * coalesce(r.price, 0), 2);
    if v_flow > 0 and not exists (
         select 1 from public.holding_flows hf
         where hf.holding_code = r.holding_code and hf.removed_at is null and hf.flow_date > r.as_of
           and hf.external_ref like 'zerodha:%:closed') and private.to_aed(v_flow, 'INR') > 0 then
      insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source,
                                        external_ref, notes)
      values (p_profile_code, r.holding_code, v_day, 'withdrawal', v_flow, private.to_aed(v_flow, 'INR'), 'import',
              'zerodha:' || r.isin || ':' || v_day || ':closed', 'Zerodha: no longer held, at its last price')
      on conflict (holding_code, external_ref) where external_ref is not null do nothing;
    end if;
    v_closed := v_closed + 1;
  end loop;

  -- A segment that could not be read keeps its last marks (prices as they were).
  insert into public.broker_positions (profile_code, account_code, holding_code, as_of, isin, name, symbol, product_type,
    quantity, price, price_in_pct, market_value, cost_price, profit, currency, fetched_at)
  select bp.profile_code, bp.account_code, bp.holding_code, v_day, bp.isin, bp.name, bp.symbol, bp.product_type,
         bp.quantity, bp.price, bp.price_in_pct, bp.market_value, bp.cost_price, bp.profit, bp.currency, bp.fetched_at
  from public.broker_positions bp
  join public.holdings h on h.holding_code = bp.holding_code and h.status = 'active'
  where bp.account_code = v_account and not (private.zerodha_segment(bp.product_type) = any (v_read))
    and bp.as_of = (select max(x.as_of) from public.broker_positions x
                    where x.account_code = v_account and x.as_of < v_day
                      and private.zerodha_segment(x.product_type) = private.zerodha_segment(bp.product_type))
  on conflict (account_code, as_of, isin) do nothing;

  -- Funds' cash as Zerodha states it, whenever it differs from the ledger's or the last is a day old.
  if v_cash is not null then
    select b.balance into v_balance from public.v_bank_balances b where b.account_code = v_account;
    if v_balance is distinct from v_cash
       or not exists (select 1 from public.balance_checkpoints b where b.account_code = v_account
                      and b.as_of > v_fetched - interval '20 hours') then
      insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source)
      values (p_profile_code, v_account, v_fetched, v_cash, 'broker');
      v_checkpoint := true;
    end if;
  end if;

  -- The account's value for the day.
  select coalesce(sum(bp.market_value), 0) into v_positions_value from public.broker_positions bp
  where bp.account_code = v_account and bp.as_of = v_day;
  v_cash := coalesce(v_cash, (select b.balance from public.v_bank_balances b where b.account_code = v_account), 0);
  insert into public.broker_snapshots (profile_code, account_code, as_of, currency, cash, positions_value, total_value, estimated)
  values (p_profile_code, v_account, v_day, 'INR', v_cash, v_positions_value, v_cash + v_positions_value, false)
  on conflict (account_code, as_of) do update set
    cash = excluded.cash, positions_value = excluded.positions_value, total_value = excluded.total_value, estimated = false;

  update public.broker_connections set last_attempt_at = now(), last_synced_at = now(), last_status = 'ok', last_error = null
  where connection_code = c.connection_code;

  return jsonb_build_object('account_code', v_account, 'positions_marked', v_marks, 'flows', v_flows,
                            'positions_closed', v_closed, 'checkpoint', v_checkpoint,
                            'value', v_cash + v_positions_value);
end;
$$;
comment on function public.import_zerodha_data(text, jsonb) is
  'Service (zerodha-sync): a Kite user''s Kite and Coin holdings, Funds cash and the day''s value for one ledger; idempotent per day. Flows are inferred from day to day.';
grant execute on function public.import_zerodha_data(text, jsonb) to service_role;

-- ── 3. the account screen ───────────────────────────────────────────────────
-- A holding is the broker account's when the account has a row or a mark for it.
create function private.broker_account_holds(p_account_code text, p_holding_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from public.broker_transactions bt
                 where bt.account_code = p_account_code and bt.holding_code = p_holding_code)
      or exists (select 1 from public.broker_positions bp
                 where bp.account_code = p_account_code and bp.holding_code = p_holding_code)
$$;

-- broker_portfolio (20261027200000): + invested and basis; a holding is the account's when it has
-- a broker row or a mark; Zerodha: net deposits = invested + cash, segments (Kite, Coin), each
-- position's segment and return, each day's invested amount and segments.
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
  v_invested numeric;
  v_positions jsonb;
  v_net numeric;
  v_income numeric;
  v_fees numeric;
  v_currency text;
  v_cost_basis boolean;
begin
  perform private.assert_member(p_profile_code, false);
  select * into c from public.broker_connections where account_code = p_account_code and profile_code = p_profile_code;
  if not found then
    return null;
  end if;
  v_cost_basis := c.provider = 'zerodha';
  select a.currency into v_currency from public.accounts a where a.account_code = p_account_code;
  select max(bp.as_of) into v_as_of from public.broker_positions bp where bp.account_code = p_account_code;
  select b.balance into v_cash from public.v_bank_balances b where b.account_code = p_account_code;
  select coalesce(sum(bt.net_amount) filter (where bt.kind in ('deposit', 'withdrawal')), 0),
         coalesce(sum(bt.net_amount) filter (where bt.kind in ('coupon', 'dividend', 'interest')), 0),
         coalesce(-sum(bt.net_amount) filter (where bt.kind = 'fee'), 0)
    into v_net, v_income, v_fees
  from public.broker_transactions bt where bt.account_code = p_account_code;

  select coalesce(jsonb_agg(x.j order by x.value desc nulls last, x.j->>'name'), '[]'::jsonb), sum(x.value), sum(x.cost)
    into v_positions, v_value, v_invested
  from (
    select bp.market_value as value, k.cost, jsonb_build_object(
      'holding_code', h.holding_code, 'kind', h.kind, 'name', h.name, 'isin', bp.isin, 'security_name', bp.name,
      'symbol', bp.symbol, 'product_type', bp.product_type, 'quantity', bp.quantity, 'price', bp.price,
      'price_in_pct', bp.price_in_pct, 'currency', bp.currency, 'value', bp.market_value,
      'value_aed', private.to_aed(bp.market_value, bp.currency), 'as_of', bp.as_of,
      'cost', k.cost, 'profit', bp.profit, 'invested', f.invested, 'income', f.income,
      'segment', case when v_cost_basis then private.zerodha_segment(bp.product_type) end,
      -- Sold today: the bid value plus what it has paid so far, against what was invested (at
      -- Zerodha, against what it cost: there is no trade history).
      'sell_now', case
        when v_cost_basis then case when bp.market_value is not null and k.cost > 0 then jsonb_build_object(
          'total', bp.market_value, 'profit', bp.market_value - k.cost,
          'return_pct', round(bp.market_value / k.cost * 100 - 100, 2)) end
        when bp.market_value is not null and f.invested > 0 then jsonb_build_object(
          'total', bp.market_value + f.income, 'profit', bp.market_value + f.income - f.invested,
          'return_pct', round((bp.market_value + f.income) / f.invested * 100 - 100, 2)) end,
      'note', case when n.note_code is not null then jsonb_build_object(
        'status', ev.e->>'status', 'next', ev.e->'next', 'if_called_next', ev.e->'scenarios'->'autocall'->0,
        'if_ended_today', ev.e->'if_ended_today', 'worst_now', ev.e->'worst_now',
        'awaiting_prices', (ev.e->>'awaiting_prices')::boolean,
        'underlyings', ev.e->'underlyings',
        'verdict', private.note_verdict(ev.e, n.status)) end) as j
    from public.broker_positions bp
    join public.holdings h on h.holding_code = bp.holding_code
    cross join lateral (
      select round(bp.quantity * bp.cost_price * case when bp.price_in_pct then 0.01 else 1 end, 2) as cost
    ) k
    cross join lateral (
      select coalesce(sum(hf.amount) filter (where hf.kind = 'contribution'), 0) as invested,
             coalesce(sum(hf.amount) filter (where hf.kind = 'income'), 0) as income
      from public.holding_flows hf where hf.holding_code = h.holding_code and hf.removed_at is null
    ) f
    left join public.structured_notes n on n.holding_code = h.holding_code and n.status <> 'cancelled'
    left join lateral (select private.note_evaluate(n.note_code, v_today) as e where n.note_code is not null) ev on true
    where bp.account_code = p_account_code and bp.as_of = v_as_of
  ) x;

  if v_cost_basis then
    v_net := coalesce(v_invested, 0) + coalesce(v_cash, 0);
  end if;

  return private.jsonb_decimal_strings(jsonb_build_object(
    'account_code', p_account_code, 'provider', c.provider, 'portfolio_ref', c.portfolio_ref, 'currency', v_currency,
    'basis', case when v_cost_basis then 'cost' else 'deposits' end,
    'sync', jsonb_build_object('last_synced_at', c.last_synced_at, 'last_attempt_at', c.last_attempt_at,
                               'status', c.last_status, 'error', c.last_error),
    'as_of', v_as_of,
    'cash', v_cash, 'positions_value', coalesce(v_value, 0), 'total', coalesce(v_cash, 0) + coalesce(v_value, 0),
    'total_aed', private.to_aed(coalesce(v_cash, 0) + coalesce(v_value, 0), v_currency),
    'invested', coalesce(v_invested, 0),
    'net_deposits', v_net, 'profit', coalesce(v_cash, 0) + coalesce(v_value, 0) - v_net,
    'income', v_income, 'fees', v_fees,
    'positions', v_positions,
    -- Kite and Coin, each in one line (Zerodha only).
    'segments', case when v_cost_basis then coalesce((
      select jsonb_agg(jsonb_build_object(
               'segment', s.segment, 'positions', s.n, 'invested', s.invested, 'value', s.value,
               'value_aed', private.to_aed(s.value, v_currency), 'profit', s.value - s.invested,
               'return_pct', case when s.invested > 0 then round(s.value / s.invested * 100 - 100, 2) end)
             order by s.segment desc)
      from (
        select private.zerodha_segment(bp.product_type) as segment, count(*) as n,
               coalesce(sum(round(bp.quantity * bp.cost_price, 2)), 0) as invested,
               coalesce(sum(bp.market_value), 0) as value
        from public.broker_positions bp
        where bp.account_code = p_account_code and bp.as_of = v_as_of
        group by 1
      ) s), '[]'::jsonb) else '[]'::jsonb end,
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
        and private.broker_account_holds(p_account_code, h.holding_code)),
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
        and private.broker_account_holds(p_account_code, h.holding_code)), '[]'::jsonb),
    'series', coalesce((
      select jsonb_agg(jsonb_build_object('as_of', s.as_of, 'total', s.total_value, 'cash', s.cash,
                                          'positions', s.positions_value,
                                          'invested', m.invested,
                                          'net_deposits', case when v_cost_basis then m.invested + coalesce(s.cash, 0)
                                                               else d.net end,
                                          'segments', case when v_cost_basis then m.segments end,
                                          'estimated', s.estimated) order by s.as_of)
      from public.broker_snapshots s
      cross join lateral (
        select coalesce(sum(bt.net_amount), 0) as net from public.broker_transactions bt
        where bt.account_code = p_account_code and bt.kind in ('deposit', 'withdrawal')
          and public.dubai_date(bt.booked_at) <= s.as_of
      ) d
      cross join lateral (
        select sum(g.invested) as invested,
               jsonb_object_agg(g.segment, jsonb_build_object('invested', g.invested, 'value', g.value)) as segments
        from (
          select private.zerodha_segment(bp.product_type) as segment,
                 sum(round(bp.quantity * bp.cost_price * case when bp.price_in_pct then 0.01 else 1 end, 2)) as invested,
                 coalesce(sum(bp.market_value), 0) as value
          from public.broker_positions bp
          where bp.account_code = p_account_code and bp.as_of = s.as_of
          group by 1
        ) g
      ) m
      where s.account_code = p_account_code), '[]'::jsonb)));
end;
$$;

-- broker_accounts_summary (20261027200000): + invested and basis; Zerodha's net deposits are
-- invested + cash; the holdings include those only marked (Zerodha has no broker rows).
create or replace function public.broker_accounts_summary(p_profile_code text)
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
             'basis', case when c.provider = 'zerodha' then 'cost' else 'deposits' end,
             'cash', x.cash, 'positions_value', x.pv, 'total', x.cash + x.pv,
             'total_aed', private.to_aed(x.cash + x.pv, a.currency),
             'invested', x.invested, 'net_deposits', n.net, 'profit', x.cash + x.pv - n.net,
             'live_notes', x.live_notes, 'positions', x.positions,
             'last_synced_at', c.last_synced_at, 'sync_status', c.last_status,
             'holding_codes', coalesce(x.holdings, '[]'::jsonb)) order by c.created_at)
    from public.broker_connections c
    join public.accounts a on a.account_code = c.account_code
    left join public.banks b on b.bank_code = a.bank_code
    cross join lateral (
      select coalesce((select v.balance from public.v_bank_balances v where v.account_code = c.account_code), 0) as cash,
             coalesce(sum(bp.market_value), 0) as pv,
             coalesce(sum(round(bp.quantity * bp.cost_price * case when bp.price_in_pct then 0.01 else 1 end, 2)), 0)
               as invested,
             coalesce((select sum(bt.net_amount) from public.broker_transactions bt
                       where bt.account_code = c.account_code and bt.kind in ('deposit', 'withdrawal')), 0) as deposits,
             (select count(*) from public.structured_notes n
              where n.funding_account_code = c.account_code and n.status = 'live') as live_notes,
             count(bp.position_code) as positions,
             (select jsonb_agg(distinct u.holding_code) from (
                select bt.holding_code from public.broker_transactions bt
                where bt.account_code = c.account_code and bt.holding_code is not null
                union
                select bp2.holding_code from public.broker_positions bp2 where bp2.account_code = c.account_code
              ) u) as holdings
      from public.broker_positions bp
      where bp.account_code = c.account_code
        and bp.as_of = (select max(bp2.as_of) from public.broker_positions bp2 where bp2.account_code = c.account_code)
    ) x
    cross join lateral (
      select case when c.provider = 'zerodha' then x.invested + x.cash else x.deposits end as net
    ) n
    where c.profile_code = p_profile_code), '[]'::jsonb));
end;
$$;

-- ── 4. nightly sync (23:30 IST, 22:00 Dubai, weekdays: after the close and most NAVs) ──
select cron.schedule('ledger-zerodha-sync', '0 18 * * 1-5', $$select private.invoke_edge('zerodha-sync')$$);

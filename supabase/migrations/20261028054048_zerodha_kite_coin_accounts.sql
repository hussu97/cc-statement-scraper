-- Zerodha as two broker accounts: Zerodha Kite (stocks, ETFs, and the Funds cash) and Zerodha Coin
-- (mutual funds), each with its own bank, logo, connection, marks and value per day
-- (tasks/todo.md §12). Before this, one Zerodha account (bank ZRD) held both, split into segments.
--
-- 1. Banks KITE ('Zerodha Kite', KITE.png) and COIN ('Zerodha Coin', COIN.png), each Zerodha's
--    own product mark (assets/banks/README.md). ZRD stays: it is history.
-- 2. A connection per segment: portfolio_ref '<KITE USER ID>-KITE' and '-COIN' (still unique per
--    provider and ref, one account each). The Kite account is made on the first sync and carries
--    Funds' cash; the Coin account is made once Coin reports a fund, and its cash is always 0 (a
--    `broker` checkpoint, kept fresh like Kite's, so its balance is never stale or missing).
-- 3. import_zerodha_data keeps the payload it had (zerodha-sync is unchanged but for the result's
--    `accounts`): marks, inferred flows and the day's value go to the segment's own account, and a
--    segment whose read failed keeps its own last marks. The per-segment work is
--    private.zerodha_import_segment, the same rules as before, scoped to one account.
-- 4. An existing single Zerodha connection (unsuffixed portfolio_ref) becomes the Kite one: its
--    account moves to bank KITE (and its nickname, if still 'Zerodha', to 'Zerodha Kite'); its
--    mutual-fund marks move to a new Coin account, and each day's value is split between the two.
--    Guarded: only rows still in the old shape change. Production has none (Zerodha never synced
--    there before this), so this is for any stack that ran the old import.
-- broker_portfolio and broker_accounts_summary are unchanged: they are per account already (a
-- Zerodha account still reads against cost, and its `segments` now has one entry).

-- ── 1. banks ────────────────────────────────────────────────────────────────
insert into public.banks (bank_code, name, sms_senders, logo_path)
values ('KITE', 'Zerodha Kite', '{}', 'KITE.png'),
       ('COIN', 'Zerodha Coin', '{}', 'COIN.png')
on conflict (bank_code) do nothing;

-- Every bank carries an FX markup (05_fx_rates). Neither account holds a card, so nothing is
-- estimated with it.
insert into private.bank_fx_fees (bank_code, markup, note)
values ('KITE', 0, 'no card in the ledger: INR cash only, no FX'),
       ('COIN', 0, 'no card in the ledger: mutual funds only, no cash, no FX')
on conflict (bank_code) do nothing;

-- ── 2. a segment's connection ───────────────────────────────────────────────
-- The connection for one Kite user's segment ('<USER>-KITE' / '-COIN'), else, when p_create, the
-- ledger's unlinked INR account at that bank, else a new one, linked. Null when absent and not
-- p_create. Raises when the segment belongs to another ledger.
create function private.zerodha_connection(p_profile_code text, p_user text, p_segment text, p_create boolean)
returns public.broker_connections
language plpgsql
set search_path = ''
as $$
declare
  v_ref text := p_user || '-' || upper(p_segment);
  v_bank text := case p_segment when 'coin' then 'COIN' else 'KITE' end;
  v_account text;
  c public.broker_connections;
begin
  select * into c from public.broker_connections where provider = 'zerodha' and portfolio_ref = v_ref;
  if found and c.profile_code <> p_profile_code then
    raise exception 'this portfolio belongs to another ledger' using errcode = '42501';
  end if;
  if found then
    return c;
  end if;
  if not p_create then
    return null;
  end if;
  select a.account_code into v_account from public.accounts a
  where a.profile_code = p_profile_code and a.bank_code = v_bank and a.kind in ('current', 'savings')
    and a.currency = 'INR' and a.status = 'active'
    and not exists (select 1 from public.broker_connections x where x.account_code = a.account_code)
  order by a.created_at limit 1;
  if v_account is null then
    -- Named on creation (a nickname is the user's to change): it has no account number to show.
    insert into public.accounts (profile_code, bank_code, kind, currency, product_name, nickname)
    values (p_profile_code, v_bank, 'current', 'INR',
            case p_segment when 'coin' then 'Mutual funds' else 'Trading account' end,
            case p_segment when 'coin' then 'Zerodha Coin' else 'Zerodha Kite' end)
    returning account_code into v_account;
  end if;
  insert into public.broker_connections (profile_code, account_code, provider, portfolio_ref)
  values (p_profile_code, v_account, 'zerodha', v_ref)
  returning * into c;
  return c;
end;
$$;

-- ── 3. a segment's marks and flows ──────────────────────────────────────────
-- One segment's day on its own account (the rules of 20261027202923, scoped to the account):
-- today's marks, one per ISIN (a fund in both lists is Coin's), each holding's inferred flow, a
-- position no longer reported closed at its last price. A segment not in p_read keeps the
-- account's last marks for the day. Returns {marks, flows, closed}.
create function private.zerodha_import_segment(p_profile_code text, p_account text, p_segment text,
                                               p_read text[], p_data jsonb, p_day date, p_fetched timestamptz)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_all jsonb := coalesce(p_data->'positions', '[]'::jsonb);
  v_mine jsonb;
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
  v_marks int := 0;
  v_flows int := 0;
  v_closed int := 0;
begin
  if not (p_segment = any (p_read)) then
    -- It could not be read: its last marks carry over (prices as they were).
    insert into public.broker_positions (profile_code, account_code, holding_code, as_of, isin, name, symbol, product_type,
      quantity, price, price_in_pct, market_value, cost_price, profit, currency, fetched_at)
    select bp.profile_code, bp.account_code, bp.holding_code, p_day, bp.isin, bp.name, bp.symbol, bp.product_type,
           bp.quantity, bp.price, bp.price_in_pct, bp.market_value, bp.cost_price, bp.profit, bp.currency, bp.fetched_at
    from public.broker_positions bp
    join public.holdings h on h.holding_code = bp.holding_code and h.status = 'active'
    where bp.account_code = p_account
      and bp.as_of = (select max(x.as_of) from public.broker_positions x where x.account_code = p_account and x.as_of < p_day)
    on conflict (account_code, as_of, isin) do nothing;
    return jsonb_build_object('marks', 0, 'flows', 0, 'closed', 0);
  end if;

  -- The segment's positions for the day, one per ISIN among the segments read (Coin's when in both).
  select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb) into v_mine
  from (
    select distinct on (p->>'isin') p->>'isin' as isin, p->>'segment' as segment,
           left(btrim(coalesce(nullif(btrim(p->>'name'), ''), p->>'symbol', p->>'isin')), 200) as name,
           left(nullif(btrim(p->>'symbol'), ''), 40) as symbol,
           (p->>'quantity')::numeric as quantity, nullif(p->>'price', '')::numeric as price,
           coalesce(nullif(p->>'cost_price', '')::numeric, 0) as cost_price
    from jsonb_array_elements(v_all) p
    where p->>'isin' ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$' and p->>'segment' = any (p_read)
      and (p->>'quantity')::numeric > 0
    order by p->>'isin', (p->>'segment' = 'coin') desc
  ) d
  where d.segment = p_segment;

  for r in
    select * from jsonb_to_recordset(v_mine)
      as x(isin text, segment text, name text, symbol text, quantity numeric, price numeric, cost_price numeric)
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
    v_ext := 'zerodha:' || r.isin || ':' || p_day;
    delete from public.holding_flows where holding_code = v_holding and external_ref = v_ext || ':closed';
    -- The day before's mark, unless the position was closed since (then this is a new opening).
    v_prev := null;
    select * into v_prev from public.broker_positions bp
    where bp.account_code = p_account and bp.isin = r.isin and bp.as_of < p_day
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
      values (p_profile_code, v_holding, p_day, v_flow_kind, v_flow, private.to_aed(v_flow, 'INR'), 'import', v_ext,
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
    values (p_profile_code, p_account, v_holding, p_day, r.isin, r.name, r.symbol,
      case r.segment when 'coin' then 'MUTUAL_FUND' else 'EQUITY' end, r.quantity, r.price, false, v_value,
      r.cost_price, v_value - v_cost, 'INR', p_fetched)
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
      where holding_code = v_holding and as_of = p_day and source = 'import';
      if not found then
        insert into public.holding_valuations (profile_code, holding_code, as_of, unit_price, source)
        values (p_profile_code, v_holding, p_day, r.price, 'import');
      end if;
    elsif v_value is not null then
      update public.holding_valuations set value = v_value, unit_price = null
      where holding_code = v_holding and as_of = p_day and source = 'import';
      if not found then
        insert into public.holding_valuations (profile_code, holding_code, as_of, value, source)
        values (p_profile_code, v_holding, p_day, v_value, 'import');
      end if;
    end if;
    v_marks := v_marks + 1;
  end loop;

  -- A same-day re-run after a sale: today's mark of a position the segment no longer holds goes.
  delete from public.broker_positions bp
  where bp.account_code = p_account and bp.as_of = p_day
    and not exists (select 1 from jsonb_array_elements(v_mine) m where m->>'isin' = bp.isin);

  -- A position no longer reported was sold or redeemed: closed at its last price. One closed
  -- since its last mark (a same-day re-run took back the day it was seen again) just closes.
  for r in
    select h.holding_code, h.external_ref as isin, lp.quantity, lp.price, lp.as_of
    from public.holdings h
    cross join lateral (
      select bp.quantity, bp.price, bp.as_of from public.broker_positions bp
      where bp.account_code = p_account and bp.holding_code = h.holding_code
      order by bp.as_of desc limit 1
    ) lp
    where h.profile_code = p_profile_code and h.status = 'active'
      and not exists (select 1 from jsonb_array_elements(v_all) p
                      where p->>'isin' = h.external_ref and (p->>'quantity')::numeric > 0)
  loop
    update public.holdings set status = 'closed' where holding_code = r.holding_code;
    delete from public.holding_flows where holding_code = r.holding_code and external_ref = 'zerodha:' || r.isin || ':' || p_day;
    v_flow := round(r.quantity * coalesce(r.price, 0), 2);
    if v_flow > 0 and not exists (
         select 1 from public.holding_flows hf
         where hf.holding_code = r.holding_code and hf.removed_at is null and hf.flow_date > r.as_of
           and hf.external_ref like 'zerodha:%:closed') and private.to_aed(v_flow, 'INR') > 0 then
      insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source,
                                        external_ref, notes)
      values (p_profile_code, r.holding_code, p_day, 'withdrawal', v_flow, private.to_aed(v_flow, 'INR'), 'import',
              'zerodha:' || r.isin || ':' || p_day || ':closed', 'Zerodha: no longer held, at its last price')
      on conflict (holding_code, external_ref) where external_ref is not null do nothing;
    end if;
    v_closed := v_closed + 1;
  end loop;

  return jsonb_build_object('marks', v_marks, 'flows', v_flows, 'closed', v_closed);
end;
$$;

-- ── 4. import ───────────────────────────────────────────────────────────────
-- Service (zerodha-sync): one Kite user's holdings, idempotent per day. p_data (decimal strings),
-- as before: {user_id, fetched_at, cash|null, segments_read: ['kite', 'coin'],
--  positions: [{segment: 'kite'|'coin', isin, name, symbol, quantity, price, cost_price}]}
-- Kite's marks and Funds' cash go to the Zerodha Kite account, Coin's to Zerodha Coin (made once
-- Coin reports a fund). Returns {accounts: {kite, coin}, account_code (Kite's), positions_marked,
-- flows, positions_closed, checkpoint, value (both accounts)}.
create or replace function public.import_zerodha_data(p_profile_code text, p_data jsonb)
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
  v_funds numeric := nullif(p_data->>'cash', '')::numeric;
  v_kite public.broker_connections;
  v_coin public.broker_connections;
  c public.broker_connections;
  v_segment text;
  v_cash numeric;
  v_balance numeric;
  v_checkpoint boolean := false;
  v_positions_value numeric;
  v_total numeric := 0;
  v_seg jsonb;
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

  -- Kite always (it holds the cash); Coin once it reports a fund.
  v_kite := private.zerodha_connection(p_profile_code, v_ref, 'kite', true);
  v_coin := private.zerodha_connection(p_profile_code, v_ref, 'coin',
    'coin' = any (v_read) and exists (
      select 1 from jsonb_array_elements(coalesce(p_data->'positions', '[]'::jsonb)) p
      where p->>'segment' = 'coin' and p->>'isin' ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$' and (p->>'quantity')::numeric > 0));

  foreach v_segment in array array['kite', 'coin'] loop
    c := case v_segment when 'coin' then v_coin else v_kite end;
    continue when c.connection_code is null;
    v_seg := private.zerodha_import_segment(p_profile_code, c.account_code, v_segment, v_read, p_data, v_day, v_fetched);
    v_marks := v_marks + (v_seg->>'marks')::int;
    v_flows := v_flows + (v_seg->>'flows')::int;
    v_closed := v_closed + (v_seg->>'closed')::int;

    -- Cash as Zerodha states it (Funds on Kite; Coin holds none), whenever it differs from the
    -- ledger's or the last is a day old.
    v_cash := case v_segment when 'coin' then 0 else v_funds end;
    if v_cash is not null then
      select b.balance into v_balance from public.v_bank_balances b where b.account_code = c.account_code;
      if v_balance is distinct from v_cash
         or not exists (select 1 from public.balance_checkpoints b where b.account_code = c.account_code
                        and b.as_of > v_fetched - interval '20 hours') then
        insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source)
        values (p_profile_code, c.account_code, v_fetched, v_cash, 'broker');
        v_checkpoint := v_checkpoint or v_segment = 'kite';
      end if;
    end if;

    -- The account's value for the day.
    select coalesce(sum(bp.market_value), 0) into v_positions_value from public.broker_positions bp
    where bp.account_code = c.account_code and bp.as_of = v_day;
    v_cash := coalesce(v_cash, (select b.balance from public.v_bank_balances b where b.account_code = c.account_code), 0);
    insert into public.broker_snapshots (profile_code, account_code, as_of, currency, cash, positions_value, total_value, estimated)
    values (p_profile_code, c.account_code, v_day, 'INR', v_cash, v_positions_value, v_cash + v_positions_value, false)
    on conflict (account_code, as_of) do update set
      cash = excluded.cash, positions_value = excluded.positions_value, total_value = excluded.total_value, estimated = false;
    v_total := v_total + v_cash + v_positions_value;

    update public.broker_connections set last_attempt_at = now(), last_synced_at = now(), last_status = 'ok', last_error = null
    where connection_code = c.connection_code;
  end loop;

  return jsonb_build_object('accounts', jsonb_build_object('kite', v_kite.account_code, 'coin', v_coin.account_code),
                            'account_code', v_kite.account_code, 'positions_marked', v_marks, 'flows', v_flows,
                            'positions_closed', v_closed, 'checkpoint', v_checkpoint, 'value', v_total);
end;
$$;
comment on function public.import_zerodha_data(text, jsonb) is
  'Service (zerodha-sync): a Kite user''s holdings for one ledger, Kite''s (and the Funds cash) on the Zerodha Kite account and Coin''s on Zerodha Coin, with each day''s value; idempotent per day. Flows are inferred from day to day.';

-- ── 5. an existing single Zerodha account becomes Kite, its funds Coin ──────
-- Guarded (only connections still unsuffixed change), so a re-run is a no-op. Returns how many
-- connections it moved. pgTAP 74 runs it on an account the old import made.
create function private.zerodha_split_single_accounts()
returns int
language plpgsql
set search_path = ''
as $$
declare
  c public.broker_connections;
  v_user text;
  v_coin text;
  v_moved int := 0;
begin
  for c in
    select * from public.broker_connections x
    where x.provider = 'zerodha' and x.portfolio_ref !~ '-(KITE|COIN)$'
      and not exists (select 1 from public.broker_connections y
                      where y.provider = 'zerodha' and y.portfolio_ref = x.portfolio_ref || '-KITE')
  loop
    v_user := c.portfolio_ref;
    update public.broker_connections set portfolio_ref = v_user || '-KITE' where connection_code = c.connection_code;
    update public.accounts set bank_code = 'KITE' where account_code = c.account_code and bank_code = 'ZRD';
    update public.accounts set nickname = 'Zerodha Kite' where account_code = c.account_code and nickname = 'Zerodha';
    v_moved := v_moved + 1;

    continue when not exists (select 1 from public.broker_positions bp
                              where bp.account_code = c.account_code and bp.product_type = 'MUTUAL_FUND');
    v_coin := (private.zerodha_connection(c.profile_code, v_user, 'coin', true)).account_code;
    update public.broker_positions bp set account_code = v_coin
    where bp.account_code = c.account_code and bp.product_type = 'MUTUAL_FUND'
      and not exists (select 1 from public.broker_positions x
                      where x.account_code = v_coin and x.as_of = bp.as_of and x.isin = bp.isin);
    -- Coin holds no cash: a 0 checkpoint from its first mark, and its value per day is its funds'.
    insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source)
    select c.profile_code, v_coin, min(bp.fetched_at), 0, 'broker' from public.broker_positions bp
    where bp.account_code = v_coin
    having count(*) > 0;
    insert into public.broker_snapshots (profile_code, account_code, as_of, currency, cash, positions_value, total_value, estimated)
    select c.profile_code, v_coin, bp.as_of, 'INR', 0, coalesce(sum(bp.market_value), 0), coalesce(sum(bp.market_value), 0), false
    from public.broker_positions bp where bp.account_code = v_coin
    group by bp.as_of
    on conflict (account_code, as_of) do nothing;
    -- Kite's value per day without them.
    update public.broker_snapshots s
    set positions_value = k.value, total_value = coalesce(s.cash, 0) + k.value
    from (
      select s2.snapshot_code, coalesce((select sum(bp.market_value) from public.broker_positions bp
                                         where bp.account_code = c.account_code and bp.as_of = s2.as_of), 0) as value
      from public.broker_snapshots s2 where s2.account_code = c.account_code
    ) k
    where s.snapshot_code = k.snapshot_code and s.positions_value is distinct from k.value;
  end loop;
  return v_moved;
end;
$$;

select private.zerodha_split_single_accounts();

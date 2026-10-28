-- Zerodha Kite and Coin in detail (tasks/todo.md §14): what each position is, how it moved today,
-- where the money sits, and the Coin SIPs.
--
-- 1. broker_positions gains nullable prev_price (Kite's previous close; a fund's previous NAV),
--    price_date (the NAV's date), exchange, folio, asset_class (stock | etf | fund), category (a
--    fund's scheme type) and issuer (its fund house). Swissquote leaves them null.
-- 2. broker_sips: a Coin SIP as Zerodha reports it, kept current by the sync, with its latest
--    order's status (a rejected instalment shows).
-- 3. import_zerodha_data takes the new position fields and an optional `sips` list (absent: the
--    last rows stay). A Kite holding still named by its ticker takes the company name. A fund's
--    previous price is its last mark from an earlier NAV date.
-- 4. broker_portfolio: each position adds the fields above, its average cost (cost_price), day
--    change, weight and return; the
--    account adds its day change, allocation, fund houses, highlights and SIPs.
-- 5. broker_position_detail(profile, account, isin): one position, its marks over time and SIPs.

-- ── 1. position fields ──────────────────────────────────────────────────────
alter table public.broker_positions
  add column prev_price numeric(18,8),
  add column price_date date,
  add column exchange text check (length(exchange) between 1 and 10),
  add column folio text check (length(folio) between 1 and 40),
  add column asset_class text check (asset_class in ('stock', 'etf', 'fund')),
  add column category text check (length(category) between 1 and 60),
  add column issuer text check (length(issuer) between 1 and 80);
comment on column public.broker_positions.prev_price is
  'The price before this one: the previous close (Kite) or the previous NAV (a fund); null when unknown.';
comment on column public.broker_positions.price_date is 'The date the price is for (a fund''s NAV date); null when the broker does not say.';
comment on column public.broker_positions.asset_class is 'stock, etf or fund (Zerodha); null for other brokers.';
comment on column public.broker_positions.category is 'A fund''s scheme type as its catalogue names it (Equity, Debt, Hybrid, …).';
comment on column public.broker_positions.issuer is 'A fund''s fund house (AMC).';

-- ── 2. SIPs ─────────────────────────────────────────────────────────────────
create table public.broker_sips (
  sip_code text primary key default public.gen_code('bsp')
    check (sip_code ~ '^bsp_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null,
  external_id text not null check (external_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  isin text not null check (isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'),
  fund text not null check (length(btrim(fund)) between 1 and 200),
  status text not null check (status in ('active', 'paused', 'cancelled', 'other')),
  frequency text check (length(frequency) between 1 and 20),
  instalment_amount numeric(14,2),
  instalment_day smallint check (instalment_day between 0 and 31),
  next_instalment date,
  last_instalment timestamptz,
  completed_instalments int,
  step_up jsonb,
  started_at timestamptz,
  last_order_status text check (last_order_status in ('open', 'complete', 'rejected', 'cancelled')),
  last_order_message text check (length(last_order_message) <= 200),
  last_order_at timestamptz,
  currency text not null default 'INR' check (currency ~ '^[A-Z]{3}$'),
  fetched_at timestamptz not null default now(),
  constraint broker_sips_account_fkey foreign key (profile_code, account_code)
    references public.accounts(profile_code, account_code) on delete cascade,
  unique (account_code, external_id)
);
comment on table public.broker_sips is
  'A systematic investment plan as the broker reports it (Zerodha Coin), kept current by the sync, with its latest order''s outcome.';
alter table public.broker_sips enable row level security;
create policy broker_sips_member_read on public.broker_sips for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.broker_sips to authenticated;
grant all on public.broker_sips to service_role;
create index broker_sips_profile_code_idx on public.broker_sips(profile_code);

-- Service: one account's SIPs as read just now; one no longer listed is cancelled. Returns the count.
create function private.zerodha_import_sips(p_profile_code text, p_account text, p_sips jsonb, p_fetched timestamptz)
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_ids text[];
begin
  with s as (
    select x.* from jsonb_to_recordset(p_sips) as x(
      sip_id text, isin text, fund text, status text, frequency text, amount numeric, day int,
      next_instalment date, last_instalment timestamptz, completed int, step_up jsonb, created timestamptz,
      last_order jsonb)
    where x.sip_id ~ '^[A-Za-z0-9_-]{1,64}$' and x.isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'
      and length(btrim(coalesce(x.fund, ''))) > 0
  ), up as (
    insert into public.broker_sips as b (profile_code, account_code, external_id, isin, fund, status, frequency,
      instalment_amount, instalment_day, next_instalment, last_instalment, completed_instalments, step_up, started_at,
      last_order_status, last_order_message, last_order_at, fetched_at)
    select p_profile_code, p_account, s.sip_id, s.isin, left(btrim(s.fund), 200),
           case when s.status in ('active', 'paused', 'cancelled') then s.status else 'other' end,
           left(nullif(btrim(s.frequency), ''), 20), s.amount,
           case when s.day between 0 and 31 then s.day end, s.next_instalment, s.last_instalment,
           s.completed, case when jsonb_typeof(s.step_up) = 'object' then s.step_up end, s.created,
           case when s.last_order->>'status' in ('open', 'complete', 'rejected', 'cancelled') then s.last_order->>'status' end,
           left(nullif(btrim(s.last_order->>'message'), ''), 200), nullif(s.last_order->>'at', '')::timestamptz,
           p_fetched
    from s
    on conflict (account_code, external_id) do update set
      isin = excluded.isin, fund = excluded.fund, status = excluded.status, frequency = excluded.frequency,
      instalment_amount = excluded.instalment_amount, instalment_day = excluded.instalment_day,
      next_instalment = excluded.next_instalment, last_instalment = excluded.last_instalment,
      completed_instalments = excluded.completed_instalments, step_up = excluded.step_up,
      started_at = excluded.started_at,
      -- An order outside the broker's recent window leaves the last outcome as it was.
      last_order_status = coalesce(excluded.last_order_status, b.last_order_status),
      last_order_message = case when excluded.last_order_status is not null then excluded.last_order_message
                                else b.last_order_message end,
      last_order_at = coalesce(excluded.last_order_at, b.last_order_at),
      fetched_at = excluded.fetched_at
    returning b.external_id
  )
  select array_agg(external_id) into v_ids from up;

  update public.broker_sips set status = 'cancelled', fetched_at = p_fetched
  where account_code = p_account and status <> 'cancelled' and not (external_id = any (coalesce(v_ids, '{}')));
  return coalesce(array_length(v_ids, 1), 0);
end;
$$;

-- An account's SIPs (one fund's, given its ISIN), active first, then by next instalment.
create function private.broker_sips_json(p_account text, p_isin text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'sip_code', s.sip_code, 'isin', s.isin, 'fund', s.fund, 'holding_code', h.holding_code,
           'status', s.status, 'frequency', s.frequency, 'amount', s.instalment_amount, 'currency', s.currency,
           'day', s.instalment_day, 'next_instalment', s.next_instalment, 'last_instalment', s.last_instalment,
           'completed', s.completed_instalments, 'step_up', s.step_up, 'started_at', s.started_at,
           'last_order', case when s.last_order_status is not null then jsonb_build_object(
             'status', s.last_order_status, 'message', s.last_order_message, 'at', s.last_order_at) end,
           'missed', s.last_order_status = 'rejected')
         order by s.status = 'active' desc, s.status = 'paused' desc, s.next_instalment nulls last, s.fund), '[]'::jsonb)
  from public.broker_sips s
  left join public.holdings h on h.profile_code = s.profile_code and h.external_ref = s.isin
  where s.account_code = p_account and (p_isin is null or s.isin = p_isin)
$$;

-- ── 3. import ───────────────────────────────────────────────────────────────
create or replace function private.zerodha_import_segment(p_profile_code text, p_account text, p_segment text,
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
      quantity, price, price_in_pct, market_value, cost_price, profit, currency, fetched_at,
      prev_price, price_date, exchange, folio, asset_class, category, issuer)
    select bp.profile_code, bp.account_code, bp.holding_code, p_day, bp.isin, bp.name, bp.symbol, bp.product_type,
           bp.quantity, bp.price, bp.price_in_pct, bp.market_value, bp.cost_price, bp.profit, bp.currency, bp.fetched_at,
           bp.prev_price, bp.price_date, bp.exchange, bp.folio, bp.asset_class, bp.category, bp.issuer
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
           coalesce(nullif(p->>'cost_price', '')::numeric, 0) as cost_price,
           nullif(p->>'prev_price', '')::numeric as prev_price, nullif(p->>'price_date', '')::date as price_date,
           left(nullif(btrim(p->>'exchange'), ''), 10) as exchange, left(nullif(btrim(p->>'folio'), ''), 40) as folio,
           case when p->>'asset_class' in ('stock', 'etf', 'fund') then p->>'asset_class'
                when p->>'segment' = 'coin' then 'fund' end as asset_class,
           left(nullif(btrim(p->>'category'), ''), 60) as category, left(nullif(btrim(p->>'issuer'), ''), 80) as issuer
    from jsonb_array_elements(v_all) p
    where p->>'isin' ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$' and p->>'segment' = any (p_read)
      and (p->>'quantity')::numeric > 0
    order by p->>'isin', (p->>'segment' = 'coin') desc
  ) d
  where d.segment = p_segment;

  for r in
    select * from jsonb_to_recordset(v_mine)
      as x(isin text, segment text, name text, symbol text, quantity numeric, price numeric, cost_price numeric,
            prev_price numeric, price_date date, exchange text, folio text, asset_class text, category text, issuer text)
  loop
    select h.holding_code, h.kind into v_holding, v_kind from public.holdings h
    where h.profile_code = p_profile_code and h.external_ref = r.isin;
    if v_holding is null then
      insert into public.holdings (profile_code, name, kind, currency, institution, units, notes, external_ref)
      values (p_profile_code, left(r.name, 80), 'security', 'INR',
              case r.segment when 'coin' then 'Zerodha Coin' else 'Zerodha Kite' end, r.quantity,
              'Synced from Zerodha; ISIN ' || r.isin, r.isin)
      returning holding_code, kind into v_holding, v_kind;
    else
      -- A holding still named by its ticker (the sync's first name for it) takes the company name.
      update public.holdings h set name = left(r.name, 80)
      where h.holding_code = v_holding and r.symbol is not null and h.name = r.symbol and r.name <> r.symbol;
    end if;
    -- A fund's previous price is its last mark from an earlier NAV date (Kite sends the previous close).
    if r.prev_price is null and r.price_date is not null then
      select bp.price into r.prev_price from public.broker_positions bp
      where bp.account_code = p_account and bp.isin = r.isin and bp.as_of < p_day and bp.price_date < r.price_date
      order by bp.as_of desc limit 1;
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
      quantity, price, price_in_pct, market_value, cost_price, profit, currency, fetched_at,
      prev_price, price_date, exchange, folio, asset_class, category, issuer)
    values (p_profile_code, p_account, v_holding, p_day, r.isin, r.name, r.symbol,
      case r.segment when 'coin' then 'MUTUAL_FUND' else 'EQUITY' end, r.quantity, r.price, false, v_value,
      r.cost_price, v_value - v_cost, 'INR', p_fetched,
      r.prev_price, r.price_date, r.exchange, r.folio, r.asset_class, r.category, r.issuer)
    on conflict (account_code, as_of, isin) do update set
      holding_code = excluded.holding_code, name = excluded.name, symbol = excluded.symbol,
      product_type = excluded.product_type, quantity = excluded.quantity, price = excluded.price,
      market_value = excluded.market_value, cost_price = excluded.cost_price, profit = excluded.profit,
      fetched_at = excluded.fetched_at, prev_price = excluded.prev_price, price_date = excluded.price_date,
      exchange = excluded.exchange, folio = excluded.folio, asset_class = excluded.asset_class,
      category = excluded.category, issuer = excluded.issuer;
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

-- ── 3b. import_zerodha_data (20261028054048) + sips ─────────────────────────
-- p_data adds, per position: prev_price, price_date, exchange, folio, asset_class (stock | etf |
-- fund), category, issuer; and top level `sips` ([{sip_id, isin, fund, status, frequency, amount,
-- day, next_instalment, last_instalment, completed, step_up, created, last_order: {status, message,
-- at} | null}], or absent when not read). The result adds `sips` (how many were read).
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
  v_sips int;
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

  -- SIPs live on the Coin account; a payload without them (not read) leaves the last rows.
  if v_coin.connection_code is not null and jsonb_typeof(p_data->'sips') = 'array' then
    v_sips := private.zerodha_import_sips(p_profile_code, v_coin.account_code, p_data->'sips', v_fetched);
  end if;

  return jsonb_build_object('accounts', jsonb_build_object('kite', v_kite.account_code, 'coin', v_coin.account_code),
                            'account_code', v_kite.account_code, 'positions_marked', v_marks, 'flows', v_flows,
                            'positions_closed', v_closed, 'checkpoint', v_checkpoint, 'value', v_total,
                            'sips', v_sips);
end;
$$;
comment on function public.import_zerodha_data(text, jsonb) is
  'Service (zerodha-sync): a Kite user''s holdings for one ledger, Kite''s (and the Funds cash) on the Zerodha Kite account and Coin''s on Zerodha Coin, with each day''s value and Coin''s SIPs; idempotent per day. Flows are inferred from day to day.';


-- ── 4. the account view ─────────────────────────────────────────────────────
-- Built from broker_portfolio's positions (their value, cost, return and day change), so the
-- figures agree with the list.

-- Where the money sits: by asset class (Kite: stocks, ETFs), a fund by its scheme type, any other
-- broker by product type. Largest first.
create function private.broker_allocation(p_positions jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with e as (
    select case when p->>'asset_class' = 'fund' then 'fund:' || coalesce(p->>'category', 'other')
                when p->>'asset_class' is not null then p->>'asset_class'
                else 'product:' || lower(coalesce(p->>'product_type', 'other')) end as key,
           case p->>'asset_class' when 'stock' then 'Stocks' when 'etf' then 'ETFs'
                when 'fund' then coalesce(p->>'category', 'Other funds')
                else initcap(replace(lower(coalesce(p->>'product_type', 'other')), '_', ' ')) end as label,
           (p->>'value')::numeric as value, (p->>'cost')::numeric as cost
    from jsonb_array_elements(p_positions) p
    where p->>'value' is not null
  ), t as (select sum(value) as total from e)
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', g.key, 'label', g.label, 'positions', g.n, 'value', g.value,
           'weight_pct', case when t.total > 0 then round(g.value / t.total * 100, 2) end,
           'invested', g.invested, 'profit', g.value - g.invested,
           'return_pct', case when g.invested > 0 then round(g.value / g.invested * 100 - 100, 2) end)
         order by g.value desc), '[]'::jsonb)
  from (select key, min(label) as label, count(*) as n, sum(value) as value, coalesce(sum(cost), 0) as invested
        from e group by key) g
  cross join t
$$;

-- Funds by fund house, largest first.
create function private.broker_issuers(p_positions jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with e as (
    select p->>'issuer' as issuer, (p->>'value')::numeric as value
    from jsonb_array_elements(p_positions) p
    where p->>'asset_class' = 'fund' and p->>'issuer' is not null and p->>'value' is not null
  ), t as (select sum(value) as total from e)
  select coalesce(jsonb_agg(jsonb_build_object(
           'issuer', g.issuer, 'positions', g.n, 'value', g.value,
           'weight_pct', case when t.total > 0 then round(g.value / t.total * 100, 2) end)
         order by g.value desc, g.issuer), '[]'::jsonb)
  from (select issuer, count(*) as n, sum(value) as value from e group by issuer) g
  cross join t
$$;

-- The best and worst three by return (only gains, only losses), today's three biggest moves each
-- way, and how much of the account its five largest positions are (more than five held).
create function private.broker_highlights(p_positions jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with e as (
    select p, (p->>'return_pct')::numeric as ret, (p->>'day_change_pct')::numeric as day,
           (p->>'weight_pct')::numeric as weight, (p->>'value')::numeric as value
    from jsonb_array_elements(p_positions) p
  ), item as (
    select e.*, jsonb_build_object('holding_code', p->'holding_code', 'isin', p->'isin', 'name', p->'name',
             'symbol', p->'symbol', 'value', p->'value', 'return_pct', p->'return_pct', 'profit', p->'profit',
             'day_change', p->'day_change', 'day_change_pct', p->'day_change_pct') as j
    from e
  )
  select jsonb_build_object(
    'best', coalesce((select jsonb_agg(j order by ret desc) from (select * from item where ret > 0 order by ret desc limit 3) x), '[]'::jsonb),
    'worst', coalesce((select jsonb_agg(j order by ret) from (select * from item where ret < 0 order by ret limit 3) x), '[]'::jsonb),
    'gainers_today', coalesce((select jsonb_agg(j order by day desc) from (select * from item where day > 0 order by day desc limit 3) x), '[]'::jsonb),
    'losers_today', coalesce((select jsonb_agg(j order by day) from (select * from item where day < 0 order by day limit 3) x), '[]'::jsonb),
    'top5_weight_pct', case when (select count(*) from e where value is not null) > 5
      then (select sum(weight) from (select weight from e where weight is not null order by weight desc limit 5) w) end)
$$;

-- broker_portfolio (20261027202923) + the fields above.
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
  v_marked numeric;
  v_day_change numeric;
  v_day_base numeric;
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

  select sum(bp.market_value) into v_marked from public.broker_positions bp
  where bp.account_code = p_account_code and bp.as_of = v_as_of;

  select coalesce(jsonb_agg(x.j order by x.value desc nulls last, x.j->>'name'), '[]'::jsonb), sum(x.value), sum(x.cost),
         sum(x.day_change), sum(x.day_base)
    into v_positions, v_value, v_invested, v_day_change, v_day_base
  from (
    select bp.market_value as value, k.cost, dc.day_change, dc.day_base, jsonb_build_object(
      'holding_code', h.holding_code, 'kind', h.kind, 'name', h.name, 'isin', bp.isin, 'security_name', bp.name,
      'symbol', bp.symbol, 'product_type', bp.product_type, 'quantity', bp.quantity, 'price', bp.price,
      'price_in_pct', bp.price_in_pct, 'currency', bp.currency, 'value', bp.market_value,
      'value_aed', private.to_aed(bp.market_value, bp.currency), 'as_of', bp.as_of,
      'cost', k.cost, 'profit', bp.profit, 'invested', f.invested, 'income', f.income,
      'segment', case when v_cost_basis then private.zerodha_segment(bp.product_type) end,
      'asset_class', bp.asset_class, 'category', bp.category, 'issuer', bp.issuer, 'exchange', bp.exchange,
      'folio', bp.folio, 'price_date', bp.price_date, 'prev_price', bp.prev_price, 'cost_price', bp.cost_price,
      'day_change', dc.day_change,
      'day_change_pct', case when dc.day_base > 0 then round(dc.day_change / dc.day_base * 100, 2) end,
      'weight_pct', case when v_marked > 0 and bp.market_value is not null then round(bp.market_value / v_marked * 100, 2) end,
      'return_pct', case when k.cost > 0 and bp.market_value is not null then round(bp.market_value / k.cost * 100 - 100, 2) end,
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
      -- Today's move: against the previous close (a fund: its previous NAV), when known.
      select case when bp.prev_price is not null and bp.price is not null and not bp.price_in_pct
                  then round(bp.quantity * (bp.price - bp.prev_price), 2) end as day_change,
             case when bp.prev_price is not null and bp.price is not null and not bp.price_in_pct
                  then bp.quantity * bp.prev_price end as day_base
    ) dc
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
    'day_change', v_day_change,
    'day_change_pct', case when v_day_base > 0 then round(v_day_change / v_day_base * 100, 2) end,
    'allocation', private.broker_allocation(v_positions),
    'issuers', private.broker_issuers(v_positions),
    'highlights', private.broker_highlights(v_positions),
    'sips', private.broker_sips_json(p_account_code, null),
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

comment on function public.broker_portfolio(text, text) is
  'Member: a broker account''s latest positions (with day change, weight and return), value, invested, profit, allocation, fund houses, highlights, SIPs, ended positions and value per day.';

-- ── 5. one position ─────────────────────────────────────────────────────────
-- Member: a position on a broker account by ISIN: as broker_portfolio shows it (null once no
-- longer held), its marks over time, and its SIPs. Null when the account has no marks for it.
create function public.broker_position_detail(p_profile_code text, p_account_code text, p_isin text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.broker_connections;
  v_last public.broker_positions;
begin
  perform private.assert_member(p_profile_code, false);
  select * into c from public.broker_connections where account_code = p_account_code and profile_code = p_profile_code;
  if not found then
    return null;
  end if;
  select * into v_last from public.broker_positions bp
  where bp.account_code = p_account_code and bp.isin = p_isin
  order by bp.as_of desc limit 1;
  if not found then
    return null;
  end if;

  return private.jsonb_decimal_strings(jsonb_build_object(
    'account_code', p_account_code, 'provider', c.provider, 'isin', p_isin,
    'holding_code', v_last.holding_code, 'name', v_last.name, 'symbol', v_last.symbol,
    'currency', v_last.currency, 'last_marked_on', v_last.as_of,
    'position', (select p from jsonb_array_elements(public.broker_portfolio(p_profile_code, p_account_code)->'positions') p
                 where p->>'isin' = p_isin),
    'series', coalesce((
      select jsonb_agg(jsonb_build_object(
               'as_of', bp.as_of, 'price', bp.price, 'price_date', bp.price_date, 'quantity', bp.quantity,
               'value', bp.market_value,
               'cost', round(bp.quantity * bp.cost_price * case when bp.price_in_pct then 0.01 else 1 end, 2))
             order by bp.as_of)
      from public.broker_positions bp
      where bp.account_code = p_account_code and bp.isin = p_isin), '[]'::jsonb),
    'sips', private.broker_sips_json(p_account_code, p_isin)));
end;
$$;
comment on function public.broker_position_detail(text, text, text) is
  'Member: one broker position by ISIN: as broker_portfolio shows it, its marks over time (price, units, value, cost) and its SIPs.';
grant execute on function public.broker_position_detail(text, text, text) to authenticated, service_role;

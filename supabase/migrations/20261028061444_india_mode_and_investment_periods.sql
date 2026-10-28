-- India mode, Investments' 30-day and 90-day periods, and a broker account's day move.
--
-- 1. India is its own mode, fully apart from Wealth: an account at an India bank (Zerodha Kite,
--    Zerodha Coin, and the legacy single Zerodha account: private.is_india_bank) and every holding
--    marked on one (holdings.portfolio = 'india', set by a trigger on broker_positions and backfilled
--    here) leave Wealth's net worth, allocation, cash, accounts, cash flow, investments, returns,
--    insights and broker summary. public.india_overview(profile, period) is India's screen: value,
--    invested, cash, P&L and the day's move per account and in total, growth over the period, and
--    the value per day. Kite's and Coin's own pages keep using broker_portfolio.
-- 2. holding_returns takes '30d' and '90d' (today − 30 / − 90 days) beside all, ytd and 12m.
-- 3. broker_accounts_summary leaves India out and gives each account its profit in AED and the
--    day's move of its open positions against each one's previous mark (change_24h, _aed, _pct).
-- Spend (cards, statements, Overview, Activity) is unchanged. Money is INR in India's figures
-- unless a field ends in _aed; decimal strings throughout (CLAUDE.md §1.3).

-- ── 1. the India scope ──────────────────────────────────────────────────────
create function private.is_india_bank(p_bank_code text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_bank_code in ('KITE', 'COIN', 'ZRD'), false)
$$;
comment on function private.is_india_bank(text) is
  'True for an India bank (KITE, COIN, legacy ZRD): its accounts, and the holdings marked on them, are India mode''s, never Wealth''s.';

alter table public.holdings add column portfolio text not null default 'wealth'
  check (portfolio in ('wealth', 'india'));
comment on column public.holdings.portfolio is
  'Which mode shows the holding: wealth, or india once it is marked on an India bank''s account (set by broker_positions_portfolio).';

-- Guarded: only holdings still on the default move.
update public.holdings h set portfolio = 'india'
where h.portfolio = 'wealth'
  and exists (select 1 from public.broker_positions bp
              join public.accounts a on a.account_code = bp.account_code
              where bp.holding_code = h.holding_code and private.is_india_bank(a.bank_code));

-- A holding marked on an India account is India's.
create function private.broker_positions_portfolio()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.holdings h set portfolio = 'india'
  where h.holding_code = new.holding_code and h.portfolio <> 'india'
    and exists (select 1 from public.accounts a
                where a.account_code = new.account_code and private.is_india_bank(a.bank_code));
  return null;
end;
$$;
create trigger broker_positions_portfolio
  after insert or update of holding_code, account_code on public.broker_positions
  for each row execute function private.broker_positions_portfolio();

-- ── 2. Wealth leaves India out ──────────────────────────────────────────────
-- Holdings: holding_values prices Wealth's holdings only, so holdings_valuation,
-- holdings_value_series, holding_returns and net worth (which read it) do too.
create or replace function private.holding_values(p_profile_code text, p_at timestamptz)
returns table (holding_code text, quote text, aed_per_gram numeric, price_as_of timestamptz, fine_factor numeric,
               value numeric, value_aed numeric, value_as_of date, is_stale boolean, is_estimate boolean)
language sql
stable
set search_path = ''
as $$
  with d as (select public.dubai_date(p_at) as day)
  select h.holding_code, m.quote, m.aed_per_gram, m.as_of, m.factor,
         v.value, case when h.currency = 'AED' then v.value else private.to_aed(v.value, h.currency) end,
         v.as_of, coalesce(v.stale, false), coalesce(v.estimate, false)
  from public.holdings h
  cross join d
  left join lateral (
    select x.quote, x.factor, p.aed_per_gram, p.as_of
    from (select case h.metal when 'gold' then 'gold_' || h.karat || 'k' else 'silver_retail' end as quote,
                 case h.metal when 'gold' then case when h.karat = 24 then private.gold_fineness_factor(h.fineness) else 1 end
                              else h.purity / 0.999 end as factor) x
    left join lateral private.metal_price_at(x.quote, p_at) p on true
    where h.kind = 'metal'
  ) m on true
  left join lateral (
    select hv.value, hv.unit_price, hv.as_of from public.holding_valuations hv
    where hv.holding_code = h.holding_code and hv.as_of <= d.day
    order by hv.as_of desc, hv.created_at desc limit 1
  ) lv on h.kind in ('plan', 'broker', 'security', 'deposit', 'structured_note')
  -- A security with a symbol: the latest close, when it is newer than the price entered.
  left join lateral (
    select sp.close, sp.price_date from public.security_prices sp
    where sp.symbol = upper(h.symbol) and sp.price_date <= d.day
    order by sp.price_date desc limit 1
  ) sp on h.kind = 'security' and h.symbol is not null
  left join public.structured_notes sn on sn.holding_code = h.holding_code and h.kind = 'structured_note'
  cross join lateral (
    select h.kind = 'security' and sp.price_date is not null and (lv.as_of is null or sp.price_date >= lv.as_of) as market
  ) mk
  cross join lateral (
    select case h.kind
             when 'metal' then round(h.grams * m.factor * m.aed_per_gram, 2)
             when 'security' then round(h.units * case when mk.market then sp.close else lv.unit_price end, 2)
             when 'deposit' then case
               when lv.value is not null then
                 round(lv.value * (1 + h.rate_pct / 100 * greatest(least(d.day, h.maturity_on) - lv.as_of, 0) / 365.0), 2)
               when d.day >= h.acquired_on then
                 round(h.principal * (1 + h.rate_pct / 100 * (least(d.day, h.maturity_on) - h.acquired_on) / 365.0), 2) end
             -- A live note: its market value (the broker's bid) once there is one on or after the
             -- trade date, else what was invested.
             when 'structured_note' then case when d.day >= sn.trade_date
                                              then case when lv.as_of >= sn.trade_date then lv.value else sn.invested_amount end end
             else lv.value
           end::numeric(14,2) as value,
           case h.kind when 'metal' then public.dubai_date(m.as_of)
                       when 'deposit' then case when lv.value is not null then greatest(lv.as_of, least(d.day, h.maturity_on))
                                                when d.day >= h.acquired_on then least(d.day, h.maturity_on) end
                       when 'structured_note' then case when d.day >= sn.trade_date
                                                        then case when lv.as_of >= sn.trade_date then lv.as_of else d.day end end
                       when 'security' then case when mk.market then sp.price_date else lv.as_of end
                       else lv.as_of end as as_of,
           case h.kind when 'metal' then m.as_of < p_at - private.metal_price_stale_after()
                       when 'deposit' then false
                       when 'structured_note' then lv.as_of >= sn.trade_date and lv.as_of < d.day - 7
                       when 'security' then case when mk.market then sp.price_date < d.day - 7 else lv.as_of < d.day - 45 end
                       else lv.as_of < d.day - 45 end as stale,
           h.kind = 'deposit' and lv.as_of is distinct from d.day as estimate
  ) v
  where h.profile_code = p_profile_code and h.status = 'active' and h.portfolio = 'wealth'
$$;

-- Returns: Wealth's holdings only, and two shorter periods.
create or replace function public.holding_returns(p_profile_code text, p_period text default 'all')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.dubai_date(now());
  v_from date;
  h record;
  v_start date;
  v0 numeric;
  v1 numeric;
  v_in numeric;
  v_out numeric;
  v_income numeric;
  v_growth numeric;
  v_dates date[];
  v_amounts numeric[];
  t_dates date[] := '{}';
  t_amounts numeric[] := '{}';
  t_v0 numeric := 0;
  t_v1 numeric := 0;
  t_in numeric := 0;
  t_out numeric := 0;
  t_income numeric := 0;
  v_rows jsonb := '[]'::jsonb;
  v_complete boolean;
  t_complete boolean := true;
begin
  perform private.assert_member(p_profile_code, false);
  if p_period is null or p_period not in ('all', 'ytd', '12m', '30d', '90d') then
    raise exception 'period must be all, ytd, 12m, 30d or 90d' using errcode = '22023';
  end if;
  v_from := case p_period when 'ytd' then date_trunc('year', v_today)::date
                          when '12m' then v_today - 365
                          when '90d' then v_today - 90
                          when '30d' then v_today - 30 end;

  for h in
    select ho.holding_code, ho.name, ho.kind,
           coalesce(least(ho.acquired_on, (select min(f.flow_date) from public.holding_flows f
                                           where f.holding_code = ho.holding_code
                                             and private.flow_is_active(f.removed_at, f.txn_code))),
                    public.dubai_date(ho.created_at)) as began
    from public.holdings ho
    where ho.profile_code = p_profile_code and ho.status = 'active' and ho.portfolio = 'wealth'
    order by ho.name
  loop
    v_start := case when v_from is null or h.began >= v_from then h.began else v_from end;
    if v_from is null or h.began >= v_from then
      v0 := 0;  -- began inside the period: the money it started with is a contribution
    else
      select hv.value_aed into v0 from private.holding_values(p_profile_code,
        (v_start::timestamp at time zone 'Asia/Dubai') - interval '1 microsecond') hv
      where hv.holding_code = h.holding_code;
    end if;
    select hv.value_aed into v1 from private.holding_values(p_profile_code, now()) hv
    where hv.holding_code = h.holding_code;
    select coalesce(sum(f.amount_aed) filter (where f.kind = 'contribution'), 0),
           coalesce(sum(f.amount_aed) filter (where f.kind = 'withdrawal'), 0),
           coalesce(sum(f.amount_aed) filter (where f.kind = 'income'), 0),
           coalesce(array_agg(f.flow_date order by f.flow_date), '{}'),
           coalesce(array_agg(case when f.kind = 'contribution' then -f.amount_aed else f.amount_aed end
                              order by f.flow_date), '{}')
    into v_in, v_out, v_income, v_dates, v_amounts
    from public.holding_flows f
    where f.holding_code = h.holding_code and private.flow_is_active(f.removed_at, f.txn_code)
      and f.flow_date >= v_start and f.flow_date <= v_today;
    -- All time needs to know what went in: a holding with no contribution has an unknown cost,
    -- and its whole value would read as growth.
    v_complete := v0 is not null and v1 is not null
                  and (v_from is null and v_in > 0 or v_from is not null);
    v_growth := case when v_complete then v1 - v0 - (v_in - v_out) + v_income end;
    if v0 > 0 then
      v_dates := array[v_start] || v_dates;
      v_amounts := array[-v0] || v_amounts;
    end if;
    if v1 is not null then
      v_dates := v_dates || v_today;
      v_amounts := v_amounts || v1;
    end if;
    v_rows := v_rows || jsonb_build_object(
      'holding_code', h.holding_code, 'name', h.name, 'kind', h.kind, 'from', v_start, 'to', v_today,
      'start_value_aed', v0::numeric(14,2)::text, 'end_value_aed', v1::numeric(14,2)::text,
      'added_aed', (v_in - v_out)::numeric(14,2)::text, 'income_aed', v_income::numeric(14,2)::text,
      'growth_aed', v_growth::numeric(14,2)::text,
      'simple_pct', case when v_complete and coalesce(v0, 0) + v_in > 0
                         then round(v_growth / (coalesce(v0, 0) + v_in) * 100, 2)::text end,
      'annual_pct', case when v_complete then private.xirr(v_dates, v_amounts)::text end,
      'complete', v_complete);
    if v_complete then
      t_v0 := t_v0 + v0; t_v1 := t_v1 + v1; t_in := t_in + v_in; t_out := t_out + v_out; t_income := t_income + v_income;
      -- The total's cash flows: everything but each holding's end value, which is added once below.
      t_dates := t_dates || v_dates[1:cardinality(v_dates) - 1];
      t_amounts := t_amounts || v_amounts[1:cardinality(v_amounts) - 1];
    else
      t_complete := false;
    end if;
  end loop;

  if t_v1 > 0 then
    t_dates := t_dates || v_today;
    t_amounts := t_amounts || t_v1;
  end if;
  return jsonb_build_object(
    'period', p_period, 'from', v_from, 'to', v_today,
    'total', jsonb_build_object(
      'start_value_aed', t_v0::numeric(14,2)::text, 'end_value_aed', t_v1::numeric(14,2)::text,
      'added_aed', (t_in - t_out)::numeric(14,2)::text, 'income_aed', t_income::numeric(14,2)::text,
      'growth_aed', (t_v1 - t_v0 - (t_in - t_out) + t_income)::numeric(14,2)::text,
      'simple_pct', case when t_v0 + t_in > 0
                         then round((t_v1 - t_v0 - (t_in - t_out) + t_income) / (t_v0 + t_in) * 100, 2)::text end,
      'annual_pct', private.xirr(t_dates, t_amounts)::text,
      'complete', t_complete),
    'holdings', v_rows);
end;
$$;
comment on function public.holding_returns(text, text) is
  'Member: per Wealth holding and in total for all time / this year / the last 12 months / 90 days / 30 days: start and end value, added, income, growth, simple % and the money-weighted yearly return (XIRR).';

-- Net worth (and so its snapshots and series): India's cash and holdings left out.
create or replace function private.net_worth(p_profile_code text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with cash as (
    select coalesce(sum(b.balance_aed), 0)::numeric(14,2) as total,
           coalesce(bool_and(b.balance_aed is not null and b.unpriced_count = 0), true) as complete,
           count(*) filter (where b.balance is null)::int as missing,
           count(*) filter (where b.is_stale)::int as stale,
           min(b.as_of) as as_of
    from public.v_bank_balances b join public.accounts a on a.account_code = b.account_code
    where b.profile_code = p_profile_code and a.status = 'active' and not private.is_india_bank(a.bank_code)
  ),
  owed as (
    select coalesce(sum(b.outstanding_aed), 0)::numeric(14,2) as total,
           coalesce(bool_and(b.anchor_kind <> 'none' and b.unpriced_count = 0), true) as complete,
           coalesce(bool_or(b.has_estimate), false) as has_estimate
    from public.v_account_balances b join public.accounts a on a.account_code = b.account_code
    where b.profile_code = p_profile_code and a.status = 'active'
  ),
  hv as (
    select v.*, h.kind, h.metal from private.holding_values(p_profile_code, now()) v
    join public.holdings h on h.holding_code = v.holding_code
  ),
  holdings as (
    select coalesce(sum(hv.value_aed), 0)::numeric(14,2) as total,
           coalesce(bool_and(hv.value_aed is not null and not hv.is_stale), true) as complete,
           count(*)::int as n
    from hv
  ),
  alloc as (
    select case when hv.kind = 'metal' then hv.metal else hv.kind end as class, sum(hv.value_aed) as value
    from hv where hv.value_aed is not null group by 1
  )
  select jsonb_build_object(
    'cash_aed', cash.total::text, 'cash_complete', cash.complete, 'cash_missing_count', cash.missing,
    'cash_stale_count', cash.stale, 'cash_as_of', cash.as_of,
    'holdings_aed', holdings.total::text, 'holdings_complete', holdings.complete, 'holdings_count', holdings.n,
    'owed_aed', owed.total::text, 'owed_complete', owed.complete, 'owed_has_estimate', owed.has_estimate,
    'net_aed', (cash.total + holdings.total - owed.total)::numeric(14,2)::text,
    'complete', cash.complete and owed.complete and holdings.complete,
    'has_bank_accounts', exists (select 1 from public.accounts a where a.profile_code = p_profile_code
                                 and a.kind in ('current', 'savings') and a.status = 'active'
                                 and not private.is_india_bank(a.bank_code)),
    -- Assets by class, largest first, then what the cards owe as a negative row. share_pct is
    -- each asset class's share of total assets (cash + holdings).
    'allocation', coalesce((
      select jsonb_agg(jsonb_build_object('class', x.class, 'value_aed', x.value::numeric(14,2)::text,
                                          'share_pct', case when x.class <> 'owed' and (cash.total + holdings.total) > 0
                                                            then round(x.value / (cash.total + holdings.total) * 100, 2)::text end)
                       order by x.ord, x.value desc)
      from (
        select 'cash'::text as class, cash.total as value, 0 as ord where cash.total <> 0
        union all select alloc.class, alloc.value, 0 from alloc where alloc.value <> 0
        union all select 'owed', -owed.total, 1 where owed.total <> 0
      ) x), '[]'::jsonb))
  from cash, owed, holdings
$$;

-- Cash and the Accounts list.
create or replace function public.cash_position(p_profile_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  select jsonb_build_object(
           -- The total counts AED balances only; complete says whether that is every account.
           'total_aed', coalesce(sum(b.balance_aed), 0)::numeric(14,2)::text,
           'complete', coalesce(bool_and(b.balance_aed is not null and b.unpriced_count = 0), true),
           'stale_count', count(*) filter (where b.is_stale)::int,
           'missing_count', count(*) filter (where b.balance is null)::int,
           'as_of', min(b.as_of),
           'accounts', coalesce(jsonb_agg(jsonb_build_object(
               'account_code', a.account_code, 'bank_code', a.bank_code, 'kind', a.kind,
               'nickname', a.nickname, 'account_ref', a.account_ref, 'currency', a.currency,
               'balance', b.balance::text, 'balance_aed', b.balance_aed::text,
               'as_of', b.as_of, 'anchor_source', b.anchor_source,
               'is_stale', b.is_stale, 'unpriced_count', b.unpriced_count)
             order by a.bank_code, a.nickname nulls last, a.account_code), '[]'::jsonb))
  into v_out
  from public.accounts a
  join public.v_bank_balances b on b.account_code = a.account_code
  where a.profile_code = p_profile_code and a.status = 'active' and not private.is_india_bank(a.bank_code);
  return v_out;
end;
$$;
comment on function public.cash_position(text) is
  'Member: active bank accounts outside India with balance (latest checkpoint + later activity), as_of and staleness, and the AED total.';

-- Cash flow and its savings: India's accounts, checkpoints and holdings left out.
create or replace function public.cash_flow_savings(p_profile_code text, p_from date, p_to date, p_account_code text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, false);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from must be on or before p_to' using errcode = '22023';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('month', x.m, 'holding_code', x.holding_code, 'holding_name', h.name,
                                        'holding_kind', h.kind, 'amount_aed', x.amt::text, 'txn_count', x.n)
                     order by x.m, x.amt desc)
    from (
      select date_trunc('month', v.txn_date)::date as m, v.holding_code, sum(v.amount_aed)::numeric(14,2) as amt,
             count(*)::int as n
      from public.v_cash_flow v
      where v.profile_code = p_profile_code and v.flow = 'saving' and v.txn_date between p_from and p_to
        and (p_account_code is null or v.account_code = p_account_code)
        and not exists (select 1 from public.accounts a
                        where a.account_code = v.account_code and private.is_india_bank(a.bank_code))
      group by 1, 2
    ) x
    left join public.holdings h on h.holding_code = x.holding_code
    where h.holding_code is null or h.portfolio = 'wealth'), '[]'::jsonb);
end;
$$;

create or replace function public.cash_flow(p_profile_code text, p_from date, p_to date, p_account_code text default null)
returns table (month date, flow text, amount_aed numeric(14,2), txn_count int, is_partial boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cover date;
begin
  perform private.assert_member(p_profile_code, false);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from must be on or before p_to' using errcode = '22023';
  end if;
  if p_account_code is not null and not exists (
       select 1 from public.accounts where account_code = p_account_code and profile_code = p_profile_code) then
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  select least(
           (select min(t.txn_date) from public.transactions t
            join public.accounts a on a.account_code = t.account_code and a.kind in ('current', 'savings')
              and not private.is_india_bank(a.bank_code)
            where t.profile_code = p_profile_code and t.status in ('pending', 'posted')
              and (p_account_code is null or t.account_code = p_account_code)),
           (select min(public.dubai_date(bc.as_of)) from public.balance_checkpoints bc
            join public.accounts a on a.account_code = bc.account_code and not private.is_india_bank(a.bank_code)
            where bc.profile_code = p_profile_code
              and (p_account_code is null or bc.account_code = p_account_code)))
  into v_cover;

  return query
  with f as (
    select date_trunc('month', v.txn_date)::date as m, v.flow as fl, v.amount_aed as amt
    from public.v_cash_flow v
    where v.profile_code = p_profile_code and v.txn_date between p_from and p_to
      and (p_account_code is null or v.account_code = p_account_code)
      and not exists (select 1 from public.accounts a
                      where a.account_code = v.account_code and private.is_india_bank(a.bank_code))
  ),
  g as (
    select f.m, f.fl, sum(f.amt)::numeric(14,2) as amt, count(*)::int as n from f group by f.m, f.fl
    union all
    select f.m, 'net'::text,
           sum(case when f.fl in ('income', 'money_in') then f.amt
                    when f.fl in ('spend', 'spend_transfer', 'support', 'saving', 'money_out') then -f.amt
                    else 0 end)::numeric(14,2),
           count(*)::int
    from f group by f.m
  )
  select g.m, g.fl, g.amt, g.n, (v_cover is null or g.m < v_cover)
  from g
  order by 1, 2;
end;
$$;

-- Wealth insights: no stale-balance or drift card for an India account.
create or replace function private.generate_wealth_insights(p_profile_code text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.dubai_date(now());
  v_month date := date_trunc('month', v_today)::date;
  v_day int := extract(day from v_today)::int;
  v_count int := 0;
  n int;
begin
  -- A bank balance never entered, or older than a week: net worth and cash flow lean on it. The
  -- key carries the balance's date, so a dismissal holds until the balance changes.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'balance_stale', 'info',
         a.account_code || ':' || coalesce(public.dubai_date(b.as_of)::text, 'none'),
         case when b.as_of is null then 'No balance yet for ' || private.bank_account_label(a)
              else private.bank_account_label(a) || ' balance is ' || (v_today - public.dubai_date(b.as_of)) || ' days old' end,
         case when b.as_of is null then 'Enter today''s balance once; alerts keep it current after that.'
              else 'Last known on ' || to_char(public.dubai_date(b.as_of), 'FMDD Mon')
                   || '. Update it, or check that the account automation is running.' end,
         jsonb_build_object('account_code', a.account_code, 'as_of', b.as_of),
         v_today + 1
  from public.accounts a
  join public.v_bank_balances b on b.account_code = a.account_code
  where a.profile_code = p_profile_code and a.status = 'active' and (b.as_of is null or b.is_stale)
    and not private.is_india_bank(a.bank_code)
  on conflict (profile_code, kind, dedupe_key) do update
    set title = excluded.title, body = excluded.body, data = excluded.data, valid_until = excluded.valid_until;
  get diagnostics n = row_count; v_count := v_count + n;
  -- A balance that is current again (or a newer stale period) retires the old card.
  delete from public.insights i
  where i.profile_code = p_profile_code and i.kind = 'balance_stale'
    and not exists (select 1 from public.accounts a join public.v_bank_balances b on b.account_code = a.account_code
                    where a.profile_code = p_profile_code and a.status = 'active' and (b.as_of is null or b.is_stale)
                      and not private.is_india_bank(a.bank_code)
                      and i.dedupe_key = a.account_code || ':' || coalesce(public.dubai_date(b.as_of)::text, 'none'));

  -- An SMS balance that disagrees with the previous checkpoint plus the activity between them:
  -- an alert was missed (or an amount misread). Last 30 days, priced activity only.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'balance_drift', 'warn', d.checkpoint_code,
         private.bank_account_label(d.acc) || ': ' || private.fmt_aed(abs(d.diff)) || ' unaccounted for',
         'The bank put the balance at ' || private.fmt_aed(d.balance) || ' on ' || to_char(public.dubai_date(d.as_of), 'FMDD Mon')
           || ', but the balance on ' || to_char(public.dubai_date(d.prev_as_of), 'FMDD Mon') || ' plus the alerts since add up to '
           || private.fmt_aed(d.expected) || '. A transaction may have been missed'
           || case when d.diff < 0 then ' (money out).' else ' (money in).' end,
         jsonb_build_object('account_code', d.account_code, 'checkpoint_code', d.checkpoint_code,
                            'balance', d.balance::text, 'expected', d.expected::text, 'difference', d.diff::text),
         public.dubai_date(d.as_of) + 14
  from (
    select a as acc, a.account_code, c.checkpoint_code, c.as_of, c.balance, p.as_of as prev_as_of,
           (p.balance + coalesce(x.activity, 0))::numeric(14,2) as expected,
           (c.balance - p.balance - coalesce(x.activity, 0))::numeric(14,2) as diff
    from public.accounts a
    join public.balance_checkpoints c on c.account_code = a.account_code and c.source = 'sms'
    cross join lateral (
      select bc.as_of, bc.balance from public.balance_checkpoints bc
      where bc.account_code = a.account_code and bc.as_of < c.as_of
      order by bc.as_of desc, bc.created_at desc limit 1
    ) p
    cross join lateral (
      select sum(r.samt) as activity, count(*) filter (where r.samt is null) as unpriced
      from private.bank_amounts(a.account_code) r where r.ts > p.as_of and r.ts <= c.as_of
    ) x
    where a.profile_code = p_profile_code and a.kind in ('current', 'savings') and a.currency = 'AED'
      and not private.is_india_bank(a.bank_code)
      and c.as_of >= now() - interval '30 days' and x.unpriced = 0
  ) d
  where abs(d.diff) >= 1
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Salary not in by its usual day: the day the month's largest income credit landed, over the
  -- last three months that had one (two at least), three days' grace. Gone once it lands.
  with m as (
    select date_trunc('month', f.txn_date)::date as mo,
           (array_agg(extract(day from f.txn_date)::int order by f.amount_aed desc))[1] as dom,
           max(f.amount_aed) as amt
    from public.v_cash_flow f
    where f.profile_code = p_profile_code and f.flow = 'income'
      and f.txn_date >= (v_month - interval '3 month')::date and f.txn_date < v_month
    group by 1
  ),
  u as (
    select percentile_disc(0.5) within group (order by m.dom) as usual_day,
           percentile_disc(0.5) within group (order by m.amt) as usual_amt, count(*) as months
    from m
  )
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'salary_late', 'warn', v_month::text,
         'Salary not in yet',
         'It has arrived by the ' || u.usual_day || case when u.usual_day in (1, 21, 31) then 'st'
                                                          when u.usual_day in (2, 22) then 'nd'
                                                          when u.usual_day in (3, 23) then 'rd' else 'th' end
           || ' in recent months (about ' || private.fmt_aed(u.usual_amt) || '); nothing this month so far.',
         jsonb_build_object('usual_day', u.usual_day, 'usual_amount', u.usual_amt::text),
         (v_month + interval '1 month')::date - 1
  from u
  where u.months >= 2 and v_day > u.usual_day + 3
    and not exists (select 1 from public.v_cash_flow f
                    where f.profile_code = p_profile_code and f.flow = 'income' and f.txn_date >= v_month
                      and f.amount_aed >= u.usual_amt / 2)
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;
  delete from public.insights i
  where i.profile_code = p_profile_code and i.kind = 'salary_late' and i.dedupe_key = v_month::text
    and exists (select 1 from public.v_cash_flow f
                where f.profile_code = p_profile_code and f.flow = 'income' and f.txn_date >= v_month
                  and f.amount_aed >= (i.data->>'usual_amount')::numeric / 2);

  -- A card's annual (membership) fee, net of reversals, above the cashback it earned in the
  -- last 12 months: raised for 60 days after the fee is charged.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'annual_fee', 'info', x.account_code || ':' || to_char(x.last_fee, 'YYYY-MM'),
         coalesce(nullif(btrim(x.nickname), ''), x.bank_code || ' card') || ': ' || private.fmt_aed(x.fees)
           || ' fee, ' || private.fmt_aed(x.cashback) || ' back',
         'In the last 12 months this card charged ' || private.fmt_aed(x.fees)
           || ' in annual fees (with VAT) and earned ' || private.fmt_aed(x.cashback)
           || ' in cashback. Ask the bank to waive the fee, or weigh a no-fee card.',
         jsonb_build_object('account_code', x.account_code, 'fees', x.fees::text, 'cashback', x.cashback::text),
         x.last_fee + 60
  from (
    select a.account_code, a.nickname, a.bank_code,
           coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)
                      filter (where t.description ~* '(ANNUAL|MEMBERSHIP) FEE'), 0)::numeric(14,2) as fees,
           coalesce(sum(t.amount_aed) filter (where t.direction = 'credit' and c.kind = 'income'
                                                and t.kind <> 'payment'), 0)::numeric(14,2) as cashback,
           max(t.txn_date) filter (where t.direction = 'debit' and t.description ~* '(ANNUAL|MEMBERSHIP) FEE') as last_fee
    from public.accounts a
    join public.transactions t on t.account_code = a.account_code
    left join public.categories c on c.category_code = t.effective_category_code
    where a.profile_code = p_profile_code and a.kind = 'credit_card' and a.status = 'active'
      and t.status in ('pending', 'posted') and t.amount_aed is not null
      and t.txn_date > v_today - 365
    group by a.account_code, a.nickname, a.bank_code
  ) x
  where x.fees > 0 and x.fees > x.cashback and x.last_fee >= v_today - 60
  on conflict (profile_code, kind, dedupe_key) do update
    set title = excluded.title, body = excluded.body, data = excluded.data;
  get diagnostics n = row_count; v_count := v_count + n;

  return v_count;
end;
$$;

-- ── 3. a broker account's latest positions and their day move ──────────────
-- Each position of the account's latest marked day: value, cost (quantity × cost price), and its
-- move against that ISIN's previous priced mark at today's quantity (so units bought or sold are
-- not a move): market value − quantity × previous price, × 0.01 when priced in % of nominal.
-- prev_value is that base; both null without a previous mark.
create function private.broker_latest_positions(p_account_code text)
returns table (position_code text, holding_code text, isin text, as_of date, market_value numeric,
               invested numeric, change_24h numeric, prev_value numeric)
language sql
stable
set search_path = ''
as $$
  select bp.position_code, bp.holding_code, bp.isin, bp.as_of, bp.market_value,
         round(bp.quantity * bp.cost_price * f.f, 2),
         case when bp.market_value is not null and pv.price is not null
              then bp.market_value - round(bp.quantity * pv.price * f.f, 2) end,
         case when bp.market_value is not null and pv.price is not null
              then round(bp.quantity * pv.price * f.f, 2) end
  from public.broker_positions bp
  cross join lateral (select case when bp.price_in_pct then 0.01 else 1 end as f) f
  left join lateral (
    select p.price from public.broker_positions p
    where p.account_code = bp.account_code and p.isin = bp.isin and p.as_of < bp.as_of and p.price is not null
    order by p.as_of desc limit 1
  ) pv on true
  where bp.account_code = p_account_code
    and bp.as_of = (select max(x.as_of) from public.broker_positions x where x.account_code = p_account_code)
$$;

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
             'profit_aed', private.to_aed(x.cash + x.pv - n.net, a.currency),
             'change_24h', x.change, 'change_24h_aed', private.to_aed(x.change, a.currency),
             'change_24h_pct', case when x.prev > 0 then round(x.change / x.prev * 100, 2) end,
             'live_notes', x.live_notes, 'positions', x.positions,
             'last_synced_at', c.last_synced_at, 'sync_status', c.last_status,
             'holding_codes', coalesce(x.holdings, '[]'::jsonb)) order by c.created_at)
    from public.broker_connections c
    join public.accounts a on a.account_code = c.account_code
    left join public.banks b on b.bank_code = a.bank_code
    cross join lateral (
      select coalesce((select v.balance from public.v_bank_balances v where v.account_code = c.account_code), 0) as cash,
             coalesce(sum(lp.market_value), 0) as pv,
             coalesce(sum(lp.invested), 0) as invested,
             sum(lp.change_24h) as change,
             sum(lp.prev_value) as prev,
             coalesce((select sum(bt.net_amount) from public.broker_transactions bt
                       where bt.account_code = c.account_code and bt.kind in ('deposit', 'withdrawal')), 0) as deposits,
             (select count(*) from public.structured_notes n
              where n.funding_account_code = c.account_code and n.status = 'live') as live_notes,
             count(lp.position_code) as positions,
             (select jsonb_agg(distinct u.holding_code) from (
                select bt.holding_code from public.broker_transactions bt
                where bt.account_code = c.account_code and bt.holding_code is not null
                union
                select bp2.holding_code from public.broker_positions bp2 where bp2.account_code = c.account_code
              ) u) as holdings
      from private.broker_latest_positions(c.account_code) lp
    ) x
    cross join lateral (
      select case when c.provider = 'zerodha' then x.invested + x.cash else x.deposits end as net
    ) n
    where c.profile_code = p_profile_code and not private.is_india_bank(a.bank_code)), '[]'::jsonb));
end;
$$;
comment on function public.broker_accounts_summary(text) is
  'Member: each synced broker account outside India in one line (value, cash, net deposits, profit and in AED, the day''s move of its open positions, live notes, its holdings) for Investments. Decimal strings.';

-- ── 4. India's screen ───────────────────────────────────────────────────────
-- The ledger's active India accounts, each at its latest mark: cash, positions' value, cost and
-- day move, its connection's last sync. ord: Kite, then Coin, then the legacy account. segment:
-- 'kite' for Kite and for the legacy combined Zerodha account (ZRD: it holds the Funds cash and
-- the shares; once split it is Kite's), 'coin' for Coin.
create function private.india_accounts(p_profile_code text)
returns table (account_code text, bank_code text, name text, segment text, currency text, ord int,
               created_at timestamptz, cash numeric, pv numeric, invested numeric, change numeric, prev numeric,
               positions int, last_synced_at timestamptz, sync_status text)
language sql
stable
set search_path = ''
as $$
  select a.account_code, a.bank_code, coalesce(nullif(btrim(a.nickname), ''), b.name, a.bank_code),
         case a.bank_code when 'COIN' then 'coin' else 'kite' end, a.currency,
         case a.bank_code when 'KITE' then 0 when 'COIN' then 1 else 2 end, a.created_at,
         coalesce((select v.balance from public.v_bank_balances v where v.account_code = a.account_code), 0),
         x.pv, x.invested, x.change, x.prev, x.positions, c.last_synced_at, c.last_status
  from public.accounts a
  left join public.banks b on b.bank_code = a.bank_code
  left join lateral (
    select bc.last_synced_at, bc.last_status from public.broker_connections bc
    where bc.account_code = a.account_code order by bc.created_at desc limit 1
  ) c on true
  cross join lateral (
    select coalesce(sum(lp.market_value), 0) as pv, coalesce(sum(lp.invested), 0) as invested,
           sum(lp.change_24h) as change, sum(lp.prev_value) as prev, count(lp.position_code)::int as positions
    from private.broker_latest_positions(a.account_code) lp
  ) x
  where a.profile_code = p_profile_code and a.status = 'active' and private.is_india_bank(a.bank_code)
$$;

-- Member: the ledger's India accounts (Kite first, then Coin) and their total, in INR (and AED
-- where named): value (cash + positions at the latest mark), invested (cost of open positions),
-- cash, P&L (positions − invested), the day's move against each position's previous mark, and
-- over the period (30d, 90d, ytd, 12m; from as in holding_returns): the value at its start and
-- end, what was added, and the growth.
--   start  = each account's last snapshot before the period (the value at the end of the day
--            before `from`, as holding_returns takes it). An account opened after the ledger's
--            India data began, inside the period, starts at 0 and its opening positions count as
--            added (holding_returns' rule for a holding that began inside the period). When the
--            ledger's India data itself begins inside the period (its first sync is after the
--            day before `from`), the start is unknown: start, added, growth and growth % are null,
--            never 0 (a first sync's positions were bought before it, at an unknown time).
--   end    = each account's latest snapshot; null with no snapshot at all.
--   added  = the change in cash + the positions' flows in the period (contributions at cost,
--            withdrawals at the price sold): money put in or taken out, so neither a deposit nor
--            a buy or a sale reads as growth.
--   growth = (end − start) − added; growth % over start + max(added, 0), null when that is 0.
-- value_aed (and change_24h_aed) in the total is null when any account's is unknown (no INR rate).
-- series: one point per day in the period with a snapshot, each account's last one carried.
create function public.india_overview(p_profile_code text, p_period text default '90d')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.dubai_date(now());
  v_from date;
  v_accounts jsonb;
  v_codes text[];
  t record;
  p record;
  v_flows numeric;
  v_added numeric;
  v_growth numeric;
  v_series jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_period is null or p_period not in ('30d', '90d', 'ytd', '12m') then
    raise exception 'period must be 30d, 90d, ytd or 12m' using errcode = '22023';
  end if;
  v_from := case p_period when 'ytd' then date_trunc('year', v_today)::date
                          when '12m' then v_today - 365
                          when '90d' then v_today - 90
                          else v_today - 30 end;

  select array_agg(i.account_code) into v_codes from private.india_accounts(p_profile_code) i;
  v_codes := coalesce(v_codes, '{}');

  select coalesce(jsonb_agg(jsonb_build_object(
           'account_code', i.account_code, 'bank_code', i.bank_code, 'name', i.name, 'segment', i.segment,
           'value', (i.cash + i.pv)::numeric(14,2)::text,
           'value_aed', private.to_aed(i.cash + i.pv, i.currency)::numeric(14,2)::text,
           'invested', i.invested::numeric(14,2)::text, 'cash', i.cash::numeric(14,2)::text,
           'pnl', (i.pv - i.invested)::numeric(14,2)::text,
           'pnl_pct', case when i.invested > 0 then round((i.pv - i.invested) / i.invested * 100, 2)::text end,
           'change_24h', i.change::numeric(14,2)::text,
           'change_24h_pct', case when i.prev > 0 then round(i.change / i.prev * 100, 2)::text end,
           'positions', i.positions::text,
           'last_synced_at', i.last_synced_at, 'sync_status', i.sync_status)
           order by i.ord, i.created_at, i.account_code), '[]'::jsonb)
  into v_accounts
  from private.india_accounts(p_profile_code) i;

  select coalesce(sum(i.cash + i.pv), 0) as value,
         case when bool_and(private.to_aed(i.cash + i.pv, i.currency) is not null) is not false
              then coalesce(sum(private.to_aed(i.cash + i.pv, i.currency)), 0) end as value_aed,
         coalesce(sum(i.invested), 0) as invested, coalesce(sum(i.cash), 0) as cash,
         coalesce(sum(i.pv), 0) as pv,
         sum(i.change) as change,
         case when bool_and(i.change is null or private.to_aed(i.change, i.currency) is not null) is not false
              then sum(private.to_aed(i.change, i.currency)) end as change_aed,
         sum(i.prev) as prev,
         coalesce(sum(i.positions), 0)::int as positions, max(i.last_synced_at) as last_synced_at
  into t
  from private.india_accounts(p_profile_code) i;

  -- The period: each account's last snapshot before it starts (0 for one opened inside it after
  -- the data began), and its latest. The start is known only when the data reaches before it.
  select exists (select 1 from public.broker_snapshots s
                 where s.account_code = any (v_codes) and s.as_of < v_from) as known,
         coalesce(sum(s0.total_value), 0) as start_value, coalesce(sum(s0.cash), 0) as start_cash,
         sum(s1.total_value) as end_value, coalesce(sum(s1.cash), 0) as end_cash
  into p
  from unnest(v_codes) ac(code)
  left join lateral (
    select s.total_value, s.cash from public.broker_snapshots s
    where s.account_code = ac.code and s.as_of < v_from order by s.as_of desc limit 1
  ) s0 on true
  left join lateral (
    select s.total_value, s.cash from public.broker_snapshots s
    where s.account_code = ac.code and s.as_of <= v_today order by s.as_of desc limit 1
  ) s1 on true;

  select coalesce(sum(case f.kind when 'contribution' then f.amount when 'withdrawal' then -f.amount else 0 end), 0)
  into v_flows
  from public.holding_flows f
  join public.holdings h on h.holding_code = f.holding_code
  where h.profile_code = p_profile_code and h.portfolio = 'india'
    and private.flow_is_active(f.removed_at, f.txn_code)
    and f.flow_date >= v_from and f.flow_date <= v_today;
  if p.known then
    v_added := (p.end_cash - p.start_cash) + v_flows;
    v_growth := (p.end_value - p.start_value) - v_added;
  end if;

  -- The value per day: each account's snapshot carried to the days another account has one.
  select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'value', d.value::numeric(14,2)::text,
                                               'invested', d.invested::numeric(14,2)::text) order by d.day), '[]'::jsonb)
  into v_series
  from (
    select dd.day, sum(ls.total_value) as value, sum(ls.invested) as invested
    from (select distinct s.as_of as day from public.broker_snapshots s
          where s.account_code = any (v_codes) and s.as_of between v_from and v_today) dd
    cross join unnest(v_codes) ac(code)
    join lateral (
      select s.total_value,
             coalesce((select sum(round(bp.quantity * bp.cost_price * case when bp.price_in_pct then 0.01 else 1 end, 2))
                       from public.broker_positions bp
                       where bp.account_code = s.account_code and bp.as_of = s.as_of), 0) as invested
      from public.broker_snapshots s
      where s.account_code = ac.code and s.as_of <= dd.day order by s.as_of desc limit 1
    ) ls on true
    group by dd.day
  ) d;

  return jsonb_build_object(
    'available', cardinality(v_codes) > 0,
    'currency', 'INR',
    'period', p_period, 'from', v_from, 'to', v_today,
    'total', jsonb_build_object(
      'value', t.value::numeric(14,2)::text, 'value_aed', t.value_aed::numeric(14,2)::text,
      'invested', t.invested::numeric(14,2)::text, 'cash', t.cash::numeric(14,2)::text,
      'pnl', (t.pv - t.invested)::numeric(14,2)::text,
      'pnl_pct', case when t.invested > 0 then round((t.pv - t.invested) / t.invested * 100, 2)::text end,
      'change_24h', t.change::numeric(14,2)::text, 'change_24h_aed', t.change_aed::numeric(14,2)::text,
      'change_24h_pct', case when t.prev > 0 then round(t.change / t.prev * 100, 2)::text end,
      'period_start_value', case when p.known then p.start_value::numeric(14,2)::text end,
      'period_end_value', p.end_value::numeric(14,2)::text,
      'period_added', v_added::numeric(14,2)::text, 'period_growth', v_growth::numeric(14,2)::text,
      'period_growth_pct', case when p.known and p.start_value + greatest(v_added, 0) <> 0
                                then round(v_growth / (p.start_value + greatest(v_added, 0)) * 100, 2)::text end,
      'positions', t.positions::text,
      'last_synced_at', t.last_synced_at),
    'accounts', v_accounts,
    'series', v_series);
end;
$$;
comment on function public.india_overview(text, text) is
  'Member: India mode (Zerodha Kite and Coin): per account and in total, value, invested, cash, P&L and the day''s move; over 30d/90d/ytd/12m the start and end value, money added, growth and growth %; the value and cost per day. INR decimal strings, *_aed in AED.';
grant execute on function public.india_overview(text, text) to authenticated, service_role;

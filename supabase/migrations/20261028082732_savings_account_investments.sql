-- A savings account as an investment (tasks/todo.md §13): Mashreq's Neo Plus Saver pays 5% a
-- year, credited monthly, so it belongs on Investments with its returns, while it stays a bank
-- account with its statements and transactions.
--
-- A `savings_account` holding is backed by one bank account (holdings.account_code). Its value on
-- any day is that account's balance (private.bank_balance_at: the latest statement or SMS balance
-- plus later transactions), so it always matches Accounts. Net worth counts it once: its
-- account's cash leaves the cash total and its value joins the holdings. The account's own
-- transactions are the holding's flows: money moved in is a contribution, money moved out a
-- withdrawal, interest is income that stays in the account (reinvested), so returns do not add
-- it again.

-- ── 1. holdings.account_code and kind savings_account ───────────────────────
alter table public.holdings add column account_code text;
alter table public.holdings add constraint holdings_account_fkey foreign key (profile_code, account_code)
  references public.accounts(profile_code, account_code) on delete cascade;
create unique index holdings_account_active_uq on public.holdings(account_code)
  where account_code is not null and status = 'active';
comment on column public.holdings.account_code is
  'A savings_account holding''s bank account: the holding is valued at its balance and its transactions are the flows.';

alter table public.holdings drop constraint holdings_kind_check;
alter table public.holdings add constraint holdings_kind_check
  check (kind in ('metal', 'plan', 'broker', 'security', 'deposit', 'structured_note', 'savings_account'));
alter table public.holdings add constraint holdings_account_kind_check
  check ((kind = 'savings_account') = (account_code is not null));

-- As before, except that a savings account may state its interest rate.
alter table public.holdings drop constraint holdings_kind_fields_check;
alter table public.holdings add constraint holdings_kind_fields_check check (
  case kind
    when 'metal' then metal is not null and grams is not null and form is not null and currency = 'AED'
      and units is null and principal is null and rate_pct is null and maturity_on is null
      and ((metal = 'gold' and karat is not null and purity is null and (fineness is null or karat = 24))
           or (metal = 'silver' and karat is null and fineness is null and purity is not null and form <> 'jewellery'))
    else metal is null and grams is null and karat is null and fineness is null and purity is null and form is null
      and cost_aed is null
      and (kind <> 'security' or units is not null) and (kind = 'security' or units is null)
      and (kind <> 'deposit' or (principal is not null and rate_pct is not null and acquired_on is not null
                                 and maturity_on is not null and maturity_on > acquired_on))
      and (kind = 'deposit' or (principal is null and maturity_on is null))
      and (kind in ('deposit', 'savings_account') or rate_pct is null)
  end
);

alter table public.holding_flows drop constraint holding_flows_source_check;
alter table public.holding_flows add constraint holding_flows_source_check
  check (source in ('manual', 'rule', 'link', 'holding_cost', 'import', 'note', 'account'));

-- ── 2. Flows from the account's transactions ────────────────────────────────
-- The flow a transaction on a savings account makes for its holding: transfers in and out are
-- contributions and withdrawals, an interest credit is income. Purchases and fees make none: they
-- stay spend, and lower the value as a loss.
create function private.account_flow_kind(t public.transactions)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when t.kind = 'interest' and t.direction = 'credit' then 'income'
           when t.kind = 'transfer_in' then 'contribution'
           when t.kind = 'transfer_out' then 'withdrawal'
         end
$$;

create or replace function private.sync_txn_holding_flow(p_txn_code text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  t public.transactions;
  h public.holdings;
  f public.holding_flows;
  v_holding text;
  v_kind text;
  x record;
begin
  select * into t from public.transactions where txn_code = p_txn_code;
  if not found or t.amount_aed is null or t.amount_aed <= 0 then
    return;
  end if;
  select * into f from public.holding_flows where txn_code = p_txn_code;
  if found then
    -- Keep a linked flow's figures in step with its transaction (an SMS amount the statement
    -- corrects, a pending date that posts). Removed links stay removed.
    if f.removed_at is null and f.source = 'account' then
      select * into h from public.holdings where holding_code = f.holding_code;
      update public.holding_flows
      set flow_date = t.txn_date, amount = coalesce(case when t.currency_original = h.currency then t.amount_original end,
                                                    amount),
          amount_aed = t.amount_aed
      where flow_code = f.flow_code
        and (flow_date, amount_aed) is distinct from (t.txn_date, t.amount_aed);
      -- A transaction re-classified (a transfer that turns out to be interest) changes its kind.
      update public.holding_flows set kind = private.account_flow_kind(t)
      where flow_code = f.flow_code and private.account_flow_kind(t) is not null
        and kind is distinct from private.account_flow_kind(t);
    elsif f.removed_at is null and f.source in ('rule', 'link') then
      select * into h from public.holdings where holding_code = f.holding_code;
      select * into x from private.flow_from_txn(t, h);
      update public.holding_flows
      set flow_date = t.txn_date, amount = coalesce(x.amount, amount), amount_aed = x.amount_aed
      where flow_code = f.flow_code
        and (flow_date, amount, amount_aed) is distinct from (t.txn_date, coalesce(x.amount, amount), x.amount_aed);
    end if;
    return;
  end if;
  if t.status not in ('pending', 'posted') then
    return;
  end if;

  -- A transaction on an account that backs a savings_account holding is that holding's flow.
  select * into h from public.holdings
  where account_code = t.account_code and kind = 'savings_account' and status = 'active';
  if found then
    v_kind := private.account_flow_kind(t);
    if v_kind is not null then
      insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code, source)
      values (t.profile_code, h.holding_code, t.txn_date, v_kind,
              case when t.currency_original = h.currency then t.amount_original else t.amount_aed end,
              t.amount_aed, t.txn_code, 'account')
      on conflict (txn_code) where txn_code is not null do nothing;
    end if;
    return;
  end if;

  v_holding := private.rule_holding_for(t);
  if v_holding is null then
    return;
  end if;
  select * into h from public.holdings where holding_code = v_holding;
  select * into x from private.flow_from_txn(t, h);
  if x.amount is null or x.amount <= 0 then
    return;
  end if;
  insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code, source)
  values (t.profile_code, h.holding_code, t.txn_date, x.kind, x.amount, x.amount_aed, t.txn_code, 'rule')
  on conflict (txn_code) where txn_code is not null do nothing;
end;
$$;

-- ── 3. Showing a savings account under Investments ──────────────────────────
create function public.track_account_as_investment(p_profile_code text, p_account_code text,
                                                   p_rate_pct text default null, p_name text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.accounts;
  v_code text;
  v_rate numeric;
begin
  perform private.assert_member(p_profile_code, true);
  select * into a from public.accounts where account_code = p_account_code and profile_code = p_profile_code;
  if not found or a.kind not in ('current', 'savings') then
    raise exception 'not a bank account of this ledger' using errcode = '22023';
  end if;
  if nullif(btrim(p_rate_pct), '') is not null then
    begin
      v_rate := btrim(p_rate_pct)::numeric;
    exception when others then
      raise exception 'rate_pct must be a number' using errcode = '22023';
    end;
    if v_rate < 0 or v_rate > 100 then
      raise exception 'rate_pct must be between 0 and 100' using errcode = '22023';
    end if;
  end if;

  select holding_code into v_code from public.holdings
  where account_code = p_account_code and kind = 'savings_account'
  order by (status = 'active') desc, created_at desc limit 1;
  if v_code is null then
    insert into public.holdings (profile_code, kind, name, currency, institution, rate_pct, account_code, created_by)
    values (p_profile_code, 'savings_account',
            left(coalesce(nullif(btrim(p_name), ''), a.product_name, a.nickname, 'Savings account'), 80),
            a.currency, a.bank_code, v_rate, p_account_code, auth.uid())
    returning holding_code into v_code;
  else
    update public.holdings
    -- No rate keeps the one set; an empty one clears it.
    set status = 'active',
        rate_pct = case when p_rate_pct is not null and btrim(p_rate_pct) = '' then null else coalesce(v_rate, rate_pct) end,
        name = coalesce(left(nullif(btrim(p_name), ''), 80), name)
    where holding_code = v_code;
  end if;

  -- The account's transactions so far become the holding's flows.
  perform private.sync_txn_holding_flow(t.txn_code)
  from public.transactions t where t.account_code = p_account_code;
  return v_code;
end;
$$;
comment on function public.track_account_as_investment(text, text, text, text) is
  'Owner: show a bank account under Investments as a savings_account holding valued at its balance (net worth counts it there, not as cash); its transfers and interest become the holding''s flows. Idempotent; reopens a closed one. No rate keeps the stated rate, an empty string clears it.';
grant execute on function public.track_account_as_investment(text, text, text, text) to authenticated, service_role;

-- ── 4. Value: the account's balance ─────────────────────────────────────────
-- The latest evidence of a bank account's balance at an instant: a checkpoint or a transaction.
create function private.bank_evidence_as_of(p_account_code text, p_at timestamptz)
returns date
language sql
stable
set search_path = ''
as $$
  select public.dubai_date(greatest(
    (select max(bc.as_of) from public.balance_checkpoints bc where bc.account_code = p_account_code and bc.as_of <= p_at),
    (select max(r.ts) from private.bank_amounts(p_account_code) r where r.ts <= p_at)))
$$;

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
  -- A savings account: its balance then, and the day of the evidence it rests on.
  left join lateral (
    select private.bank_balance_at(h.account_code, p_at) as balance,
           private.bank_evidence_as_of(h.account_code, p_at) as as_of
  ) ab on h.kind = 'savings_account'
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
             when 'savings_account' then ab.balance
             else lv.value
           end::numeric(14,2) as value,
           case h.kind when 'metal' then public.dubai_date(m.as_of)
                       when 'deposit' then case when lv.value is not null then greatest(lv.as_of, least(d.day, h.maturity_on))
                                                when d.day >= h.acquired_on then least(d.day, h.maturity_on) end
                       when 'structured_note' then case when d.day >= sn.trade_date
                                                        then case when lv.as_of >= sn.trade_date then lv.as_of else d.day end end
                       when 'security' then case when mk.market then sp.price_date else lv.as_of end
                       when 'savings_account' then ab.as_of
                       else lv.as_of end as as_of,
           case h.kind when 'metal' then m.as_of < p_at - private.metal_price_stale_after()
                       when 'deposit' then false
                       when 'structured_note' then lv.as_of >= sn.trade_date and lv.as_of < d.day - 7
                       when 'security' then case when mk.market then sp.price_date < d.day - 7 else lv.as_of < d.day - 45 end
                       when 'savings_account' then ab.as_of < d.day - 45
                       else lv.as_of < d.day - 45 end as stale,
           h.kind = 'deposit' and lv.as_of is distinct from d.day as estimate
  ) v
  where h.profile_code = p_profile_code and h.status = 'active' and h.portfolio = 'wealth'
$$;

-- ── 5. Returns: a savings account's interest stays in it ────────────────────
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
  v_paid numeric;
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
  t_paid numeric := 0;
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
    -- A savings account's interest is credited into it: income it reports, but money that never
    -- left, so it is neither added to growth again nor a cash flow of the yearly return.
    select coalesce(sum(f.amount_aed) filter (where f.kind = 'contribution'), 0),
           coalesce(sum(f.amount_aed) filter (where f.kind = 'withdrawal'), 0),
           coalesce(sum(f.amount_aed) filter (where f.kind = 'income'), 0),
           coalesce(array_agg(f.flow_date order by f.flow_date)
                      filter (where f.kind <> 'income' or h.kind <> 'savings_account'), '{}'),
           coalesce(array_agg(case when f.kind = 'contribution' then -f.amount_aed else f.amount_aed end
                              order by f.flow_date)
                      filter (where f.kind <> 'income' or h.kind <> 'savings_account'), '{}')
    into v_in, v_out, v_income, v_dates, v_amounts
    from public.holding_flows f
    where f.holding_code = h.holding_code and private.flow_is_active(f.removed_at, f.txn_code)
      and f.flow_date >= v_start and f.flow_date <= v_today;
    v_paid := case when h.kind = 'savings_account' then 0 else v_income end;
    -- All time needs to know what went in: a holding with no contribution has an unknown cost,
    -- and its whole value would read as growth.
    v_complete := v0 is not null and v1 is not null
                  and (v_from is null and v_in > 0 or v_from is not null);
    v_growth := case when v_complete then v1 - v0 - (v_in - v_out) + v_paid end;
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
      t_v0 := t_v0 + v0; t_v1 := t_v1 + v1; t_in := t_in + v_in; t_out := t_out + v_out;
      t_income := t_income + v_income; t_paid := t_paid + v_paid;
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
      'growth_aed', (t_v1 - t_v0 - (t_in - t_out) + t_paid)::numeric(14,2)::text,
      'simple_pct', case when t_v0 + t_in > 0
                         then round((t_v1 - t_v0 - (t_in - t_out) + t_paid) / (t_v0 + t_in) * 100, 2)::text end,
      'annual_pct', private.xirr(t_dates, t_amounts)::text,
      'complete', t_complete),
    'holdings', v_rows);
end;
$$;
comment on function public.holding_returns(text, text) is
  'Member: per Wealth holding and in total for all time / this year / the last 12 months / 90 days / 30 days: start and end value, added, income, growth, simple % and the money-weighted yearly return (XIRR). A savings account''s interest is income that stays in it.';

-- ── 6. Net worth and Accounts count it once ─────────────────────────────────
-- An account that backs an active Wealth savings_account holding.
create function private.account_is_invested(p_account_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from public.holdings h
                 where h.account_code = p_account_code and h.kind = 'savings_account'
                   and h.status = 'active' and h.portfolio = 'wealth')
$$;

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
      -- A savings account shown as an investment is counted with the holdings.
      and not private.account_is_invested(a.account_code)
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

-- Accounts lists every bank account; one shown as an investment says so and stays out of the
-- cash total (it is counted under Investments).
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
           'total_aed', coalesce(sum(b.balance_aed) filter (where x.holding_code is null), 0)::numeric(14,2)::text,
           'complete', coalesce(bool_and(b.balance_aed is not null and b.unpriced_count = 0)
                                  filter (where x.holding_code is null), true),
           'stale_count', count(*) filter (where b.is_stale and x.holding_code is null)::int,
           'missing_count', count(*) filter (where b.balance is null and x.holding_code is null)::int,
           'as_of', min(b.as_of) filter (where x.holding_code is null),
           'accounts', coalesce(jsonb_agg(jsonb_build_object(
               'account_code', a.account_code, 'bank_code', a.bank_code, 'kind', a.kind,
               'nickname', a.nickname, 'account_ref', a.account_ref, 'currency', a.currency,
               'balance', b.balance::text, 'balance_aed', b.balance_aed::text,
               'as_of', b.as_of, 'anchor_source', b.anchor_source,
               'is_stale', b.is_stale, 'unpriced_count', b.unpriced_count,
               'investment_holding_code', x.holding_code)
             order by a.bank_code, a.nickname nulls last, a.account_code), '[]'::jsonb))
  into v_out
  from public.accounts a
  join public.v_bank_balances b on b.account_code = a.account_code
  left join lateral (
    select h.holding_code from public.holdings h
    where h.account_code = a.account_code and h.kind = 'savings_account'
      and h.status = 'active' and h.portfolio = 'wealth'
  ) x on true
  where a.profile_code = p_profile_code and a.status = 'active' and not private.is_india_bank(a.bank_code);
  return v_out;
end;
$$;
comment on function public.cash_position(text) is
  'Member: active bank accounts outside India with balance (latest checkpoint + later activity), as_of and staleness, and the AED total. An account shown as an investment (investment_holding_code) is listed but left out of the total.';

-- ── 7. Valuation: a savings account's gain counts its interest once ─────────
create or replace function public.holdings_valuation(p_profile_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := now();
  v_today date := public.dubai_date(now());
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  with n as (select * from private.holding_values(p_profile_code, v_now)),
  y as (select * from private.holding_values(p_profile_code, v_now - interval '24 hours')),
  ft as (select * from private.holding_flow_totals(p_profile_code, v_today)),
  r as (
    select h.*, n.quote, n.aed_per_gram, n.price_as_of, n.value, n.value_aed, n.value_as_of, n.is_stale, n.is_estimate,
           case when n.value_aed is not null and y.value_aed is not null then n.value_aed - y.value_aed end as change_24h,
           ft.contributions - ft.withdrawals as net_added, ft.income, coalesce(ft.flow_count, 0) as flow_count,
           -- A savings account's interest is already in its balance: not added to the gain again.
           case when n.value_aed is not null and ft.holding_code is not null
                then n.value_aed - (ft.contributions - ft.withdrawals)
                     + case when h.kind = 'savings_account' then 0 else ft.income end end as gain
    from public.holdings h
    join n on n.holding_code = h.holding_code
    left join y on y.holding_code = h.holding_code
    left join ft on ft.holding_code = h.holding_code
  ),
  t as (
    select coalesce(sum(r.value_aed), 0)::numeric(14,2) as value,
           sum(r.net_added) filter (where r.value_aed is not null)::numeric(14,2) as cost,
           sum(r.gain)::numeric(14,2) as gain,
           sum(r.net_added) filter (where r.gain is not null) as gain_base,
           sum(r.change_24h)::numeric(14,2) as change_24h,
           coalesce(bool_and(r.value_aed is not null), true) as complete,
           coalesce(bool_and(r.net_added is not null), true) as costs_complete,
           count(*) filter (where r.is_stale)::int as stale_count,
           count(*)::int as holdings_count
    from r
  )
  select jsonb_build_object(
    'value_aed', t.value::text,
    'cost_aed', t.cost::text,
    'gain_aed', t.gain::text,
    'gain_pct', case when t.gain_base > 0 then round(t.gain / t.gain_base * 100, 2)::text end,
    'change_24h_aed', t.change_24h::text,
    'complete', t.complete, 'costs_complete', t.costs_complete,
    'stale_count', t.stale_count, 'holdings_count', t.holdings_count,
    'prices', coalesce((
      select jsonb_object_agg(q.quote, jsonb_build_object(
               'aed_per_gram', now_p.aed_per_gram::text, 'as_of', now_p.as_of,
               'change_24h_pct', case when prev_p.aed_per_gram > 0
                                      then round((now_p.aed_per_gram / prev_p.aed_per_gram - 1) * 100, 2)::text end,
               'is_stale', now_p.as_of < v_now - private.metal_price_stale_after()))
      from (values ('gold_24k'), ('gold_22k'), ('gold_21k'), ('gold_18k'), ('gold_spot'), ('silver_retail'), ('silver_spot')) q(quote)
      join lateral private.metal_price_at(q.quote, v_now) now_p on true
      left join lateral private.metal_price_at(q.quote, v_now - interval '24 hours') prev_p on true), '{}'::jsonb),
    'holdings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'holding_code', r.holding_code, 'name', r.name, 'kind', r.kind, 'currency', r.currency,
               'institution', r.institution, 'metal', r.metal,
               'grams', r.grams::text, 'karat', r.karat, 'fineness', r.fineness, 'purity', r.purity::text,
               'form', r.form, 'image_path', case when r.kind = 'metal' then r.metal || '-' || r.form || '.jpg' end,
               'units', r.units::text, 'symbol', r.symbol, 'principal', r.principal::text,
               'rate_pct', r.rate_pct::text, 'maturity_on', r.maturity_on, 'link_pattern', r.link_pattern,
               'link_exact', r.link_exact, 'account_code', r.account_code,
               'cost_aed', r.net_added::numeric(14,2)::text, 'income_aed', r.income::numeric(14,2)::text,
               'acquired_on', r.acquired_on, 'notes', r.notes,
               'quote', r.quote, 'aed_per_gram', r.aed_per_gram::text, 'price_as_of', r.price_as_of,
               'value', r.value::text, 'value_as_of', r.value_as_of,
               'price_is_stale', coalesce(r.is_stale, false), 'is_estimate', r.is_estimate,
               'value_aed', r.value_aed::text, 'gain_aed', r.gain::text,
               'gain_pct', case when r.net_added > 0 and r.gain is not null
                                then round(r.gain / r.net_added * 100, 2)::text end,
               'change_24h_aed', r.change_24h::text, 'flow_count', r.flow_count)
             order by r.value_aed desc nulls last, r.name)
      from r), '[]'::jsonb))
  into v_out
  from t;
  return v_out;
end;
$$;
comment on function public.holdings_valuation(text) is
  'Member: each active holding''s value (in its currency and AED), what it cost (contributions − withdrawals), income, gain and % (a savings account''s interest counted once), its bank account, 24-hour change, the figure''s date and staleness, with totals and the latest metal prices. Decimal strings.';
grant execute on function public.holdings_valuation(text) to authenticated, service_role;

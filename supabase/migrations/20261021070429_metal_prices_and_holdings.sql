-- Gold and silver in Wealth (tasks/todo.md §6): prices on a cron, holdings, value and gains.
--
-- 1. metal_prices: global reference data like fx_rates, one row per fetch (the history behind
--    the charts). Quotes: gold_24k / gold_22k / gold_21k / gold_18k are the Dubai Jewellery
--    Group's suggested retail rates in AED per gram (dubaicityofgold.com, Khaleej Times as the
--    24K fallback); silver_retail is Dubai's retail silver rate (Khaleej Times, from Al Kananah,
--    printed per kilo); gold_spot and silver_spot are international spot in USD per troy ounce,
--    converted here to AED per gram at the 3.6725 peg, kept for reference.
--    The metal-prices Edge Function writes them every 6 hours (pg_cron ledger-metal-prices)
--    through record_metal_prices, which refuses a price more than 50% away from the last one
--    (a misread page must not halve a holding's value).
-- 2. holdings: a ledger's gold and silver (grams; karat, and fineness for 24K bars, for gold;
--    purity for silver; what was paid, optional). Owner RPCs save_holding / close_holding.
-- 3. private.holding_values(profile, at): each active holding priced at an instant. Gold is
--    grams × its karat's Dubai retail rate; the 24K rate is for 999.9, and a 999.5, 999 or 995
--    bar takes it × private.gold_fineness_factor (a hardcoded approximation, decision of
--    21 Oct). Silver is grams × the Dubai retail rate × purity / 0.999.
--    holdings_valuation(profile): value, cost, gain and %, the change since the price 24 hours
--    earlier, each price's age, totals. holdings_value_series and metal_price_series for charts.
-- 4. Net worth = cash + metals − owed; net_worth_snapshots gains holdings_aed.
-- 5. Each holding has a form (bar, coin, jewellery); holdings_valuation returns image_path,
--    `<metal>-<form>.jpg` in the public `investment-images` bucket (assets/investments/,
--    uploaded with scripts/brand/upload-investment-images.sh, like the bank logos).
-- Money and rates cross the wire as decimal strings (§1.3); every figure is computed here (§2.2).

-- ── 1. metal_prices ──────────────────────────────────────────────────────────
create table public.metal_prices (
  price_code text primary key default public.gen_code('mtp')
    check (price_code ~ '^mtp_[0-9a-z]{26}$'),
  quote text not null
    check (quote in ('gold_24k', 'gold_22k', 'gold_21k', 'gold_18k', 'gold_spot', 'silver_retail', 'silver_spot')),
  aed_per_gram numeric(18,6) not null check (aed_per_gram > 0),
  usd_per_oz numeric(18,6) check (usd_per_oz > 0),
  source text not null check (length(source) between 1 and 80),
  as_of timestamptz not null,
  created_at timestamptz not null default now()
);
create index metal_prices_quote_idx on public.metal_prices(quote, as_of desc);
comment on table public.metal_prices is
  'Gold and silver prices in AED per gram, one row per fetch (metal-prices Edge Function, every 6 hours). Global reference data.';
alter table public.metal_prices enable row level security;
create policy metal_prices_read on public.metal_prices for select to authenticated using (true);
grant select on public.metal_prices to authenticated;
grant all on public.metal_prices to service_role;

-- Service role (the metal-prices function): p_quotes is an array of
--   {quote, aed_per_gram | aed_per_kg | usd_per_oz, source, as_of?}
-- Spot quotes send usd_per_oz; AED per gram = USD/oz × 3.6725 / 31.1034768 (troy ounce).
-- Returns {stored: [quotes], rejected: [{quote, reason}]}.
create function public.record_metal_prices(p_quotes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  q jsonb;
  v_quote text;
  v_usd numeric;
  v_aed numeric;
  v_last numeric;
  v_stored jsonb := '[]'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
begin
  perform private.assert_service_role();
  if jsonb_typeof(p_quotes) <> 'array' then
    raise exception 'p_quotes must be an array' using errcode = '22023';
  end if;
  for q in select * from jsonb_array_elements(p_quotes) loop
    v_quote := q->>'quote';
    if v_quote is null or v_quote not in ('gold_24k', 'gold_22k', 'gold_21k', 'gold_18k', 'gold_spot', 'silver_retail', 'silver_spot') then
      v_rejected := v_rejected || jsonb_build_object('quote', v_quote, 'reason', 'unknown quote');
      continue;
    end if;
    begin
      v_usd := nullif(q->>'usd_per_oz', '')::numeric;
      v_aed := coalesce(nullif(q->>'aed_per_gram', '')::numeric,
                        round(nullif(q->>'aed_per_kg', '')::numeric / 1000, 6),
                        round(v_usd * 3.6725 / 31.1034768, 6));
    exception when others then
      v_rejected := v_rejected || jsonb_build_object('quote', v_quote, 'reason', 'not a number');
      continue;
    end;
    if v_aed is null or v_aed <= 0 then
      v_rejected := v_rejected || jsonb_build_object('quote', v_quote, 'reason', 'no price');
      continue;
    end if;
    select m.aed_per_gram into v_last from public.metal_prices m
    where m.quote = v_quote order by m.as_of desc, m.created_at desc limit 1;
    if v_last is not null and (v_aed > v_last * 1.5 or v_aed < v_last * 0.5) then
      v_rejected := v_rejected || jsonb_build_object('quote', v_quote, 'reason',
                      'more than 50% from the last price (' || v_last || ' → ' || v_aed || ')');
      continue;
    end if;
    insert into public.metal_prices (quote, aed_per_gram, usd_per_oz, source, as_of)
    values (v_quote, v_aed, v_usd, coalesce(nullif(q->>'source', ''), 'unknown'),
            coalesce((q->>'as_of')::timestamptz, now()));
    v_stored := v_stored || to_jsonb(v_quote);
  end loop;
  return jsonb_build_object('stored', v_stored, 'rejected', v_rejected);
end;
$$;
comment on function public.record_metal_prices(jsonb) is
  'Service role (metal-prices): stores gold/silver quotes in AED per gram (spot converted from USD/oz at the peg); refuses a jump over 50%.';
grant execute on function public.record_metal_prices(jsonb) to service_role;

-- The latest price of a quote at an instant.
create function private.metal_price_at(p_quote text, p_at timestamptz)
returns table (aed_per_gram numeric, as_of timestamptz)
language sql
stable
set search_path = ''
as $$
  select m.aed_per_gram, m.as_of from public.metal_prices m
  where m.quote = p_quote and m.as_of <= p_at
  order by m.as_of desc, m.created_at desc
  limit 1
$$;

-- Member (any signed-in user; prices are global): the last price of each Dubai day.
create function public.metal_price_series(p_quote text, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if private.caller_role() not in ('authenticated', 'service_role', 'none') then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from must be on or before p_to' using errcode = '22023';
  end if;
  if p_to - p_from > 400 then
    raise exception 'at most 400 days' using errcode = '22023';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('date', d::date, 'aed_per_gram', p.aed_per_gram::text)
                              order by d), '[]'::jsonb)
    from generate_series(p_from, least(p_to, public.dubai_date(now())), interval '1 day') d
    left join lateral private.metal_price_at(p_quote,
      ((d::date + 1)::timestamp at time zone 'Asia/Dubai') - interval '1 microsecond') p on true
  );
end;
$$;
comment on function public.metal_price_series(text, date, date) is
  'Signed-in: a metal quote''s last AED/gram price per Dubai day (null before the first). Wealth mode.';
grant execute on function public.metal_price_series(text, date, date) to authenticated, service_role;

-- ── 2. holdings ──────────────────────────────────────────────────────────────
create table public.holdings (
  holding_code text primary key default public.gen_code('hld')
    check (holding_code ~ '^hld_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 80),
  metal text not null check (metal in ('gold', 'silver')),
  grams numeric(14,3) not null check (grams > 0),
  karat int check (karat in (24, 22, 21, 18)),
  fineness int check (fineness in (9999, 9995, 9990, 9950)),   -- 24K bars, parts per 10,000
  purity numeric(5,4) check (purity > 0 and purity <= 1),
  form text not null default 'bar' check (form in ('bar', 'coin', 'jewellery')),
  cost_aed numeric(14,2) check (cost_aed >= 0),
  acquired_on date,
  notes text check (length(notes) <= 500),
  status text not null default 'active' check (status in ('active', 'closed')),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint holdings_metal_fields_check check (
    (metal = 'gold' and karat is not null and purity is null and (fineness is null or karat = 24))
    or (metal = 'silver' and karat is null and fineness is null and purity is not null and form <> 'jewellery'))
);
create index holdings_profile_idx on public.holdings(profile_code, status);
comment on table public.holdings is
  'A ledger''s gold (grams, karat, fineness for 24K bars) and silver (grams, purity), with what was paid. Valued by holdings_valuation from metal_prices.';
create trigger holdings_touch before update on public.holdings
  for each row execute function private.touch_updated_at();
alter table public.holdings enable row level security;
create policy holdings_member_read on public.holdings for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.holdings to authenticated;
grant all on public.holdings to service_role;

-- Owner: add (p_holding_code null) or edit a holding. Gold defaults to 24K (999.9 when 24K),
-- silver to 999; the form to a bar (gold below 24K: jewellery). Amounts are decimal strings.
-- Returns the holding_code.
create function public.save_holding(
  p_profile_code text, p_name text, p_metal text, p_grams text,
  p_karat int default null, p_purity text default null, p_cost_aed text default null,
  p_acquired_on date default null, p_notes text default null, p_holding_code text default null,
  p_fineness int default null, p_form text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_grams numeric;
  v_purity numeric;
  v_cost numeric;
  v_form text := coalesce(p_form, case when p_metal = 'gold' and coalesce(p_karat, 24) <> 24 then 'jewellery' else 'bar' end);
begin
  perform private.assert_member(p_profile_code, true);
  if v_form not in ('bar', 'coin', 'jewellery') or (p_metal = 'silver' and v_form = 'jewellery') then
    raise exception 'form must be bar, coin or (gold only) jewellery' using errcode = '22023';
  end if;
  if p_metal is null or p_metal not in ('gold', 'silver') then
    raise exception 'metal must be gold or silver' using errcode = '22023';
  end if;
  begin
    v_grams := btrim(p_grams)::numeric;
    v_purity := nullif(btrim(coalesce(p_purity, '')), '')::numeric;
    v_cost := nullif(btrim(coalesce(p_cost_aed, '')), '')::numeric;
  exception when others then
    raise exception 'grams, purity and cost must be decimal numbers' using errcode = '22023';
  end;
  if v_grams is null or v_grams <= 0 then
    raise exception 'grams must be above 0' using errcode = '22023';
  end if;
  if p_fineness is not null and (p_metal <> 'gold' or coalesce(p_karat, 24) <> 24) then
    raise exception 'fineness is for 24K gold only' using errcode = '22023';
  end if;
  if p_acquired_on > public.dubai_date(now()) then
    raise exception 'acquired_on cannot be in the future' using errcode = '22023';
  end if;
  if p_holding_code is null then
    insert into public.holdings (profile_code, name, metal, grams, karat, fineness, purity, form, cost_aed, acquired_on, notes, created_by)
    values (p_profile_code, btrim(p_name), p_metal, v_grams,
            case when p_metal = 'gold' then coalesce(p_karat, 24) end,
            case when p_metal = 'gold' and coalesce(p_karat, 24) = 24 then coalesce(p_fineness, 9999) end,
            case when p_metal = 'silver' then coalesce(v_purity, 0.999) end,
            v_form, v_cost, p_acquired_on, nullif(btrim(coalesce(p_notes, '')), ''), auth.uid())
    returning holding_code into v_code;
  else
    update public.holdings
    set name = btrim(p_name), metal = p_metal, grams = v_grams,
        karat = case when p_metal = 'gold' then coalesce(p_karat, 24) end,
        fineness = case when p_metal = 'gold' and coalesce(p_karat, 24) = 24 then coalesce(p_fineness, 9999) end,
        purity = case when p_metal = 'silver' then coalesce(v_purity, 0.999) end,
        form = v_form, cost_aed = v_cost, acquired_on = p_acquired_on, notes = nullif(btrim(coalesce(p_notes, '')), '')
    where holding_code = p_holding_code and profile_code = p_profile_code and status = 'active'
    returning holding_code into v_code;
    if v_code is null then
      raise exception 'holding not found' using errcode = 'P0002';
    end if;
  end if;
  return v_code;
end;
$$;
comment on function public.save_holding(text, text, text, text, int, text, text, date, text, text, int, text) is
  'Owner: adds or edits a gold/silver holding (grams; karat and 24K fineness, or silver purity; cost in AED as decimal strings).';
grant execute on function public.save_holding(text, text, text, text, int, text, text, date, text, text, int, text)
  to authenticated, service_role;

-- Owner: a holding that was sold or given away leaves the valuation (kept, never deleted).
create function public.close_holding(p_profile_code text, p_holding_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, true);
  update public.holdings set status = 'closed'
  where holding_code = p_holding_code and profile_code = p_profile_code and status = 'active';
  if not found then
    raise exception 'holding not found' using errcode = 'P0002';
  end if;
end;
$$;
comment on function public.close_holding(text, text) is 'Owner: closes a holding (it stops counting; the row is kept).';
grant execute on function public.close_holding(text, text) to authenticated, service_role;

-- ── 3. Valuation ─────────────────────────────────────────────────────────────
-- The Dubai 24K rate is for 999.9 gold. A lower-fineness bar is valued at that rate times its
-- share of fine gold relative to 999.9 (995 TT bars and 999.5 bars are priced pro rata to
-- fineness against 999.9 in the Dubai bullion market). Hardcoded by decision (21 Oct); change
-- the table here, never in a client.
create function private.gold_fineness_factor(p_fineness int)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case coalesce(p_fineness, 9999)
           when 9999 then 1.0000
           when 9995 then 0.9996
           when 9990 then 0.9991
           when 9950 then 0.9951
         end
$$;

-- Every active holding priced at an instant; value is null with no price yet.
create function private.holding_values(p_profile_code text, p_at timestamptz)
returns table (holding_code text, quote text, aed_per_gram numeric, price_as_of timestamptz,
               fine_factor numeric, value_aed numeric(14,2))
language sql
stable
set search_path = ''
as $$
  select h.holding_code, x.quote, p.aed_per_gram, p.as_of, x.factor,
         round(h.grams * x.factor * p.aed_per_gram, 2)::numeric(14,2)
  from public.holdings h
  cross join lateral (
    select case h.metal when 'gold' then 'gold_' || h.karat || 'k' else 'silver_retail' end as quote,
           case h.metal when 'gold' then case when h.karat = 24 then private.gold_fineness_factor(h.fineness) else 1 end
                        else h.purity / 0.999 end as factor
  ) x
  left join lateral private.metal_price_at(x.quote, p_at) p on true
  where h.profile_code = p_profile_code and h.status = 'active'
$$;

-- Prices older than this are stale: Dubai retail rates are set daily; spot pauses at weekends.
create function private.metal_price_stale_after()
returns interval language sql immutable set search_path = '' as $$ select interval '3 days' $$;

create function public.holdings_valuation(p_profile_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := now();
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  with n as (select * from private.holding_values(p_profile_code, v_now)),
  y as (select * from private.holding_values(p_profile_code, v_now - interval '24 hours')),
  r as (
    select h.*, n.quote, n.aed_per_gram, n.price_as_of, n.value_aed,
           (n.price_as_of < v_now - private.metal_price_stale_after()) as price_is_stale,
           case when n.value_aed is not null and y.value_aed is not null then n.value_aed - y.value_aed end as change_24h,
           case when n.value_aed is not null and h.cost_aed is not null then n.value_aed - h.cost_aed end as gain
    from public.holdings h
    join n on n.holding_code = h.holding_code
    left join y on y.holding_code = h.holding_code
  ),
  t as (
    select coalesce(sum(r.value_aed), 0)::numeric(14,2) as value,
           sum(r.cost_aed) filter (where r.value_aed is not null)::numeric(14,2) as cost,
           sum(r.gain)::numeric(14,2) as gain,
           sum(r.cost_aed) filter (where r.gain is not null) as gain_base,
           sum(r.change_24h)::numeric(14,2) as change_24h,
           coalesce(bool_and(r.value_aed is not null), true) as complete,
           coalesce(bool_and(r.cost_aed is not null), true) as costs_complete,
           count(*) filter (where r.price_is_stale)::int as stale_count,
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
               'holding_code', r.holding_code, 'name', r.name, 'metal', r.metal,
               'grams', r.grams::text, 'karat', r.karat, 'fineness', r.fineness, 'purity', r.purity::text,
               'form', r.form, 'image_path', r.metal || '-' || r.form || '.jpg',
               'cost_aed', r.cost_aed::text, 'acquired_on', r.acquired_on, 'notes', r.notes,
               'quote', r.quote, 'aed_per_gram', r.aed_per_gram::text, 'price_as_of', r.price_as_of,
               'price_is_stale', coalesce(r.price_is_stale, false),
               'value_aed', r.value_aed::text, 'gain_aed', r.gain::text,
               'gain_pct', case when r.cost_aed > 0 and r.gain is not null
                                then round(r.gain / r.cost_aed * 100, 2)::text end,
               'change_24h_aed', r.change_24h::text)
             order by r.value_aed desc nulls last, r.name)
      from r), '[]'::jsonb))
  into v_out
  from t;
  return v_out;
end;
$$;
comment on function public.holdings_valuation(text) is
  'Member: each active gold/silver holding''s value (Dubai retail rates; 24K fineness factor), gain vs cost, 24-hour change and price age, with totals and the latest prices. Decimal strings.';
grant execute on function public.holdings_valuation(text) to authenticated, service_role;

-- Member: per Dubai day, what today's holdings were worth at that day's last prices (each
-- from its acquired_on, if set), and their cost. A day before any price for a holding is null.
create function public.holdings_value_series(p_profile_code text, p_from date, p_to date)
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
  if p_to - p_from > 400 then
    raise exception 'at most 400 days' using errcode = '22023';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'date', s.d, 'value_aed', s.value::text, 'cost_aed', s.cost::text) order by s.d), '[]'::jsonb)
    from (
      select d::date as d,
             case when bool_and(v.value_aed is not null) then sum(v.value_aed)::numeric(14,2) end as value,
             sum(h.cost_aed)::numeric(14,2) as cost
      from generate_series(p_from, least(p_to, public.dubai_date(now())), interval '1 day') d
      join public.holdings h on h.profile_code = p_profile_code and h.status = 'active'
                            and (h.acquired_on is null or h.acquired_on <= d::date)
      join lateral private.holding_values(p_profile_code,
             ((d::date + 1)::timestamp at time zone 'Asia/Dubai') - interval '1 microsecond') v
        on v.holding_code = h.holding_code
      group by d
    ) s
  );
end;
$$;
comment on function public.holdings_value_series(text, date, date) is
  'Member: per Dubai day, the value of today''s active holdings at that day''s last prices (from acquired_on), and their cost. Wealth mode.';
grant execute on function public.holdings_value_series(text, date, date) to authenticated, service_role;

-- ── 4. Net worth with metals ─────────────────────────────────────────────────
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
    where b.profile_code = p_profile_code and a.status = 'active'
  ),
  owed as (
    select coalesce(sum(b.outstanding_aed), 0)::numeric(14,2) as total,
           coalesce(bool_and(b.anchor_kind <> 'none' and b.unpriced_count = 0), true) as complete,
           coalesce(bool_or(b.has_estimate), false) as has_estimate
    from public.v_account_balances b join public.accounts a on a.account_code = b.account_code
    where b.profile_code = p_profile_code and a.status = 'active'
  ),
  metals as (
    select coalesce(sum(v.value_aed), 0)::numeric(14,2) as total,
           coalesce(bool_and(v.value_aed is not null
                             and v.price_as_of >= now() - private.metal_price_stale_after()), true) as complete,
           count(*)::int as n
    from private.holding_values(p_profile_code, now()) v
  )
  select jsonb_build_object(
    'cash_aed', cash.total::text, 'cash_complete', cash.complete, 'cash_missing_count', cash.missing,
    'cash_stale_count', cash.stale, 'cash_as_of', cash.as_of,
    'holdings_aed', metals.total::text, 'holdings_complete', metals.complete, 'holdings_count', metals.n,
    'owed_aed', owed.total::text, 'owed_complete', owed.complete, 'owed_has_estimate', owed.has_estimate,
    'net_aed', (cash.total + metals.total - owed.total)::numeric(14,2)::text,
    'complete', cash.complete and owed.complete and metals.complete,
    'has_bank_accounts', exists (select 1 from public.accounts a where a.profile_code = p_profile_code
                                 and a.kind in ('current', 'savings') and a.status = 'active'))
  from cash, owed, metals
$$;

alter table public.net_worth_snapshots add column holdings_aed numeric(14,2) not null default 0;

create or replace function private.snapshot_net_worth(p_profile_code text)
returns void
language sql
set search_path = ''
as $$
  insert into public.net_worth_snapshots (profile_code, snap_date, cash_aed, holdings_aed, owed_aed, net_aed, complete)
  select p_profile_code, public.dubai_date(now()), (n->>'cash_aed')::numeric, (n->>'holdings_aed')::numeric,
         (n->>'owed_aed')::numeric, (n->>'net_aed')::numeric, (n->>'complete')::boolean
  from (select private.net_worth(p_profile_code) n) x
  on conflict (profile_code, snap_date) do update
    set cash_aed = excluded.cash_aed, holdings_aed = excluded.holdings_aed, owed_aed = excluded.owed_aed,
        net_aed = excluded.net_aed, complete = excluded.complete
$$;

create or replace function public.net_worth_series(p_profile_code text, p_months int default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date := date_trunc('month', public.dubai_date(now()))::date;
  v_live jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_months is null or p_months < 1 or p_months > 120 then
    raise exception 'p_months must be 1 to 120' using errcode = '22023';
  end if;
  v_live := private.net_worth(p_profile_code);
  return coalesce((
    select jsonb_agg(x.j order by x.m)
    from (
      select distinct on (date_trunc('month', s.snap_date))
             date_trunc('month', s.snap_date)::date as m,
             jsonb_build_object('month', date_trunc('month', s.snap_date)::date, 'as_of', s.snap_date,
                                'cash_aed', s.cash_aed::text, 'holdings_aed', s.holdings_aed::text,
                                'owed_aed', s.owed_aed::text,
                                'net_aed', s.net_aed::text, 'complete', s.complete, 'is_live', false) as j
      from public.net_worth_snapshots s
      where s.profile_code = p_profile_code and s.snap_date < v_month
        and s.snap_date >= (v_month - make_interval(months => p_months - 1))::date
      order by date_trunc('month', s.snap_date), s.snap_date desc
    ) x), '[]'::jsonb)
    || jsonb_build_array(jsonb_build_object('month', v_month, 'as_of', public.dubai_date(now()),
                         'cash_aed', v_live->>'cash_aed', 'holdings_aed', v_live->>'holdings_aed',
                         'owed_aed', v_live->>'owed_aed',
                         'net_aed', v_live->>'net_aed', 'complete', (v_live->>'complete')::boolean,
                         'is_live', true));
end;
$$;

-- ── 5. Images ────────────────────────────────────────────────────────────────
-- Public read (the public object endpoint, no RLS); no client policy writes it, so only the
-- service role (the upload script) does. Clients build
--   <SUPABASE_URL>/storage/v1/object/public/investment-images/<image_path>
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('investment-images', 'investment-images', true, 1048576, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- ── 6. Schedule ──────────────────────────────────────────────────────────────
select cron.schedule('ledger-metal-prices', '7 */6 * * *', $$select private.invoke_edge('metal-prices')$$);

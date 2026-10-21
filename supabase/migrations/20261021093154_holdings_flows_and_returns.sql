-- Investments beyond metals: holding types, valuations, flows, returns, links and allocation
-- (tasks/todo.md §7, decisions of 21 Oct).
--
-- 1. holdings.kind: metal (priced by metal-prices), plan (an RL360-style savings / insurance
--    plan), broker (a broker account valued as a whole), security (a share or fund: units × a
--    price you enter), deposit (principal, profit rate, maturity; value accrues). Each holding
--    has a currency (USD → AED at the 3.6725 peg, others at fx_rates), an institution, and an
--    optional link_pattern: a payment whose description contains it is linked automatically.
-- 2. holding_valuations: evidence, never edited. A value (plan, broker) or a unit price
--    (security) as of a date; the latest on or before a day is the holding's value that day.
-- 3. holding_flows: contribution | withdrawal | income, dated, in the holding's currency and in
--    AED, optionally the ledger transaction that paid it (one flow per transaction). A removed
--    flow keeps its row (removed_at), so the rule never re-links a payment the user unlinked.
--    A metal's cost and purchase date are its first contribution (source holding_cost), kept in
--    sync by save_holding. What a holding cost = contributions − withdrawals.
-- 4. Linking: an AFTER trigger on transactions links new payments by rule and keeps a linked
--    flow's amounts current; link_transaction links or unlinks by hand. A linked payment is
--    saving (decision 1): v_spend leaves it out, v_cash_flow files it as `saving` with its
--    holding (a linked credit is a withdrawal: negative saving). cash_flow_savings breaks the
--    month's saving down by holding. v_transactions and account_ledger name the holding.
-- 5. Values at any instant for every kind (private.holding_values); holdings_valuation,
--    holding_detail, holdings_value_series (with cost to date from the flows) and
--    holding_returns: per holding and in total, for all time / this year / the last 12 months:
--    start value, added (contributions − withdrawals), income, growth, a simple % and a
--    money-weighted yearly return (XIRR, from 90 days of history).
-- 6. net_worth gains `allocation` by class (cash, gold, silver, plan, broker, security,
--    deposit; owed as a negative row).
-- Money crosses the wire as decimal strings (§1.3); every figure is computed here (§2.2).

-- ── 1. holdings: kinds ───────────────────────────────────────────────────────
alter table public.holdings add constraint holdings_profile_holding_uq unique (profile_code, holding_code);
alter table public.holdings add column kind text not null default 'metal'
  check (kind in ('metal', 'plan', 'broker', 'security', 'deposit'));
alter table public.holdings add column currency text not null default 'AED' check (currency ~ '^[A-Z]{3}$');
alter table public.holdings add column institution text check (length(institution) <= 80);
alter table public.holdings add column units numeric(18,6) check (units > 0);
alter table public.holdings add column symbol text check (length(symbol) <= 20);
alter table public.holdings add column principal numeric(14,2) check (principal > 0);
alter table public.holdings add column rate_pct numeric(6,3) check (rate_pct >= 0 and rate_pct <= 100);
alter table public.holdings add column maturity_on date;
alter table public.holdings add column link_pattern text check (length(btrim(link_pattern)) between 3 and 60);
alter table public.holdings alter column metal drop not null;
alter table public.holdings alter column grams drop not null;
alter table public.holdings alter column form drop not null;
alter table public.holdings alter column form drop default;
alter table public.holdings drop constraint holdings_metal_fields_check;
alter table public.holdings add constraint holdings_kind_fields_check check (
  case kind
    when 'metal' then
      metal is not null and grams is not null and form is not null and currency = 'AED'
      and units is null and principal is null and rate_pct is null and maturity_on is null
      and ((metal = 'gold' and karat is not null and purity is null and (fineness is null or karat = 24))
           or (metal = 'silver' and karat is null and fineness is null and purity is not null and form <> 'jewellery'))
    else
      metal is null and grams is null and karat is null and fineness is null and purity is null and form is null
      and cost_aed is null
      and (kind <> 'security' or units is not null)
      and (kind = 'security' or units is null)
      and (kind <> 'deposit' or (principal is not null and rate_pct is not null and acquired_on is not null
                                 and maturity_on is not null and maturity_on > acquired_on))
      and (kind = 'deposit' or (principal is null and rate_pct is null and maturity_on is null))
  end);
comment on table public.holdings is
  'A ledger''s investments: metals (priced by metal_prices), plans, broker accounts, securities (units) and deposits (principal, rate, maturity). Valued by private.holding_values.';

-- An amount in a currency, in AED: the peg for USD, else the day's market rate (fx_rates).
create function private.to_aed(p_amount numeric, p_currency text)
returns numeric
language sql
stable
set search_path = ''
as $$
  select round(p_amount * case p_currency when 'AED' then 1 when 'USD' then 3.6725
                                 else (select r.aed_per_unit from public.fx_rates r where r.currency = p_currency) end, 2)
$$;

-- ── 2. holding_valuations ────────────────────────────────────────────────────
create table public.holding_valuations (
  valuation_code text primary key default public.gen_code('hvl')
    check (valuation_code ~ '^hvl_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  holding_code text not null,
  as_of date not null,
  value numeric(14,2) check (value >= 0),              -- in the holding's currency
  unit_price numeric(18,6) check (unit_price >= 0),     -- securities
  source text not null default 'manual' check (source in ('manual', 'import')),
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint holding_valuations_holding_fkey foreign key (profile_code, holding_code)
    references public.holdings(profile_code, holding_code) on delete cascade,
  constraint holding_valuations_one_figure_check check ((value is null) <> (unit_price is null))
);
create index holding_valuations_holding_idx on public.holding_valuations(holding_code, as_of desc, created_at desc);
create index holding_valuations_profile_idx on public.holding_valuations(profile_code);
comment on table public.holding_valuations is
  'A holding''s value (plan, broker) or unit price (security) as of a date. Evidence: never updated; the latest on or before a day wins.';
alter table public.holding_valuations enable row level security;
create policy holding_valuations_member_read on public.holding_valuations for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.holding_valuations to authenticated;
grant all on public.holding_valuations to service_role;

-- ── 3. holding_flows ─────────────────────────────────────────────────────────
create table public.holding_flows (
  flow_code text primary key default public.gen_code('hfl')
    check (flow_code ~ '^hfl_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  holding_code text not null,
  flow_date date not null,
  kind text not null check (kind in ('contribution', 'withdrawal', 'income')),
  amount numeric(14,2) not null check (amount > 0),        -- in the holding's currency
  amount_aed numeric(14,2) not null check (amount_aed > 0),
  txn_code text references public.transactions(txn_code) on delete set null,
  source text not null check (source in ('manual', 'rule', 'link', 'holding_cost')),
  notes text check (length(notes) <= 200),
  removed_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint holding_flows_holding_fkey foreign key (profile_code, holding_code)
    references public.holdings(profile_code, holding_code) on delete cascade
);
create unique index holding_flows_txn_uq on public.holding_flows(txn_code) where txn_code is not null;
create unique index holding_flows_cost_uq on public.holding_flows(holding_code) where source = 'holding_cost';
create index holding_flows_holding_idx on public.holding_flows(holding_code, flow_date);
create index holding_flows_profile_idx on public.holding_flows(profile_code);
comment on table public.holding_flows is
  'Money into (contribution) and out of (withdrawal, income) a holding, optionally the transaction that paid it. removed_at keeps an unlinked payment from being re-linked.';
create trigger holding_flows_touch before update on public.holding_flows
  for each row execute function private.touch_updated_at();
alter table public.holding_flows enable row level security;
create policy holding_flows_member_read on public.holding_flows for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.holding_flows to authenticated;
grant all on public.holding_flows to service_role;

-- A flow counts while it is not removed and its transaction (if any) is live.
create function private.flow_is_active(p_removed_at timestamptz, p_txn_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_removed_at is null
     and (p_txn_code is null or exists (select 1 from public.transactions t
                                        where t.txn_code = p_txn_code and t.status in ('pending', 'posted')))
$$;

-- A metal's cost and purchase date as its first contribution.
create function private.sync_holding_cost_flow(p_holding_code text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  h public.holdings;
begin
  select * into h from public.holdings where holding_code = p_holding_code;
  if h.kind = 'metal' and h.cost_aed is not null and h.cost_aed > 0 then
    insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source, created_by)
    values (h.profile_code, h.holding_code, coalesce(h.acquired_on, public.dubai_date(h.created_at)), 'contribution',
            h.cost_aed, h.cost_aed, 'holding_cost', h.created_by)
    on conflict (holding_code) where source = 'holding_cost' do update
      set flow_date = excluded.flow_date, amount = excluded.amount, amount_aed = excluded.amount_aed, removed_at = null;
  else
    update public.holding_flows set removed_at = coalesce(removed_at, now())
    where holding_code = p_holding_code and source = 'holding_cost';
  end if;
end;
$$;

-- Existing metals: their cost becomes the first contribution.
select private.sync_holding_cost_flow(holding_code) from public.holdings where cost_aed is not null;

-- ── 4. Linking ───────────────────────────────────────────────────────────────
-- The flow a transaction makes for a holding: a debit adds money, a credit takes it out;
-- the amount in the holding's currency when the transaction was in it, else from AED.
create function private.flow_from_txn(t public.transactions, h public.holdings)
returns table (kind text, amount numeric, amount_aed numeric)
language sql
stable
set search_path = ''
as $$
  select case when t.direction = 'debit' then 'contribution' else 'withdrawal' end,
         case when t.currency_original = h.currency then t.amount_original
              else round(t.amount_aed / nullif(private.to_aed(1, h.currency), 0), 2) end,
         t.amount_aed
$$;

-- The holding whose rule matches a transaction (purchases, fees and bank transfers).
create function private.rule_holding_for(t public.transactions)
returns text
language sql
stable
set search_path = ''
as $$
  select h.holding_code from public.holdings h
  where h.profile_code = t.profile_code and h.status = 'active' and h.link_pattern is not null
    and t.kind in ('purchase', 'fee', 'transfer_out', 'transfer_in', 'refund')
    and t.description ilike '%' || replace(replace(replace(btrim(h.link_pattern), '\', '\\'), '%', '\%'), '_', '\_') || '%'
    and (h.acquired_on is null or t.txn_date >= h.acquired_on - 7)
  order by h.created_at, h.holding_code
  limit 1
$$;

create function private.sync_txn_holding_flow(p_txn_code text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  t public.transactions;
  h public.holdings;
  f public.holding_flows;
  v_holding text;
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
    if f.removed_at is null and f.source in ('rule', 'link') then
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

create function private.transactions_holding_link()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform private.sync_txn_holding_flow(new.txn_code);
  return null;
end;
$$;
create trigger transactions_holding_link
  after insert or update of status, amount_aed, amount_original, description, txn_date
  on public.transactions
  for each row execute function private.transactions_holding_link();

-- Run a holding's rule over the ledger's existing transactions.
create function private.apply_holding_rule(p_holding_code text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  h public.holdings;
  r record;
  n int := 0;
begin
  select * into h from public.holdings where holding_code = p_holding_code;
  if h.link_pattern is null or h.status <> 'active' then
    return 0;
  end if;
  for r in
    select t.txn_code from public.transactions t
    where t.profile_code = h.profile_code and t.status in ('pending', 'posted')
      and not exists (select 1 from public.holding_flows f where f.txn_code = t.txn_code)
      and private.rule_holding_for(t) = h.holding_code
  loop
    perform private.sync_txn_holding_flow(r.txn_code);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Owner: link a transaction to a holding (p_holding_code null unlinks it, for good: the rule
-- will not link it again). p_kind defaults from the direction.
create function public.link_transaction(p_profile_code text, p_txn_code text, p_holding_code text,
                                        p_kind text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.transactions;
  h public.holdings;
  x record;
  v_code text;
begin
  perform private.assert_member(p_profile_code, true);
  select * into t from public.transactions where txn_code = p_txn_code and profile_code = p_profile_code;
  if not found then
    raise exception 'transaction not found' using errcode = 'P0002';
  end if;
  if p_holding_code is null then
    update public.holding_flows set removed_at = now()
    where txn_code = p_txn_code and removed_at is null
    returning flow_code into v_code;
    if v_code is null then
      -- Not linked yet: record the refusal so the rule leaves it alone.
      select * into h from public.holdings where profile_code = p_profile_code and holding_code = private.rule_holding_for(t);
      if found and t.amount_aed is not null and t.amount_aed > 0 then
        select * into x from private.flow_from_txn(t, h);
        insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code,
                                          source, removed_at, created_by)
        values (p_profile_code, h.holding_code, t.txn_date, x.kind, coalesce(x.amount, t.amount_aed), t.amount_aed,
                t.txn_code, 'link', now(), auth.uid())
        on conflict (txn_code) where txn_code is not null do nothing;
      end if;
    end if;
    return null;
  end if;
  if p_kind is not null and p_kind not in ('contribution', 'withdrawal', 'income') then
    raise exception 'kind must be contribution, withdrawal or income' using errcode = '22023';
  end if;
  select * into h from public.holdings
  where holding_code = p_holding_code and profile_code = p_profile_code and status = 'active';
  if not found then
    raise exception 'holding not found' using errcode = 'P0002';
  end if;
  if t.amount_aed is null or t.amount_aed <= 0 then
    raise exception 'the transaction has no AED amount yet' using errcode = '22023';
  end if;
  select * into x from private.flow_from_txn(t, h);
  insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code, source, created_by)
  values (p_profile_code, h.holding_code, t.txn_date, coalesce(p_kind, x.kind), coalesce(x.amount, t.amount_aed),
          t.amount_aed, t.txn_code, 'link', auth.uid())
  on conflict (txn_code) where txn_code is not null do update
    set holding_code = excluded.holding_code, kind = excluded.kind, amount = excluded.amount,
        amount_aed = excluded.amount_aed, flow_date = excluded.flow_date, source = 'link', removed_at = null
  returning flow_code into v_code;
  return v_code;
end;
$$;
comment on function public.link_transaction(text, text, text, text) is
  'Owner: links a transaction to a holding as a contribution (debit) or withdrawal (credit), or unlinks it (null) for good. A linked payment is saving, not spend.';
grant execute on function public.link_transaction(text, text, text, text) to authenticated, service_role;

-- Owner: a flow not paid through the ledger (a dividend, a deposit made elsewhere).
create function public.add_holding_flow(p_profile_code text, p_holding_code text, p_kind text, p_flow_date date,
                                        p_amount text, p_amount_aed text default null, p_notes text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  h public.holdings;
  v_amount numeric;
  v_aed numeric;
  v_code text;
begin
  perform private.assert_member(p_profile_code, true);
  select * into h from public.holdings
  where holding_code = p_holding_code and profile_code = p_profile_code and status = 'active';
  if not found then
    raise exception 'holding not found' using errcode = 'P0002';
  end if;
  if p_kind is null or p_kind not in ('contribution', 'withdrawal', 'income') then
    raise exception 'kind must be contribution, withdrawal or income' using errcode = '22023';
  end if;
  if p_flow_date is null or p_flow_date > public.dubai_date(now()) then
    raise exception 'flow_date must be today or earlier' using errcode = '22023';
  end if;
  begin
    v_amount := btrim(p_amount)::numeric;
    v_aed := nullif(btrim(coalesce(p_amount_aed, '')), '')::numeric;
  exception when others then
    raise exception 'amounts must be decimal numbers' using errcode = '22023';
  end;
  v_aed := coalesce(v_aed, private.to_aed(v_amount, h.currency));
  if v_amount is null or v_amount <= 0 or v_aed is null or v_aed <= 0 then
    raise exception 'amount must be above 0 (and convertible to AED)' using errcode = '22023';
  end if;
  insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source, notes, created_by)
  values (p_profile_code, p_holding_code, p_flow_date, p_kind, v_amount, v_aed, 'manual',
          nullif(btrim(coalesce(p_notes, '')), ''), auth.uid())
  returning flow_code into v_code;
  return v_code;
end;
$$;
comment on function public.add_holding_flow(text, text, text, date, text, text, text) is
  'Owner: records a contribution, withdrawal or income for a holding (amounts as decimal strings; AED defaults from the currency).';
grant execute on function public.add_holding_flow(text, text, text, date, text, text, text) to authenticated, service_role;

-- Owner: removes a manual or linked flow (a metal's cost is edited on the holding).
create function public.remove_holding_flow(p_profile_code text, p_flow_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, true);
  update public.holding_flows set removed_at = now()
  where flow_code = p_flow_code and profile_code = p_profile_code and removed_at is null and source <> 'holding_cost';
  if not found then
    raise exception 'flow not found (a metal''s cost is edited on the holding)' using errcode = 'P0002';
  end if;
end;
$$;
grant execute on function public.remove_holding_flow(text, text) to authenticated, service_role;

-- Owner: a plan's or broker account's value, or a security's unit price, as of a date.
create function public.record_holding_value(p_profile_code text, p_holding_code text, p_value text default null,
                                            p_unit_price text default null, p_as_of date default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  h public.holdings;
  v_value numeric;
  v_price numeric;
  v_code text;
begin
  perform private.assert_member(p_profile_code, true);
  select * into h from public.holdings
  where holding_code = p_holding_code and profile_code = p_profile_code and status = 'active';
  if not found then
    raise exception 'holding not found' using errcode = 'P0002';
  end if;
  begin
    v_value := nullif(btrim(coalesce(p_value, '')), '')::numeric;
    v_price := nullif(btrim(coalesce(p_unit_price, '')), '')::numeric;
  exception when others then
    raise exception 'value and unit price must be decimal numbers' using errcode = '22023';
  end;
  if h.kind in ('plan', 'broker') and (v_value is null or v_price is not null) then
    raise exception 'a plan or broker account takes a value' using errcode = '22023';
  elsif h.kind = 'security' and (v_price is null or v_value is not null) then
    raise exception 'a share or fund takes a unit price' using errcode = '22023';
  elsif h.kind in ('metal', 'deposit') then
    raise exception 'metals are priced by the feed and deposits accrue: no value to record' using errcode = '22023';
  end if;
  if coalesce(v_value, v_price) < 0 then
    raise exception 'value must not be negative' using errcode = '22023';
  end if;
  if p_as_of > public.dubai_date(now()) then
    raise exception 'as_of cannot be in the future' using errcode = '22023';
  end if;
  insert into public.holding_valuations (profile_code, holding_code, as_of, value, unit_price, created_by)
  values (p_profile_code, p_holding_code, coalesce(p_as_of, public.dubai_date(now())), v_value, v_price, auth.uid())
  returning valuation_code into v_code;
  return v_code;
end;
$$;
comment on function public.record_holding_value(text, text, text, text, date) is
  'Owner: a plan''s or broker account''s value, or a share''s / fund''s unit price, as of a date (default today). Decimal strings.';
grant execute on function public.record_holding_value(text, text, text, text, date) to authenticated, service_role;

-- save_holding: every kind. Old calls (named metal arguments) keep working: kind defaults to
-- metal. Returns the holding_code.
drop function public.save_holding(text, text, text, text, int, text, text, date, text, text, int, text);
create function public.save_holding(
  p_profile_code text, p_name text, p_metal text default null, p_grams text default null,
  p_karat int default null, p_purity text default null, p_cost_aed text default null,
  p_acquired_on date default null, p_notes text default null, p_holding_code text default null,
  p_fineness int default null, p_form text default null,
  p_kind text default null, p_currency text default null, p_institution text default null,
  p_units text default null, p_symbol text default null, p_principal text default null,
  p_rate_pct text default null, p_maturity_on date default null, p_link_pattern text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text := coalesce(p_kind, 'metal');
  v_code text;
  v_grams numeric;
  v_purity numeric;
  v_cost numeric;
  v_units numeric;
  v_principal numeric;
  v_rate numeric;
  v_form text;
  v_currency text := upper(coalesce(nullif(btrim(coalesce(p_currency, '')), ''), 'AED'));
  v_link text := nullif(btrim(coalesce(p_link_pattern, '')), '');
begin
  perform private.assert_member(p_profile_code, true);
  if v_kind not in ('metal', 'plan', 'broker', 'security', 'deposit') then
    raise exception 'kind must be metal, plan, broker, security or deposit' using errcode = '22023';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'name is required' using errcode = '22023';
  end if;
  begin
    v_grams := nullif(btrim(coalesce(p_grams, '')), '')::numeric;
    v_purity := nullif(btrim(coalesce(p_purity, '')), '')::numeric;
    v_cost := nullif(btrim(coalesce(p_cost_aed, '')), '')::numeric;
    v_units := nullif(btrim(coalesce(p_units, '')), '')::numeric;
    v_principal := nullif(btrim(coalesce(p_principal, '')), '')::numeric;
    v_rate := nullif(btrim(coalesce(p_rate_pct, '')), '')::numeric;
  exception when others then
    raise exception 'grams, purity, cost, units, principal and rate must be decimal numbers' using errcode = '22023';
  end;
  if p_acquired_on > public.dubai_date(now()) then
    raise exception 'acquired_on cannot be in the future' using errcode = '22023';
  end if;
  if v_currency !~ '^[A-Z]{3}$' or (v_currency not in ('AED', 'USD')
                                    and not exists (select 1 from public.fx_rates r where r.currency = v_currency)) then
    raise exception 'unknown currency %', v_currency using errcode = '22023';
  end if;
  if v_kind = 'metal' then
    v_form := coalesce(p_form, case when p_metal = 'gold' and coalesce(p_karat, 24) <> 24 then 'jewellery' else 'bar' end);
    if p_metal is null or p_metal not in ('gold', 'silver') then
      raise exception 'metal must be gold or silver' using errcode = '22023';
    end if;
    if v_form not in ('bar', 'coin', 'jewellery') or (p_metal = 'silver' and v_form = 'jewellery') then
      raise exception 'form must be bar, coin or (gold only) jewellery' using errcode = '22023';
    end if;
    if v_grams is null or v_grams <= 0 then
      raise exception 'grams must be above 0' using errcode = '22023';
    end if;
    if p_fineness is not null and (p_metal <> 'gold' or coalesce(p_karat, 24) <> 24) then
      raise exception 'fineness is for 24K gold only' using errcode = '22023';
    end if;
    v_currency := 'AED';
  else
    if v_kind = 'security' and (v_units is null or v_units <= 0) then
      raise exception 'a share or fund needs its units' using errcode = '22023';
    end if;
    if v_kind = 'deposit' and (v_principal is null or v_principal <= 0 or v_rate is null or p_acquired_on is null
                               or p_maturity_on is null or p_maturity_on <= p_acquired_on) then
      raise exception 'a deposit needs principal, rate, start date and a later maturity date' using errcode = '22023';
    end if;
  end if;

  if p_holding_code is null then
    insert into public.holdings (profile_code, name, kind, metal, grams, karat, fineness, purity, form, cost_aed,
                                 currency, institution, units, symbol, principal, rate_pct, maturity_on, link_pattern,
                                 acquired_on, notes, created_by)
    values (p_profile_code, btrim(p_name), v_kind,
            case when v_kind = 'metal' then p_metal end,
            case when v_kind = 'metal' then v_grams end,
            case when v_kind = 'metal' and p_metal = 'gold' then coalesce(p_karat, 24) end,
            case when v_kind = 'metal' and p_metal = 'gold' and coalesce(p_karat, 24) = 24 then coalesce(p_fineness, 9999) end,
            case when v_kind = 'metal' and p_metal = 'silver' then coalesce(v_purity, 0.999) end,
            v_form,
            case when v_kind = 'metal' then v_cost end,
            v_currency, nullif(btrim(coalesce(p_institution, '')), ''),
            case when v_kind = 'security' then v_units end,
            case when v_kind = 'security' then nullif(upper(btrim(coalesce(p_symbol, ''))), '') end,
            case when v_kind = 'deposit' then v_principal end,
            case when v_kind = 'deposit' then v_rate end,
            case when v_kind = 'deposit' then p_maturity_on end,
            v_link, p_acquired_on, nullif(btrim(coalesce(p_notes, '')), ''), auth.uid())
    returning holding_code into v_code;
  else
    update public.holdings
    set name = btrim(p_name), kind = v_kind,
        metal = case when v_kind = 'metal' then p_metal end,
        grams = case when v_kind = 'metal' then v_grams end,
        karat = case when v_kind = 'metal' and p_metal = 'gold' then coalesce(p_karat, 24) end,
        fineness = case when v_kind = 'metal' and p_metal = 'gold' and coalesce(p_karat, 24) = 24 then coalesce(p_fineness, 9999) end,
        purity = case when v_kind = 'metal' and p_metal = 'silver' then coalesce(v_purity, 0.999) end,
        form = v_form,
        cost_aed = case when v_kind = 'metal' then v_cost end,
        currency = v_currency, institution = nullif(btrim(coalesce(p_institution, '')), ''),
        units = case when v_kind = 'security' then v_units end,
        symbol = case when v_kind = 'security' then nullif(upper(btrim(coalesce(p_symbol, ''))), '') end,
        principal = case when v_kind = 'deposit' then v_principal end,
        rate_pct = case when v_kind = 'deposit' then v_rate end,
        maturity_on = case when v_kind = 'deposit' then p_maturity_on end,
        link_pattern = v_link, acquired_on = p_acquired_on, notes = nullif(btrim(coalesce(p_notes, '')), '')
    where holding_code = p_holding_code and profile_code = p_profile_code and status = 'active'
    returning holding_code into v_code;
    if v_code is null then
      raise exception 'holding not found' using errcode = 'P0002';
    end if;
  end if;
  perform private.sync_holding_cost_flow(v_code);
  perform private.apply_holding_rule(v_code);
  return v_code;
end;
$$;
comment on function public.save_holding(text, text, text, text, int, text, text, date, text, text, int, text,
                                        text, text, text, text, text, text, text, date, text) is
  'Owner: adds or edits a holding of any kind (decimal strings). A metal''s cost is its first contribution; a link_pattern links matching payments.';
grant execute on function public.save_holding(text, text, text, text, int, text, text, date, text, text, int, text,
                                              text, text, text, text, text, text, text, date, text)
  to authenticated, service_role;

-- ── 5. Values ────────────────────────────────────────────────────────────────
-- Every active holding at an instant: value in its currency and in AED (null when unknown),
-- the date the figure is as of, and whether it is stale or an estimate.
drop function private.holding_values(text, timestamptz);
create function private.holding_values(p_profile_code text, p_at timestamptz)
returns table (holding_code text, quote text, aed_per_gram numeric, price_as_of timestamptz, fine_factor numeric,
               value numeric(14,2), value_aed numeric(14,2), value_as_of date, is_stale boolean, is_estimate boolean)
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
  ) lv on h.kind in ('plan', 'broker', 'security')
  cross join lateral (
    select case h.kind
             when 'metal' then round(h.grams * m.factor * m.aed_per_gram, 2)
             when 'security' then round(h.units * lv.unit_price, 2)
             when 'deposit' then case when d.day >= h.acquired_on then
               round(h.principal * (1 + h.rate_pct / 100 * (least(d.day, h.maturity_on) - h.acquired_on) / 365.0), 2) end
             else lv.value
           end::numeric(14,2) as value,
           case h.kind when 'metal' then public.dubai_date(m.as_of)
                       when 'deposit' then case when d.day >= h.acquired_on then least(d.day, h.maturity_on) end
                       else lv.as_of end as as_of,
           case h.kind when 'metal' then m.as_of < p_at - private.metal_price_stale_after()
                       when 'deposit' then false
                       else lv.as_of < d.day - 45 end as stale,
           h.kind = 'deposit' as estimate
  ) v
  where h.profile_code = p_profile_code and h.status = 'active'
$$;

-- Each holding's money in and out up to a day (active flows): added = contributions −
-- withdrawals; income kept apart.
create function private.holding_flow_totals(p_profile_code text, p_to date)
returns table (holding_code text, contributions numeric, withdrawals numeric, income numeric, first_flow date, flow_count int)
language sql
stable
set search_path = ''
as $$
  select f.holding_code,
         coalesce(sum(f.amount_aed) filter (where f.kind = 'contribution'), 0),
         coalesce(sum(f.amount_aed) filter (where f.kind = 'withdrawal'), 0),
         coalesce(sum(f.amount_aed) filter (where f.kind = 'income'), 0),
         min(f.flow_date), count(*)::int
  from public.holding_flows f
  where f.profile_code = p_profile_code and f.flow_date <= p_to and private.flow_is_active(f.removed_at, f.txn_code)
  group by f.holding_code
$$;

drop function public.holdings_valuation(text);
create function public.holdings_valuation(p_profile_code text)
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
           case when n.value_aed is not null and ft.holding_code is not null
                then n.value_aed - (ft.contributions - ft.withdrawals) + ft.income end as gain
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
  'Member: each active holding''s value (in its currency and AED), what it cost (contributions − withdrawals), income, gain and %, 24-hour change, the figure''s date and staleness, with totals and the latest metal prices. Decimal strings.';
grant execute on function public.holdings_valuation(text) to authenticated, service_role;

-- Member: one holding's flows (with the transaction that paid each) and value history.
create function public.holding_detail(p_profile_code text, p_holding_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, false);
  if not exists (select 1 from public.holdings where holding_code = p_holding_code and profile_code = p_profile_code) then
    raise exception 'holding not found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'flows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'flow_code', f.flow_code, 'flow_date', f.flow_date, 'kind', f.kind, 'amount', f.amount::text,
               'amount_aed', f.amount_aed::text, 'source', f.source, 'notes', f.notes, 'txn_code', f.txn_code,
               'txn_description', t.description, 'txn_bank_code', a.bank_code, 'txn_account_kind', a.kind)
             order by f.flow_date desc, f.created_at desc)
      from public.holding_flows f
      left join public.transactions t on t.txn_code = f.txn_code
      left join public.accounts a on a.account_code = t.account_code
      where f.holding_code = p_holding_code and private.flow_is_active(f.removed_at, f.txn_code)), '[]'::jsonb),
    'valuations', coalesce((
      select jsonb_agg(jsonb_build_object('valuation_code', v.valuation_code, 'as_of', v.as_of,
                                          'value', v.value::text, 'unit_price', v.unit_price::text, 'source', v.source)
             order by v.as_of desc, v.created_at desc)
      from public.holding_valuations v where v.holding_code = p_holding_code), '[]'::jsonb));
end;
$$;
comment on function public.holding_detail(text, text) is
  'Member: a holding''s active flows (with the paying transaction) and its recorded values, newest first.';
grant execute on function public.holding_detail(text, text) to authenticated, service_role;

drop function public.holdings_value_series(text, date, date);
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
             sum(ft.contributions - ft.withdrawals)::numeric(14,2) as cost
      from generate_series(p_from, least(p_to, public.dubai_date(now())), interval '1 day') d
      join lateral private.holding_values(p_profile_code,
             ((d::date + 1)::timestamp at time zone 'Asia/Dubai') - interval '1 microsecond') v on true
      join public.holdings h on h.holding_code = v.holding_code
      left join lateral private.holding_flow_totals(p_profile_code, d::date) ft on ft.holding_code = h.holding_code
      where coalesce(h.acquired_on, ft.first_flow, public.dubai_date(h.created_at)) <= d::date
      group by d
    ) s
  );
end;
$$;
comment on function public.holdings_value_series(text, date, date) is
  'Member: per Dubai day, the value of the active holdings held then (at that day''s prices and values) and what they had cost to date.';
grant execute on function public.holdings_value_series(text, date, date) to authenticated, service_role;

-- ── Returns ──────────────────────────────────────────────────────────────────
-- Money-weighted yearly return: the rate r at which Σ amount / (1 + r)^(days / 365) = 0, with
-- money in negative and value out positive. Bisection on [-0.99, 10]; null without a sign
-- change or with under 90 days between the first and last cash flow.
create function private.xirr(p_dates date[], p_amounts numeric[])
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  d0 date;
  lo double precision := -0.99;
  hi double precision := 10;
  mid double precision;
  f_lo double precision;
  f_mid double precision;
  i int;
  k int;
  npv double precision;
begin
  if p_dates is null or cardinality(p_dates) < 2 then
    return null;
  end if;
  select min(x) into d0 from unnest(p_dates) x;
  if (select max(x) from unnest(p_dates) x) - d0 < 90 then
    return null;
  end if;
  -- Rate maths only (never money): double precision is fine for the search.
  f_lo := 0;
  for i in 1 .. cardinality(p_dates) loop
    f_lo := f_lo + p_amounts[i]::double precision / power(1 + lo, (p_dates[i] - d0) / 365.0);
  end loop;
  npv := 0;
  for i in 1 .. cardinality(p_dates) loop
    npv := npv + p_amounts[i]::double precision / power(1 + hi, (p_dates[i] - d0) / 365.0);
  end loop;
  if sign(f_lo) = sign(npv) then
    return null;
  end if;
  for k in 1 .. 200 loop
    mid := (lo + hi) / 2;
    f_mid := 0;
    for i in 1 .. cardinality(p_dates) loop
      f_mid := f_mid + p_amounts[i]::double precision / power(1 + mid, (p_dates[i] - d0) / 365.0);
    end loop;
    if abs(f_mid) < 1e-7 or (hi - lo) < 1e-10 then
      exit;
    end if;
    if sign(f_mid) = sign(f_lo) then
      lo := mid; f_lo := f_mid;
    else
      hi := mid;
    end if;
  end loop;
  return round((mid * 100)::numeric, 2);
end;
$$;

-- Member: returns per holding and in total for a period ('all', 'ytd', '12m'). For each:
-- start value (0 when the holding began inside the period), end value (today), added
-- (contributions − withdrawals in the period), income, growth = end − start − added + income,
-- simple % = growth / (start + contributions), and the yearly money-weighted return. A holding
-- whose start value is unknown (no price or value then) is not complete and stays out of the
-- total.
create function public.holding_returns(p_profile_code text, p_period text default 'all')
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
  if p_period is null or p_period not in ('all', 'ytd', '12m') then
    raise exception 'period must be all, ytd or 12m' using errcode = '22023';
  end if;
  v_from := case p_period when 'ytd' then date_trunc('year', v_today)::date
                          when '12m' then v_today - 365 end;

  for h in
    select ho.holding_code, ho.name, ho.kind,
           coalesce(least(ho.acquired_on, (select min(f.flow_date) from public.holding_flows f
                                           where f.holding_code = ho.holding_code
                                             and private.flow_is_active(f.removed_at, f.txn_code))),
                    public.dubai_date(ho.created_at)) as began
    from public.holdings ho
    where ho.profile_code = p_profile_code and ho.status = 'active'
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
    v_complete := v0 is not null and v1 is not null;
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
  'Member: per holding and in total for all time / this year / the last 12 months: start and end value, added, income, growth, simple % and the money-weighted yearly return (XIRR).';
grant execute on function public.holding_returns(text, text) to authenticated, service_role;

-- ── Spend, cash flow and the ledger ──────────────────────────────────────────
create function private.active_flow_holding(p_txn_code text)
returns text
language sql
stable
set search_path = ''
as $$
  select f.holding_code from public.holding_flows f where f.txn_code = p_txn_code and f.removed_at is null
$$;

create or replace view public.v_spend
with (security_invoker = true) as
select
  t.txn_code, t.profile_code, t.account_code, t.card_code, t.txn_date, t.txn_at,
  t.merchant_code, t.description, t.effective_category_code as category_code,
  case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end as spend_aed,
  t.amount_original, t.currency_original, t.status, t.amount_aed_is_estimate, t.kind,
  case when a.kind = 'credit_card' then 'credit_card' else 'debit_card' end as instrument
from public.transactions t
join public.accounts a on a.account_code = t.account_code
left join public.categories c on c.category_code = t.effective_category_code
where t.status in ('pending', 'posted')
  and not t.exclude_from_spend
  and t.amount_aed is not null
  and ((t.direction = 'debit' and t.kind in ('purchase', 'fee', 'interest', 'cash_advance'))
       or (t.direction = 'credit' and t.kind = 'refund'))
  and coalesce(c.kind, 'spend') not in ('transfer', 'ignore', 'income', 'saving', 'support')
  -- A payment linked to a holding is saving (20261021093154).
  and not exists (select 1 from public.holding_flows f where f.txn_code = t.txn_code and f.removed_at is null);

create or replace view public.v_cash_flow with (security_invoker = true) as
select s.profile_code, s.txn_code, s.account_code, s.txn_date, 'spend'::text as flow, s.instrument,
       s.spend_aed::numeric(14,2) as amount_aed, null::text as holding_code
from public.v_spend s
union all
select t.profile_code, t.txn_code, t.account_code, t.txn_date,
       case
         when lk.holding_code is not null then 'saving'
         when t.direction = 'credit' then
           case c.kind when 'income' then 'income' when 'transfer' then 'internal_in'
                       else case when c.kind is null and own.yes then 'internal_in'
                                 else 'money_in' end end
         when exists (select 1 from public.card_transfers x where x.from_txn_code = t.txn_code) then 'card_repayment'
         else case c.kind when 'support' then 'support' when 'saving' then 'saving'
                          when 'transfer' then 'internal_out'
                          when 'spend' then 'spend_transfer' when 'fee' then 'spend_transfer'
                          else case when c.kind is null and own.yes then 'internal_out'
                                    else 'money_out' end end
       end,
       null::text,
       -- Money back out of a holding into the bank is negative saving.
       (case when lk.holding_code is not null and t.direction = 'credit' then -t.amount_aed else t.amount_aed end)::numeric(14,2),
       lk.holding_code
from public.transactions t
join public.accounts a on a.account_code = t.account_code and a.kind in ('current', 'savings')
left join public.categories c on c.category_code = t.effective_category_code
cross join lateral (select private.active_flow_holding(t.txn_code) as holding_code) lk
cross join lateral (
  select exists (
    -- (a) the other leg, on another of the ledger's bank accounts
    select 1 from public.transactions o
    join public.accounts oa on oa.account_code = o.account_code and oa.kind in ('current', 'savings')
    where o.profile_code = t.profile_code and o.account_code <> t.account_code
      and o.kind = case t.kind when 'transfer_out' then 'transfer_in' else 'transfer_out' end
      and o.amount_aed = t.amount_aed and abs(o.txn_date - t.txn_date) <= 3
      and o.status in ('pending', 'posted')
  ) or (t.kind = 'transfer_out' and exists (
    -- (b) a transfer notice from this account, same amount, naming another of its bank accounts
    select 1 from public.sms_messages n
    join public.accounts d
      on d.profile_code = n.profile_code and d.account_code <> n.account_code
     and d.kind in ('current', 'savings') and d.account_ref is not null
     and right(regexp_replace(coalesce(n.parsed_fields->>'counterparty_ref', ''), '[^0-9]', '', 'g'),
               length(d.account_ref)) = d.account_ref
    where n.profile_code = t.profile_code and n.account_code = t.account_code
      and n.msg_kind = 'transfer_notice' and n.parse_status = 'parsed'
      and n.amount = t.amount_original and abs(public.dubai_date(n.event_at) - t.txn_date) <= 1
  )) as yes
) own
where t.kind in ('transfer_in', 'transfer_out') and t.status in ('pending', 'posted')
  and t.amount_aed is not null and (lk.holding_code is not null or coalesce(c.kind, '') <> 'ignore')
union all
-- A card or debit-card purchase filed under saving or support (an investment plan paid by card),
-- or linked to a holding, is that flow: v_spend leaves it out, so it would otherwise not appear.
select t.profile_code, t.txn_code, t.account_code, t.txn_date,
       case when lk.holding_code is not null then 'saving' else c.kind end,
       case when a.kind = 'credit_card' then 'credit_card' else 'debit_card' end,
       (case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)::numeric(14,2),
       lk.holding_code
from public.transactions t
join public.accounts a on a.account_code = t.account_code
left join public.categories c on c.category_code = t.effective_category_code
cross join lateral (select private.active_flow_holding(t.txn_code) as holding_code) lk
where t.status in ('pending', 'posted') and not t.exclude_from_spend and t.amount_aed is not null
  and (lk.holding_code is not null or c.kind in ('saving', 'support'))
  and ((t.direction = 'debit' and t.kind in ('purchase', 'fee', 'interest', 'cash_advance'))
       or (t.direction = 'credit' and t.kind = 'refund'));

-- Member: the month's saving by holding (null holding = saving filed by category only).
create function public.cash_flow_savings(p_profile_code text, p_from date, p_to date)
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
      group by 1, 2
    ) x
    left join public.holdings h on h.holding_code = x.holding_code), '[]'::jsonb);
end;
$$;
comment on function public.cash_flow_savings(text, date, date) is
  'Member: saving per month by holding (linked payments), and saving filed by category with no holding (holding_code null).';
grant execute on function public.cash_flow_savings(text, date, date) to authenticated, service_role;

-- ── 6. Net worth with every holding, and allocation ─────────────────────────
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
                                 and a.kind in ('current', 'savings') and a.status = 'active'),
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

-- ── v_transactions and account_ledger name a linked holding ──────────────────
create or replace view public.v_transactions with (security_invoker = true) as
select t.txn_code,
       t.profile_code,
       t.account_code,
       t.card_code,
       t.status,
       t.kind,
       t.direction,
       t.txn_date,
       t.txn_at,
       t.posting_date,
       t.stmt_code,
       t.merchant_code,
       t.description,
       m.display_name as merchant_name,
       t.amount_original,
       t.currency_original,
       t.amount_aed,
       t.amount_aed_is_estimate,
       t.fx_rate,
       t.auth_amount,
       t.amount_source,
       t.related_txn_code,
       t.exclude_from_spend,
       t.notes,
       t.effective_category_code as category_code,
       c.name as category_name,
       c.color_token as category_color,
       c.kind as category_kind,
       case
         when t.manual_category_code is not null then 'manual'
         when t.merchant_category_source = 'manual' and t.merchant_category_code is not null then 'merchant'
         when t.rule_category_code is not null then 'rule'
         when t.merchant_category_source = 'llm' and t.merchant_category_code is not null then 'suggested'
       end as category_source,
       a.bank_code,
       cd.last4 as card_last4,
       a.nickname as account_nickname,
       coalesce((select true from public.transaction_evidence e
                 where e.txn_code = t.txn_code and e.is_active and e.evidence_type = 'sms'
                 limit 1), false) as has_sms,
       coalesce((select true from public.transaction_evidence e
                 where e.txn_code = t.txn_code and e.is_active and e.evidence_type in ('statement_line', 'history_line')
                 limit 1), false) as has_statement,
       t.created_at,
       t.updated_at,
       -- Card transfers (appended, so the column order above is unchanged).
       tr.transfer_txn_code,
       tr.transfer_bank_code,
       tr.transfer_card_last4,
       -- Wealth mode (appended): the account's kind, and whether the row is spending business.
       a.kind as account_kind,
       (a.kind = 'credit_card' or t.kind in ('purchase', 'refund', 'fee', 'interest', 'cash_advance')) as in_spending,
       -- Investments (appended): the holding a payment is linked to.
       lk.holding_code,
       lk.holding_name
from public.transactions t
join public.accounts a on a.account_code = t.account_code
left join public.cards cd on cd.card_code = t.card_code
left join public.categories c on c.category_code = t.effective_category_code
left join public.merchants m on m.merchant_code = t.merchant_code
left join lateral (
  select ot.txn_code as transfer_txn_code, oa.bank_code as transfer_bank_code, oc.last4 as transfer_card_last4
  from public.card_transfers ct
  join public.transactions ot
    on ot.txn_code = case when ct.from_txn_code = t.txn_code then ct.to_txn_code else ct.from_txn_code end
  join public.accounts oa on oa.account_code = ot.account_code
  left join public.cards oc on oc.card_code = ot.card_code
  where ct.from_txn_code = t.txn_code or ct.to_txn_code = t.txn_code
  limit 1
) tr on true
left join lateral (
  select f.holding_code, h.name as holding_name
  from public.holding_flows f join public.holdings h on h.holding_code = f.holding_code
  where f.txn_code = t.txn_code and f.removed_at is null
) lk on true;

-- account_ledger: each row names the holding it is linked to (20261020162834 otherwise).
create or replace function public.account_ledger(p_profile_code text, p_account_code text, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  a public.accounts;
  v_start timestamptz := p_from::timestamp at time zone 'Asia/Dubai';
  v_end timestamptz := (p_to + 1)::timestamp at time zone 'Asia/Dubai';
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from must be on or before p_to' using errcode = '22023';
  end if;
  if p_to - p_from > 400 then
    raise exception 'at most 400 days' using errcode = '22023';
  end if;
  select * into a from public.accounts
  where account_code = p_account_code and profile_code = p_profile_code and kind in ('current', 'savings');
  if not found then
    raise exception 'bank account not found' using errcode = 'P0002';
  end if;

  with rb as (select * from private.bank_running_balances(p_account_code)),
  fl as (select f.txn_code, min(f.flow) as flow from public.v_cash_flow f
         where f.account_code = p_account_code and f.txn_date between p_from and p_to
         group by f.txn_code),
  lr as (
    select t.*, rb.ts, rb.samt, rb.balance_after, fl.flow
    from public.v_transactions t
    join rb on rb.txn_code = t.txn_code
    left join fl on fl.txn_code = t.txn_code
    where t.account_code = p_account_code and t.txn_date between p_from and p_to
  )
  select jsonb_build_object(
    'account', jsonb_build_object('account_code', a.account_code, 'bank_code', a.bank_code, 'kind', a.kind,
                                  'nickname', a.nickname, 'account_ref', a.account_ref, 'currency', a.currency,
                                  'status', a.status),
    'from', p_from, 'to', p_to,
    -- Before the account's first evidence the balance is unknown, but the balance just before
    -- the period's first row is still that row's balance less its amount.
    'opening_balance', coalesce(private.bank_balance_at(p_account_code, v_start - interval '1 microsecond'),
                                (select (r.balance_after - r.samt)::numeric(14,2) from lr r
                                 order by r.ts, r.txn_code limit 1))::text,
    'closing_balance', private.bank_balance_at(p_account_code, v_end - interval '1 microsecond')::text,
    'money_in', coalesce((select sum(r.samt) from lr r where r.samt > 0), 0)::numeric(14,2)::text,
    'money_out', coalesce((select -sum(r.samt) from lr r where r.samt < 0), 0)::numeric(14,2)::text,
    'unpriced_count', (select count(*) from lr r where r.samt is null)::int,
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'txn_code', r.txn_code, 'txn_date', r.txn_date, 'txn_at', r.txn_at, 'status', r.status,
        'kind', r.kind, 'direction', r.direction, 'description', r.description,
        'merchant_code', r.merchant_code, 'merchant_name', r.merchant_name,
        'amount', abs(r.samt)::numeric(14,2)::text,
        'amount_aed', r.amount_aed::text,
        'amount_original', r.amount_original::text, 'currency_original', r.currency_original,
        'category_code', r.category_code, 'category_name', r.category_name,
        'category_color', r.category_color, 'category_kind', r.category_kind,
        'category_source', r.category_source,
        'flow', r.flow,
        'balance_after', r.balance_after::text,
        'notes', r.notes, 'has_sms', r.has_sms,
        'transfer_txn_code', r.transfer_txn_code, 'transfer_bank_code', r.transfer_bank_code,
        'transfer_card_last4', r.transfer_card_last4,
        'holding_code', r.holding_code, 'holding_name', r.holding_name)
        order by r.ts desc, r.txn_code desc) from lr r), '[]'::jsonb))
  into v_out;
  return v_out;
end;
$$;
comment on function public.account_ledger(text, text, date, date) is
  'Member: a bank account''s transactions for a period, newest first, with flow and running balance, plus opening/closing balance and money in/out (account currency, decimal strings). Wealth mode.';
grant execute on function public.account_ledger(text, text, date, date) to authenticated, service_role;

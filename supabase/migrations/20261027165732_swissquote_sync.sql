-- Swissquote sync: the broker's cash account, positions, note values and history.
--
-- The swissquote-sync Edge Function reads the web platform's own JSON nightly (login: form post
-- plus the Level-3 matrix card) and hands it to public.import_broker_data:
-- 1. broker_transactions: one row per Swissquote cash or position movement, keyed by
--    Swissquote's transaction id (evidence, immutable). A cash row derives one transaction on
--    the account (amount_source 'broker', posted), so the account reads like any debit account:
--    deposits, buys, coupons, redemptions, dividends, interest, custody fees and reversals.
--    Buys, sells, coupons, redemptions and dividends are also holding flows (saving and income,
--    never spend).
-- 2. Each ISIN is a holding (external_ref = ISIN): shares are `security`, anything else is a
--    `broker` holding until a term sheet makes it a structured note, which then adopts the
--    holding (its flows and marks stay).
-- 3. broker_positions: each day's mark (quantity, bid, value, cost, P&L); it writes the holding's
--    valuation. A live note is now worth its market value once it has one (the 27 Oct decision
--    "worth what was invested" stays the fallback).
-- 4. balance_checkpoints source 'broker': Swissquote's own cash figure at each sync.
-- 5. broker_snapshots: the account's value per day (cash, positions, total); days before the
--    first sync are rebuilt from Swissquote's daily performance index (estimated).
-- 6. A note funded from a synced account posts nothing of its own: its purchase, coupons and
--    redemption are the broker's rows, linked once they arrive; cancelling it never voids them.
-- 7. note_summary gains what the note fetches sold today and what it pays if called next.
-- Money crosses the wire as decimal strings (§1.3); every figure is computed here (§2.2).

-- ── 1. sources ──────────────────────────────────────────────────────────────
alter table public.transactions drop constraint transactions_amount_source_check;
alter table public.transactions add constraint transactions_amount_source_check
  check (amount_source in ('statement_line', 'history_line', 'sms', 'manual', 'broker'));

alter table public.balance_checkpoints drop constraint balance_checkpoints_source_check;
alter table public.balance_checkpoints add constraint balance_checkpoints_source_check
  check (source in ('manual', 'sms', 'statement', 'broker'));

-- ── 2. tables ───────────────────────────────────────────────────────────────
create table public.broker_connections (
  connection_code text primary key default public.gen_code('bkc')
    check (connection_code ~ '^bkc_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null,
  provider text not null check (provider in ('swissquote')),
  portfolio_ref text not null check (portfolio_ref ~ '^[0-9A-Za-z-]{3,40}$'),
  last_attempt_at timestamptz,
  last_synced_at timestamptz,
  last_status text check (last_status in ('ok', 'error')),
  last_error text check (length(last_error) <= 500),
  terms_tried text[] not null default '{}',     -- ISINs whose term sheet was read once (made a note or not)
  created_at timestamptz not null default now(),
  constraint broker_connections_account_fkey foreign key (profile_code, account_code)
    references public.accounts(profile_code, account_code) on delete cascade,
  unique (provider, portfolio_ref),
  unique (account_code)
);
comment on table public.broker_connections is
  'A broker portfolio a sync keeps (Swissquote): its cash account in the ledger and how the last sync went.';

create table public.broker_transactions (
  btx_code text primary key default public.gen_code('btx')
    check (btx_code ~ '^btx_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null,
  external_id text not null check (external_id ~ '^[0-9A-Za-z-]{1,40}$'),
  contract_ref text check (length(contract_ref) <= 40),
  booked_at timestamptz not null,
  action text not null check (length(action) between 1 and 10),
  label text not null check (length(label) between 1 and 60),
  kind text not null check (kind in ('deposit', 'withdrawal', 'buy', 'sell', 'coupon', 'redemption', 'dividend',
                                     'interest', 'fee', 'reversal', 'position', 'other')),
  isin text check (isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'),
  security_name text check (length(security_name) <= 200),
  symbol text check (length(symbol) <= 40),
  quantity numeric(18,6),
  unit_price numeric(18,8),
  net_amount numeric(14,2) not null,            -- signed, in currency: + into the account
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  commission numeric(14,2) not null default 0,
  balance_after numeric(14,2),                  -- the broker's running cash balance
  is_reversal boolean not null default false,
  holding_code text,
  txn_code text references public.transactions(txn_code) on delete set null,
  created_at timestamptz not null default now(),
  constraint broker_transactions_account_fkey foreign key (profile_code, account_code)
    references public.accounts(profile_code, account_code) on delete cascade,
  constraint broker_transactions_holding_fkey foreign key (profile_code, holding_code)
    references public.holdings(profile_code, holding_code),
  unique (account_code, external_id)
);
create index broker_transactions_isin_idx on public.broker_transactions(account_code, isin, kind);
create index broker_transactions_holding_idx on public.broker_transactions(holding_code) where holding_code is not null;
create unique index broker_transactions_txn_uq on public.broker_transactions(txn_code) where txn_code is not null;
comment on table public.broker_transactions is
  'Evidence: one broker cash or position movement as the broker reports it (Swissquote transaction id), never edited. A cash row derives one transaction on the account; a security row is a flow of its holding.';

create table public.broker_positions (
  position_code text primary key default public.gen_code('bpo')
    check (position_code ~ '^bpo_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null,
  holding_code text not null,
  as_of date not null,
  isin text not null check (isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'),
  name text not null check (length(btrim(name)) between 1 and 200),
  symbol text check (length(symbol) <= 40),
  product_type text not null check (length(product_type) between 1 and 40),
  quantity numeric(18,6) not null,
  price numeric(18,8),                          -- per unit, or % of nominal when price_in_pct
  price_in_pct boolean not null,
  market_value numeric(14,2),                   -- null: the broker has no price yet
  cost_price numeric(18,8),
  profit numeric(14,2),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  fetched_at timestamptz not null default now(),
  constraint broker_positions_account_fkey foreign key (profile_code, account_code)
    references public.accounts(profile_code, account_code) on delete cascade,
  constraint broker_positions_holding_fkey foreign key (profile_code, holding_code)
    references public.holdings(profile_code, holding_code) on delete cascade,
  unique (account_code, as_of, isin)
);
create index broker_positions_holding_idx on public.broker_positions(holding_code, as_of desc);
comment on table public.broker_positions is
  'A position as the broker marked it on a day: quantity, price (bid; % of nominal for notes), market value, cost and P&L.';

create table public.broker_snapshots (
  snapshot_code text primary key default public.gen_code('bsn')
    check (snapshot_code ~ '^bsn_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null,
  as_of date not null,
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  cash numeric(14,2),
  positions_value numeric(14,2),
  total_value numeric(14,2) not null,
  estimated boolean not null default false,     -- rebuilt from the performance index, not a mark
  created_at timestamptz not null default now(),
  constraint broker_snapshots_account_fkey foreign key (profile_code, account_code)
    references public.accounts(profile_code, account_code) on delete cascade,
  unique (account_code, as_of)
);
comment on table public.broker_snapshots is
  'A broker account''s value on a day (cash + positions). Estimated rows are rebuilt from the broker''s daily performance index and the deposits; a sync''s own mark replaces them.';

do $$
declare
  t text;
begin
  foreach t in array array['broker_connections', 'broker_transactions', 'broker_positions', 'broker_snapshots'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated
                      using (profile_code = any ((select authz.my_profile_codes())::text[]))', t || '_member_read', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('create index %I on public.%I(profile_code)', t || '_profile_code_idx', t);
  end loop;
end;
$$;

create function private.is_broker_account(p_profile_code text, p_account_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from public.broker_connections c
                 where c.account_code = p_account_code and c.profile_code = p_profile_code)
$$;

-- ── 3. transactions from broker rows ────────────────────────────────────────
-- refresh_transaction (20261027124257) gains one source of typed evidence: a broker row.
CREATE OR REPLACE FUNCTION private.refresh_transaction(p_txn_code text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  t public.transactions%rowtype;
  l public.statement_lines%rowtype;
  s public.sms_messages%rowtype;
  v_has_line boolean := false;
  v_has_sms boolean := false;
  v_fx numeric;
  p public.transactions%rowtype;
begin
  select * into t from public.transactions where txn_code = p_txn_code for update;
  if not found then
    return;
  end if;

  select sl.* into l
  from public.transaction_evidence e
  join public.statement_lines sl on sl.line_code = e.line_code and sl.profile_code = e.profile_code
  where e.txn_code = p_txn_code and e.profile_code = t.profile_code
    and e.is_active and e.evidence_type in ('statement_line', 'history_line')
  order by case e.evidence_type when 'statement_line' then 0 else 1 end
  limit 1;
  v_has_line := found;

  select sm.* into s
  from public.transaction_evidence e
  join public.sms_messages sm on sm.sms_code = e.sms_code and sm.profile_code = e.profile_code
  where e.txn_code = p_txn_code and e.profile_code = t.profile_code and e.is_active and e.role <> 'duplicate'
  order by sm.event_at
  limit 1;
  v_has_sms := found;

  if v_has_line then
    t.card_code := coalesce(l.card_code, t.card_code);
    t.txn_date := l.txn_date;
    t.posting_date := l.posting_date;
    t.description := l.description;
    t.amount_original := l.amount_original;
    t.currency_original := l.currency_original;
    t.amount_aed := l.amount_aed;
    t.fx_rate := case when l.currency_original = 'AED' then null else l.fx_rate end;  -- X-33
    t.amount_aed_is_estimate := false;
    t.kind := l.kind;
    t.direction := l.direction;
    t.amount_source := l.evidence_type;
    t.stmt_code := l.stmt_code;
    t.status := 'posted';
    t.voided_at := null;
    t.void_reason := null;
    if l.amount_aed is null then
      v_fx := coalesce(l.fx_rate, private.estimate_fx(t.profile_code, l.currency_original, private.account_bank(l.account_code),
                                                    coalesce(l.posting_date, l.txn_date)));
      t.amount_aed := round(l.amount_original * v_fx, 2);
      t.amount_aed_is_estimate := t.amount_aed is not null;
      t.fx_rate := v_fx;  -- the rate the estimate used, as on a pending SMS row
    end if;
    if v_has_sms then
      t.txn_at := s.event_at;
      t.auth_amount := case when s.amount is distinct from l.amount_original then s.amount end;
    else
      t.txn_at := null;
      t.auth_amount := null;
    end if;
  elsif v_has_sms then
    t.card_code := coalesce(s.card_code, t.card_code);
    t.txn_at := s.event_at;
    t.txn_date := public.dubai_date(s.event_at);
    t.posting_date := null;
    t.description := coalesce(s.description, t.description);
    t.amount_original := s.amount;
    t.currency_original := s.currency;
    t.auth_amount := null;
    t.stmt_code := null;
    t.amount_source := 'sms';
    if s.currency = 'AED' then
      t.amount_aed := s.amount;
      t.fx_rate := null;
      t.amount_aed_is_estimate := false;
    else
      v_fx := private.estimate_fx(t.profile_code, s.currency,
                                  coalesce(s.bank_code, private.account_bank(coalesce(s.account_code, t.account_code))),
                                  public.dubai_date(s.event_at));
      t.fx_rate := v_fx;
      t.amount_aed := round(s.amount * v_fx, 2);
      t.amount_aed_is_estimate := true;
    end if;
    -- A card's SMS waits for its statement; a bank account has none, so its SMS is final (2b).
    t.status := case when t.voided_at is not null then 'void'
                     when exists (select 1 from public.accounts a
                                  where a.account_code = t.account_code and a.kind in ('current', 'savings'))
                       then 'posted'
                     -- A transfer out of a credit line is final too: no statement line will post it.
                     when t.kind in ('transfer_in', 'transfer_out') then 'posted'
                     else 'pending' end;
  elsif t.leg_of_txn_code is not null then
    -- The other leg of a card payment drawn from a bank account (the Wio Credit autopay): the
    -- one SMS is the payment's evidence, so this row's facts are the payment's. It stands while
    -- the payment does, and is final (a bank account has no statement to wait for).
    select * into p from public.transactions where txn_code = t.leg_of_txn_code;
    t.txn_at := p.txn_at;
    t.txn_date := p.txn_date;
    t.posting_date := null;
    t.amount_original := p.amount_original;
    t.currency_original := p.currency_original;
    t.amount_aed := p.amount_aed;
    t.amount_aed_is_estimate := p.amount_aed_is_estimate;
    t.fx_rate := p.fx_rate;
    t.auth_amount := null;
    t.stmt_code := null;
    t.amount_source := p.amount_source;
    if p.status in ('pending', 'posted') then
      if t.void_reason = 'payment_gone' then
        t.voided_at := null;
        t.void_reason := null;
      end if;
      t.status := case when t.voided_at is not null then 'void' else 'posted' end;
    else
      t.voided_at := coalesce(t.voided_at, now());
      t.void_reason := coalesce(t.void_reason, 'payment_gone');
      t.status := 'void';
    end if;
  elsif exists (select 1 from public.account_entries x where x.txn_code = t.txn_code)
     or exists (select 1 from public.structured_note_events x where x.txn_code = t.txn_code)
     or exists (select 1 from public.structured_notes x where x.purchase_txn_code = t.txn_code)
     or exists (select 1 from public.broker_transactions x where x.txn_code = t.txn_code) then
    -- Typed evidence (20261027124257): a deposit the user entered, or a note's purchase or
    -- payment; or a broker's own row (20261027165732). Its facts were set from that evidence;
    -- it stands until voided.
    t.status := case when t.voided_at is not null then 'void' else 'posted' end;
  else
    t.status := case when t.voided_at is not null then 'void' else 'orphaned' end;
  end if;

  t.merchant_code := private.resolve_merchant(t.description);

  update public.transactions set
    card_code = t.card_code, status = t.status, kind = t.kind, direction = t.direction,
    txn_date = t.txn_date, txn_at = t.txn_at, posting_date = t.posting_date, stmt_code = t.stmt_code,
    merchant_code = t.merchant_code, description = t.description,
    amount_original = t.amount_original, currency_original = t.currency_original,
    amount_aed = t.amount_aed, amount_aed_is_estimate = t.amount_aed_is_estimate, fx_rate = t.fx_rate,
    auth_amount = t.auth_amount, amount_source = t.amount_source,
    voided_at = t.voided_at, void_reason = t.void_reason
  where txn_code = p_txn_code
    and (card_code, status, kind, direction, txn_date, txn_at, posting_date, stmt_code, merchant_code,
         description, amount_original, currency_original, amount_aed, amount_aed_is_estimate, fx_rate,
         auth_amount, amount_source, voided_at, void_reason)
      is distinct from
        (t.card_code, t.status, t.kind, t.direction, t.txn_date, t.txn_at, t.posting_date, t.stmt_code, t.merchant_code,
         t.description, t.amount_original, t.currency_original, t.amount_aed, t.amount_aed_is_estimate, t.fx_rate,
         t.auth_amount, t.amount_source, t.voided_at, t.void_reason);

  if t.status = 'orphaned' then
    insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason)
    values (t.profile_code, t.account_code, 'transaction', t.txn_code, 'orphaned')
    on conflict do nothing;
  else
    -- An orphan review raised and answered within the same transaction (a
    -- re-parse that detached a line and re-matched it) was never news: drop it (DP-06).
    delete from public.match_reviews
    where profile_code = t.profile_code and subject_type = 'transaction' and subject_code = t.txn_code
      and reason = 'orphaned' and status = 'open' and created_at = now();
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'evidence_reattached'),
      resolved_at = now()
    where profile_code = t.profile_code and subject_type = 'transaction' and subject_code = t.txn_code
      and reason = 'orphaned' and status = 'open';
  end if;
  if t.status <> 'pending' then
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'no_longer_pending'),
      resolved_at = now()
    where profile_code = t.profile_code and subject_type = 'transaction' and subject_code = t.txn_code
      and reason = 'missing_from_statement' and status = 'open';
  end if;
  -- A payment's other leg follows it.
  perform private.refresh_transaction(x.txn_code)
  from public.transactions x
  where x.profile_code = t.profile_code and x.leg_of_txn_code = p_txn_code;
end;
$function$;

-- What a broker row is, from Swissquote's action code (B buy, S sell, G payment, E coupon,
-- CAC cash of a redemption, CAS its security leg, D dividend, K interest, J custody fee).
create function private.broker_kind(p_action text, p_label text, p_net numeric, p_reversal boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_reversal then 'reversal'
    when p_action = 'G' then case when p_net >= 0 then 'deposit' else 'withdrawal' end
    when p_action = 'B' then 'buy'
    when p_action = 'S' then 'sell'
    when p_action = 'E' then 'coupon'
    when p_action = 'CAC' or (p_net > 0 and p_label ilike 'redemption%') then 'redemption'
    when p_action = 'D' then 'dividend'
    when p_action = 'K' then 'interest'
    when p_action = 'J' then 'fee'
    when p_net = 0 then 'position'
    else 'other'
  end
$$;

-- The holding of a broker position (its ISIN), made when first seen: shares and funds are a
-- `security`, anything else a `broker` holding until a term sheet makes it a note. A note
-- already entered for the ISIN is adopted.
create function private.broker_holding(p_profile_code text, p_account_code text, p_isin text, p_name text,
                                       p_symbol text, p_product_type text, p_currency text, p_acquired date,
                                       p_units numeric)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_code text;
  v_security boolean := upper(coalesce(p_product_type, '')) in ('SHARE', 'ETF', 'FUND');
begin
  select h.holding_code into v_code from public.holdings h
  where h.profile_code = p_profile_code and h.external_ref = p_isin;
  if v_code is not null then
    return v_code;
  end if;
  select n.holding_code into v_code from public.structured_notes n
  where n.profile_code = p_profile_code and n.isin = p_isin and n.status <> 'cancelled'
    and (n.funding_account_code is null or n.funding_account_code = p_account_code)
  order by n.created_at limit 1;
  if v_code is not null then
    update public.holdings set external_ref = p_isin where holding_code = v_code;
    return v_code;
  end if;
  insert into public.holdings (profile_code, name, kind, currency, institution, acquired_on, units, symbol, notes, external_ref)
  values (p_profile_code, left(btrim(coalesce(nullif(btrim(p_name), ''), p_symbol, p_isin)), 80),
          case when v_security then 'security' else 'broker' end, p_currency,
          (select b.name from public.banks b join public.accounts a on a.bank_code = b.bank_code
           where a.account_code = p_account_code),
          p_acquired, case when v_security then greatest(coalesce(p_units, 0), 0.000001) end,
          case when v_security and p_symbol ~ '^[A-Z0-9.^=-]{1,20}$' then p_symbol end,
          'Synced from the broker; ISIN ' || p_isin, p_isin)
  returning holding_code into v_code;
  return v_code;
end;
$$;

-- A transaction from a broker row: its facts, posted (typed evidence, see refresh_transaction).
create function private.broker_txn(p_profile text, p_account text, p_kind text, p_direction text, p_amount numeric,
                                   p_currency text, p_at timestamptz, p_description text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_txn text;
  v_aed numeric := private.to_aed(p_amount, p_currency);
begin
  insert into public.transactions (profile_code, account_code, kind, direction, txn_date, txn_at, description,
    merchant_code, amount_original, currency_original, amount_aed, amount_aed_is_estimate, amount_source, status)
  values (p_profile, p_account, p_kind, p_direction, public.dubai_date(p_at), p_at, upper(p_description),
    private.resolve_merchant(upper(p_description)), p_amount, p_currency, v_aed,
    p_currency not in ('AED', 'USD') and v_aed is not null, 'broker', 'posted')
  returning txn_code into v_txn;
  return v_txn;
end;
$$;

-- Service (swissquote-sync): one portfolio's data, idempotent. p_data (decimal strings):
-- {portfolio_ref, currency, account_number, iban, fetched_at, cash, opening:{as_of, balance}|null,
--  securities:[{isin, name, symbol, product_type, currency}],
--  transactions:[{id, booked_at, action, label, reversal, isin, name, symbol, quantity, unit_price,
--                 net_amount, currency, commission, balance, contract_ref}],
--  positions:[{isin, name, symbol, product_type, quantity, price, price_in_pct, value, cost_price,
--              profit, currency}] (absent: positions not read, nothing is closed),
--  snapshots:[{as_of, cash, positions_value, total_value, estimated}]}
-- Finds or makes the cash account, adds new rows, marks positions, records the cash balance and
-- the day's value, settles notes funded from the account. Returns counts and the ISINs held
-- without terms (for the term-sheet import).
create function public.import_broker_data(p_profile_code text, p_provider text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bank text := case p_provider when 'swissquote' then 'SWQ' end;
  v_ref text := btrim(coalesce(p_data->>'portfolio_ref', ''));
  v_currency text := upper(coalesce(p_data->>'currency', 'USD'));
  v_fetched timestamptz := coalesce((p_data->>'fetched_at')::timestamptz, now());
  v_day date := public.dubai_date(coalesce((p_data->>'fetched_at')::timestamptz, now()));
  v_number text := nullif(regexp_replace(coalesce(p_data->>'account_number', ''), '[^0-9]', '', 'g'), '');
  v_iban text := nullif(upper(regexp_replace(coalesce(p_data->>'iban', ''), '\s', '', 'g')), '');
  c public.broker_connections;
  v_account text;
  r record;
  o public.broker_transactions;
  ot public.transactions;
  v_kind text;
  v_holding text;
  v_txn text;
  v_tkind text;
  v_desc text;
  v_amount numeric;
  v_flow text;
  v_name text;
  v_new int := 0;
  v_flows int := 0;
  v_marks int := 0;
  v_closed int := 0;
  v_cash numeric := nullif(p_data->>'cash', '')::numeric;
  v_balance numeric;
  v_checkpoint boolean := false;
  v_positions_value numeric;
  v_settled int := 0;
begin
  perform private.assert_service_role();
  if v_bank is null then
    raise exception 'unknown provider %', p_provider using errcode = '22023';
  end if;
  if v_ref !~ '^[0-9A-Za-z-]{3,40}$' then
    raise exception 'portfolio_ref is required' using errcode = '22023';
  end if;
  if v_currency !~ '^[A-Z]{3}$' then
    raise exception 'currency must be a 3-letter code' using errcode = '22023';
  end if;

  -- The cash account: the connection's, else the ledger's unlinked account at this bank in this
  -- currency, else a new one.
  select * into c from public.broker_connections where provider = p_provider and portfolio_ref = v_ref;
  if found and c.profile_code <> p_profile_code then
    raise exception 'this portfolio belongs to another ledger' using errcode = '42501';
  end if;
  if found then
    v_account := c.account_code;
  else
    select a.account_code into v_account from public.accounts a
    where a.profile_code = p_profile_code and a.bank_code = v_bank and a.kind in ('current', 'savings')
      and a.currency = v_currency and a.status = 'active'
      and not exists (select 1 from public.broker_connections x where x.account_code = a.account_code)
    order by a.created_at limit 1;
    if v_account is null then
      insert into public.accounts (profile_code, bank_code, kind, currency, account_ref, account_number, iban, product_name)
      values (p_profile_code, v_bank, 'current', v_currency, right(v_number, 4), v_number,
              case when v_iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then v_iban end, 'Trading account')
      returning account_code into v_account;
    end if;
    insert into public.broker_connections (profile_code, account_code, provider, portfolio_ref)
    values (p_profile_code, v_account, p_provider, v_ref)
    returning * into c;
  end if;
  update public.accounts a set
    account_number = coalesce(a.account_number, case when v_number ~ '^[0-9]{6,34}$' then v_number end),
    iban = coalesce(a.iban, case when v_iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then v_iban end),
    account_ref = coalesce(a.account_ref, case when right(v_number, 4) ~ '^[0-9]{3,12}$' then right(v_number, 4) end)
  where a.account_code = v_account;

  -- Holdings for every ISIN the data names (a position's quantity sets a share's units).
  for r in
    select s.isin, (array_agg(s.name order by s.pri))[1] as name, (array_agg(s.symbol order by s.pri))[1] as symbol,
           (array_agg(s.product_type order by s.pri) filter (where s.product_type is not null))[1] as product_type,
           (array_agg(s.currency order by s.pri))[1] as currency,
           (array_agg(s.quantity order by s.pri) filter (where s.quantity is not null))[1] as quantity
    from (
      select p->>'isin' as isin, p->>'name' as name, p->>'symbol' as symbol, p->>'product_type' as product_type,
             upper(coalesce(p->>'currency', v_currency)) as currency, (p->>'quantity')::numeric as quantity, 1 as pri
      from jsonb_array_elements(coalesce(p_data->'positions', '[]')) p
      union all
      select s->>'isin', s->>'name', s->>'symbol', s->>'product_type', upper(coalesce(s->>'currency', v_currency)), null, 2
      from jsonb_array_elements(coalesce(p_data->'securities', '[]')) s
      union all
      select t->>'isin', t->>'name', t->>'symbol', null, upper(coalesce(t->>'currency', v_currency)),
             nullif(t->>'quantity', '')::numeric, 3
      from jsonb_array_elements(coalesce(p_data->'transactions', '[]')) t
      where (t->>'action') in ('B', 'S')
    ) s
    where s.isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'
    group by s.isin
  loop
    perform private.broker_holding(p_profile_code, v_account, r.isin, r.name, r.symbol, r.product_type, r.currency,
      (select min(public.dubai_date((t->>'booked_at')::timestamptz))
       from jsonb_array_elements(coalesce(p_data->'transactions', '[]')) t where t->>'isin' = r.isin),
      abs(r.quantity));
  end loop;

  -- New rows, oldest first (a reversal after what it reverses).
  for r in
    select t->>'id' as id, (t->>'booked_at')::timestamptz as booked_at, t->>'action' as action,
           left(coalesce(nullif(btrim(t->>'label'), ''), t->>'action'), 60) as label,
           coalesce((t->>'reversal')::boolean, false) as reversal,
           nullif(t->>'isin', '') as isin, left(nullif(btrim(t->>'name'), ''), 200) as name,
           left(nullif(btrim(t->>'symbol'), ''), 40) as symbol,
           nullif(t->>'quantity', '')::numeric as quantity, nullif(t->>'unit_price', '')::numeric as unit_price,
           (t->>'net_amount')::numeric as net, upper(coalesce(t->>'currency', v_currency)) as currency,
           coalesce(nullif(t->>'commission', '')::numeric, 0) as commission,
           nullif(t->>'balance', '')::numeric as balance, left(nullif(t->>'contract_ref', ''), 40) as contract_ref
    from jsonb_array_elements(coalesce(p_data->'transactions', '[]')) t
    order by (t->>'booked_at')::timestamptz, coalesce((t->>'reversal')::boolean, false), t->>'id'
  loop
    continue when exists (select 1 from public.broker_transactions x where x.account_code = v_account and x.external_id = r.id);
    v_kind := private.broker_kind(r.action, r.label, r.net, r.reversal);
    v_holding := (select h.holding_code from public.holdings h
                  where h.profile_code = p_profile_code and h.external_ref = r.isin);
    v_txn := null;
    v_flow := null;
    v_amount := abs(r.net);
    if r.net <> 0 and r.currency = (select a.currency from public.accounts a where a.account_code = v_account) then
      if v_kind = 'reversal' then
        select * into o from public.broker_transactions x
        where x.account_code = v_account and x.external_id = regexp_replace(r.id, '-R$', '');
        select * into ot from public.transactions x where x.txn_code = o.txn_code;
        v_tkind := case ot.kind when 'transfer_in' then 'transfer_out' when 'transfer_out' then 'transfer_in'
                                when 'fee' then 'refund' else ot.kind end;
        v_tkind := coalesce(v_tkind, case when r.net > 0 then 'transfer_in' else 'transfer_out' end);
        v_desc := 'REVERSAL ' || coalesce(ot.description, upper(r.label));
        -- What it reverses no longer counts in the holding.
        update public.holding_flows set removed_at = coalesce(removed_at, now())
        where txn_code = o.txn_code and o.txn_code is not null;
      else
        v_tkind := case v_kind
          when 'deposit' then 'transfer_in' when 'withdrawal' then 'transfer_out'
          when 'buy' then 'transfer_out' when 'sell' then 'transfer_in'
          when 'coupon' then 'transfer_in' when 'redemption' then 'transfer_in' when 'dividend' then 'transfer_in'
          when 'interest' then case when r.net > 0 then 'transfer_in' else 'interest' end
          when 'fee' then case when r.net < 0 then 'fee' else 'refund' end
          else case when r.net > 0 then 'transfer_in' else 'transfer_out' end end;
        v_name := coalesce(r.symbol, r.isin);
        v_desc := case v_kind
          when 'deposit' then 'INCOMING TRANSFER' when 'withdrawal' then 'OUTGOING TRANSFER'
          when 'buy' then 'BUY ' || coalesce(v_name, r.label) when 'sell' then 'SELL ' || coalesce(v_name, r.label)
          when 'coupon' then 'NOTE COUPON ' || coalesce(r.isin, v_name, '')
          when 'redemption' then 'NOTE REDEMPTION ' || coalesce(r.isin, v_name, '')
          when 'dividend' then 'DIVIDEND ' || coalesce(v_name, '')
          when 'interest' then 'DEPOSIT INTEREST'
          when 'fee' then case when r.label ilike 'custody%' then 'SWISSQUOTE CUSTODY FEE' else 'SWISSQUOTE ' || upper(r.label) end
          else upper(r.label) || coalesce(' ' || r.isin, '') end;
        v_flow := case v_kind when 'buy' then 'contribution' when 'sell' then 'withdrawal' when 'redemption' then 'withdrawal'
                              when 'coupon' then 'income' when 'dividend' then 'income' end;
      end if;
      v_txn := private.broker_txn(p_profile_code, v_account, v_tkind, case when r.net > 0 then 'credit' else 'debit' end,
                                  v_amount, r.currency, r.booked_at, btrim(v_desc));
    end if;
    insert into public.broker_transactions (profile_code, account_code, external_id, contract_ref, booked_at, action, label,
      kind, isin, security_name, symbol, quantity, unit_price, net_amount, currency, commission, balance_after, is_reversal,
      holding_code, txn_code)
    values (p_profile_code, v_account, r.id, r.contract_ref, r.booked_at, r.action, r.label, v_kind, r.isin, r.name,
      r.symbol, r.quantity, r.unit_price, r.net, r.currency, r.commission, r.balance, r.reversal, v_holding, v_txn);
    v_new := v_new + 1;
    if v_flow is not null and v_holding is not null and v_txn is not null then
      -- A rule may have linked it elsewhere; the broker's own link wins.
      delete from public.holding_flows where txn_code = v_txn;
      insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code, source,
                                        external_ref, notes)
      values (p_profile_code, v_holding, public.dubai_date(r.booked_at), v_flow, v_amount,
              private.to_aed(v_amount, r.currency), v_txn, 'import', 'broker:' || r.id, left(r.label, 200));
      v_flows := v_flows + 1;
    end if;
  end loop;

  -- Notes entered before their buy arrived: the buy is their purchase.
  update public.structured_notes n set purchase_txn_code = (
    select bt.txn_code from public.broker_transactions bt
    where bt.account_code = v_account and bt.isin = n.isin and bt.kind = 'buy' and bt.txn_code is not null
    order by bt.booked_at limit 1)
  where n.profile_code = p_profile_code and n.funding_account_code = v_account and n.purchase_txn_code is null
    and n.isin is not null and n.status <> 'cancelled';

  -- Today's marks.
  if p_data ? 'positions' then
    for r in
      select p->>'isin' as isin, left(btrim(coalesce(nullif(p->>'name', ''), p->>'symbol', p->>'isin')), 200) as name,
             left(nullif(btrim(p->>'symbol'), ''), 40) as symbol,
             left(coalesce(nullif(btrim(p->>'product_type'), ''), 'OTHER'), 40) as product_type,
             (p->>'quantity')::numeric as quantity, nullif(p->>'price', '')::numeric as price,
             coalesce((p->>'price_in_pct')::boolean, false) as price_in_pct, nullif(p->>'value', '')::numeric as value,
             nullif(p->>'cost_price', '')::numeric as cost_price, nullif(p->>'profit', '')::numeric as profit,
             upper(coalesce(p->>'currency', v_currency)) as currency
      from jsonb_array_elements(p_data->'positions') p
      where p->>'isin' ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'
    loop
      select h.holding_code into v_holding from public.holdings h
      where h.profile_code = p_profile_code and h.external_ref = r.isin;
      insert into public.broker_positions (profile_code, account_code, holding_code, as_of, isin, name, symbol, product_type,
        quantity, price, price_in_pct, market_value, cost_price, profit, currency, fetched_at)
      values (p_profile_code, v_account, v_holding, v_day, r.isin, r.name, r.symbol, r.product_type, r.quantity, r.price,
        r.price_in_pct, r.value, r.cost_price, r.profit, r.currency, v_fetched)
      on conflict (account_code, as_of, isin) do update set
        holding_code = excluded.holding_code, name = excluded.name, symbol = excluded.symbol,
        product_type = excluded.product_type, quantity = excluded.quantity, price = excluded.price,
        price_in_pct = excluded.price_in_pct, market_value = excluded.market_value, cost_price = excluded.cost_price,
        profit = excluded.profit, currency = excluded.currency, fetched_at = excluded.fetched_at;
      update public.holdings h set status = 'active',
        units = case when h.kind = 'security' and r.quantity > 0 then r.quantity else h.units end
      where h.holding_code = v_holding;
      -- The holding's value for the day: a share's price, anything else the market value.
      if (select h.kind from public.holdings h where h.holding_code = v_holding) = 'security' and r.price is not null
         and not r.price_in_pct then
        update public.holding_valuations set unit_price = r.price, value = null
        where holding_code = v_holding and as_of = v_day and source = 'import';
        if not found then
          insert into public.holding_valuations (profile_code, holding_code, as_of, unit_price, source)
          values (p_profile_code, v_holding, v_day, r.price, 'import');
        end if;
      elsif r.value is not null then
        update public.holding_valuations set value = r.value, unit_price = null
        where holding_code = v_holding and as_of = v_day and source = 'import';
        if not found then
          insert into public.holding_valuations (profile_code, holding_code, as_of, value, source)
          values (p_profile_code, v_holding, v_day, r.value, 'import');
        end if;
      end if;
      v_marks := v_marks + 1;
    end loop;
    -- A position the broker no longer reports has been sold or redeemed.
    with gone as (
      update public.holdings h set status = 'closed'
      where h.profile_code = p_profile_code and h.status = 'active' and h.external_ref is not null
        and exists (select 1 from public.broker_transactions bt where bt.account_code = v_account and bt.holding_code = h.holding_code)
        and not exists (select 1 from jsonb_array_elements(p_data->'positions') p where p->>'isin' = h.external_ref)
      returning 1)
    select count(*) into v_closed from gone;
    select sum(bp.market_value) into v_positions_value from public.broker_positions bp
    where bp.account_code = v_account and bp.as_of = v_day;
  end if;

  -- The cash balance as the broker states it: once at the opening, and whenever it differs from
  -- what the ledger computes or the last one is a day old.
  if p_data->'opening' is not null and jsonb_typeof(p_data->'opening') = 'object'
     and not exists (select 1 from public.balance_checkpoints b where b.account_code = v_account
                     and b.as_of <= ((p_data->'opening'->>'as_of')::timestamptz)) then
    insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source)
    values (p_profile_code, v_account, (p_data->'opening'->>'as_of')::timestamptz,
            (p_data->'opening'->>'balance')::numeric, 'broker');
  end if;
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

  -- The account's value per day: the rebuilt history (never over a real mark), then today's mark.
  insert into public.broker_snapshots (profile_code, account_code, as_of, currency, cash, positions_value, total_value, estimated)
  select p_profile_code, v_account, (s->>'as_of')::date, v_currency, nullif(s->>'cash', '')::numeric,
         nullif(s->>'positions_value', '')::numeric, (s->>'total_value')::numeric, coalesce((s->>'estimated')::boolean, true)
  from jsonb_array_elements(coalesce(p_data->'snapshots', '[]')) s
  where (s->>'total_value') is not null and (s->>'as_of')::date < v_day
  on conflict (account_code, as_of) do update set
    cash = excluded.cash, positions_value = excluded.positions_value, total_value = excluded.total_value,
    estimated = excluded.estimated
  where public.broker_snapshots.estimated or not excluded.estimated;
  if v_cash is not null and p_data ? 'positions' then
    insert into public.broker_snapshots (profile_code, account_code, as_of, currency, cash, positions_value, total_value, estimated)
    values (p_profile_code, v_account, v_day, v_currency, v_cash, coalesce(v_positions_value, 0),
            v_cash + coalesce(v_positions_value, 0), false)
    on conflict (account_code, as_of) do update set
      cash = excluded.cash, positions_value = excluded.positions_value, total_value = excluded.total_value, estimated = false;
  end if;

  -- Notes funded from this account settle against the broker's rows.
  for r in select n.note_code from public.structured_notes n
           where n.funding_account_code = v_account and n.status = 'live' loop
    perform private.settle_structured_note(r.note_code);
    v_settled := v_settled + 1;
  end loop;

  update public.broker_connections set last_attempt_at = now(), last_synced_at = now(), last_status = 'ok', last_error = null
  where connection_code = c.connection_code;

  return jsonb_build_object(
    'account_code', v_account, 'transactions_added', v_new, 'flows_added', v_flows, 'positions_marked', v_marks,
    'positions_closed', v_closed, 'checkpoint', v_checkpoint, 'notes_settled', v_settled,
    'isins_without_terms', coalesce((
      select jsonb_agg(distinct h.external_ref) from public.holdings h
      where h.profile_code = p_profile_code and h.kind = 'broker' and h.external_ref is not null
        and exists (select 1 from public.broker_transactions bt where bt.account_code = v_account
                    and bt.holding_code = h.holding_code)), '[]'::jsonb));
end;
$$;
comment on function public.import_broker_data(text, text, jsonb) is
  'Service (swissquote-sync): a broker portfolio''s transactions, positions, cash and daily values for one ledger; idempotent. Returns counts and the ISINs held without terms.';
grant execute on function public.import_broker_data(text, text, jsonb) to service_role;

-- Service: a sync that failed (sign-in included), for the account screen.
create function public.record_broker_sync_error(p_profile_code text, p_provider text, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  update public.broker_connections set last_attempt_at = now(), last_status = 'error', last_error = left(p_error, 500)
  where profile_code = p_profile_code and provider = p_provider;
end;
$$;
grant execute on function public.record_broker_sync_error(text, text, text) to service_role;

-- Service: the term sheet for an ISIN was read once; the sync does not send it to the model again.
create function public.record_broker_terms_tried(p_account_code text, p_isin text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  update public.broker_connections set terms_tried = array_append(terms_tried, p_isin)
  where account_code = p_account_code and not (p_isin = any (terms_tried));
end;
$$;
grant execute on function public.record_broker_terms_tried(text, text) to service_role;

-- ── 4. the account screen ───────────────────────────────────────────────────
-- Member: a synced broker account (null when the account has no sync): cash, the latest marks
-- with what each position cost and has paid, and for a note what it fetches sold today against
-- what it pays if called at its next autocall date; positions that ended, with their result;
-- the value per day against the net deposits; and how the last sync went. Decimal strings.
create function public.broker_portfolio(p_profile_code text, p_account_code text)
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
        'awaiting_prices', (ev.e->>'awaiting_prices')::boolean) end) as j
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
comment on function public.broker_portfolio(text, text) is
  'Member: a synced broker account: cash, positions (value, cost, paid, sold-today and if-called-next for notes), ended positions with their result, the daily value against net deposits, and the last sync. Null when the account has no sync. Decimal strings.';
grant execute on function public.broker_portfolio(text, text) to authenticated, service_role;

-- ── 5. notes funded from a synced account; a note's market value ──────────
-- create_structured_note (20261027124257): on a synced account the broker's buys are the purchase
-- and the position's holding is adopted.
create or replace function public.create_structured_note(p_profile_code text, p_draft jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  t jsonb := p_draft->'terms';
  i jsonb := p_draft->'investment';
  a public.accounts;
  v_holding text;
  v_note text;
  v_name text := btrim(coalesce(p_draft->>'name', ''));
  v_currency text := upper(coalesce(t->>'currency', ''));
  v_denom numeric := (t->>'denomination')::numeric;
  v_issue numeric := (t->>'issue_price_pct')::numeric;
  v_strike date := (t->>'strike_date')::date;
  v_final date := (t->>'final_valuation_date')::date;
  v_maturity date := (t->>'maturity_date')::date;
  v_price numeric := coalesce(nullif(i->>'purchase_price_pct', '')::numeric, v_issue);
  v_invested numeric := nullif(i->>'invested_amount', '')::numeric;
  v_nominal numeric;
  v_trade date := coalesce(nullif(i->>'trade_date', '')::date, nullif(t->>'issue_date', '')::date, v_strike);
  v_account text := nullif(i->>'funding_account_code', '');
  v_txn text;
  v_bad int;
  v_isin text := nullif(upper(btrim(t->>'isin')), '');
  v_synced boolean;
  v_buy_amount numeric;
  v_buy_date date;
  v_buy_qty numeric;
  v_buy_price numeric;
begin
  perform private.assert_member(p_profile_code, true);
  if length(v_name) not between 1 and 80 then
    raise exception 'a note needs a name of 1–80 characters' using errcode = '22023';
  end if;
  if v_currency !~ '^[A-Z]{3}$' or v_denom is null or v_denom <= 0 or v_issue is null or v_issue <= 0
     or v_strike is null or v_final is null or v_maturity is null then
    raise exception 'terms need currency, denomination, issue price, strike, final valuation and maturity dates'
      using errcode = '22023';
  end if;
  -- Bought on an account a broker sync keeps: what was bought, when and at what price default to
  -- the broker's own buy rows for the ISIN (20261027165732).
  v_synced := v_account is not null and v_isin is not null and private.is_broker_account(p_profile_code, v_account);
  if v_synced then
    select sum(-bt.net_amount), min(public.dubai_date(bt.booked_at)), sum(bt.quantity),
           (array_agg(bt.unit_price order by bt.booked_at))[1]
      into v_buy_amount, v_buy_date, v_buy_qty, v_buy_price
    from public.broker_transactions bt
    where bt.account_code = v_account and bt.isin = v_isin and bt.kind = 'buy' and not bt.is_reversal;
    v_invested := coalesce(v_invested, v_buy_amount);
    if nullif(i->>'trade_date', '') is null and v_buy_date is not null then
      v_trade := v_buy_date;
    end if;
    if nullif(i->>'purchase_price_pct', '') is null and v_buy_price is not null then
      v_price := round(v_buy_price * 100, 5);
    end if;
    if nullif(i->>'nominal', '') is null and v_buy_qty is not null then
      i := i || jsonb_build_object('nominal', v_buy_qty::text);
    end if;
  end if;
  if v_invested is null or v_invested <= 0 or v_invested <> round(v_invested, 2) or v_price <= 0 then
    raise exception 'the amount invested must be positive with at most 2 decimals' using errcode = '22023';
  end if;
  v_nominal := coalesce(nullif(i->>'nominal', '')::numeric, round(v_invested / v_price * 100, 2));
  if v_nominal <= 0 then
    raise exception 'nominal must be positive' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(t->'underlyings', '[]')) not between 1 and 20 then
    raise exception 'a note has 1–20 underlyings' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(t->'payout', '[]')) = 0
     or not exists (select 1 from jsonb_array_elements(t->'payout') b where (b->>'min_worst_pct')::numeric = 0) then
    raise exception 'the final payout needs a branch from 0%% (what is paid however far the worst share falls)'
      using errcode = '22023';
  end if;
  select count(*) into v_bad from jsonb_array_elements(coalesce(t->'observations', '[]')) o
  where (o->>'obs_date')::date > v_final or (o->>'obs_date')::date < v_strike;
  if v_bad > 0 then
    raise exception 'every observation falls between the strike date and the final valuation' using errcode = '22023';
  end if;
  if v_account is not null then
    select * into a from public.accounts
    where account_code = v_account and profile_code = p_profile_code and kind in ('current', 'savings') and status = 'active';
    if not found then
      raise exception 'funding account not found' using errcode = 'P0002';
    end if;
    if a.currency <> v_currency then
      raise exception 'the funding account is in %, the note in %', a.currency, v_currency using errcode = '22023';
    end if;
  end if;

  -- A position the sync already holds (its ISIN) becomes the note's holding, keeping its flows
  -- and market values.
  if v_synced then
    select h.holding_code into v_holding from public.holdings h
    where h.profile_code = p_profile_code and h.external_ref = v_isin;
    if v_holding is not null and exists (select 1 from public.structured_notes x
                                         where x.holding_code = v_holding and x.status <> 'cancelled') then
      raise exception 'this ledger already has a note for %', v_isin using errcode = '23505';
    end if;
  end if;
  if v_holding is not null then
    update public.holdings set kind = 'structured_note', name = v_name, currency = v_currency, units = null, symbol = null,
      notes = coalesce(nullif(btrim(p_draft->>'notes'), ''), notes)
    where holding_code = v_holding;
  else
    insert into public.holdings (profile_code, name, kind, currency, institution, acquired_on, notes, created_by, external_ref)
    values (p_profile_code, v_name, 'structured_note', v_currency,
            coalesce(nullif(btrim(p_draft->>'institution'), ''), (select b.name from public.banks b where b.bank_code = a.bank_code)),
            v_trade, nullif(btrim(p_draft->>'notes'), ''), auth.uid(), case when v_synced then v_isin end)
    returning holding_code into v_holding;
  end if;

  insert into public.structured_notes (profile_code, holding_code, product_name, isin, issuer, guarantor, currency,
    denomination, issue_price_pct, strike_date, issue_date, final_valuation_date, maturity_date, trade_date, nominal,
    purchase_price_pct, invested_amount, funding_account_code, termsheet_path, termsheet_filename, extracted_terms, created_by)
  values (p_profile_code, v_holding, coalesce(nullif(btrim(t->>'product_name'), ''), v_name), nullif(upper(t->>'isin'), ''),
    nullif(btrim(t->>'issuer'), ''), nullif(btrim(t->>'guarantor'), ''), v_currency, v_denom, v_issue, v_strike,
    nullif(t->>'issue_date', '')::date, v_final, v_maturity, v_trade, v_nominal, v_price, v_invested, v_account,
    nullif(p_draft->>'termsheet_path', ''), nullif(p_draft->>'termsheet_filename', ''), p_draft->'extracted_terms', auth.uid())
  returning note_code into v_note;

  insert into public.structured_note_underlyings (profile_code, note_code, ordinal, name, symbol, bloomberg_code, isin,
                                                  exchange, initial_level)
  select p_profile_code, v_note, u.ord::int, btrim(u.x->>'name'), upper(btrim(u.x->>'symbol')),
         nullif(btrim(u.x->>'bloomberg_code'), ''), nullif(upper(u.x->>'isin'), ''), nullif(btrim(u.x->>'exchange'), ''),
         (u.x->>'initial_level')::numeric
  from jsonb_array_elements(t->'underlyings') with ordinality u(x, ord);

  insert into public.structured_note_observations (profile_code, note_code, seq, obs_date, pay_date, coupon_rate_pct,
    coupon_barrier_pct, coupon_memory, autocall_trigger_pct, autocall_amount_pct)
  select p_profile_code, v_note, row_number() over (order by (o->>'obs_date')::date)::int, (o->>'obs_date')::date,
         (o->>'pay_date')::date, nullif(o->>'coupon_rate_pct', '')::numeric, nullif(o->>'coupon_barrier_pct', '')::numeric,
         coalesce((o->>'coupon_memory')::boolean, false), nullif(o->>'autocall_trigger_pct', '')::numeric,
         nullif(o->>'autocall_amount_pct', '')::numeric
  from jsonb_array_elements(coalesce(t->'observations', '[]')) o;

  insert into public.structured_note_payout_branches (profile_code, note_code, min_worst_pct, intercept_pct, slope, settlement)
  select p_profile_code, v_note, (b->>'min_worst_pct')::numeric, (b->>'intercept_pct')::numeric, (b->>'slope')::numeric,
         coalesce(b->>'settlement', 'cash')
  from jsonb_array_elements(t->'payout') b;

  if v_synced then
    -- The broker's buy rows are the purchase, and the sync already linked them to the holding.
    update public.structured_notes set purchase_txn_code = (
      select bt.txn_code from public.broker_transactions bt
      where bt.account_code = v_account and bt.isin = v_isin and bt.kind = 'buy' and not bt.is_reversal
      order by bt.booked_at limit 1)
    where note_code = v_note;
  elsif v_account is not null then
    v_txn := private.evidence_txn(p_profile_code, v_account, 'transfer_out', 'debit', v_invested, v_currency, v_trade,
                                  'NOTE PURCHASE ' || coalesce(nullif(upper(t->>'isin'), ''), v_name));
    update public.structured_notes set purchase_txn_code = v_txn where note_code = v_note;
    -- The rule trigger may have linked it elsewhere; the note's own link wins.
    delete from public.holding_flows where txn_code = v_txn;
  end if;
  if not v_synced then
    insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code, source, created_by)
    values (p_profile_code, v_holding, v_trade, 'contribution', v_invested, private.to_aed(v_invested, v_currency), v_txn,
            'note', auth.uid());
  end if;

  perform private.settle_structured_note(v_note);
  return v_holding;
end;
$$;

-- settle_structured_note (20261027124257): on a synced account, link the broker's rows.
create or replace function private.settle_structured_note(p_note_code text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  n public.structured_notes;
  h public.holdings;
  v_today date := public.dubai_date(now());
  v_eval jsonb;
  e jsonb;
  ev public.structured_note_events;
  v_txn text;
  v_holding text;
  v_share_value numeric;
  v_synced boolean;
  v_redeemed date;
begin
  select * into n from public.structured_notes where note_code = p_note_code for update;
  if not found or n.status = 'cancelled' then
    return;
  end if;
  select * into h from public.holdings where holding_code = n.holding_code;
  v_eval := private.note_evaluate(n.note_code, v_today);
  -- Funded from an account a broker sync keeps: the broker's rows are the payments
  -- (20261027165732). Nothing is posted here; an event settles once its row has arrived.
  v_synced := n.funding_account_code is not null and n.isin is not null
              and private.is_broker_account(n.profile_code, n.funding_account_code);
  if v_synced then
    select min(public.dubai_date(bt.booked_at)) into v_redeemed from public.broker_transactions bt
    where bt.account_code = n.funding_account_code and bt.isin = n.isin and bt.kind = 'redemption';
  end if;

  for e in select x from jsonb_array_elements(v_eval->'events') x
           where x->>'kind' in ('coupon', 'autocall', 'maturity') loop
    insert into public.structured_note_events (profile_code, note_code, kind, seq, obs_date, pay_date, worst_pct,
      worst_symbol, rate_pct, amount, settlement, shares, share_price)
    values (n.profile_code, n.note_code, e->>'kind', (e->>'seq')::int, (e->>'obs_date')::date, (e->>'pay_date')::date,
      (e->>'worst_pct')::numeric, e->>'worst_symbol', (e->>'rate_pct')::numeric, (e->>'amount')::numeric,
      coalesce(e->>'settlement', 'cash'), (e->>'shares')::numeric, (e->>'share_price')::numeric)
    on conflict (note_code, kind, obs_date) do nothing;
  end loop;

  for ev in select * from public.structured_note_events x
            where x.note_code = n.note_code and x.settled_at is null and x.pay_date <= v_today
            order by x.pay_date, x.kind loop
    v_txn := null;
    if v_synced then
      if ev.amount > 0 then
        select bt.txn_code into v_txn from public.broker_transactions bt
        where bt.account_code = n.funding_account_code and bt.isin = n.isin and bt.txn_code is not null
          and bt.kind = case ev.kind when 'coupon' then 'coupon' else 'redemption' end
          and public.dubai_date(bt.booked_at) between ev.pay_date - 10 and ev.pay_date + 30
          and not exists (select 1 from public.structured_note_events x where x.txn_code = bt.txn_code)
        order by abs(public.dubai_date(bt.booked_at) - ev.pay_date), bt.booked_at
        limit 1;
        -- A coupon paid inside the redemption price (one row for both) settles with it.
        if v_txn is null and not (ev.kind = 'coupon' and v_redeemed is not null and v_redeemed >= ev.pay_date - 10) then
          continue;
        end if;
      end if;
      update public.structured_note_events set settled_at = now(), txn_code = v_txn where event_code = ev.event_code;
      continue;
    end if;
    if ev.amount > 0 and n.funding_account_code is not null then
      v_txn := private.evidence_txn(n.profile_code, n.funding_account_code, 'transfer_in', 'credit', ev.amount,
        n.currency, ev.pay_date,
        case ev.kind when 'coupon' then 'NOTE COUPON ' when 'autocall' then 'NOTE AUTOCALL ' else 'NOTE REDEMPTION ' end
        || coalesce(n.isin, h.name));
    end if;
    if ev.kind = 'coupon' then
      if ev.amount > 0 then
        insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source, notes)
        values (n.profile_code, n.holding_code, ev.pay_date, 'income', ev.amount, private.to_aed(ev.amount, n.currency),
                'note', 'coupon ' || ev.rate_pct::numeric(9,3) || '%');
      end if;
    else
      if ev.amount > 0 then
        insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code, source, notes)
        values (n.profile_code, n.holding_code, ev.pay_date, 'withdrawal', ev.amount, private.to_aed(ev.amount, n.currency),
                v_txn, 'note', ev.kind);
      end if;
      if ev.settlement = 'physical' and coalesce(ev.shares, 0) > 0 then
        v_share_value := round(ev.shares * ev.share_price, 2);
        insert into public.holdings (profile_code, name, kind, currency, institution, units, symbol, acquired_on, notes, created_by)
        values (n.profile_code, left(ev.worst_symbol || ' shares (from ' || h.name || ')', 80), 'security', n.currency,
                h.institution, ev.shares, ev.worst_symbol, ev.pay_date, 'Delivered at maturity of ' || coalesce(n.isin, h.name),
                n.created_by)
        returning holding_code into v_holding;
        insert into public.holding_valuations (profile_code, holding_code, as_of, unit_price, source)
        values (n.profile_code, v_holding, ev.obs_date, ev.share_price, 'import');
        insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source, notes)
        values (n.profile_code, n.holding_code, ev.pay_date, 'withdrawal', v_share_value,
                private.to_aed(v_share_value, n.currency), 'note', 'shares delivered'),
               (n.profile_code, v_holding, ev.pay_date, 'contribution', v_share_value,
                private.to_aed(v_share_value, n.currency), 'note', 'delivered by ' || coalesce(n.isin, h.name));
      end if;
    end if;
    update public.structured_note_events set settled_at = now(), txn_code = v_txn, delivered_holding_code = v_holding
    where event_code = ev.event_code;
    v_holding := null;
  end loop;

  if v_eval->>'status' in ('autocalled', 'matured') and (v_eval->>'ended_on')::date <= v_today then
    update public.structured_notes set status = v_eval->>'status', ended_on = (v_eval->>'ended_on')::date
    where note_code = n.note_code;
    update public.holdings set status = 'closed' where holding_code = n.holding_code and status = 'active';
  elsif v_synced and v_redeemed is not null then
    -- The broker redeemed it (before any close could tell): it ended that day.
    update public.structured_notes
    set status = case when v_redeemed >= n.final_valuation_date then 'matured' else 'autocalled' end, ended_on = v_redeemed
    where note_code = n.note_code and status = 'live';
    update public.holdings set status = 'closed' where holding_code = n.holding_code and status = 'active';
  end if;
end;
$$;

-- cancel_structured_note (20261027124257): a synced position stays.
create or replace function public.cancel_structured_note(p_profile_code text, p_holding_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.structured_notes;
  v_txn text;
  v_keep text;
begin
  perform private.assert_member(p_profile_code, true);
  select * into n from public.structured_notes where holding_code = p_holding_code and profile_code = p_profile_code;
  if not found then
    raise exception 'note not found' using errcode = 'P0002';
  end if;
  -- A synced position stays a position (20261027165732): the cancelled terms move to a closed
  -- holding of their own, and the broker's rows and flows are untouched.
  if exists (select 1 from public.broker_transactions bt where bt.holding_code = n.holding_code) then
    insert into public.holdings (profile_code, name, kind, currency, institution, acquired_on, status, notes, created_by)
    select h.profile_code, h.name, 'structured_note', h.currency, h.institution, h.acquired_on, 'closed',
           'Terms cancelled', auth.uid()
    from public.holdings h where h.holding_code = n.holding_code
    returning holding_code into v_keep;
    update public.structured_notes set status = 'cancelled', holding_code = v_keep where note_code = n.note_code;
    update public.holdings h set kind = 'broker',
      name = left(coalesce((select bt.security_name from public.broker_transactions bt
                            where bt.holding_code = h.holding_code and bt.security_name is not null
                            order by bt.booked_at limit 1), h.name), 80)
    where h.holding_code = n.holding_code;
    update public.structured_note_events set txn_code = null where note_code = n.note_code;
    return;
  end if;
  update public.structured_notes set status = 'cancelled' where note_code = n.note_code;
  update public.holdings set status = 'closed' where holding_code = n.holding_code;
  update public.holding_flows set removed_at = coalesce(removed_at, now()) where holding_code = n.holding_code;
  for v_txn in
    select n.purchase_txn_code where n.purchase_txn_code is not null
    union all select e.txn_code from public.structured_note_events e where e.note_code = n.note_code and e.txn_code is not null
  loop
    update public.transactions set voided_at = coalesce(voided_at, now()), void_reason = coalesce(void_reason, 'note_cancelled')
    where txn_code = v_txn;
    perform private.refresh_transaction(v_txn);
  end loop;
end;
$$;

-- note_summary (20261027124257): market value and the next call.
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

-- structured_note_detail (20261027124257): a note the broker ended shows no live figures.
create or replace function public.structured_note_detail(p_profile_code text, p_holding_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  n public.structured_notes;
  e jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  select * into n from public.structured_notes where holding_code = p_holding_code and profile_code = p_profile_code;
  if not found then
    raise exception 'note not found' using errcode = 'P0002';
  end if;
  e := private.note_evaluate(n.note_code, public.dubai_date(now()));
  -- Ended by the broker before its closes could tell (20261027165732): no live figures.
  if n.status in ('autocalled', 'matured') and coalesce(e->>'status', '') not in ('autocalled', 'matured') then
    e := e - 'levels' - 'scenarios' - 'next' - 'if_ended_today';
  end if;
  return private.jsonb_decimal_strings(private.note_summary(n, e) || jsonb_build_object(
    'terms', jsonb_build_object(
      'guarantor', n.guarantor, 'denomination', n.denomination::text, 'issue_price_pct', n.issue_price_pct::text,
      'strike_date', n.strike_date, 'issue_date', n.issue_date, 'final_valuation_date', n.final_valuation_date,
      'maturity_date', n.maturity_date, 'termsheet_path', n.termsheet_path, 'termsheet_filename', n.termsheet_filename),
    'observations', coalesce((
      select jsonb_agg(jsonb_build_object('seq', o.seq, 'obs_date', o.obs_date, 'pay_date', o.pay_date,
               'coupon_rate_pct', o.coupon_rate_pct::text, 'coupon_barrier_pct', o.coupon_barrier_pct::text,
               'coupon_memory', o.coupon_memory, 'autocall_trigger_pct', o.autocall_trigger_pct::text,
               'autocall_amount_pct', o.autocall_amount_pct::text) order by o.obs_date)
      from public.structured_note_observations o where o.note_code = n.note_code), '[]'::jsonb),
    'payout', coalesce((
      select jsonb_agg(jsonb_build_object('min_worst_pct', b.min_worst_pct::text, 'intercept_pct', b.intercept_pct::text,
               'slope', b.slope::text, 'settlement', b.settlement) order by b.min_worst_pct desc)
      from public.structured_note_payout_branches b where b.note_code = n.note_code), '[]'::jsonb),
    'memory_unpaid_pct', e->>'memory_unpaid_pct',
    'underlyings', e->'underlyings', 'levels', e->'levels', 'scenarios', e->'scenarios', 'outcomes', e->'events',
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('event_code', x.event_code, 'kind', x.kind, 'obs_date', x.obs_date,
               'pay_date', x.pay_date, 'rate_pct', x.rate_pct::text, 'amount', x.amount::text, 'settlement', x.settlement,
               'shares', x.shares::text, 'share_symbol', case when x.shares is not null then x.worst_symbol end,
               'txn_code', x.txn_code, 'delivered_holding_code', x.delivered_holding_code, 'settled', x.settled_at is not null)
             order by x.pay_date desc)
      from public.structured_note_events x where x.note_code = n.note_code), '[]'::jsonb),
    'series', coalesce((
      select jsonb_object_agg(s.symbol, s.points)
      from (
        select u.symbol, jsonb_agg(jsonb_build_array(sp.price_date, round(sp.close / u.initial_level * 100, 2)::text)
                                   order by sp.price_date) as points
        from public.structured_note_underlyings u
        join public.security_prices sp on sp.symbol = u.symbol and sp.price_date >= n.strike_date
             and sp.price_date <= coalesce(n.ended_on, public.dubai_date(now()))
        where u.note_code = n.note_code
        group by u.symbol
      ) s), '{}'::jsonb)));
end;
$$;

-- holding_values (20261027124257): a live note at its market value once it has one.
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
  where h.profile_code = p_profile_code and h.status = 'active'
$$;

-- note_evaluate (20261027124257): a coupon paid before the note was bought is the seller's.
create or replace function private.note_evaluate(p_note_code text, p_as_of date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  n public.structured_notes;
  o record;
  w record;
  wf record;
  pf record;
  v_status text := 'live';
  v_awaiting boolean := false;
  v_unpaid numeric := 0;
  v_rate numeric;
  v_amount numeric;
  v_events jsonb := '[]'::jsonb;
  v_ended date;
  v_last_obs date;
  v_coupons_paid numeric := 0;
  v_coupons_due numeric := 0;
  v_redemption_paid numeric := 0;
  v_redemption_due numeric := 0;
  v_now record;
  v_next record;
  v_next_ac record;
  v_next_cp record;
  v_be numeric;
  v_per_note numeric;
  v_whole numeric;
  v_result jsonb;
  v_today_payout record;
  v_unpaid_future numeric;
  v_cum numeric;
  v_rows jsonb := '[]'::jsonb;
  v_total numeric;
  v_days int;
  v_best numeric;
  v_best_row jsonb;
  v_curve jsonb := '[]'::jsonb;
  v_wp numeric;
begin
  select * into n from public.structured_notes where note_code = p_note_code;
  if not found then
    return null;
  end if;

  -- The past: coupons (with memory), an autocall, the final valuation.
  for o in select * from public.structured_note_observations x where x.note_code = n.note_code order by x.obs_date loop
    exit when o.obs_date > p_as_of;
    select * into w from private.note_worst(n.note_code, o.obs_date, 4);
    if not coalesce(w.priced, false) then
      v_awaiting := true;
      exit;
    end if;
    v_last_obs := o.obs_date;
    if o.coupon_rate_pct is not null then
      if w.worst_pct >= o.coupon_barrier_pct and o.pay_date <= n.trade_date then
        -- Paid before the note was bought (a purchase after issue): the seller's coupon. Memory
        -- still resets; nothing is counted or settled (20261027165732).
        v_unpaid := 0;
        v_events := v_events || jsonb_build_object('kind', 'coupon_before_purchase', 'seq', o.seq, 'obs_date', o.obs_date,
          'pay_date', o.pay_date, 'worst_pct', round(w.worst_pct, 4), 'worst_symbol', w.worst_symbol,
          'barrier_pct', o.coupon_barrier_pct, 'rate_pct', o.coupon_rate_pct);
      elsif w.worst_pct >= o.coupon_barrier_pct then
        v_rate := o.coupon_rate_pct + v_unpaid;
        v_unpaid := 0;
        v_amount := round(n.nominal * v_rate / 100, 2);
        v_events := v_events || jsonb_build_object('kind', 'coupon', 'seq', o.seq, 'obs_date', o.obs_date,
          'pay_date', o.pay_date, 'worst_pct', round(w.worst_pct, 4), 'worst_symbol', w.worst_symbol,
          'barrier_pct', o.coupon_barrier_pct, 'rate_pct', v_rate, 'amount', v_amount, 'paid', o.pay_date <= p_as_of);
        if o.pay_date <= p_as_of then v_coupons_paid := v_coupons_paid + v_amount;
        else v_coupons_due := v_coupons_due + v_amount; end if;
      else
        if o.coupon_memory then
          v_unpaid := v_unpaid + o.coupon_rate_pct;
        end if;
        v_events := v_events || jsonb_build_object('kind', 'coupon_missed', 'seq', o.seq, 'obs_date', o.obs_date,
          'pay_date', o.pay_date, 'worst_pct', round(w.worst_pct, 4), 'worst_symbol', w.worst_symbol,
          'barrier_pct', o.coupon_barrier_pct, 'rate_pct', o.coupon_rate_pct, 'memory', o.coupon_memory);
      end if;
    end if;
    if o.autocall_trigger_pct is not null then
      if w.worst_pct >= o.autocall_trigger_pct then
        v_amount := round(n.nominal * o.autocall_amount_pct / 100, 2);
        v_events := v_events || jsonb_build_object('kind', 'autocall', 'seq', o.seq, 'obs_date', o.obs_date,
          'pay_date', o.pay_date, 'worst_pct', round(w.worst_pct, 4), 'worst_symbol', w.worst_symbol,
          'trigger_pct', o.autocall_trigger_pct, 'rate_pct', o.autocall_amount_pct, 'amount', v_amount,
          'settlement', 'cash', 'paid', o.pay_date <= p_as_of);
        if o.pay_date <= p_as_of then v_redemption_paid := v_amount; else v_redemption_due := v_amount; end if;
        v_status := 'autocalled';
        v_ended := o.pay_date;
        exit;
      else
        v_events := v_events || jsonb_build_object('kind', 'autocall_missed', 'seq', o.seq, 'obs_date', o.obs_date,
          'pay_date', o.pay_date, 'worst_pct', round(w.worst_pct, 4), 'worst_symbol', w.worst_symbol,
          'trigger_pct', o.autocall_trigger_pct);
      end if;
    end if;
  end loop;

  if v_status = 'live' and not v_awaiting and n.final_valuation_date <= p_as_of then
    select * into wf from private.note_worst(n.note_code, n.final_valuation_date, 4);
    if coalesce(wf.priced, false) then
      select * into pf from private.note_payout(n.note_code, wf.worst_pct);
      if pf.settlement = 'physical' and pf.payout_pct > 0 then
        -- Shares per note, rounded down to whole shares; the fraction is paid in cash.
        v_per_note := n.denomination * pf.payout_pct / 100 / wf.worst_close;
        v_whole := floor(v_per_note);
        v_amount := round((v_per_note - v_whole) * wf.worst_close * (n.nominal / n.denomination), 2);
        v_whole := v_whole * (n.nominal / n.denomination);
      else
        v_whole := null;
        v_amount := round(n.nominal * pf.payout_pct / 100, 2);
      end if;
      v_events := v_events || jsonb_build_object('kind', 'maturity', 'seq', null, 'obs_date', n.final_valuation_date,
        'pay_date', n.maturity_date, 'worst_pct', round(wf.worst_pct, 4), 'worst_symbol', wf.worst_symbol,
        'rate_pct', round(pf.payout_pct, 5), 'amount', v_amount, 'settlement', pf.settlement,
        'shares', v_whole, 'share_price', case when v_whole is not null then wf.worst_close end,
        'share_value', case when v_whole is not null then round(v_whole * wf.worst_close, 2) end,
        'paid', n.maturity_date <= p_as_of);
      v_amount := round(n.nominal * pf.payout_pct / 100, 2);   -- cash + shares, at the final close
      if n.maturity_date <= p_as_of then v_redemption_paid := v_amount; else v_redemption_due := v_amount; end if;
      v_status := 'matured';
      v_ended := n.maturity_date;
    else
      v_awaiting := true;
    end if;
  end if;

  -- Today: the latest closes.
  select * into v_now from private.note_worst(n.note_code, p_as_of, 100000);
  select * into v_today_payout from private.note_payout(n.note_code, v_now.worst_pct);
  v_be := private.note_break_even(n.note_code, n.purchase_price_pct);

  -- The next observation still to come, and the next coupon and autocall levels.
  select * into v_next from public.structured_note_observations x
  where x.note_code = n.note_code and x.obs_date > coalesce(v_last_obs, n.strike_date - 1)
  order by x.obs_date limit 1;
  select * into v_next_ac from public.structured_note_observations x
  where x.note_code = n.note_code and x.obs_date > coalesce(v_last_obs, n.strike_date - 1) and x.autocall_trigger_pct is not null
  order by x.obs_date limit 1;
  select * into v_next_cp from public.structured_note_observations x
  where x.note_code = n.note_code and x.obs_date > coalesce(v_last_obs, n.strike_date - 1) and x.coupon_rate_pct is not null
  order by x.obs_date limit 1;

  -- Scenarios: called on each future autocall date (coupons up to it paid), and the final
  -- payout across worst performances.
  if v_status = 'live' then
    v_cum := 0;
    v_unpaid_future := v_unpaid;
    for o in select * from public.structured_note_observations x
             where x.note_code = n.note_code and x.obs_date > coalesce(v_last_obs, n.strike_date - 1)
             order by x.obs_date loop
      if o.coupon_rate_pct is not null then
        v_cum := v_cum + o.coupon_rate_pct + case when o.coupon_memory then v_unpaid_future else 0 end;
        if o.coupon_memory then v_unpaid_future := 0; end if;
      end if;
      if o.autocall_trigger_pct is not null then
        v_total := v_coupons_paid + v_coupons_due + round(n.nominal * v_cum / 100, 2)
                   + round(n.nominal * o.autocall_amount_pct / 100, 2);
        v_days := o.pay_date - n.trade_date;
        v_rows := v_rows || jsonb_build_object('obs_date', o.obs_date, 'pay_date', o.pay_date,
          'trigger_pct', o.autocall_trigger_pct, 'redemption_pct', o.autocall_amount_pct,
          'redemption', round(n.nominal * o.autocall_amount_pct / 100, 2),
          'coupons', round(v_coupons_paid + v_coupons_due + n.nominal * v_cum / 100, 2),
          'total', round(v_total, 2), 'profit', round(v_total - n.invested_amount, 2),
          'return_pct', round((v_total / n.invested_amount - 1) * 100, 2),
          'annualised_pct', case when v_days > 0 and v_total > 0
                                 then round((power(v_total / n.invested_amount, 365.0 / v_days) - 1) * 100, 2) end);
      end if;
    end loop;
    -- The coupons if every remaining one is paid (for the maturity "best case").
    v_cum := round(n.nominal * v_cum / 100, 2);
    v_wp := 0;
    while v_wp <= 150 loop
      select * into pf from private.note_payout(n.note_code, v_wp);
      v_curve := v_curve || jsonb_build_object('worst_pct', v_wp, 'payout_pct', round(pf.payout_pct, 4),
        'amount', round(n.nominal * pf.payout_pct / 100, 2), 'settlement', pf.settlement,
        'profit', round(n.nominal * pf.payout_pct / 100 + v_coupons_paid + v_coupons_due - n.invested_amount, 2));
      v_wp := v_wp + 5;
    end loop;
    select max((r->>'total')::numeric) into v_best from jsonb_array_elements(v_rows) r;
    select pf2.payout_pct into v_rate from private.note_payout(n.note_code, 1000000) pf2;
    v_total := round(n.nominal * v_rate / 100, 2) + v_coupons_paid + v_coupons_due + v_cum;
    if v_best is null or v_total > v_best then
      v_best := v_total;
      v_best_row := jsonb_build_object('when', 'maturity', 'date', n.maturity_date);
    else
      select jsonb_build_object('when', 'autocall', 'date', r->>'pay_date') into v_best_row
      from jsonb_array_elements(v_rows) r where (r->>'total')::numeric = v_best limit 1;
    end if;
  end if;

  v_result := jsonb_build_object(
    'as_of', p_as_of,
    'status', case when v_status = 'live' and p_as_of < n.strike_date then 'awaiting_strike' else v_status end,
    'awaiting_prices', v_awaiting,
    'ended_on', v_ended,
    'currency', n.currency,
    'nominal', n.nominal::text,
    'invested', n.invested_amount::text,
    'received', jsonb_build_object(
      'coupons', v_coupons_paid::numeric(14,2)::text, 'redemption', v_redemption_paid::numeric(14,2)::text,
      'total', (v_coupons_paid + v_redemption_paid)::numeric(14,2)::text),
    'due', jsonb_build_object(
      'coupons', v_coupons_due::numeric(14,2)::text, 'redemption', v_redemption_due::numeric(14,2)::text,
      'total', (v_coupons_due + v_redemption_due)::numeric(14,2)::text),
    'result', case when v_status in ('autocalled', 'matured') then jsonb_build_object(
      'total', (v_coupons_paid + v_coupons_due + v_redemption_paid + v_redemption_due)::numeric(14,2)::text,
      'profit', (v_coupons_paid + v_coupons_due + v_redemption_paid + v_redemption_due - n.invested_amount)::numeric(14,2)::text,
      'return_pct', round(((v_coupons_paid + v_coupons_due + v_redemption_paid + v_redemption_due) / n.invested_amount - 1) * 100, 2)::text)
      end,
    'memory_unpaid_pct', v_unpaid::text,
    'break_even_pct', v_be::text,
    'worst_now', case when v_now.worst_pct is not null then jsonb_build_object(
      'pct', round(v_now.worst_pct, 4)::text, 'symbol', v_now.worst_symbol, 'priced', v_now.priced) end,
    'underlyings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'symbol', u.symbol, 'name', u.name, 'bloomberg_code', u.bloomberg_code,
               'initial', u.initial_level::text, 'close', c.close::text, 'close_date', c.price_date,
               'perf_pct', round(c.close / u.initial_level * 100, 4)::text,
               'is_worst', u.symbol = v_now.worst_symbol,
               'to_autocall_pct', case when c.close is not null and v_next_ac.autocall_trigger_pct is not null
                 then round((v_next_ac.autocall_trigger_pct * u.initial_level / 100 / c.close - 1) * 100, 2)::text end,
               'to_coupon_pct', case when c.close is not null and v_next_cp.coupon_barrier_pct is not null
                 then round((v_next_cp.coupon_barrier_pct * u.initial_level / 100 / c.close - 1) * 100, 2)::text end,
               'to_break_even_pct', case when c.close is not null and v_be is not null
                 then round((v_be * u.initial_level / 100 / c.close - 1) * 100, 2)::text end,
               'autocall_level', case when v_next_ac.autocall_trigger_pct is not null
                 then round(v_next_ac.autocall_trigger_pct * u.initial_level / 100, 4)::text end,
               'coupon_level', case when v_next_cp.coupon_barrier_pct is not null
                 then round(v_next_cp.coupon_barrier_pct * u.initial_level / 100, 4)::text end,
               'break_even_level', case when v_be is not null then round(v_be * u.initial_level / 100, 4)::text end)
             order by u.ordinal)
      from public.structured_note_underlyings u
      left join lateral private.security_close(u.symbol, p_as_of, 100000) c on true
      where u.note_code = n.note_code), '[]'::jsonb),
    -- The worst share against each level that matters: next autocall, next coupon barrier,
    -- the final branches and break-even.
    'levels', case when v_status = 'live' and v_now.worst_pct is not null then (
      select coalesce(jsonb_agg(x.l order by (x.l->>'pct')::numeric desc), '[]'::jsonb) from (
        select jsonb_build_object('kind', 'autocall', 'pct', v_next_ac.autocall_trigger_pct::text,
                                  'date', v_next_ac.obs_date,
                                  'distance_pct', round((v_next_ac.autocall_trigger_pct / v_now.worst_pct - 1) * 100, 2)::text) as l
        where v_next_ac.autocall_trigger_pct is not null
        union all
        select jsonb_build_object('kind', 'coupon', 'pct', v_next_cp.coupon_barrier_pct::text, 'date', v_next_cp.obs_date,
                                  'distance_pct', round((v_next_cp.coupon_barrier_pct / v_now.worst_pct - 1) * 100, 2)::text)
        where v_next_cp.coupon_barrier_pct is not null and v_next_cp.coupon_barrier_pct > 0
        union all
        select jsonb_build_object('kind', 'final', 'pct', b.min_worst_pct::text, 'date', n.final_valuation_date,
                                  'payout_pct', round(b.intercept_pct + b.slope * b.min_worst_pct, 4)::text,
                                  'settlement', b.settlement,
                                  'distance_pct', round((b.min_worst_pct / v_now.worst_pct - 1) * 100, 2)::text)
        from public.structured_note_payout_branches b where b.note_code = n.note_code and b.min_worst_pct > 0
        union all
        select jsonb_build_object('kind', 'break_even', 'pct', v_be::text, 'date', n.final_valuation_date,
                                  'distance_pct', round((v_be / v_now.worst_pct - 1) * 100, 2)::text)
        where v_be is not null and v_be > 0
      ) x) end,
    'next', case when v_status = 'live' and v_next.obs_date is not null then jsonb_build_object(
      'kind', 'observation', 'seq', v_next.seq, 'obs_date', v_next.obs_date, 'pay_date', v_next.pay_date,
      'days', v_next.obs_date - p_as_of, 'is_final', v_next.obs_date = n.final_valuation_date,
      'coupon', case when v_next.coupon_rate_pct is not null then jsonb_build_object(
        'rate_pct', (v_next.coupon_rate_pct + case when v_next.coupon_memory then v_unpaid else 0 end)::text,
        'barrier_pct', v_next.coupon_barrier_pct::text,
        'amount', round(n.nominal * (v_next.coupon_rate_pct + case when v_next.coupon_memory then v_unpaid else 0 end) / 100, 2)::text,
        'would_pay', v_now.worst_pct >= v_next.coupon_barrier_pct) end,
      'autocall', case when v_next.autocall_trigger_pct is not null then jsonb_build_object(
        'trigger_pct', v_next.autocall_trigger_pct::text, 'redemption_pct', v_next.autocall_amount_pct::text,
        'amount', round(n.nominal * v_next.autocall_amount_pct / 100, 2)::text,
        'would_call', v_now.worst_pct >= v_next.autocall_trigger_pct) end)
      when v_status = 'live' and n.final_valuation_date >= p_as_of then jsonb_build_object(
      'kind', 'final', 'obs_date', n.final_valuation_date, 'pay_date', n.maturity_date,
      'days', n.final_valuation_date - p_as_of, 'is_final', true) end,
    'if_ended_today', case when v_status = 'live' and v_today_payout.payout_pct is not null then jsonb_build_object(
      'payout_pct', round(v_today_payout.payout_pct, 4)::text, 'settlement', v_today_payout.settlement,
      'amount', round(n.nominal * v_today_payout.payout_pct / 100, 2)::text,
      'total', round(n.nominal * v_today_payout.payout_pct / 100 + v_coupons_paid + v_coupons_due, 2)::text,
      'profit', round(n.nominal * v_today_payout.payout_pct / 100 + v_coupons_paid + v_coupons_due - n.invested_amount, 2)::text) end,
    'scenarios', case when v_status = 'live' then jsonb_build_object(
      'autocall', v_rows,
      'maturity', v_curve,
      'remaining_coupons', v_cum::text,
      'best', jsonb_build_object('total', v_best::numeric(14,2)::text,
                                 'profit', (v_best - n.invested_amount)::numeric(14,2)::text) || coalesce(v_best_row, '{}'::jsonb),
      'worst', (select jsonb_build_object(
                  'total', round(n.nominal * p0.payout_pct / 100 + v_coupons_paid + v_coupons_due, 2)::text,
                  'profit', round(n.nominal * p0.payout_pct / 100 + v_coupons_paid + v_coupons_due - n.invested_amount, 2)::text)
                from private.note_payout(n.note_code, 0) p0)) end,
    'events', v_events);
  return private.jsonb_decimal_strings(v_result);
end;
$$;

-- ── 6. seed rules: what a broker account earns and pays ─────────────────────
insert into private.seed_rules (category_name, pattern, match_type, conditions)
select v.category_name, v.pattern, v.match_type, v.conditions::jsonb
from (values ('Dividends', 'DIVIDEND ', 'prefix', '{"kind":"transfer_in","bank_code":"SWQ"}'),
             ('Investment income', 'DEPOSIT INTEREST', 'exact', '{"kind":"transfer_in","bank_code":"SWQ"}'),
             ('Bank Fees & Interest', 'SWISSQUOTE CUSTODY FEE', 'exact', '{}')) v(category_name, pattern, match_type, conditions)
where not exists (select 1 from private.seed_rules r where r.category_name = v.category_name and r.pattern = v.pattern);

insert into public.category_rules (profile_code, category_code, name, match_type, pattern, conditions, source)
select c.profile_code, c.category_code, 'seed: ' || btrim(v.pattern) || ' (Swissquote)', v.match_type, v.pattern,
       v.conditions::jsonb, 'seed'
from (values ('Dividends', 'DIVIDEND ', 'prefix', '{"kind":"transfer_in","bank_code":"SWQ"}'),
             ('Investment income', 'DEPOSIT INTEREST', 'exact', '{"kind":"transfer_in","bank_code":"SWQ"}'),
             ('Bank Fees & Interest', 'SWISSQUOTE CUSTODY FEE', 'exact', '{}')) v(category_name, pattern, match_type, conditions)
join public.categories c on c.name = v.category_name
where not exists (select 1 from public.category_rules r
                  where r.profile_code = c.profile_code and upper(r.pattern) = upper(v.pattern));

-- ── 7. nightly sync (01:30 Dubai, after the US close) ───────────────────────
select cron.schedule('ledger-swissquote-sync', '30 21 * * *', $$select private.invoke_edge('swissquote-sync')$$);

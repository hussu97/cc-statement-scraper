-- Structured notes held at a broker (Swissquote first), and the broker's cash account.
--
-- 1. Swissquote (SWQ) is a bank: its cash is an ordinary `current` account in USD. A non-AED
--    bank account now counts in cash and net worth (v_bank_balances.balance_aed through
--    private.to_aed; it used to be null outside AED).
-- 2. account_entries: a deposit or withdrawal typed by the user on a bank account (evidence; its
--    transaction is derived from it). For an account no SMS or statement reaches.
-- 3. A structured note is a holding (kind structured_note) plus its terms: underlyings with the
--    initial level, the observation schedule (coupon rate, barrier and memory; autocall trigger
--    and amount) and the final payout as branches on the worst performance WP (in % of the
--    initial level): the highest branch with min_worst_pct <= WP pays
--    greatest(0, intercept_pct + slope * WP) % of the nominal, in cash or in shares of the worst
--    underlying worth that much. Every worst-of autocallable we hold fits (Marex, BBVA, BNP).
--    Terms come from a term sheet the termsheet-extract function reads, reviewed by the user.
-- 4. security_prices: daily closes (reference data, filled by the stock-prices function).
-- 5. private.note_evaluate walks the schedule against the closes: coupons (with memory),
--    autocall, the final payout; and from today's prices: how far the worst stock is from each
--    barrier, what the next observation would do, what the note pays if it ended today, and the
--    autocall / maturity scenarios. structured_note_events keep each determined outcome;
--    private.settle_structured_notes posts them to the funding account on their payment date
--    (a coupon is income, a redemption is money back out of the holding) and closes the
--    holding when it ends. Physical delivery becomes a `security` holding of the shares.
-- 6. A live note is worth what was invested (decision of 27 Oct): holding_values. A security
--    with a symbol is priced from security_prices when that is newer than the price entered.
-- Money crosses the wire as decimal strings (§1.3); every figure is computed here (§2.2).

-- ── 1. Swissquote, USD cash ─────────────────────────────────────────────────
-- The logo is Swissquote's own icon (assets/banks/SWQ.png), uploaded with
-- scripts/brand/upload-bank-logos.sh.
insert into public.banks (bank_code, name, sms_senders, logo_path)
values ('SWQ', 'Swissquote', '{}', 'SWQ.png')
on conflict (bank_code) do nothing;

-- Every bank carries an FX markup (05_fx_rates). The Swissquote account holds USD and has no
-- card, so nothing is estimated with it; 0.95% is Swissquote's standard currency-exchange margin.
insert into private.bank_fx_fees (bank_code, markup, note)
values ('SWQ', 0.009500, 'no card in the ledger: USD cash only; 0.95% standard Swissquote FX margin')
on conflict (bank_code) do nothing;

create or replace view public.v_bank_balances with (security_invoker = true) as
select a.profile_code, a.account_code, a.bank_code, a.kind, a.currency,
       c.checkpoint_code, c.as_of, c.source as anchor_source, c.balance as anchor_balance,
       (c.balance + coalesce(x.activity, 0))::numeric(14,2) as balance,
       private.to_aed(c.balance + coalesce(x.activity, 0), a.currency) as balance_aed,
       coalesce(x.unpriced_count, 0)::int as unpriced_count,
       coalesce(c.as_of < now() - interval '7 days', false) as is_stale
from public.accounts a
left join lateral (
  select bc.checkpoint_code, bc.as_of, bc.source, bc.balance
  from public.balance_checkpoints bc
  where bc.account_code = a.account_code
  order by bc.as_of desc, bc.created_at desc
  limit 1
) c on true
left join lateral (
  select sum(case when t.direction = 'credit' then v.amt else -v.amt end) as activity,
         count(*) filter (where v.amt is null) as unpriced_count
  from public.transactions t
  cross join lateral (select case when a.currency = 'AED' then t.amount_aed
                                  when t.currency_original = a.currency then t.amount_original end as amt) v
  where t.account_code = a.account_code and t.status in ('pending', 'posted')
    and c.as_of is not null and coalesce(t.txn_at, t.txn_date::timestamptz) > c.as_of
) x on true
where a.kind in ('current', 'savings');
comment on view public.v_bank_balances is
  'A bank account''s balance: latest balance_checkpoints row plus its transactions after it; balance_aed for any currency (USD at the peg, others at fx_rates). Cards are v_account_balances.';

-- ── 2. account_entries ──────────────────────────────────────────────────────
create table public.account_entries (
  entry_code text primary key default public.gen_code('aen')
    check (entry_code ~ '^aen_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null,
  entry_date date not null,
  direction text not null check (direction in ('credit', 'debit')),
  amount numeric(14,2) not null check (amount > 0),          -- in the account's currency
  description text not null check (length(btrim(description)) between 1 and 80),
  txn_code text references public.transactions(txn_code) on delete set null,
  removed_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint account_entries_account_fkey foreign key (profile_code, account_code)
    references public.accounts(profile_code, account_code) on delete cascade
);
create index account_entries_account_idx on public.account_entries(account_code, entry_date);
create index account_entries_profile_idx on public.account_entries(profile_code);
create unique index account_entries_txn_uq on public.account_entries(txn_code) where txn_code is not null;
comment on table public.account_entries is
  'A deposit or withdrawal the user typed on a bank account no SMS or statement reaches (Swissquote cash). Evidence: its transaction is derived from it; removing it voids the transaction.';
alter table public.account_entries enable row level security;
create policy account_entries_member_read on public.account_entries for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.account_entries to authenticated;
grant all on public.account_entries to service_role;

-- ── 3. holdings.kind structured_note; note terms ────────────────────────────
alter table public.holdings drop constraint holdings_kind_check;
alter table public.holdings add constraint holdings_kind_check
  check (kind in ('metal', 'plan', 'broker', 'security', 'deposit', 'structured_note'));

alter table public.holding_flows drop constraint holding_flows_source_check;
alter table public.holding_flows add constraint holding_flows_source_check
  check (source in ('manual', 'rule', 'link', 'holding_cost', 'import', 'note'));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('term-sheets', 'term-sheets', false, 26214400, array['application/pdf'])
on conflict (id) do nothing;

-- Objects live at `<profile_code>/<sha256>.pdf`; only termsheet-extract writes them.
create policy term_sheets_bucket_member_read on storage.objects for select to authenticated
  using (
    bucket_id = 'term-sheets'
    and (storage.foldername(name))[1] = any ((select authz.my_profile_codes())::text[])
  );

create table public.structured_notes (
  note_code text primary key default public.gen_code('snt')
    check (note_code ~ '^snt_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  holding_code text not null,
  product_name text not null check (length(btrim(product_name)) between 1 and 300),
  isin text check (isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'),
  issuer text check (length(issuer) <= 120),
  guarantor text check (length(guarantor) <= 120),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  denomination numeric(14,2) not null check (denomination > 0),
  issue_price_pct numeric(9,5) not null check (issue_price_pct > 0),
  strike_date date not null,
  issue_date date,
  final_valuation_date date not null,
  maturity_date date not null,
  -- What was bought: nominal at a price (% of nominal) on the trade date; the money left the
  -- funding account (null: not tracked in the ledger).
  trade_date date not null,
  nominal numeric(14,2) not null check (nominal > 0),
  purchase_price_pct numeric(9,5) not null check (purchase_price_pct > 0),
  invested_amount numeric(14,2) not null check (invested_amount > 0),
  funding_account_code text,
  purchase_txn_code text references public.transactions(txn_code) on delete set null,
  termsheet_path text,
  termsheet_filename text check (length(termsheet_filename) <= 200),
  extracted_terms jsonb,                    -- what the model read, kept for audit; never used
  status text not null default 'live' check (status in ('live', 'autocalled', 'matured', 'cancelled')),
  ended_on date,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint structured_notes_profile_note_uq unique (profile_code, note_code),
  constraint structured_notes_holding_uq unique (holding_code),
  constraint structured_notes_holding_fkey foreign key (profile_code, holding_code)
    references public.holdings(profile_code, holding_code) on delete cascade,
  constraint structured_notes_account_fkey foreign key (profile_code, funding_account_code)
    references public.accounts(profile_code, account_code),
  constraint structured_notes_dates_check check (
    strike_date <= final_valuation_date and final_valuation_date <= maturity_date
    and (issue_date is null or issue_date >= strike_date))
);
create index structured_notes_profile_idx on public.structured_notes(profile_code, status);
comment on table public.structured_notes is
  'A structured note''s terms and what was bought (nominal, price, amount, funding account). One per holding of kind structured_note. Evaluated by private.note_evaluate.';
create trigger structured_notes_touch before update on public.structured_notes
  for each row execute function private.touch_updated_at();

create table public.structured_note_underlyings (
  underlying_code text primary key default public.gen_code('snu')
    check (underlying_code ~ '^snu_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  note_code text not null,
  ordinal int not null check (ordinal between 1 and 20),
  name text not null check (length(btrim(name)) between 1 and 120),
  symbol text not null check (symbol ~ '^[A-Z0-9^][A-Z0-9.^=-]{0,19}$'),   -- the price feed's ticker
  bloomberg_code text check (length(bloomberg_code) <= 40),
  isin text check (isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'),
  exchange text check (length(exchange) <= 80),
  initial_level numeric(18,6) not null check (initial_level > 0),
  constraint structured_note_underlyings_note_fkey foreign key (profile_code, note_code)
    references public.structured_notes(profile_code, note_code) on delete cascade,
  unique (note_code, ordinal),
  unique (note_code, symbol)
);
create index structured_note_underlyings_symbol_idx on public.structured_note_underlyings(symbol);

create table public.structured_note_observations (
  observation_code text primary key default public.gen_code('sno')
    check (observation_code ~ '^sno_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  note_code text not null,
  seq int not null check (seq >= 1),
  obs_date date not null,
  pay_date date not null,
  coupon_rate_pct numeric(9,5) check (coupon_rate_pct >= 0),
  coupon_barrier_pct numeric(9,5) check (coupon_barrier_pct >= 0),
  coupon_memory boolean not null default false,
  autocall_trigger_pct numeric(9,5) check (autocall_trigger_pct > 0),
  autocall_amount_pct numeric(9,5) check (autocall_amount_pct >= 0),
  constraint structured_note_observations_note_fkey foreign key (profile_code, note_code)
    references public.structured_notes(profile_code, note_code) on delete cascade,
  constraint structured_note_observations_shape_check check (
    pay_date >= obs_date
    and (coupon_rate_pct is null) = (coupon_barrier_pct is null)
    and (coupon_rate_pct is not null or not coupon_memory)
    and (autocall_trigger_pct is null) = (autocall_amount_pct is null)
    and (coupon_rate_pct is not null or autocall_trigger_pct is not null)),
  unique (note_code, seq),
  unique (note_code, obs_date)
);

create table public.structured_note_payout_branches (
  branch_code text primary key default public.gen_code('snb')
    check (branch_code ~ '^snb_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  note_code text not null,
  min_worst_pct numeric(9,5) not null check (min_worst_pct >= 0),
  intercept_pct numeric(9,5) not null,
  slope numeric(12,8) not null check (slope >= 0),
  settlement text not null check (settlement in ('cash', 'physical')),
  constraint structured_note_payout_branches_note_fkey foreign key (profile_code, note_code)
    references public.structured_notes(profile_code, note_code) on delete cascade,
  unique (note_code, min_worst_pct)
);
comment on table public.structured_note_payout_branches is
  'At the final valuation, the branch with the highest min_worst_pct <= the worst performance (% of initial) pays greatest(0, intercept_pct + slope * WP) % of the nominal, in cash or in shares of the worst underlying worth that.';

create table public.structured_note_events (
  event_code text primary key default public.gen_code('sne')
    check (event_code ~ '^sne_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  note_code text not null,
  kind text not null check (kind in ('coupon', 'autocall', 'maturity')),
  seq int,                                   -- the observation; null for the final valuation
  obs_date date not null,
  pay_date date not null,
  worst_pct numeric(9,5) not null,
  worst_symbol text not null,
  rate_pct numeric(9,5) not null,            -- % of nominal: coupon (with memory) or redemption
  amount numeric(14,2) not null check (amount >= 0),   -- cash, in the note's currency
  settlement text not null default 'cash' check (settlement in ('cash', 'physical')),
  shares numeric(18,6) check (shares >= 0),  -- physical delivery: whole shares of worst_symbol
  share_price numeric(18,6),                 -- the final close they are valued at
  txn_code text references public.transactions(txn_code) on delete set null,
  delivered_holding_code text,
  settled_at timestamptz,
  created_at timestamptz not null default now(),
  constraint structured_note_events_note_fkey foreign key (profile_code, note_code)
    references public.structured_notes(profile_code, note_code) on delete cascade,
  unique (note_code, kind, obs_date)
);
create unique index structured_note_events_txn_uq on public.structured_note_events(txn_code) where txn_code is not null;
comment on table public.structured_note_events is
  'What a note paid, once its observation is determined from the closes: a coupon, an autocall or the final redemption (cash, or shares plus a cash residual). settled_at: posted to the funding account on pay_date.';

create table public.security_prices (
  price_code text primary key default public.gen_code('spx')
    check (price_code ~ '^spx_[0-9a-z]{26}$'),
  symbol text not null check (symbol ~ '^[A-Z0-9^][A-Z0-9.^=-]{0,19}$'),
  price_date date not null,
  close numeric(18,6) not null check (close > 0),
  currency text check (currency ~ '^[A-Z]{3}$'),
  source text not null check (source in ('yahoo', 'manual')),
  fetched_at timestamptz not null default now(),
  unique (symbol, price_date)
);
comment on table public.security_prices is
  'Daily official closes of a share (reference data; the stock-prices function keeps the symbols of notes and delivered shares).';
alter table public.security_prices enable row level security;
create policy security_prices_read on public.security_prices for select to authenticated using (true);
grant select on public.security_prices to authenticated;
grant all on public.security_prices to service_role;

do $$
declare
  t text;
begin
  foreach t in array array['structured_notes', 'structured_note_underlyings', 'structured_note_observations',
                           'structured_note_payout_branches', 'structured_note_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated
                      using (profile_code = any ((select authz.my_profile_codes())::text[]))', t || '_member_read', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('create index %I on public.%I(profile_code)', t || '_profile_code_idx', t);
  end loop;
end;
$$;

-- Coupons are income: a category every ledger gets, and the rule that files them.
insert into private.seed_categories (name, kind, sort_order, color_token)
select 'Investment income', 'income', 156, 'cat-5'
where not exists (select 1 from private.seed_categories where name = 'Investment income');

insert into public.categories (profile_code, name, kind, sort_order, color_token)
select p.profile_code, 'Investment income', 'income', 156, 'cat-5'
from public.profiles p
where exists (select 1 from public.categories c where c.profile_code = p.profile_code)
  and not exists (select 1 from public.categories c where c.profile_code = p.profile_code
                  and lower(c.name) = 'investment income');

insert into private.seed_rules (category_name, pattern, match_type, conditions)
select 'Investment income', 'NOTE COUPON ', 'prefix', '{"kind":"transfer_in"}'::jsonb
where not exists (select 1 from private.seed_rules where category_name = 'Investment income' and pattern = 'NOTE COUPON ');

insert into public.category_rules (profile_code, category_code, name, match_type, pattern, conditions, source)
select c.profile_code, c.category_code, 'seed: NOTE COUPON (structured notes)', 'prefix', 'NOTE COUPON ',
       '{"kind":"transfer_in"}'::jsonb, 'seed'
from public.categories c
where c.name = 'Investment income' and c.kind = 'income'
  and not exists (select 1 from public.category_rules r
                  where r.profile_code = c.profile_code and upper(r.pattern) = 'NOTE COUPON ');

-- ── 4. transactions from typed evidence ─────────────────────────────────────
-- refresh_transaction (20261020170933) gains one branch: a transaction made from an account
-- entry or a note event stands while that evidence does (it used to fall through to orphaned).
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
     or exists (select 1 from public.structured_notes x where x.purchase_txn_code = t.txn_code) then
    -- Typed evidence (20261027124257): a deposit the user entered, or a note's purchase or
    -- payment. Its facts were set from that evidence; it stands until voided.
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

-- A transaction from typed evidence: in the account's currency, AED at the peg or fx_rates.
create function private.evidence_txn(p_profile text, p_account text, p_kind text, p_direction text,
                                     p_amount numeric, p_currency text, p_day date, p_description text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_txn text;
  v_aed numeric := private.to_aed(p_amount, p_currency);
begin
  insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description,
    merchant_code, amount_original, currency_original, amount_aed, amount_aed_is_estimate, amount_source, status)
  values (p_profile, p_account, p_kind, p_direction, p_day, upper(p_description),
    private.resolve_merchant(upper(p_description)), p_amount, p_currency, v_aed,
    p_currency not in ('AED', 'USD') and v_aed is not null, 'manual', 'posted')
  returning txn_code into v_txn;
  return v_txn;
end;
$$;

-- Owner: a deposit (credit) or withdrawal (debit) on a bank account, in its currency.
create function public.add_account_entry(p_profile_code text, p_account_code text, p_direction text,
                                         p_amount text, p_entry_date date, p_description text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.accounts;
  v_amount numeric;
  v_code text;
  v_txn text;
  v_desc text;
begin
  perform private.assert_member(p_profile_code, true);
  select * into a from public.accounts
  where account_code = p_account_code and profile_code = p_profile_code and kind in ('current', 'savings');
  if not found then
    raise exception 'bank account not found' using errcode = 'P0002';
  end if;
  if p_direction not in ('credit', 'debit') then
    raise exception 'an entry is a credit (deposit) or a debit (withdrawal)' using errcode = '22023';
  end if;
  v_amount := nullif(btrim(p_amount), '')::numeric;
  if v_amount is null or v_amount <= 0 or v_amount <> round(v_amount, 2) then
    raise exception 'amount must be positive with at most 2 decimals' using errcode = '22023';
  end if;
  if p_entry_date is null or p_entry_date > public.dubai_date(now()) then
    raise exception 'an entry is dated today or earlier' using errcode = '22023';
  end if;
  v_desc := coalesce(nullif(btrim(p_description), ''), case p_direction when 'credit' then 'Deposit' else 'Withdrawal' end);
  if length(v_desc) > 80 then
    raise exception 'description is at most 80 characters' using errcode = '22023';
  end if;
  v_txn := private.evidence_txn(p_profile_code, p_account_code,
                                case p_direction when 'credit' then 'transfer_in' else 'transfer_out' end,
                                p_direction, v_amount, a.currency, p_entry_date, v_desc);
  insert into public.account_entries (profile_code, account_code, entry_date, direction, amount, description,
                                      txn_code, created_by)
  values (p_profile_code, p_account_code, p_entry_date, p_direction, v_amount, v_desc, v_txn, auth.uid())
  returning entry_code into v_code;
  return v_code;
end;
$$;
comment on function public.add_account_entry(text, text, text, text, date, text) is
  'Owner: a deposit (credit) or withdrawal (debit) typed on a bank account, in its currency; posts its transaction. Returns entry_code.';
grant execute on function public.add_account_entry(text, text, text, text, date, text) to authenticated, service_role;

create function public.remove_account_entry(p_profile_code text, p_entry_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.account_entries;
begin
  perform private.assert_member(p_profile_code, true);
  select * into e from public.account_entries where entry_code = p_entry_code and profile_code = p_profile_code;
  if not found then
    raise exception 'entry not found' using errcode = 'P0002';
  end if;
  update public.account_entries set removed_at = coalesce(removed_at, now()) where entry_code = e.entry_code;
  update public.transactions set voided_at = coalesce(voided_at, now()), void_reason = coalesce(void_reason, 'entry_removed')
  where txn_code = e.txn_code;
  perform private.refresh_transaction(e.txn_code);
end;
$$;
grant execute on function public.remove_account_entry(text, text) to authenticated, service_role;

-- ── 5. evaluation ───────────────────────────────────────────────────────────
-- A symbol's close on a day, or the latest within p_window days before it (an observation on an
-- exchange holiday; a large window = "the latest close").
create function private.security_close(p_symbol text, p_day date, p_window int)
returns table (close numeric, price_date date)
language sql
stable
set search_path = ''
as $$
  select sp.close, sp.price_date from public.security_prices sp
  where sp.symbol = p_symbol and sp.price_date <= p_day and sp.price_date >= p_day - p_window
  order by sp.price_date desc
  limit 1
$$;

-- The worst performance of a note's underlyings on a day (% of initial), its symbol and close,
-- and whether every underlying had a close.
create function private.note_worst(p_note_code text, p_day date, p_window int)
returns table (worst_pct numeric, worst_symbol text, worst_close numeric, priced boolean)
language sql
stable
set search_path = ''
as $$
  select (array_agg(x.perf order by x.perf))[1], (array_agg(x.symbol order by x.perf))[1],
         (array_agg(x.close order by x.perf))[1], bool_and(x.close is not null)
  from (
    select u.symbol, c.close, c.close / u.initial_level * 100 as perf
    from public.structured_note_underlyings u
    left join lateral private.security_close(u.symbol, p_day, p_window) c on true
    where u.note_code = p_note_code
  ) x
$$;

-- The final payout (% of nominal) at a worst performance, and how it is settled.
create function private.note_payout(p_note_code text, p_worst numeric)
returns table (payout_pct numeric, settlement text)
language sql
stable
set search_path = ''
as $$
  select greatest(0, b.intercept_pct + b.slope * p_worst), b.settlement
  from public.structured_note_payout_branches b
  where b.note_code = p_note_code and b.min_worst_pct <= p_worst
  order by b.min_worst_pct desc
  limit 1
$$;

-- The lowest worst performance at which the final payout returns at least p_price (% of
-- nominal): the note's break-even at maturity, coupons aside. Null when none does.
create function private.note_break_even(p_note_code text, p_price numeric)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  b record;
  v_wp numeric;
begin
  for b in
    select x.*, lead(x.min_worst_pct) over (order by x.min_worst_pct) as upper_pct
    from public.structured_note_payout_branches x where x.note_code = p_note_code
    order by x.min_worst_pct
  loop
    if b.slope = 0 then
      v_wp := case when b.intercept_pct >= p_price then b.min_worst_pct end;
    else
      v_wp := greatest(b.min_worst_pct, (p_price - b.intercept_pct) / b.slope);
    end if;
    if v_wp is not null and (b.upper_pct is null or v_wp < b.upper_pct) then
      return round(v_wp, 4);
    end if;
  end loop;
  return null;
end;
$$;

-- Everything about a note as of a day. Outcomes come from the closes on the observation dates
-- (an observation without every close stops the walk: awaiting_prices); the rest from the
-- latest closes. Distances are the % move of a share from its latest close to a level
-- (negative: room to fall). Scenarios assume the coupons up to a date are paid.
create function private.note_evaluate(p_note_code text, p_as_of date)
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
      if w.worst_pct >= o.coupon_barrier_pct then
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
  return v_result;
end;
$$;

-- ── 6. settlement ───────────────────────────────────────────────────────────
-- Records a note's determined outcomes and posts each on its payment date: a coupon is a
-- transfer_in filed as income (and an income flow); a redemption is a transfer_in linked to
-- the holding (a withdrawal); delivered shares become a security holding. Closes the note
-- and its holding once its last payment is made. Idempotent.
create function private.settle_structured_note(p_note_code text)
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
begin
  select * into n from public.structured_notes where note_code = p_note_code for update;
  if not found or n.status = 'cancelled' then
    return;
  end if;
  select * into h from public.holdings where holding_code = n.holding_code;
  v_eval := private.note_evaluate(n.note_code, v_today);

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
  end if;
end;
$$;

-- Service: settle every live note (the stock-prices function, after storing the closes).
create function public.settle_structured_notes()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int := 0;
  r record;
begin
  perform private.assert_service_role();
  for r in select note_code from public.structured_notes where status = 'live' order by created_at loop
    perform private.settle_structured_note(r.note_code);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
grant execute on function public.settle_structured_notes() to service_role;

-- Service: the symbols to price and the first day each needs (notes not ended or cancelled,
-- and shares a note delivered), optionally for one ledger.
create function public.price_symbols(p_profile_code text default null)
returns table (symbol text, from_date date, last_date date)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  return query
  select s.symbol, min(s.from_date), (select max(sp.price_date) from public.security_prices sp where sp.symbol = s.symbol)
  from (
    select u.symbol, n.strike_date - 7 as from_date
    from public.structured_note_underlyings u
    join public.structured_notes n on n.note_code = u.note_code
    where n.status in ('live', 'autocalled', 'matured') and (n.ended_on is null or n.ended_on >= public.dubai_date(now()) - 7)
      and (p_profile_code is null or n.profile_code = p_profile_code)
    union all
    select h.symbol, h.acquired_on - 7
    from public.holdings h
    join public.structured_note_events e on e.delivered_holding_code = h.holding_code
    where h.status = 'active' and (p_profile_code is null or h.profile_code = p_profile_code)
  ) s
  group by s.symbol;
end;
$$;
grant execute on function public.price_symbols(text) to service_role;

-- Service: store closes [{symbol, date, close, currency}]; a later fetch of a day replaces it.
create function public.record_security_prices(p_rows jsonb, p_source text default 'yahoo')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  perform private.assert_service_role();
  insert into public.security_prices (symbol, price_date, close, currency, source)
  select upper(r->>'symbol'), (r->>'date')::date, (r->>'close')::numeric, nullif(r->>'currency', ''), p_source
  from jsonb_array_elements(p_rows) r
  where (r->>'close')::numeric > 0
  on conflict (symbol, price_date) do update
    set close = excluded.close, currency = excluded.currency, source = excluded.source, fetched_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
grant execute on function public.record_security_prices(jsonb, text) to service_role;

-- ── 7. user RPCs ────────────────────────────────────────────────────────────
-- Owner: a note from reviewed terms (the termsheet-v1 draft, docs/contracts/termsheet-v1.md)
-- and what was bought. Decimal strings throughout. The purchase leaves the funding account on
-- the trade date (a transfer_out linked to the holding: saving). Returns the holding_code.
create function public.create_structured_note(p_profile_code text, p_draft jsonb)
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

  insert into public.holdings (profile_code, name, kind, currency, institution, acquired_on, notes, created_by)
  values (p_profile_code, v_name, 'structured_note', v_currency,
          coalesce(nullif(btrim(p_draft->>'institution'), ''), (select b.name from public.banks b where b.bank_code = a.bank_code)),
          v_trade, nullif(btrim(p_draft->>'notes'), ''), auth.uid())
  returning holding_code into v_holding;

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

  if v_account is not null then
    v_txn := private.evidence_txn(p_profile_code, v_account, 'transfer_out', 'debit', v_invested, v_currency, v_trade,
                                  'NOTE PURCHASE ' || coalesce(nullif(upper(t->>'isin'), ''), v_name));
    update public.structured_notes set purchase_txn_code = v_txn where note_code = v_note;
    -- The rule trigger may have linked it elsewhere; the note's own link wins.
    delete from public.holding_flows where txn_code = v_txn;
  end if;
  insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code, source, created_by)
  values (p_profile_code, v_holding, v_trade, 'contribution', v_invested, private.to_aed(v_invested, v_currency), v_txn,
          'note', auth.uid());

  perform private.settle_structured_note(v_note);
  return v_holding;
end;
$$;
comment on function public.create_structured_note(text, jsonb) is
  'Owner: a structured note from reviewed terms and what was bought ({name, institution, terms, investment, termsheet_path, termsheet_filename, extracted_terms}); posts the purchase on the funding account. Returns holding_code.';
grant execute on function public.create_structured_note(text, jsonb) to authenticated, service_role;

-- Owner: undo a note entered by mistake: its ledger entries are voided, its flows removed and
-- the holding closed; the terms and events stay (status cancelled).
create function public.cancel_structured_note(p_profile_code text, p_holding_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.structured_notes;
  v_txn text;
begin
  perform private.assert_member(p_profile_code, true);
  select * into n from public.structured_notes where holding_code = p_holding_code and profile_code = p_profile_code;
  if not found then
    raise exception 'note not found' using errcode = 'P0002';
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
grant execute on function public.cancel_structured_note(text, text) to authenticated, service_role;

-- A note's one-line summary: terms, what was bought, and the evaluation's headline figures.
create function private.note_summary(n public.structured_notes, e jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'note_code', n.note_code, 'holding_code', n.holding_code, 'name', h.name, 'institution', h.institution,
    'product_name', n.product_name, 'isin', n.isin, 'issuer', n.issuer, 'currency', n.currency,
    'status', case when n.status = 'cancelled' then 'cancelled' else e->>'status' end,
    'awaiting_prices', (e->>'awaiting_prices')::boolean,
    'trade_date', n.trade_date, 'maturity_date', n.maturity_date, 'ended_on', coalesce(n.ended_on, (e->>'ended_on')::date),
    'invested', n.invested_amount::text, 'nominal', n.nominal::text, 'purchase_price_pct', n.purchase_price_pct::text,
    'funding_account_code', n.funding_account_code,
    'received', e->'received', 'due', e->'due', 'result', e->'result',
    'worst_now', e->'worst_now', 'break_even_pct', e->>'break_even_pct', 'next', e->'next',
    'if_ended_today', e->'if_ended_today',
    'symbols', (select jsonb_agg(u.symbol order by u.ordinal) from public.structured_note_underlyings u
                where u.note_code = n.note_code))
  from public.holdings h where h.holding_code = n.holding_code
$$;

-- Member: every note of a ledger (cancelled ones left out), newest trade first.
create function public.structured_notes_summary(p_profile_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.dubai_date(now());
begin
  perform private.assert_member(p_profile_code, false);
  return coalesce((
    select jsonb_agg(private.note_summary(n, private.note_evaluate(n.note_code, v_today))
                     order by (n.status = 'live') desc, n.trade_date desc, n.created_at desc)
    from public.structured_notes n
    where n.profile_code = p_profile_code and n.status <> 'cancelled'), '[]'::jsonb);
end;
$$;
comment on function public.structured_notes_summary(text) is
  'Member: each structured note with status, invested, received, the worst share now, the next observation and what it would pay if it ended today. Decimal strings.';
grant execute on function public.structured_notes_summary(text) to authenticated, service_role;

-- Member: one note in full: summary, terms, schedule, payout, evaluation (levels, scenarios,
-- events), the recorded events with their ledger entries, and each share's closes since the
-- strike as % of its initial level.
create function public.structured_note_detail(p_profile_code text, p_holding_code text)
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
  return private.note_summary(n, e) || jsonb_build_object(
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
      ) s), '{}'::jsonb));
end;
$$;
comment on function public.structured_note_detail(text, text) is
  'Member: one structured note: summary, terms, schedule, payout branches, each share against the barriers, levels, scenarios, outcomes so far, recorded events and the price series (% of initial).';
grant execute on function public.structured_note_detail(text, text) to authenticated, service_role;

-- ── 8. values: a live note at what was invested; securities from security_prices ──
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
  ) lv on h.kind in ('plan', 'broker', 'security', 'deposit')
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
             -- A live note is worth what was invested (its payout is not a market price).
             when 'structured_note' then case when d.day >= sn.trade_date then sn.invested_amount end
             else lv.value
           end::numeric(14,2) as value,
           case h.kind when 'metal' then public.dubai_date(m.as_of)
                       when 'deposit' then case when lv.value is not null then greatest(lv.as_of, least(d.day, h.maturity_on))
                                                when d.day >= h.acquired_on then least(d.day, h.maturity_on) end
                       when 'structured_note' then case when d.day >= sn.trade_date then d.day end
                       when 'security' then case when mk.market then sp.price_date else lv.as_of end
                       else lv.as_of end as as_of,
           case h.kind when 'metal' then m.as_of < p_at - private.metal_price_stale_after()
                       when 'deposit' then false
                       when 'structured_note' then false
                       when 'security' then case when mk.market then sp.price_date < d.day - 7 else lv.as_of < d.day - 45 end
                       else lv.as_of < d.day - 45 end as stale,
           h.kind = 'deposit' and lv.as_of is distinct from d.day as estimate
  ) v
  where h.profile_code = p_profile_code and h.status = 'active'
$$;

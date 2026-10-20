-- Wealth mode (tasks/todo.md §5): the app splits into Spending (cards, budgets) and Wealth (bank
-- accounts, cash flow, net worth). This migration is the Wealth side's data.
--
-- 1. v_transactions gains account_kind and in_spending. Spending's Activity shows only rows that
--    are spending business: every card row, and purchases, refunds, fees, interest and cash
--    advances on any account (a debit-card purchase still counts as spend, decision 2). Salary,
--    transfers and autopay live in the account's ledger. activity_selection and activity_summary
--    take scope = 'spending'; without it they read everything, as before (older app builds).
-- 2. account_ledger(profile, account, from, to): a bank account's rows like a bank statement,
--    each with its cash-flow flow and its running balance, plus the period's opening and closing
--    balance and money in/out. A row's balance is anchored on the nearest balance checkpoint: the
--    next one at or after it (the bank's own figure wins), else the latest before it, which is
--    how v_bank_balances computes today's balance, so the newest row matches the Accounts list.
-- 3. bank_balance_series(profile, account, from, to): end-of-day balances for the account chart,
--    known from the account's first transaction or checkpoint on.
-- 4. net_worth(profile): bank cash − what the cards owe now, with completeness. A nightly
--    snapshot (net_worth_snapshots) gives net_worth_series its history; holdings join in Phase 1.
-- 5. cash_flow takes an optional account and marks is_partial months: before the ledger (or the
--    account) had any bank evidence, a month holds card spend and no income, so its net is not a
--    loss.
-- 6. Insights: balance_stale, balance_drift, salary_late, annual_fee. generate_insights becomes a
--    wrapper: generate_spending_insights (the old body, renamed) then generate_wealth_insights.
-- Money crosses the wire as decimal strings (§1.3); every figure is computed here (§2.2).

-- ── 1. Spending scope ────────────────────────────────────────────────────────
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
       (a.kind = 'credit_card' or t.kind in ('purchase', 'refund', 'fee', 'interest', 'cash_advance')) as in_spending
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
) tr on true;

create or replace function private.activity_selection(p_profile_code text, p_txn_codes text[], p_filter jsonb)
returns setof public.v_transactions
language plpgsql
stable
set search_path = ''
as $$
declare
  v_bad text;
  v_status text := p_filter->>'status';
  v_source text := p_filter->>'source';
  v_category text := p_filter->>'category';
  v_scope text := p_filter->>'scope';
  v_pattern text := private.activity_search_pattern(p_filter->>'q');
begin
  if (p_txn_codes is null) = (p_filter is null) then
    raise exception 'pass either p_txn_codes or p_filter' using errcode = '22023';
  end if;
  if p_txn_codes is not null then
    return query
      select t.* from public.v_transactions t
      where t.profile_code = p_profile_code and t.txn_code = any (p_txn_codes);
    return;
  end if;

  if jsonb_typeof(p_filter) <> 'object' then
    raise exception 'p_filter must be an object' using errcode = '22023';
  end if;
  select k into v_bad from jsonb_object_keys(p_filter) k
  where k not in ('from', 'to', 'account', 'card', 'category', 'status', 'source', 'q', 'scope')
  limit 1;
  if v_bad is not null then
    raise exception 'unknown filter %', v_bad using errcode = '22023';
  end if;
  if v_status is not null and v_status not in ('pending', 'posted', 'void', 'orphaned') then
    raise exception 'status must be pending, posted, void or orphaned' using errcode = '22023';
  end if;
  if v_source is not null and v_source not in ('sms', 'statement', 'both') then
    raise exception 'source must be sms, statement or both' using errcode = '22023';
  end if;
  if v_scope is not null and v_scope <> 'spending' then
    raise exception 'scope must be spending' using errcode = '22023';
  end if;

  return query
    select t.* from public.v_transactions t
    where t.profile_code = p_profile_code
      and (v_scope is null or t.in_spending)
      and (p_filter->>'from' is null or t.txn_date >= (p_filter->>'from')::date)
      and (p_filter->>'to' is null or t.txn_date <= (p_filter->>'to')::date)
      and (p_filter->>'account' is null or t.account_code = p_filter->>'account')
      and (p_filter->>'card' is null or t.card_code = p_filter->>'card')
      and (case when v_category = 'none' then t.category_code is null
                else v_category is null or t.category_code = v_category end)
      and (v_status is null or t.status = v_status)
      and (v_source is null
           or (v_source = 'sms' and t.has_sms and not t.has_statement)
           or (v_source = 'statement' and t.has_statement and not t.has_sms)
           or (v_source = 'both' and t.has_sms and t.has_statement))
      and (v_pattern is null or t.description ilike v_pattern or t.merchant_name ilike v_pattern);
end;
$$;

drop function public.activity_summary(text, date, date, text, text, text, boolean, text, text, text);
create function public.activity_summary(
  p_profile_code text,
  p_from date default null,
  p_to date default null,
  p_account_code text default null,
  p_card_code text default null,
  p_category_code text default null,
  p_uncategorized boolean default false,
  p_status text default null,
  p_source text default null,
  p_q text default null,
  p_scope text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pattern text := private.activity_search_pattern(p_q);
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_status is not null and p_status not in ('pending', 'posted', 'void', 'orphaned') then
    raise exception 'p_status must be pending, posted, void or orphaned' using errcode = '22023';
  end if;
  if p_source is not null and p_source not in ('sms', 'statement', 'both') then
    raise exception 'p_source must be sms, statement or both' using errcode = '22023';
  end if;
  if p_scope is not null and p_scope <> 'spending' then
    raise exception 'p_scope must be spending' using errcode = '22023';
  end if;

  select jsonb_build_object(
           'txn_count', count(*),
           'net_aed', coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)
                                 filter (where t.status in ('pending', 'posted')), 0)::numeric(14,2)::text,
           'unpriced_count', count(*) filter (where t.status in ('pending', 'posted') and t.amount_aed is null),
           'has_estimate', coalesce(bool_or(t.amount_aed_is_estimate) filter (where t.status in ('pending', 'posted')), false),
           'earliest_date', min(t.txn_date),
           'latest_date', max(t.txn_date))
  into v_out
  from public.v_transactions t
  where t.profile_code = p_profile_code
    and (p_scope is null or t.in_spending)
    and (p_from is null or t.txn_date >= p_from)
    and (p_to is null or t.txn_date <= p_to)
    and (p_account_code is null or t.account_code = p_account_code)
    and (p_card_code is null or t.card_code = p_card_code)
    and (case when coalesce(p_uncategorized, false) then t.category_code is null
              else p_category_code is null or t.category_code = p_category_code end)
    and (p_status is null or t.status = p_status)
    and (p_source is null
         or (p_source = 'sms' and t.has_sms and not t.has_statement)
         or (p_source = 'statement' and t.has_statement and not t.has_sms)
         or (p_source = 'both' and t.has_sms and t.has_statement))
    and (v_pattern is null or t.description ilike v_pattern or t.merchant_name ilike v_pattern);
  return v_out;
end;
$$;
comment on function public.activity_summary(text, date, date, text, text, text, boolean, text, text, text, text) is
  'Member: totals for the Activity filter. p_scope = spending keeps card rows and purchases, refunds, fees, interest and cash advances (Wealth mode).';
grant execute on function public.activity_summary(text, date, date, text, text, text, boolean, text, text, text, text)
  to authenticated, service_role;

-- ── 2. Running balances ──────────────────────────────────────────────────────
-- A bank account's live transactions, signed (credit +, debit −) in the account's currency, as
-- v_bank_balances prices them: amount_aed on an AED account, amount_original when the currency
-- matches, else null (unpriced). ts is the instant v_bank_balances compares with a checkpoint.
create function private.bank_amounts(p_account_code text)
returns table (txn_code text, ts timestamptz, samt numeric)
language sql
stable
set search_path = ''
as $$
  select t.txn_code, coalesce(t.txn_at, t.txn_date::timestamptz),
         case when t.direction = 'credit' then v.amt else -v.amt end
  from public.transactions t
  join public.accounts a on a.account_code = t.account_code
  cross join lateral (select case when a.currency = 'AED' then t.amount_aed
                                  when t.currency_original = a.currency then t.amount_original end as amt) v
  where t.account_code = p_account_code and t.status in ('pending', 'posted')
$$;

-- Each checkpoint with the running sum of every transaction it already includes (ts <= as_of).
-- For any instant X: balance(X) = cp.balance + sum(ts <= X) − cp.cum_at, with cp the next
-- checkpoint at or after X, else the latest one.
create function private.bank_checkpoints(p_account_code text)
returns table (as_of timestamptz, balance numeric, created_at timestamptz, cum_at numeric)
language sql
stable
set search_path = ''
as $$
  -- One pass: transactions and checkpoints on one timeline, a transaction sorting before a
  -- checkpoint at the same instant (the checkpoint already includes it).
  with ev as (
    select r.ts, coalesce(r.samt, 0) as samt, null::numeric as balance, null::timestamptz as created_at, 0 as is_cp
    from private.bank_amounts(p_account_code) r
    union all
    select bc.as_of, 0, bc.balance, bc.created_at, 1
    from public.balance_checkpoints bc
    where bc.account_code = p_account_code
  ),
  c as (select ev.*, sum(ev.samt) over (order by ev.ts, ev.is_cp rows unbounded preceding) as cum from ev)
  select c.ts, c.balance, c.created_at, c.cum from c where c.is_cp = 1
$$;

create function private.bank_running_balances(p_account_code text)
returns table (txn_code text, ts timestamptz, samt numeric, balance_after numeric(14,2))
language sql
stable
set search_path = ''
as $$
  with r as (select * from private.bank_amounts(p_account_code)),
  c as (select r.txn_code, r.ts, r.samt,
               sum(coalesce(r.samt, 0)) over (order by r.ts, r.txn_code) as cum
        from r),
  cp as (select * from private.bank_checkpoints(p_account_code))
  select c.txn_code, c.ts, c.samt,
         (coalesce(nx.balance, lt.balance) + c.cum - coalesce(nx.cum_at, lt.cum_at))::numeric(14,2)
  from c
  left join lateral (select cp.balance, cp.cum_at from cp where cp.as_of >= c.ts
                     order by cp.as_of, cp.created_at desc limit 1) nx on true
  left join lateral (select cp.balance, cp.cum_at from cp
                     order by cp.as_of desc, cp.created_at desc limit 1) lt on true
$$;

-- The balance at an instant; null with no checkpoint, or before the account's first evidence.
create function private.bank_balance_at(p_account_code text, p_at timestamptz)
returns numeric(14,2)
language sql
stable
set search_path = ''
as $$
  with r as (select * from private.bank_amounts(p_account_code)),
  cp as (select * from private.bank_checkpoints(p_account_code)),
  k as (
    select coalesce(nx.balance, lt.balance) as balance, coalesce(nx.cum_at, lt.cum_at) as cum_at
    from (select 1) one
    left join lateral (select cp.balance, cp.cum_at from cp where cp.as_of >= p_at
                       order by cp.as_of, cp.created_at desc limit 1) nx on true
    left join lateral (select cp.balance, cp.cum_at from cp
                       order by cp.as_of desc, cp.created_at desc limit 1) lt on true
  )
  select case when p_at < least((select min(r.ts) from r), (select min(cp.as_of) from cp)) then null
              else (k.balance + coalesce((select sum(coalesce(r.samt, 0)) from r where r.ts <= p_at), 0) - k.cum_at)::numeric(14,2)
         end
  from k
$$;

-- ── 3. account_ledger ────────────────────────────────────────────────────────
create function public.account_ledger(p_profile_code text, p_account_code text, p_from date, p_to date)
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
        'transfer_card_last4', r.transfer_card_last4)
        order by r.ts desc, r.txn_code desc) from lr r), '[]'::jsonb))
  into v_out;
  return v_out;
end;
$$;
comment on function public.account_ledger(text, text, date, date) is
  'Member: a bank account''s transactions for a period, newest first, with flow and running balance, plus opening/closing balance and money in/out (account currency, decimal strings). Wealth mode.';
grant execute on function public.account_ledger(text, text, date, date) to authenticated, service_role;

-- ── 4. bank_balance_series ───────────────────────────────────────────────────
create function public.bank_balance_series(p_profile_code text, p_account_code text, p_from date, p_to date)
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
  if not exists (select 1 from public.accounts where account_code = p_account_code
                 and profile_code = p_profile_code and kind in ('current', 'savings')) then
    raise exception 'bank account not found' using errcode = 'P0002';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'date', d::date,
             'balance', private.bank_balance_at(p_account_code,
                          ((d::date + 1)::timestamp at time zone 'Asia/Dubai') - interval '1 microsecond')::text)
             order by d), '[]'::jsonb)
    from generate_series(p_from, least(p_to, public.dubai_date(now())), interval '1 day') d
  );
end;
$$;
comment on function public.bank_balance_series(text, text, date, date) is
  'Member: a bank account''s end-of-day balance (Dubai days), null before its first evidence or with no checkpoint. Wealth mode.';
grant execute on function public.bank_balance_series(text, text, date, date) to authenticated, service_role;

-- ── 5. Net worth ─────────────────────────────────────────────────────────────
-- Cash (active bank accounts, AED) − owed (active cards, v_account_balances). Complete only when
-- every bank account has a priced balance and every card has an anchor with every amount known.
create function private.net_worth(p_profile_code text)
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
  )
  select jsonb_build_object(
    'cash_aed', cash.total::text, 'cash_complete', cash.complete, 'cash_missing_count', cash.missing,
    'cash_stale_count', cash.stale, 'cash_as_of', cash.as_of,
    'owed_aed', owed.total::text, 'owed_complete', owed.complete, 'owed_has_estimate', owed.has_estimate,
    'net_aed', (cash.total - owed.total)::numeric(14,2)::text,
    'complete', cash.complete and owed.complete,
    'has_bank_accounts', exists (select 1 from public.accounts a where a.profile_code = p_profile_code
                                 and a.kind in ('current', 'savings') and a.status = 'active'))
  from cash, owed
$$;

create function public.net_worth(p_profile_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, false);
  return private.net_worth(p_profile_code) || jsonb_build_object(
    'cards', coalesce((select jsonb_agg(jsonb_build_object(
               'account_code', a.account_code, 'bank_code', a.bank_code, 'nickname', a.nickname,
               'product_name', a.product_name, 'outstanding_aed', b.outstanding_aed::text,
               'anchor_kind', b.anchor_kind, 'has_estimate', b.has_estimate)
               order by b.outstanding_aed desc nulls last, a.bank_code, a.account_code)
             from public.v_account_balances b join public.accounts a on a.account_code = b.account_code
             where b.profile_code = p_profile_code and a.status = 'active'), '[]'::jsonb));
end;
$$;
comment on function public.net_worth(text) is
  'Member: bank cash − what the cards owe now (AED, decimal strings), with completeness, and each card''s outstanding. Wealth mode.';
grant execute on function public.net_worth(text) to authenticated, service_role;

create table public.net_worth_snapshots (
  snapshot_code text primary key default public.gen_code('nws')
    check (snapshot_code ~ '^nws_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  snap_date date not null,
  cash_aed numeric(14,2) not null,
  owed_aed numeric(14,2) not null,
  net_aed numeric(14,2) not null,
  complete boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_code, snap_date)
);
comment on table public.net_worth_snapshots is
  'Net worth as computed on a Dubai date (nightly), the history behind net_worth_series. Derived, not evidence: the day''s row is rewritten until the day ends.';
create trigger net_worth_snapshots_touch before update on public.net_worth_snapshots
  for each row execute function private.touch_updated_at();
alter table public.net_worth_snapshots enable row level security;
create policy net_worth_snapshots_member_read on public.net_worth_snapshots for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.net_worth_snapshots to authenticated;
grant all on public.net_worth_snapshots to service_role;

create function private.snapshot_net_worth(p_profile_code text)
returns void
language sql
set search_path = ''
as $$
  insert into public.net_worth_snapshots (profile_code, snap_date, cash_aed, owed_aed, net_aed, complete)
  select p_profile_code, public.dubai_date(now()), (n->>'cash_aed')::numeric, (n->>'owed_aed')::numeric,
         (n->>'net_aed')::numeric, (n->>'complete')::boolean
  from (select private.net_worth(p_profile_code) n) x
  on conflict (profile_code, snap_date) do update
    set cash_aed = excluded.cash_aed, owed_aed = excluded.owed_aed, net_aed = excluded.net_aed,
        complete = excluded.complete
$$;

-- Month by month: the month's last snapshot, and this month's live figure.
create function public.net_worth_series(p_profile_code text, p_months int default 12)
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
                                'cash_aed', s.cash_aed::text, 'owed_aed', s.owed_aed::text,
                                'net_aed', s.net_aed::text, 'complete', s.complete, 'is_live', false) as j
      from public.net_worth_snapshots s
      where s.profile_code = p_profile_code and s.snap_date < v_month
        and s.snap_date >= (v_month - make_interval(months => p_months - 1))::date
      order by date_trunc('month', s.snap_date), s.snap_date desc
    ) x), '[]'::jsonb)
    || jsonb_build_array(jsonb_build_object('month', v_month, 'as_of', public.dubai_date(now()),
                         'cash_aed', v_live->>'cash_aed', 'owed_aed', v_live->>'owed_aed',
                         'net_aed', v_live->>'net_aed', 'complete', (v_live->>'complete')::boolean,
                         'is_live', true));
end;
$$;
comment on function public.net_worth_series(text, int) is
  'Member: net worth per month (the month''s last nightly snapshot), ending with this month''s live figure. Wealth mode.';
grant execute on function public.net_worth_series(text, int) to authenticated, service_role;

-- ── 6. cash_flow: per account, and partial months ────────────────────────────
-- Coverage starts at the first bank evidence (a bank-account transaction or checkpoint) of the
-- ledger, or of the one account. A month that starts before it is partial.
drop function public.cash_flow(text, date, date);
create function public.cash_flow(p_profile_code text, p_from date, p_to date, p_account_code text default null)
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
            where t.profile_code = p_profile_code and t.status in ('pending', 'posted')
              and (p_account_code is null or t.account_code = p_account_code)),
           (select min(public.dubai_date(bc.as_of)) from public.balance_checkpoints bc
            where bc.profile_code = p_profile_code
              and (p_account_code is null or bc.account_code = p_account_code)))
  into v_cover;

  return query
  with f as (
    select date_trunc('month', v.txn_date)::date as m, v.flow as fl, v.amount_aed as amt
    from public.v_cash_flow v
    where v.profile_code = p_profile_code and v.txn_date between p_from and p_to
      and (p_account_code is null or v.account_code = p_account_code)
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
comment on function public.cash_flow(text, date, date, text) is
  'Member: money in and out per month by flow, plus net (in − spend − support − saving − unfiled out); optionally one account. is_partial: the month starts before the first bank evidence. Phase 2c, Wealth mode.';
grant execute on function public.cash_flow(text, date, date, text) to authenticated, service_role;

-- ── 7. Insights ──────────────────────────────────────────────────────────────
alter table public.insights drop constraint insights_kind_check;
alter table public.insights add constraint insights_kind_check check (kind in
  ('spend_pace', 'category_spike', 'budget_risk', 'price_change', 'new_recurring', 'statement_due',
   'uncategorized', 'review_backlog', 'large_transaction', 'cash_advance',
   'balance_stale', 'balance_drift', 'salary_late', 'annual_fee'));

-- The spending generator keeps its body (20261020131850); a later change to it replaces
-- private.generate_spending_insights, never the wrapper below.
alter function private.generate_insights(text) rename to generate_spending_insights;

create function private.bank_account_label(a public.accounts)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(nullif(btrim(a.nickname), ''),
                  a.bank_code || ' ' || initcap(a.kind) || coalesce(' ··' || a.account_ref, ''))
$$;

create function private.generate_wealth_insights(p_profile_code text)
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
  on conflict (profile_code, kind, dedupe_key) do update
    set title = excluded.title, body = excluded.body, data = excluded.data, valid_until = excluded.valid_until;
  get diagnostics n = row_count; v_count := v_count + n;
  -- A balance that is current again (or a newer stale period) retires the old card.
  delete from public.insights i
  where i.profile_code = p_profile_code and i.kind = 'balance_stale'
    and not exists (select 1 from public.accounts a join public.v_bank_balances b on b.account_code = a.account_code
                    where a.profile_code = p_profile_code and a.status = 'active' and (b.as_of is null or b.is_stale)
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

create function private.generate_insights(p_profile_code text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  return private.generate_spending_insights(p_profile_code) + private.generate_wealth_insights(p_profile_code);
end;
$$;
comment on function private.generate_insights(text) is
  'Spending then wealth insights. Change the generators, not this wrapper (20261020162834).';

-- ── 8. Nightly: snapshot net worth too ───────────────────────────────────────
create or replace function private.nightly(p_profile_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p text;
  v_void int;
  v_purged int;
  v_out jsonb := '{}'::jsonb;
  v_state text;
  v_msg text;
begin
  begin
    v_void := private.void_released_authorisations();
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    perform private.log_job_error('nightly.void_released_authorisations', null, null, v_state, v_msg);
  end;
  if p_profile_code is null then
    begin
      v_purged := private.purge_document_events();
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('nightly.purge_document_events', null, null, v_state, v_msg);
    end;
  end if;
  for p in select profile_code from public.profiles where p_profile_code is null or profile_code = p_profile_code loop
    begin
      v_out := v_out || jsonb_build_object(p, jsonb_build_object(
        'recurring', private.detect_recurring(p),
        'insights', private.generate_insights(p)
      ));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('nightly', p, null, v_state, v_msg);
      v_out := v_out || jsonb_build_object(p, jsonb_build_object('error', v_state));
    end;
    begin
      perform private.snapshot_net_worth(p);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('nightly.snapshot_net_worth', p, null, v_state, v_msg);
    end;
  end loop;
  return v_out || jsonb_build_object('voided', v_void, 'document_events_purged', v_purged);
end;
$$;

-- Today's figure for every ledger, so the series starts now rather than tomorrow night.
select private.snapshot_net_worth(profile_code) from public.profiles;

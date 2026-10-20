-- Phase 2c (tasks/todo.md §3): where the money goes, beyond card spend.
--
-- 1. categories.kind adds 'saving' and 'support' (decision 2, approved 2026-10-20): money to
--    family and to savings/investments is its own flow, never spend. New ledgers and existing
--    ones get Salary (income), Family support, Savings & investing and Transfers (transfer),
--    added only where a category of that name is absent.
-- 2. v_spend leaves saving/support out like transfer/ignore/income, and gains `instrument`
--    (credit_card / debit_card, from the account). filtered_spend, spend_series and
--    spend_breakdown take p_instruments (null = both, today's numbers).
-- 3. Repayments: a bank transfer_out pairs with a card payment of the same AED amount within 3
--    days through card_transfers, so paying a card from the bank counts once, as a move.
-- 4. v_cash_flow / cash_flow(): each month's money in and out by flow. Payees are category rules
--    (amount, kind and bank conditions already exist): "ADCB transfer_out of 23,700 → Family
--    support" is a rule, so no separate payee table.

-- ── 1. category kinds ───────────────────────────────────────────────────────
alter table public.categories drop constraint categories_kind_check;
alter table public.categories add constraint categories_kind_check
  check (kind in ('spend', 'income', 'transfer', 'fee', 'ignore', 'saving', 'support'));

insert into private.seed_categories (name, kind, sort_order, color_token)
select v.name, v.kind, v.sort_order, v.color_token
from (values ('Salary', 'income', 152, 'cat-13'), ('Transfers', 'transfer', 165, 'cat-10'),
             ('Family support', 'support', 190, 'cat-11'), ('Savings & investing', 'saving', 195, 'cat-7'))
  as v(name, kind, sort_order, color_token)
where not exists (select 1 from private.seed_categories s where s.name = v.name);

insert into public.categories (profile_code, name, kind, sort_order, color_token)
select p.profile_code, v.name, v.kind, v.sort_order, v.color_token
from public.profiles p
cross join (values ('Salary', 'income', 152, 'cat-13'), ('Transfers', 'transfer', 165, 'cat-10'),
                   ('Family support', 'support', 190, 'cat-11'), ('Savings & investing', 'saving', 195, 'cat-7'))
  as v(name, kind, sort_order, color_token)
where exists (select 1 from public.categories c where c.profile_code = p.profile_code)
  and not exists (select 1 from public.categories c where c.profile_code = p.profile_code and lower(c.name) = lower(v.name));

-- ── 2. v_spend: instrument, and saving/support are not spend ────────────────
-- The spend functions return v_spend rows, so they go first and come back with p_instruments.
drop function public.spend_series(text, date, date, text, text, int, text[], text[], text[], text);
drop function public.spend_breakdown(text, date, date, text, integer, text[], text[], text[], text);
drop function private.filtered_spend(text, date, date, text[], text[], text[], text);

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
  and coalesce(c.kind, 'spend') not in ('transfer', 'ignore', 'income', 'saving', 'support');

create or replace function private.filtered_spend(
  p_profile_code text, p_from date, p_to date,
  p_category_codes text[], p_bank_codes text[], p_card_codes text[], p_q text,
  p_instruments text[] default null
)
returns setof public.v_spend
language sql
stable
set search_path = ''
as $$
  select s.*
  from public.v_spend s
  where s.profile_code = p_profile_code
    and s.txn_date between p_from and p_to
    and (p_category_codes is null or cardinality(p_category_codes) = 0
         or s.category_code = any (p_category_codes)
         or (s.category_code is null and '__uncategorized__' = any (p_category_codes)))
    and (p_bank_codes is null or cardinality(p_bank_codes) = 0
         or exists (select 1 from public.accounts a
                    where a.account_code = s.account_code and a.bank_code = any (p_bank_codes)))
    and (p_card_codes is null or cardinality(p_card_codes) = 0 or s.card_code = any (p_card_codes))
    and (p_instruments is null or cardinality(p_instruments) = 0 or s.instrument = any (p_instruments))
    and (private.activity_search_pattern(p_q) is null
         or s.description ilike private.activity_search_pattern(p_q)
         or exists (select 1 from public.merchants m
                    where m.merchant_code = s.merchant_code
                      and m.display_name ilike private.activity_search_pattern(p_q)))
$$;

create or replace function public.spend_series(
  p_profile_code text, p_from date, p_to date, p_grain text default 'month', p_group text default 'none',
  p_top int default null,
  p_category_codes text[] default null, p_bank_codes text[] default null, p_card_codes text[] default null,
  p_q text default null,
  p_instruments text[] default null
)
returns table (bucket date, group_key text, group_label text, color_token text, amount numeric, txn_count bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, false);
  return query
  with base as (
    select
      date_trunc(case when p_grain in ('day', 'week', 'month') then p_grain else 'month' end, s.txn_date)::date as bucket,
      case p_group
        when 'category' then s.category_code
        when 'merchant' then s.merchant_code
        when 'account' then s.account_code
        when 'card' then s.card_code
      end as group_key,
      case p_group
        when 'category' then coalesce(c.name, 'Uncategorised')
        when 'merchant' then coalesce(m.display_name, s.description)
        when 'account' then coalesce(a.nickname, a.bank_code)
        when 'card' then coalesce(a.bank_code || ' •' || cd.last4, a.bank_code)
        else 'Total'
      end as group_label,
      case when p_group = 'category' then c.color_token end as color_token,
      s.spend_aed
    from private.filtered_spend(p_profile_code, p_from, p_to, p_category_codes, p_bank_codes, p_card_codes, p_q, p_instruments) s
    left join public.categories c on c.category_code = s.category_code
    left join public.merchants m on m.merchant_code = s.merchant_code
    left join public.accounts a on a.account_code = s.account_code
    left join public.cards cd on cd.card_code = s.card_code
  ),
  ranked as (
    select b.group_key, b.group_label, b.color_token,
           row_number() over (order by sum(b.spend_aed) desc, b.group_label, b.group_key) as rnk
    from base b
    group by b.group_key, b.group_label, b.color_token
  ),
  folded as (
    select b.bucket,
           case when f.fold then null else b.group_key end as group_key,
           case when f.fold then 'Other' else b.group_label end as group_label,
           case when f.fold then null else b.color_token end as color_token,
           b.spend_aed
    from base b
    join ranked r
      on r.group_key is not distinct from b.group_key
     and r.group_label is not distinct from b.group_label
     and r.color_token is not distinct from b.color_token
    cross join lateral (
      select (p_top is not null and coalesce(p_group, 'none') <> 'none' and r.rnk > greatest(p_top, 1)) as fold
    ) f
  )
  select x.bucket, x.group_key, x.group_label, x.color_token, sum(x.spend_aed) as amount, count(*) as txn_count
  from folded x
  group by 1, 2, 3, 4
  order by 1, 5 desc;
end;
$$;

create or replace function public.spend_breakdown(
  p_profile_code text,
  p_from date,
  p_to date,
  p_group_by text,
  p_top_n integer default 10,
  p_category_codes text[] default null,
  p_bank_codes text[] default null,
  p_card_codes text[] default null,
  p_q text default null,
  p_instruments text[] default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_top integer := least(greatest(coalesce(p_top_n, 10), 1), 50);
  v_from date := date_trunc('month', p_from)::date;
  v_to date := date_trunc('month', p_to)::date;
  v_total numeric;
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_group_by is null or p_group_by not in ('category', 'bank', 'merchant') then
    raise exception 'p_group_by must be category, bank or merchant' using errcode = '22023';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from must be on or before p_to' using errcode = '22023';
  end if;
  if (v_to - v_from) > 3660 then
    raise exception 'the range is limited to 10 years' using errcode = '22023';
  end if;

  with base as (
    select to_char(s.txn_date, 'YYYY-MM') as month,
           case p_group_by
             when 'category' then coalesce(s.category_code, '__uncategorized__')
             when 'bank' then a.bank_code
             else coalesce(s.merchant_code, '__unknown__')
           end as key,
           case p_group_by
             when 'category' then coalesce(c.name, 'Uncategorised')
             when 'bank' then coalesce(b.name, a.bank_code)
             else coalesce(m.display_name, 'Unknown merchant')
           end as label,
           case when p_group_by = 'category' then c.color_token end as color_token,
           case when p_group_by = 'bank' then b.logo_path end as logo_path,
           s.spend_aed
    from private.filtered_spend(p_profile_code, p_from, p_to, p_category_codes, p_bank_codes, p_card_codes, p_q, p_instruments) s
    join public.accounts a on a.account_code = s.account_code and a.profile_code = p_profile_code
    left join public.banks b on b.bank_code = a.bank_code
    left join public.categories c on c.category_code = s.category_code and c.profile_code = p_profile_code
    left join public.merchants m on m.merchant_code = s.merchant_code
  ),
  per_key as (
    select key, min(label) as label, min(color_token) as color_token, min(logo_path) as logo_path,
           sum(spend_aed) as total
    from base group by key
  ),
  ranked as (
    select k.*, row_number() over (order by k.total desc, k.label, k.key) as rnk from per_key k
  ),
  grouped as (
    select case when r.rnk <= v_top then r.key else '__other__' end as key,
           case when r.rnk <= v_top then r.label else 'Others' end as label,
           case when r.rnk <= v_top then r.color_token end as color_token,
           case when r.rnk <= v_top then r.logo_path end as logo_path,
           case when r.rnk <= v_top then r.rnk else v_top + 1 end as ord,
           r.total
    from ranked r
  ),
  groups as (
    select key, min(label) as label, min(color_token) as color_token, min(logo_path) as logo_path,
           min(ord) as ord, sum(total) as total
    from grouped group by key
  ),
  months as (
    select to_char(g, 'YYYY-MM') as month
    from generate_series(v_from, v_to, interval '1 month') g
  ),
  cells as (
    select mo.month, gr.key, coalesce(sum(b.spend_aed), 0) as amount
    from months mo
    cross join groups gr
    left join ranked r on (case when r.rnk <= v_top then r.key else '__other__' end) = gr.key
    left join base b on b.month = mo.month and b.key = r.key
    group by mo.month, gr.key
  )
  select
    coalesce((select sum(total) from groups), 0),
    jsonb_build_object(
      'months', (select coalesce(jsonb_agg(month order by month), '[]'::jsonb) from months),
      'groups', (select coalesce(jsonb_agg(jsonb_build_object('key', g.key, 'label', g.label,
                   'color_token', g.color_token, 'logo_path', g.logo_path,
                   'total', g.total::numeric(14,2)::text,
                   'share', case when t.total > 0
                                 then greatest(0, least(1, round(g.total / t.total, 4)))::numeric(5,4)::text
                                 else '0.0000' end)
                   order by g.ord, g.key), '[]'::jsonb)
                 from groups g cross join (select sum(total) as total from groups) t),
      'series', (select coalesce(jsonb_agg(jsonb_build_object('month', x.month,
                   'total', x.total::numeric(14,2)::text, 'values', x.vals) order by x.month), '[]'::jsonb)
                 from (select c.month, sum(c.amount) as total,
                              coalesce(jsonb_object_agg(c.key, c.amount::numeric(14,2)::text), '{}'::jsonb) as vals
                       from cells c group by c.month
                       union all
                       select mo.month, 0, '{}'::jsonb from months mo
                       where not exists (select 1 from groups)) x)
    )
  into v_total, v_out;

  return jsonb_build_object('group_by', p_group_by, 'total', v_total::numeric(14,2)::text) || v_out;
end;
$$;

grant execute on function public.spend_series(text, date, date, text, text, int, text[], text[], text[], text, text[])
  to authenticated, service_role;
grant execute on function public.spend_breakdown(text, date, date, text, integer, text[], text[], text[], text, text[])
  to authenticated, service_role;

-- ── 3. repayments from a bank account ───────────────────────────────────────
create or replace function private.card_transfer_candidates(p_txn_code text)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select c.txn_code
  from public.transactions t
  join public.transactions c
    on c.profile_code = t.profile_code
   and c.account_code <> t.account_code
   and (c.kind = 'payment' or (c.kind = 'transfer_out' and c.direction = 'debit'))
   and (c.kind = 'payment' or t.kind = 'payment')   -- one side is always a card payment
   and c.direction <> t.direction
   and c.amount_aed = t.amount_aed
   and c.status in ('pending', 'posted')
   and abs(c.txn_date - t.txn_date) <= 3
  where t.txn_code = p_txn_code
    and (t.kind = 'payment' or (t.kind = 'transfer_out' and t.direction = 'debit'))
    and t.status in ('pending', 'posted') and t.amount_aed is not null
    and not exists (select 1 from public.card_transfers x
                    where x.from_txn_code = c.txn_code or x.to_txn_code = c.txn_code)
$$;

create or replace function private.link_card_transfer(p_txn_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.transactions%rowtype;
  v_link public.card_transfers%rowtype;
  v_partner text;
  v_count integer;
begin
  select * into t from public.transactions where txn_code = p_txn_code;
  if not found then
    return null;
  end if;

  select * into v_link from public.card_transfers
  where from_txn_code = p_txn_code or to_txn_code = p_txn_code;
  if found then
    v_partner := case when v_link.from_txn_code = p_txn_code then v_link.to_txn_code else v_link.from_txn_code end;
    -- Still a valid pair: keep it.
    if exists (
      select 1 from public.transactions p
      where p.txn_code = v_partner
        and t.kind in ('payment', 'transfer_out') and p.kind in ('payment', 'transfer_out')
        and (t.kind = 'payment' or p.kind = 'payment')
        and t.status in ('pending', 'posted') and p.status in ('pending', 'posted')
        and t.direction <> p.direction and t.account_code <> p.account_code
        and t.amount_aed = p.amount_aed and abs(t.txn_date - p.txn_date) <= 3
    ) then
      return v_link.transfer_code;
    end if;
    delete from public.card_transfers where transfer_code = v_link.transfer_code;
    perform private.link_card_transfer(v_partner);
  end if;

  select count(*), min(c) into v_count, v_partner from private.card_transfer_candidates(p_txn_code) c;
  if v_count <> 1 then
    return null;
  end if;
  -- The partner must have no other candidate either.
  if (select count(*) from private.card_transfer_candidates(v_partner)) <> 1 then
    return null;
  end if;

  insert into public.card_transfers (profile_code, from_txn_code, to_txn_code)
  select t.profile_code,
         case when t.direction = 'debit' then t.txn_code else v_partner end,
         case when t.direction = 'debit' then v_partner else t.txn_code end
  on conflict do nothing
  returning transfer_code into v_link.transfer_code;
  return v_link.transfer_code;
end;
$$;

create or replace function private.transactions_link_card_transfer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind in ('payment', 'transfer_out') or (tg_op = 'UPDATE' and old.kind in ('payment', 'transfer_out')) then
    perform private.link_card_transfer(new.txn_code);
  end if;
  return null;
end;
$$;

-- Existing bank transfers pick up their card payment.
select private.link_card_transfer(t.txn_code)
from public.transactions t
where t.kind = 'transfer_out' and t.status in ('pending', 'posted')
  and not exists (select 1 from public.card_transfers x where x.from_txn_code = t.txn_code);

-- ── 4. cash flow ────────────────────────────────────────────────────────────
-- One row per transaction that moves money, with its flow:
--   spend            card or debit-card spend (v_spend; refunds negative), with its instrument
--   income           money into a bank account filed under an income category (Salary)
--   money_in         other money in, not yet filed
--   internal_in/out  between the ledger's own accounts (a Transfers category)
--   card_repayment   a bank transfer paired with a card payment (card_transfers)
--   support, saving  filed under a support or saving category
--   spend_transfer   a bank transfer filed under a spend or fee category (rent by transfer)
--   money_out        other money out, not yet filed
-- Ignore-kind categories and void/orphaned rows are left out.
create or replace view public.v_cash_flow with (security_invoker = true) as
select s.profile_code, s.txn_code, s.account_code, s.txn_date, 'spend'::text as flow, s.instrument,
       s.spend_aed::numeric(14,2) as amount_aed
from public.v_spend s
union all
select t.profile_code, t.txn_code, t.account_code, t.txn_date,
       case
         when t.direction = 'credit' then
           case c.kind when 'income' then 'income' when 'transfer' then 'internal_in' else 'money_in' end
         when exists (select 1 from public.card_transfers x where x.from_txn_code = t.txn_code) then 'card_repayment'
         else case c.kind when 'support' then 'support' when 'saving' then 'saving'
                          when 'transfer' then 'internal_out'
                          when 'spend' then 'spend_transfer' when 'fee' then 'spend_transfer'
                          else 'money_out' end
       end,
       null::text,
       t.amount_aed::numeric(14,2)
from public.transactions t
join public.accounts a on a.account_code = t.account_code and a.kind in ('current', 'savings')
left join public.categories c on c.category_code = t.effective_category_code
where t.kind in ('transfer_in', 'transfer_out') and t.status in ('pending', 'posted')
  and t.amount_aed is not null and coalesce(c.kind, '') <> 'ignore';
comment on view public.v_cash_flow is
  'Money moved per transaction by flow (spend, income, support, saving, card_repayment, …). Phase 2c.';
grant select on public.v_cash_flow to authenticated;
grant select on public.v_cash_flow to service_role;

-- Per month: each flow's total and count, plus a 'net' row: money in (income + money_in) less
-- spend, spend_transfer, support, saving and money_out. Card repayments and internal moves are
-- settlement between the ledger's own accounts, so they never change net.
create or replace function public.cash_flow(p_profile_code text, p_from date, p_to date)
returns table (month date, flow text, amount_aed numeric(14,2), txn_count int)
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
  return query
  with f as (
    select date_trunc('month', v.txn_date)::date as m, v.flow as fl, v.amount_aed as amt
    from public.v_cash_flow v
    where v.profile_code = p_profile_code and v.txn_date between p_from and p_to
  )
  select f.m, f.fl, sum(f.amt)::numeric(14,2), count(*)::int from f group by f.m, f.fl
  union all
  select f.m, 'net'::text,
         sum(case when f.fl in ('income', 'money_in') then f.amt
                  when f.fl in ('spend', 'spend_transfer', 'support', 'saving', 'money_out') then -f.amt
                  else 0 end)::numeric(14,2),
         count(*)::int
  from f group by f.m
  order by 1, 2;
end;
$$;
comment on function public.cash_flow(text, date, date) is
  'Member: money in and out per month by flow, plus net (in − spend − support − saving − unfiled out). Phase 2c.';
grant execute on function public.cash_flow(text, date, date) to authenticated, service_role;

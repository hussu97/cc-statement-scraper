-- Server-side analytics. Clients render these results; they never compute money.
-- Every function is SECURITY INVOKER, so RLS limits rows to the caller's profiles.
--
-- ONE definition of spend (v_spend): debit purchases, fees, interest and cash
-- advances, minus refunds; excluding payments, transfers, ignored/income
-- categories, voided/orphaned transactions and anything marked exclude_from_spend.
-- Buckets use txn_date, which is already a Dubai calendar date.

create view public.v_spend
with (security_invoker = true) as
select
  t.txn_code, t.profile_code, t.account_code, t.card_code, t.txn_date, t.txn_at,
  t.merchant_code, t.description, t.effective_category_code as category_code,
  case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end as spend_aed,
  t.amount_original, t.currency_original, t.status, t.amount_aed_is_estimate, t.kind
from public.transactions t
left join public.categories c on c.category_code = t.effective_category_code
where t.status in ('pending', 'posted')
  and not t.exclude_from_spend
  and t.amount_aed is not null
  and ((t.direction = 'debit' and t.kind in ('purchase', 'fee', 'interest', 'cash_advance'))
       or (t.direction = 'credit' and t.kind = 'refund'))
  and coalesce(c.kind, 'spend') not in ('transfer', 'ignore', 'income');

-- Activity screen: transactions with everything a row needs, in one read.
create view public.v_transactions
with (security_invoker = true) as
select
  t.txn_code, t.profile_code, t.account_code, t.card_code, t.status, t.kind, t.direction,
  t.txn_date, t.txn_at, t.posting_date, t.stmt_code, t.merchant_code, t.description,
  m.display_name as merchant_name,
  t.amount_original, t.currency_original, t.amount_aed, t.amount_aed_is_estimate, t.fx_rate, t.auth_amount,
  t.amount_source, t.related_txn_code, t.exclude_from_spend, t.notes,
  t.effective_category_code as category_code, c.name as category_name, c.color_token as category_color,
  c.kind as category_kind,
  case
    when t.manual_category_code is not null then 'manual'
    when t.merchant_category_source = 'manual' and t.merchant_category_code is not null then 'merchant'
    when t.rule_category_code is not null then 'rule'
    when t.merchant_category_source = 'llm' and t.merchant_category_code is not null then 'suggested'
  end as category_source,
  a.bank_code, cd.last4 as card_last4, a.nickname as account_nickname,
  exists (select 1 from public.transaction_evidence e
          where e.txn_code = t.txn_code and e.is_active and e.evidence_type = 'sms') as has_sms,
  exists (select 1 from public.transaction_evidence e
          where e.txn_code = t.txn_code and e.is_active and e.evidence_type in ('statement_line', 'history_line')) as has_statement,
  t.created_at, t.updated_at
from public.transactions t
join public.accounts a on a.account_code = t.account_code
left join public.cards cd on cd.card_code = t.card_code
left join public.categories c on c.category_code = t.effective_category_code
left join public.merchants m on m.merchant_code = t.merchant_code;

grant select on public.v_spend, public.v_transactions to authenticated, service_role;

-- ── overview ────────────────────────────────────────────────────────────────
create or replace function public.overview(p_profile_code text, p_month date default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_today date := public.dubai_date(now());
  v_month date := date_trunc('month', coalesce(p_month, v_today))::date;
  v_next date := (v_month + interval '1 month')::date;
  v_prev date := (v_month - interval '1 month')::date;
  v_day int := least(extract(day from v_today)::int, extract(day from (v_next - 1))::int);
  r jsonb;
begin
  select jsonb_build_object(
    'month', v_month,
    'spend', coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_month and txn_date < v_next), 0)::text,
    'spend_prev_month', coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_prev and txn_date < v_month), 0)::text,
    -- same day-of-month last month, for a fair month-to-date comparison
    'spend_prev_month_to_date', coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_prev and txn_date < v_prev + v_day), 0)::text,
    'spend_avg_3m', coalesce((select round(sum(spend_aed) / 3, 2) from public.v_spend
                       where profile_code = p_profile_code
                         and txn_date >= (v_month - interval '3 month')::date and txn_date < v_month), 0)::text,
    'payments', coalesce((select sum(amount_aed) from public.transactions
                       where profile_code = p_profile_code and kind = 'payment' and direction = 'credit'
                         and status in ('pending', 'posted') and txn_date >= v_month and txn_date < v_next), 0)::text,
    'pending_count', (select count(*) from public.transactions where profile_code = p_profile_code and status = 'pending'),
    'pending_amount', coalesce((select sum(case when direction = 'debit' then amount_aed else -amount_aed end)
                       from public.transactions where profile_code = p_profile_code and status = 'pending'), 0)::text,
    'uncategorized_count', (select count(*) from public.v_spend
                       where profile_code = p_profile_code and category_code is null
                         and txn_date >= v_month and txn_date < v_next),
    'open_reviews', (select count(*) from public.match_reviews where profile_code = p_profile_code and status = 'open'),
    'last_sms_at', (select max(received_at) from public.sms_messages where profile_code = p_profile_code),
    'top_categories', coalesce((
      select jsonb_agg(x order by x.amount desc) from (
        select s.category_code, c.name, c.color_token, sum(s.spend_aed) as amount, count(*) as txn_count
        from public.v_spend s left join public.categories c on c.category_code = s.category_code
        where s.profile_code = p_profile_code and s.txn_date >= v_month and s.txn_date < v_next
        group by s.category_code, c.name, c.color_token
        order by sum(s.spend_aed) desc limit 6
      ) x), '[]'::jsonb),
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'account_code', a.account_code, 'bank_code', a.bank_code, 'nickname', a.nickname,
        'product_name', a.product_name, 'credit_limit', a.credit_limit::text,
        'last4', (select string_agg(cd.last4, ',' order by cd.is_supplementary, cd.last4)
                  from public.cards cd where cd.account_code = a.account_code),
        'latest_statement', (
          select jsonb_build_object('stmt_code', st.stmt_code, 'statement_date', st.statement_date,
            'due_date', st.due_date, 'closing_balance', st.closing_balance::text, 'min_due', st.min_due::text)
          from public.statements st
          where st.account_code = a.account_code and st.kind = 'statement' and st.status = 'active'
          order by st.statement_date desc limit 1),
        'unbilled_aed', coalesce((
          select sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)
          from public.transactions t
          where t.account_code = a.account_code and t.status in ('pending', 'posted')
            and t.txn_date > coalesce((select max(st.statement_date) from public.statements st
                                       where st.account_code = a.account_code and st.kind = 'statement'
                                         and st.status = 'active'), '1900-01-01'::date)), 0)::text
      ) order by a.bank_code)
      from public.accounts a where a.profile_code = p_profile_code and a.status = 'active'), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(to_jsonb(v) order by v.txn_date desc, v.txn_at desc nulls last)
      from (select txn_code, txn_date, txn_at, description, merchant_name, amount_aed::text as amount_aed,
                   amount_original::text as amount_original, currency_original, direction, status, category_name,
                   category_color, has_sms, has_statement
            from public.v_transactions where profile_code = p_profile_code
            order by txn_date desc, txn_at desc nulls last limit 8) v), '[]'::jsonb)
  ) into r;
  return r;
end;
$$;

-- ── series ──────────────────────────────────────────────────────────────────
-- p_grain: day | week | month. p_group: none | category | merchant | account | card.
create or replace function public.spend_series(
  p_profile_code text, p_from date, p_to date, p_grain text default 'month', p_group text default 'none'
)
returns table (bucket date, group_key text, group_label text, color_token text, amount numeric, txn_count bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    date_trunc(case when p_grain in ('day', 'week', 'month') then p_grain else 'month' end, s.txn_date)::date as bucket,
    case p_group
      when 'category' then s.category_code
      when 'merchant' then s.merchant_code
      when 'account' then s.account_code
      when 'card' then s.card_code
    end as group_key,
    case p_group
      when 'category' then coalesce(c.name, 'Uncategorized')
      when 'merchant' then coalesce(m.display_name, s.description)
      when 'account' then coalesce(a.nickname, a.bank_code)
      when 'card' then coalesce(a.bank_code || ' •' || cd.last4, a.bank_code)
      else 'Total'
    end as group_label,
    case when p_group = 'category' then c.color_token end as color_token,
    sum(s.spend_aed) as amount,
    count(*) as txn_count
  from public.v_spend s
  left join public.categories c on c.category_code = s.category_code
  left join public.merchants m on m.merchant_code = s.merchant_code
  left join public.accounts a on a.account_code = s.account_code
  left join public.cards cd on cd.card_code = s.card_code
  where s.profile_code = p_profile_code and s.txn_date between p_from and p_to
  group by 1, 2, 3, 4
  order by 1, 5 desc
$$;

create or replace function public.category_breakdown(p_profile_code text, p_from date, p_to date)
returns table (category_code text, name text, color_token text, amount numeric, txn_count bigint,
               share numeric, prev_amount numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  with cur as (
    select s.category_code, sum(s.spend_aed) as amount, count(*) as n
    from public.v_spend s
    where s.profile_code = p_profile_code and s.txn_date between p_from and p_to
    group by s.category_code
  ),
  prev as (
    select s.category_code, sum(s.spend_aed) as amount
    from public.v_spend s
    where s.profile_code = p_profile_code
      and s.txn_date between p_from - (p_to - p_from + 1) and p_from - 1
    group by s.category_code
  ),
  tot as (select nullif(sum(amount), 0) as total from cur)
  select cur.category_code, coalesce(c.name, 'Uncategorized'), c.color_token, cur.amount, cur.n,
         round(cur.amount / tot.total, 4), coalesce(prev.amount, 0)
  from cur
  cross join tot
  left join prev on prev.category_code is not distinct from cur.category_code
  left join public.categories c on c.category_code = cur.category_code
  order by cur.amount desc
$$;

create or replace function public.merchant_leaderboard(p_profile_code text, p_from date, p_to date, p_limit int default 20)
returns table (merchant_code text, merchant_name text, category_code text, category_name text,
               amount numeric, txn_count bigint, avg_amount numeric, last_date date)
language sql
stable
security invoker
set search_path = ''
as $$
  select s.merchant_code, coalesce(m.display_name, min(s.description)),
         mode() within group (order by s.category_code), max(c.name),
         sum(s.spend_aed), count(*), round(avg(s.spend_aed), 2), max(s.txn_date)
  from public.v_spend s
  left join public.merchants m on m.merchant_code = s.merchant_code
  left join public.categories c on c.category_code = s.category_code
  where s.profile_code = p_profile_code and s.txn_date between p_from and p_to
  group by s.merchant_code, m.display_name
  order by sum(s.spend_aed) desc
  limit least(greatest(p_limit, 1), 200)
$$;

create or replace function public.daily_spend(p_profile_code text, p_from date, p_to date)
returns table (day date, amount numeric, txn_count bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select d::date, coalesce(sum(s.spend_aed), 0), count(s.txn_code)
  from generate_series(p_from, p_to, interval '1 day') d
  left join public.v_spend s on s.txn_date = d::date and s.profile_code = p_profile_code
  group by d
  order by d
$$;

-- Needs exact times, so only transactions seen by SMS contribute.
create or replace function public.hour_weekday_pattern(p_profile_code text, p_from date, p_to date)
returns table (dow int, hour int, amount numeric, txn_count bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select extract(isodow from s.txn_at at time zone 'Asia/Dubai')::int,
         extract(hour from s.txn_at at time zone 'Asia/Dubai')::int,
         sum(s.spend_aed), count(*)
  from public.v_spend s
  where s.profile_code = p_profile_code and s.txn_at is not null and s.txn_date between p_from and p_to
  group by 1, 2
  order by 1, 2
$$;

create or replace function public.fx_spend(p_profile_code text, p_from date, p_to date)
returns table (currency text, amount_original numeric, amount_aed numeric, txn_count bigint,
               implied_rate numeric, estimated_share numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select s.currency_original, sum(s.amount_original * sign(s.spend_aed)), sum(s.spend_aed), count(*),
         round(sum(s.spend_aed) / nullif(sum(s.amount_original * sign(s.spend_aed)), 0), 6),
         round(avg(case when s.amount_aed_is_estimate then 1 else 0 end), 3)
  from public.v_spend s
  where s.profile_code = p_profile_code and s.currency_original <> 'AED' and s.txn_date between p_from and p_to
  group by s.currency_original
  order by sum(s.spend_aed) desc
$$;

create or replace function public.statement_cycles(p_profile_code text, p_limit int default 24)
returns table (stmt_code text, account_code text, bank_code text, card_last4 text, kind text,
               statement_date date, period_start date, period_end date, due_date date,
               closing_balance numeric, min_due numeric, credit_limit numeric, utilisation numeric,
               line_count bigint, debits numeric, credits numeric, recon_status text, recon_checks jsonb,
               doc_code text)
language sql
stable
security invoker
set search_path = ''
as $$
  select st.stmt_code, st.account_code, a.bank_code, st.primary_card_last4, st.kind,
         st.statement_date, st.period_start, st.period_end, st.due_date,
         st.closing_balance, st.min_due, coalesce(st.credit_limit, a.credit_limit),
         round(st.closing_balance / nullif(coalesce(st.credit_limit, a.credit_limit), 0), 4),
         (select count(*) from public.statement_lines l where l.stmt_code = st.stmt_code and l.is_current),
         (select coalesce(sum(l.amount_aed), 0) from public.statement_lines l
           where l.stmt_code = st.stmt_code and l.is_current and l.direction = 'debit'),
         (select coalesce(sum(l.amount_aed), 0) from public.statement_lines l
           where l.stmt_code = st.stmt_code and l.is_current and l.direction = 'credit'),
         r.status, r.checks, st.doc_code
  from public.statements st
  join public.accounts a on a.account_code = st.account_code
  left join public.statement_recon r on r.stmt_code = st.stmt_code
  where st.profile_code = p_profile_code and st.status = 'active'
  order by st.statement_date desc
  limit least(greatest(p_limit, 1), 500)
$$;

create or replace function public.yoy_compare(p_profile_code text, p_year int default null)
returns table (month int, this_year numeric, last_year numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  with y as (select coalesce(p_year, extract(year from public.dubai_date(now()))::int) as yr)
  select m,
         coalesce((select sum(s.spend_aed) from public.v_spend s
                   where s.profile_code = p_profile_code
                     and extract(year from s.txn_date) = y.yr and extract(month from s.txn_date) = m), 0),
         coalesce((select sum(s.spend_aed) from public.v_spend s
                   where s.profile_code = p_profile_code
                     and extract(year from s.txn_date) = y.yr - 1 and extract(month from s.txn_date) = m), 0)
  from y, generate_series(1, 12) m
  order by m
$$;

-- Outliers: > mean + 3σ of the same merchant (≥5 prior samples) or category
-- (≥10 prior samples) over the preceding 12 months, or a first-time merchant
-- above AED 500.
create or replace function public.anomalies(p_profile_code text, p_from date, p_to date)
returns table (txn_code text, txn_date date, description text, amount numeric, reason text,
               baseline_mean numeric, baseline_sd numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  with cur as (
    select * from public.v_spend s
    where s.profile_code = p_profile_code and s.txn_date between p_from and p_to and s.spend_aed > 0
  ),
  scored as (
    select c.txn_code, c.txn_date, c.description, c.spend_aed,
           mh.n as m_n, mh.mean as m_mean, mh.sd as m_sd,
           ch.n as c_n, ch.mean as c_mean, ch.sd as c_sd
    from cur c
    left join lateral (
      select count(*) n, avg(h.spend_aed) mean, stddev_samp(h.spend_aed) sd
      from public.v_spend h
      where h.profile_code = p_profile_code and h.merchant_code = c.merchant_code and h.spend_aed > 0
        and h.txn_date >= c.txn_date - 365 and h.txn_date < c.txn_date
    ) mh on true
    left join lateral (
      select count(*) n, avg(h.spend_aed) mean, stddev_samp(h.spend_aed) sd
      from public.v_spend h
      where h.profile_code = p_profile_code and h.category_code is not distinct from c.category_code
        and h.spend_aed > 0 and h.txn_date >= c.txn_date - 365 and h.txn_date < c.txn_date
    ) ch on true
  )
  select txn_code, txn_date, description, spend_aed,
         case
           when m_n >= 5 and spend_aed > m_mean + 3 * coalesce(m_sd, 0) and spend_aed > m_mean * 1.5 then 'merchant_outlier'
           when c_n >= 10 and spend_aed > c_mean + 3 * coalesce(c_sd, 0) then 'category_outlier'
           when m_n = 0 and spend_aed >= 500 then 'new_merchant_large'
         end,
         round(coalesce(case when m_n >= 5 then m_mean end, c_mean), 2),
         round(coalesce(case when m_n >= 5 then m_sd end, c_sd), 2)
  from scored
  where (m_n >= 5 and spend_aed > m_mean + 3 * coalesce(m_sd, 0) and spend_aed > m_mean * 1.5)
     or (c_n >= 10 and spend_aed > c_mean + 3 * coalesce(c_sd, 0))
     or (m_n = 0 and spend_aed >= 500)
  order by spend_aed desc
$$;

create or replace function public.filter_meta(p_profile_code text)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('account_code', a.account_code, 'bank_code', a.bank_code,
                  'nickname', a.nickname, 'product_name', a.product_name) order by a.bank_code)
                from public.accounts a where a.profile_code = p_profile_code), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('card_code', c.card_code, 'account_code', c.account_code,
                  'bank_code', c.bank_code, 'last4', c.last4, 'is_supplementary', c.is_supplementary) order by c.bank_code, c.last4)
                from public.cards c where c.profile_code = p_profile_code), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('category_code', c.category_code, 'name', c.name,
                  'kind', c.kind, 'color_token', c.color_token, 'parent_code', c.parent_code, 'archived', c.archived_at is not null)
                  order by c.sort_order, c.name)
                from public.categories c where c.profile_code = p_profile_code), '[]'::jsonb),
    'banks', coalesce((select jsonb_agg(jsonb_build_object('bank_code', b.bank_code, 'name', b.name) order by b.bank_code)
                from public.banks b), '[]'::jsonb),
    'date_range', (select jsonb_build_object('min', min(txn_date), 'max', max(txn_date))
                from public.transactions where profile_code = p_profile_code)
  )
$$;

grant execute on function public.overview(text, date), public.spend_series(text, date, date, text, text),
  public.category_breakdown(text, date, date), public.merchant_leaderboard(text, date, date, int),
  public.daily_spend(text, date, date), public.hour_weekday_pattern(text, date, date),
  public.fx_spend(text, date, date), public.statement_cycles(text, int), public.yoy_compare(text, int),
  public.anomalies(text, date, date), public.filter_meta(text)
  to authenticated, service_role;

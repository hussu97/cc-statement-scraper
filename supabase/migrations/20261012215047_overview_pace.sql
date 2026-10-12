-- Overview pace (audit WEB-26): a month-to-date baseline and a projected month end.
--
-- The web pace rule set month-to-date spend against `spend_avg_3m`, a full-month average, so on
-- the 8th it read "way under" whatever the month was doing. `overview` now also returns:
--
--   spend_avg_3m_to_date  The previous 3 months' spend up to the same day of the month, averaged
--                         over 3 (like spend_avg_3m), from public.v_spend (CLAUDE.md §1.12) on
--                         Asia/Dubai business dates. "The same day" is public.month_to_date_end:
--                           * day d of the viewed month covers days 1..d of each earlier month,
--                             clamped to that month's length (31 Oct covers all of September);
--                           * the viewed month's last day covers each earlier month in full
--                             (28 Feb covers all 31 days of January), so on the last day the
--                             to-date average equals spend_avg_3m;
--                           * a completed (past) month compares whole months; a future month
--                             compares nothing (0.00).
--   projected_month_end   Where the month is heading (public.spend_pace):
--                           * current month, with spend in the previous 3 months:
--                               spend + (rest-of-month spend in those months) / n
--                             where n is the number of those months that have any spend (1-3),
--                             i.e. what is spent so far plus what the months with history spent,
--                             on average, in the rest of the month. With 3 months of history this
--                             is spend + (spend_avg_3m − spend_avg_3m_to_date); dividing by 3 when
--                             only 1-2 months have data would project a young ledger too low. It follows the month's usual
--                             shape (rent on the 1st, a mid-month bill) instead of extrapolating
--                             the first few days, and it equals spend on the last day.
--                           * current month, no spend in the previous 3 months (a new ledger):
--                               spend / d × days_in_month   (the run rate, d = today's day)
--                           * a completed month: spend. A future month: null.
--
-- Both are numeric(14,2) decimal strings (§1.3); every existing overview field is unchanged, so
-- older web and iOS clients keep decoding. public.spend_pace takes `p_today` so pgTAP can pin
-- the edges (month start, 30 Oct vs 31 Aug, 31 Oct vs 30 Sep, February); overview passes the
-- Dubai date. Both run as the caller (security invoker, like overview), so RLS scopes every row
-- to the caller's profiles; private.assert_member is not reachable from an invoker function
-- (client roles have no USAGE on `private`), and the RLS policies are the guard here.

-- Exclusive end of the "same day of the month" window inside p_month, for p_viewed_month as
-- seen on p_today. Pure; see the header for the rules.
create or replace function public.month_to_date_end(p_month date, p_viewed_month date, p_today date)
returns date
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
    -- the viewed month is complete (today is its last day, or later): whole months
    when p_today >= (date_trunc('month', p_viewed_month) + interval '1 month')::date - 1
      then (date_trunc('month', p_month) + interval '1 month')::date
    -- the viewed month has not started: nothing
    when p_today < date_trunc('month', p_viewed_month)::date
      then date_trunc('month', p_month)::date
    -- days 1..d, clamped to p_month's length
    else least(date_trunc('month', p_month)::date + extract(day from p_today)::int,
               (date_trunc('month', p_month) + interval '1 month')::date)
  end
$$;

-- The pace figures for one month as seen on p_today (default: today in Dubai).
create or replace function public.spend_pace(p_profile_code text, p_month date default null, p_today date default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_today date := coalesce(p_today, public.dubai_date(now()));
  v_month date := date_trunc('month', coalesce(p_month, v_today))::date;
  v_next date := (v_month + interval '1 month')::date;
  v_from date := (v_month - interval '3 month')::date;
  v_days int := v_next - v_month;
  v_spend numeric;
  v_avg_3m numeric;
  v_avg_to_date numeric;
  v_rest numeric;
  v_months int;
  v_projected numeric;
begin
  -- The same three sums overview makes, so the figures line up with its spend and spend_avg_3m.
  v_spend := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_month and txn_date < v_next), 0);
  select coalesce(round(sum(s.spend_aed) / 3, 2), 0),
         coalesce(round(sum(s.spend_aed) filter (
                    where s.txn_date < public.month_to_date_end(s.txn_date, v_month, v_today)) / 3, 2), 0),
         coalesce(sum(s.spend_aed) filter (
                    where s.txn_date >= public.month_to_date_end(s.txn_date, v_month, v_today)), 0),
         count(distinct date_trunc('month', s.txn_date))
  into v_avg_3m, v_avg_to_date, v_rest, v_months
  from public.v_spend s
  where s.profile_code = p_profile_code and s.txn_date >= v_from and s.txn_date < v_month;

  v_projected := case
    when v_today < v_month then null                                     -- future month
    when v_today >= v_next - 1 then v_spend                              -- complete (or its last day)
    when v_months > 0 then v_spend + v_rest / v_months                   -- the usual rest of the month
    else v_spend / extract(day from v_today)::int * v_days               -- run rate, no history
  end;

  return jsonb_build_object(
    'spend_avg_3m_to_date', v_avg_to_date::numeric(14,2)::text,
    'projected_month_end', round(v_projected, 2)::numeric(14,2)::text);
end;
$$;

create or replace function public.overview(p_profile_code text, p_month date default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_today date := public.dubai_date(now());
  v_month date := date_trunc('month', coalesce(p_month, v_today))::date;
  v_next date := (v_month + interval '1 month')::date;
  v_prev date := (v_month - interval '1 month')::date;
  v_prev_mtd_end date := public.prev_month_to_date_end(v_month, v_today);
  v_spend numeric;
  v_prev_month numeric;
  v_prev_mtd numeric;
  v_avg_3m numeric;
  v_base numeric;
  v_pace jsonb := public.spend_pace(p_profile_code, v_month, v_today);
  r jsonb;
begin
  v_spend := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_month and txn_date < v_next), 0);
  v_prev_month := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_prev and txn_date < v_month), 0);
  -- same day-of-month last month, for a fair month-to-date comparison (DB-18)
  v_prev_mtd := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_prev and txn_date < v_prev_mtd_end), 0);
  v_avg_3m := coalesce((select round(sum(spend_aed) / 3, 2) from public.v_spend
                       where profile_code = p_profile_code
                         and txn_date >= (v_month - interval '3 month')::date and txn_date < v_month), 0);
  v_base := case when v_month < date_trunc('month', v_today)::date then v_prev_month else v_prev_mtd end;

  select jsonb_build_object(
    'month', v_month,
    'spend', v_spend::text,
    'spend_prev_month', v_prev_month::text,
    'spend_prev_month_to_date', v_prev_mtd::text,
    'spend_avg_3m', v_avg_3m::text,
    -- The 3-month average up to the same day of the month, and the projected month end (WEB-26;
    -- public.spend_pace documents both).
    'spend_avg_3m_to_date', v_pace->>'spend_avg_3m_to_date',
    'projected_month_end', v_pace->>'projected_month_end',
    'change_vs_prev_month_to_date', round((v_spend - v_base) / nullif(v_base, 0), 4)::text,
    'change_vs_avg_3m', round((v_spend - v_avg_3m) / nullif(v_avg_3m, 0), 4)::text,
    'payments', coalesce((select sum(amount_aed) from public.transactions
                       where profile_code = p_profile_code and kind = 'payment' and direction = 'credit'
                         and status in ('pending', 'posted') and txn_date >= v_month and txn_date < v_next), 0)::text,
    -- What the active cards owe today (v_account_balances): positive is owed, negative is credit.
    -- Complete only when every active account has a balance anchor and every AED amount is known.
    'outstanding', (select coalesce(sum(b.outstanding_aed), 0)::numeric(14,2)::text
                    from public.v_account_balances b join public.accounts a on a.account_code = b.account_code
                    where b.profile_code = p_profile_code and a.status = 'active'),
    'outstanding_complete', coalesce((select bool_and(b.anchor_kind <> 'none' and b.unpriced_count = 0)
                    from public.v_account_balances b join public.accounts a on a.account_code = b.account_code
                    where b.profile_code = p_profile_code and a.status = 'active'), true),
    'outstanding_has_estimate', coalesce((select bool_or(b.has_estimate)
                    from public.v_account_balances b join public.accounts a on a.account_code = b.account_code
                    where b.profile_code = p_profile_code and a.status = 'active'), false),
    'pending_count', (select count(*) from public.transactions where profile_code = p_profile_code and status = 'pending'),
    'pending_amount', coalesce((select sum(case when direction = 'debit' then amount_aed else -amount_aed end)
                       from public.transactions where profile_code = p_profile_code and status = 'pending'), 0)::text,
    -- Pending foreign charges with no rate yet: not in spend or pending_amount (DB-45).
    'pending_unpriced_count', (select count(*) from public.transactions
                       where profile_code = p_profile_code and status = 'pending' and amount_aed is null),
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
        'logo_path', (select b.logo_path from public.banks b where b.bank_code = a.bank_code),
        'last4', (select string_agg(cd.last4, ',' order by cd.is_supplementary, cd.last4)
                  from public.cards cd where cd.account_code = a.account_code),
        'latest_statement', (
          select jsonb_build_object('stmt_code', st.stmt_code, 'statement_date', st.statement_date,
            'due_date', st.due_date, 'closing_balance', st.closing_balance::text, 'min_due', st.min_due::text)
          from public.statements st
          where st.account_code = a.account_code and st.kind = 'statement' and st.status = 'active'
          order by st.statement_date desc limit 1),
        -- A card in credit has used none of its limit (DB-39).
        'utilisation', (
          select round(greatest(st.closing_balance, 0) / nullif(coalesce(st.credit_limit, a.credit_limit), 0), 4)::text
          from public.statements st
          where st.account_code = a.account_code and st.kind = 'statement' and st.status = 'active'
          order by st.statement_date desc limit 1),
        'unbilled_aed', coalesce((
          select sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)
          from public.transactions t
          where t.account_code = a.account_code and t.status in ('pending', 'posted')
            and t.txn_date > coalesce((select max(st.statement_date) from public.statements st
                                       where st.account_code = a.account_code and st.kind = 'statement'
                                         and st.status = 'active'), '1900-01-01'::date)), 0)::text,
        -- The balance the bank would show now, and what it is anchored on (v_account_balances).
        'outstanding_aed', b.outstanding_aed::text,
        'balance_anchor', b.anchor_kind,
        'balance_anchor_date', b.anchor_date,
        'balance_has_estimate', b.has_estimate,
        'balance_unpriced_count', b.unpriced_count
      ) order by a.bank_code)
      from public.accounts a
      join public.v_account_balances b on b.account_code = a.account_code
      where a.profile_code = p_profile_code and a.status = 'active'), '[]'::jsonb),
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

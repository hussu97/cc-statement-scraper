-- Statement payment status (audit UX-1r server part, WEB-36; CLAUDE.md §2.2).
--
-- The overview card and the statements list showed a due date but never whether it was paid: a
-- past due date read the same paid or not, and the web would have had to match payments itself.
-- The server now says it, per statement cycle:
--
--   amount_paid     card repayments (transactions kind 'payment', direction 'credit', pending or
--                   posted, with an AED amount) dated after the statement date, up to and including
--                   the account's next statement date (open-ended while there is none). A payment on
--                   the statement date itself is already inside that statement's closing balance.
--   payment_status  one of
--                     'paid'       amount_paid covers the closing balance (or nothing was owed:
--                                  closing balance ≤ 0);
--                     'overdue'    the due date has passed (Asia/Dubai, §1.4) and amount_paid so
--                                  far is less than the minimum due (with no minimum on the
--                                  statement: nothing has been paid). A minimum paid late makes it
--                                  'part_paid', a late payment of the whole balance 'paid';
--                     'part_paid'  something was paid but not the whole balance, and it is not
--                                  overdue (before the due date, or the minimum is covered);
--                     'unpaid'     nothing paid yet and not overdue (due today or later, or no due
--                                  date on the statement);
--                     null         unknown: the statement has no closing balance.
--   History extracts have no due amount: both are null.
--
-- One definition, public.v_statement_payments (security_invoker), read by:
--   • overview         accounts[].latest_statement.{payment_status, amount_paid};
--   • statement_cycles two appended columns payment_status, amount_paid (text: money crosses the
--                      wire as a decimal string, §1.3). A new OUT column changes the return type,
--                      so the function is dropped first;
--   • statement_detail statement.{payment_status, amount_paid}.
-- iOS decodes both names as optional; older clients ignore them.

create view public.v_statement_payments with (security_invoker = true) as
select st.profile_code,
       st.stmt_code,
       st.account_code,
       p.amount_paid,
       case
         when st.closing_balance is null then null
         when st.closing_balance <= 0 or p.amount_paid >= st.closing_balance then 'paid'
         when st.due_date is not null and public.dubai_date(now()) > st.due_date
              and case when st.min_due is null then p.amount_paid <= 0 else p.amount_paid < st.min_due end
           then 'overdue'
         when p.amount_paid > 0 then 'part_paid'
         else 'unpaid'
       end as payment_status
from public.statements st
cross join lateral (
  select min(n.statement_date) as next_statement_date
  from public.statements n
  where n.account_code = st.account_code and n.kind = 'statement' and n.status = 'active'
    and n.statement_date > st.statement_date
) nx
cross join lateral (
  select coalesce(sum(t.amount_aed), 0)::numeric(14,2) as amount_paid
  from public.transactions t
  where t.account_code = st.account_code
    and t.kind = 'payment' and t.direction = 'credit' and t.status in ('pending', 'posted')
    and t.amount_aed is not null
    and t.txn_date > st.statement_date
    and (nx.next_statement_date is null or t.txn_date <= nx.next_statement_date)
) p
where st.kind = 'statement';

grant select on public.v_statement_payments to authenticated, service_role;

-- ── statement_cycles: two appended columns ─────────────────────────────────
drop function if exists public.statement_cycles(text, integer);
create function public.statement_cycles(p_profile_code text, p_limit integer default 24)
returns table (stmt_code text, account_code text, bank_code text, card_last4 text, kind text, statement_date date,
               period_start date, period_end date, due_date date, closing_balance numeric, min_due numeric,
               credit_limit numeric, utilisation numeric, line_count bigint, debits numeric, credits numeric,
               recon_status text, recon_checks jsonb, doc_code text, logo_path text,
               payment_status text, amount_paid text)
language sql
stable
set search_path = ''
as $$
  select st.stmt_code, st.account_code, a.bank_code, st.primary_card_last4, st.kind,
         st.statement_date, st.period_start, st.period_end, st.due_date,
         st.closing_balance, st.min_due, coalesce(st.credit_limit, a.credit_limit),
         round(greatest(st.closing_balance, 0) / nullif(coalesce(st.credit_limit, a.credit_limit), 0), 4),
         (select count(*) from public.statement_lines l where l.stmt_code = st.stmt_code and l.is_current),
         (select coalesce(sum(l.amount_aed), 0) from public.statement_lines l
           where l.stmt_code = st.stmt_code and l.is_current and l.direction = 'debit'),
         (select coalesce(sum(l.amount_aed), 0) from public.statement_lines l
           where l.stmt_code = st.stmt_code and l.is_current and l.direction = 'credit'),
         r.status, r.checks, st.doc_code, b.logo_path,
         sp.payment_status, sp.amount_paid::text
  from public.statements st
  join public.accounts a on a.profile_code = st.profile_code and a.account_code = st.account_code
  join public.banks b on b.bank_code = a.bank_code
  left join public.statement_recon r on r.stmt_code = st.stmt_code
  left join public.v_statement_payments sp on sp.profile_code = st.profile_code and sp.stmt_code = st.stmt_code
  where st.profile_code = p_profile_code and st.status = 'active'
  order by st.statement_date desc
  limit least(greatest(p_limit, 1), 5000)
$$;
grant execute on function public.statement_cycles(text, integer) to authenticated, service_role;

-- ── overview: latest_statement carries the status ──────────────────────────
-- Unchanged from 20261012215047 except latest_statement's two new keys.
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
        -- payment_status / amount_paid: public.v_statement_payments (UX-1r, WEB-36).
        'latest_statement', (
          select jsonb_build_object('stmt_code', st.stmt_code, 'statement_date', st.statement_date,
            'due_date', st.due_date, 'closing_balance', st.closing_balance::text, 'min_due', st.min_due::text,
            'payment_status', sp.payment_status, 'amount_paid', sp.amount_paid::text)
          from public.statements st
          left join public.v_statement_payments sp on sp.profile_code = st.profile_code and sp.stmt_code = st.stmt_code
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

-- ── statement_detail: the statement header carries the status ──────────────
-- Unchanged from 20261010000200 except the header's two new keys.
create or replace function public.statement_detail(p_profile_code text, p_stmt_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  st public.statements%rowtype;
  v_bank text;
  v_lines jsonb;
  v_last4s text[];
begin
  perform private.assert_member(p_profile_code, false);
  select * into st from public.statements s where s.stmt_code = p_stmt_code and s.profile_code = p_profile_code;
  if not found then
    raise exception 'unknown statement %', p_stmt_code using errcode = 'P0002';
  end if;
  select a.bank_code into v_bank from public.accounts a
  where a.account_code = st.account_code and a.profile_code = p_profile_code;

  with lines as (
    select l.line_code, l.line_no, l.txn_date, l.posting_date, l.description_raw, l.direction, l.kind,
           l.amount_aed, l.amount_original, l.currency_original,
           coalesce(l.card_last4, cd.last4) as card_last4,
           t.txn_code, t.effective_category_code, m.display_name as merchant_name
    from public.statement_lines l
    left join public.cards cd on cd.card_code = l.card_code and cd.profile_code = p_profile_code
    left join lateral (
      select e.txn_code from public.transaction_evidence e
      where e.line_code = l.line_code and e.profile_code = p_profile_code and e.is_active
      order by e.created_at limit 1
    ) ev on true
    left join public.transactions t on t.txn_code = ev.txn_code and t.profile_code = p_profile_code
    left join public.merchants m on m.merchant_code = t.merchant_code
    where l.stmt_code = st.stmt_code and l.profile_code = p_profile_code and l.is_current
  ),
  sides as (
    select x.direction,
           count(*) as n,
           sum(x.amount_aed) as total,
           jsonb_agg(jsonb_build_object(
             'line_code', x.line_code, 'txn_code', x.txn_code, 'txn_date', x.txn_date,
             'posting_date', x.posting_date, 'description', x.description_raw,
             'merchant_name', x.merchant_name, 'amount_aed', x.amount_aed::text,
             'amount_original', x.amount_original::text, 'currency_original', x.currency_original,
             'category_code', x.effective_category_code, 'kind', x.kind, 'card_last4', x.card_last4)
             order by x.txn_date, x.line_no, x.line_code) as lines
    from lines x
    group by x.direction
  )
  select jsonb_object_agg(s.direction, jsonb_build_object(
           'count', s.n, 'total', coalesce(s.total, 0)::numeric(14,2)::text, 'lines', s.lines))
  into v_lines
  from sides s;

  select coalesce(array_agg(distinct x.last4 order by x.last4), '{}'::text[]) into v_last4s
  from (
    select st.primary_card_last4 as last4
    union
    select coalesce(l.card_last4, cd.last4)
    from public.statement_lines l
    left join public.cards cd on cd.card_code = l.card_code and cd.profile_code = p_profile_code
    where l.stmt_code = st.stmt_code and l.profile_code = p_profile_code and l.is_current
  ) x
  where x.last4 is not null;

  return jsonb_build_object(
    'statement', (
      select jsonb_build_object(
        'stmt_code', st.stmt_code, 'kind', st.kind, 'bank_code', v_bank, 'account_code', st.account_code,
        'card_last4s', to_jsonb(v_last4s), 'statement_date', st.statement_date,
        'period_start', st.period_start, 'period_end', st.period_end, 'due_date', st.due_date,
        'opening_balance', st.opening_balance::text, 'closing_balance', st.closing_balance::text,
        'total_debits', st.total_debits::text, 'total_credits', st.total_credits::text,
        'min_due', st.min_due::text, 'credit_limit', st.credit_limit::text, 'doc_code', st.doc_code,
        -- closing / limit, never negative (a card in credit has used none of it, DB-39).
        'utilisation', round(greatest(st.closing_balance, 0) / nullif(coalesce(st.credit_limit,
          (select ac.credit_limit from public.accounts ac where ac.account_code = st.account_code)), 0), 4)::text,
        'recon_status', r.status, 'recon_checks', r.checks,
        -- public.v_statement_payments (UX-1r, WEB-36); null for a history extract.
        'payment_status', sp.payment_status, 'amount_paid', sp.amount_paid::text)
      from (select 1) one
      left join public.statement_recon r on r.stmt_code = st.stmt_code and r.profile_code = p_profile_code
      left join public.v_statement_payments sp on sp.profile_code = p_profile_code and sp.stmt_code = st.stmt_code),
    'debits', coalesce(v_lines->'debit', jsonb_build_object('count', 0, 'total', '0.00', 'lines', '[]'::jsonb)),
    'credits', coalesce(v_lines->'credit', jsonb_build_object('count', 0, 'total', '0.00', 'lines', '[]'::jsonb))
  );
end;
$$;

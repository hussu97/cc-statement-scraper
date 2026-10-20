-- A cash_advance insight (financial audit 2026-10-20): every cash advance of the last 30 days,
-- with the bank's same-day CASH ADVANCE FEE, linking to the transaction. A cash withdrawal on a
-- credit card is expensive (a fee, and interest from day one) and was invisible as a "purchase"
-- until 20261020120340_cash_advance_backfill. The insights kind CHECK gains 'cash_advance';
-- private.generate_insights is otherwise identical to 20261013183327_statement_due_skips_paid.

alter table public.insights drop constraint insights_kind_check;
alter table public.insights add constraint insights_kind_check check (kind in
  ('spend_pace', 'category_spike', 'budget_risk', 'price_change', 'new_recurring', 'statement_due',
   'uncategorized', 'review_backlog', 'large_transaction', 'cash_advance'));

CREATE OR REPLACE FUNCTION private.generate_insights(p_profile_code text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_today date := public.dubai_date(now());
  v_month date := date_trunc('month', v_today)::date;
  v_day int := extract(day from v_today)::int;
  v_days_in_month int := extract(day from ((v_month + interval '1 month')::date - 1))::int;
  v_count int := 0;
  n int;
begin
  -- Category spending ahead of its usual pace this month.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'category_spike', case when cur > base * 2 then 'alert' else 'warn' end,
         x.category_code || ':' || v_month,
         x.name || ' is running ' || round((cur / base - 1) * 100) || '% above usual',
         'You''ve spent ' || private.fmt_aed(cur) || ' on ' || x.name || ' so far this month, against a typical '
           || private.fmt_aed(base) || ' by day ' || v_day || '.',
         jsonb_build_object('category_code', x.category_code, 'current', cur::text, 'baseline', base::text),
         (v_month + interval '1 month')::date - 1
  from (
    select s.category_code, c.name,
           sum(s.spend_aed) filter (where s.txn_date >= v_month) as cur,
           sum(s.spend_aed) filter (where s.txn_date < v_month
                                      and extract(day from s.txn_date) <= v_day) / 3 as base
    from public.v_spend s join public.categories c on c.category_code = s.category_code
    where s.profile_code = p_profile_code and s.txn_date >= (v_month - interval '3 month')::date
    group by s.category_code, c.name
  ) x
  where x.base > 0 and x.cur > x.base * 1.3 and x.cur - x.base > 200
  on conflict (profile_code, kind, dedupe_key) do update
    set title = excluded.title, body = excluded.body, data = excluded.data, severity = excluded.severity;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Budgets projected to overrun.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'budget_risk', case when b.share_used >= 1 then 'alert' else 'warn' end,
         -- A card's budget keys on the card too; an all-cards budget keeps its old key.
         coalesce(b.category_code, 'total') || coalesce('@' || b.account_code, '') || ':' || v_month,
         case when b.account_code is null then b.category_name
              when b.category_code is null then b.account_name
              else b.category_name || ' on ' || b.account_name end
           || case when b.share_used >= 1 then ' budget exceeded' else ' budget at risk' end,
         private.fmt_aed(b.spent_aed) || ' of ' || private.fmt_aed(b.budget_aed) || ' spent; on pace for '
           || private.fmt_aed(b.projected_aed) || ' this month.',
         jsonb_build_object('budget_code', b.budget_code, 'spent', b.spent_aed::text, 'projected', b.projected_aed::text),
         (v_month + interval '1 month')::date - 1
  from public.budget_status(p_profile_code, v_month) b
  where b.projected_aed > b.budget_aed and v_day >= 5
  on conflict (profile_code, kind, dedupe_key) do update
    set title = excluded.title, body = excluded.body, data = excluded.data, severity = excluded.severity;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Subscription price changes.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data)
  select p_profile_code, 'price_change', 'info', r.recurring_code || ':' || r.last_date,
         m.display_name || ' changed price',
         m.display_name || ' charged ' || private.fmt_aed(r.last_amount) || ', usually ' || private.fmt_aed(r.expected_amount) || '.',
         jsonb_build_object('recurring_code', r.recurring_code)
  from public.recurring_series r join public.merchants m on m.merchant_code = r.merchant_code
  where r.profile_code = p_profile_code and r.status = 'active' and r.last_date >= v_today - 14
    and abs(r.last_amount - r.expected_amount) > greatest(r.expected_amount * 0.05, 1)
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Statements due soon.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'statement_due', case when st.due_date - v_today <= 2 then 'alert' else 'warn' end,
         st.stmt_code,
         a.bank_code || ' payment due ' || to_char(st.due_date, 'FMDD Mon'),
         coalesce('Closing balance ' || private.fmt_aed(st.closing_balance), 'Statement')
           || coalesce(', minimum due ' || private.fmt_aed(st.min_due), '') || '.',
         jsonb_build_object('stmt_code', st.stmt_code, 'due_date', st.due_date),
         st.due_date
  from public.statements st join public.accounts a on a.account_code = st.account_code
  where st.profile_code = p_profile_code and st.kind = 'statement' and st.status = 'active'
    and st.due_date between v_today and v_today + 5
    -- A statement the payments already cover needs no reminder (v_statement_payments).
    and not exists (select 1 from public.v_statement_payments sp
                    where sp.stmt_code = st.stmt_code and sp.payment_status = 'paid')
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Housekeeping nudges.
  select count(*) into n from public.v_spend
  where profile_code = p_profile_code and category_code is null and txn_date >= v_today - 30;
  if n >= 10 then
    insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
    values (p_profile_code, 'uncategorized', 'info', to_char(v_today, 'IYYY-IW'),
            n || ' transactions need a category', 'Categorise them once and set a rule so it sticks.',
            jsonb_build_object('count', n), v_today + 7)
    on conflict (profile_code, kind, dedupe_key) do update set title = excluded.title, data = excluded.data;
    v_count := v_count + 1;
  end if;

  -- Total spend ahead of its usual pace this month (DB-29r).
  if v_day >= 5 then
    insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
    select p_profile_code, 'spend_pace', case when x.cur > x.base * 1.5 then 'alert' else 'warn' end,
           v_month::text,
           'Spending is ' || round((x.cur / x.base - 1) * 100) || '% ahead of your usual pace',
           private.fmt_aed(x.cur) || ' spent by day ' || v_day || ', against a typical ' || private.fmt_aed(x.base)
             || '; on pace for ' || private.fmt_aed(round(x.cur / v_day * v_days_in_month, 2)) || ' this month.',
           jsonb_build_object('current', x.cur::text, 'baseline', x.base::text,
                              'projected', round(x.cur / v_day * v_days_in_month, 2)::text),
           (v_month + interval '1 month')::date - 1
    from (
      select sum(s.spend_aed) filter (where s.txn_date >= v_month) as cur,
             round(sum(s.spend_aed) filter (where s.txn_date < v_month
                                              and extract(day from s.txn_date) <= v_day) / 3, 2) as base
      from public.v_spend s
      where s.profile_code = p_profile_code and s.txn_date >= (v_month - interval '3 month')::date
    ) x
    where x.base > 0 and x.cur > x.base * 1.25 and x.cur - x.base > 500
    on conflict (profile_code, kind, dedupe_key) do update
      set title = excluded.title, body = excluded.body, data = excluded.data, severity = excluded.severity;
    get diagnostics n = row_count; v_count := v_count + n;
  end if;

  -- Newly detected subscriptions (DB-29r).
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'new_recurring', 'info', r.recurring_code,
         'New ' || r.cadence || ' charge: ' || m.display_name,
         m.display_name || ' has charged about ' || private.fmt_aed(r.expected_amount) || ' ' || r.occurrences
           || ' times; next expected ' || to_char(r.next_expected, 'FMDD Mon') || '.',
         jsonb_build_object('recurring_code', r.recurring_code, 'merchant_code', r.merchant_code),
         v_today + 14
  from public.recurring_series r join public.merchants m on m.merchant_code = r.merchant_code
  where r.profile_code = p_profile_code and r.status = 'active' and r.detected_by = 'auto'
    and r.created_at >= now() - interval '7 days'
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Unusually large charges of the last three days, from public.anomalies (DB-29r).
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'large_transaction', 'warn', a.txn_code,
         'Unusually large: ' || coalesce(nullif(btrim(a.merchant_name), ''), initcap(lower(left(a.description, 40)))),
         private.fmt_aed(a.amount) || case when a.reason = 'new_merchant_large' then ' at a merchant you haven''t used before.'
                                        else ', usually about ' || private.fmt_aed(a.baseline_mean) || '.' end,
         jsonb_build_object('txn_code', a.txn_code, 'amount', a.amount::text, 'reason', a.reason),
         v_today + 14
  from public.anomalies(p_profile_code, v_today - 3, v_today) a
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Cash advances (financial audit 2026-10-20): every one, since each carries a fee and interest
  -- from the day it is taken, with no grace period. The bank's CASH ADVANCE FEE (and its VAT) on
  -- the same card account and day is shown with it. Kept 30 days from the withdrawal.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'cash_advance', 'warn', t.txn_code,
         'Cash advance: ' || coalesce(nullif(btrim(m.display_name), ''), initcap(lower(left(t.description, 40)))),
         private.fmt_aed(t.amount_aed)
           || case when t.currency_original <> 'AED'
                   then ' (' || t.currency_original || ' ' || to_char(t.amount_original, 'FM999,999,990.00') || ')'
                   else '' end
           || ' withdrawn on ' || to_char(t.txn_date, 'FMDD Mon')
           || case when f.fee is not null then ', plus ' || private.fmt_aed(f.fee) || ' in fees' else '' end
           || '. Cash advances accrue interest from the day they''re taken.',
         jsonb_build_object('txn_code', t.txn_code, 'amount', t.amount_aed::text, 'fee', f.fee::text),
         t.txn_date + 30
  from public.transactions t
  left join public.merchants m on m.merchant_code = t.merchant_code
  left join lateral (
    select sum(x.amount_aed) as fee
    from public.transactions x
    where x.profile_code = t.profile_code and x.account_code = t.account_code and x.txn_date = t.txn_date
      and x.status in ('pending', 'posted') and x.direction = 'debit' and x.kind = 'fee'
      and x.description ~ '^(VAT ON )?CASH ADV(ANCE)? FEE\M'
  ) f on true
  where t.profile_code = p_profile_code and t.kind = 'cash_advance' and t.direction = 'debit'
    and t.status in ('pending', 'posted') and t.amount_aed is not null
    and t.txn_date >= v_today - 30
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Review backlog nudge (DB-29r).
  select count(*) into n from public.match_reviews where profile_code = p_profile_code and status = 'open';
  if n >= 10 then
    insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
    values (p_profile_code, 'review_backlog', 'info', to_char(v_today, 'IYYY-IW'),
            n || ' items to review', 'Some statement lines and messages need a decision before they count.',
            jsonb_build_object('count', n), v_today + 7)
    on conflict (profile_code, kind, dedupe_key) do update set title = excluded.title, data = excluded.data;
    v_count := v_count + 1;
  end if;

  delete from public.insights where profile_code = p_profile_code and valid_until < v_today;
  return v_count;
end;
$function$;

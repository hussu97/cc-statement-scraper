-- Budgets for one card: a budget may name an account (card), and then counts only that
-- card's spend in the month, either all of it or one category's. No account: every card,
-- as before.

alter table public.budgets add column account_code text;
alter table public.budgets add constraint budgets_account_fk
  foreign key (profile_code, account_code) references public.accounts(profile_code, account_code)
  on delete cascade;
create index budgets_account_idx on public.budgets(account_code) where account_code is not null;

-- One budget per scope (card × category) and start month.
drop index public.budgets_uq;
create unique index budgets_uq on public.budgets
  (profile_code, coalesce(account_code, ''), coalesce(category_code, ''), effective_from);

-- budget_status gains the card: its code and display name (nickname, else "BANK · product",
-- as the web's accountLabel). The return type changes, so the function is dropped first.
drop function public.budget_status(text, date);
create function public.budget_status(p_profile_code text, p_month date default null)
returns table (budget_code text, category_code text, category_name text, color_token text,
               budget_aed numeric, spent_aed numeric, projected_aed numeric, share_used numeric,
               account_code text, account_name text, bank_code text)
language sql
stable
security invoker
set search_path = ''
as $$
  with m as (
    select date_trunc('month', coalesce(p_month, public.dubai_date(now())))::date as start
  ),
  b as (
    select distinct on (coalesce(bu.account_code, ''), coalesce(bu.category_code, '')) bu.*
    from public.budgets bu, m
    where bu.profile_code = p_profile_code and bu.effective_from <= m.start
      and (bu.effective_to is null or bu.effective_to >= m.start)
    order by coalesce(bu.account_code, ''), coalesce(bu.category_code, ''), bu.effective_from desc
  ),
  spent as (
    select b.budget_code, coalesce(sum(s.spend_aed), 0) as amount
    from b cross join m
    left join public.v_spend s
      on s.profile_code = p_profile_code
     and s.txn_date >= m.start and s.txn_date < (m.start + interval '1 month')::date
     and (b.category_code is null or s.category_code = b.category_code)
     and (b.account_code is null or s.account_code = b.account_code)
    group by b.budget_code
  ),
  days as (
    select m.start,
           extract(day from ((m.start + interval '1 month')::date - 1))::numeric as in_month,
           least(greatest(public.dubai_date(now()) - m.start + 1, 1),
                 extract(day from ((m.start + interval '1 month')::date - 1))::int)::numeric as elapsed
    from m
  )
  select b.budget_code, b.category_code, coalesce(c.name, 'All spending'), c.color_token,
         b.amount_aed, sp.amount,
         round(sp.amount / days.elapsed * days.in_month, 2),
         round(sp.amount / b.amount_aed, 4),
         b.account_code,
         case when a.account_code is not null
              then coalesce(nullif(btrim(a.nickname), ''), concat_ws(' · ', a.bank_code, a.product_name)) end,
         a.bank_code
  from b
  join spent sp on sp.budget_code = b.budget_code
  cross join days
  left join public.categories c on c.category_code = b.category_code
  left join public.accounts a on a.account_code = b.account_code
  order by b.account_code nulls first, b.category_code nulls first, c.name
$$;
grant execute on function public.budget_status(text, date) to authenticated, service_role;

-- Budget insights name the card, and key on it so two cards' budgets don't collide.
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
         'Unusually large: ' || initcap(lower(left(a.description, 40))),
         private.fmt_aed(a.amount) || case when a.reason = 'new_merchant_large' then ' at a merchant you haven''t used before.'
                                        else ', usually about ' || private.fmt_aed(a.baseline_mean) || '.' end,
         jsonb_build_object('txn_code', a.txn_code, 'amount', a.amount::text, 'reason', a.reason),
         v_today + 14
  from public.anomalies(p_profile_code, v_today - 3, v_today) a
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

-- Merging accounts moves their budgets too.
create or replace function private.merge_accounts(p_profile_code text, p_from text, p_into text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  f public.accounts%rowtype;
  t public.accounts%rowtype;
  v_cards int; v_stmts int; v_lines int; v_txns int; v_sms int; v_reviews int; v_budgets int;
begin
  perform private.lock_profile(p_profile_code);
  select * into f from public.accounts where account_code = p_from and profile_code = p_profile_code;
  select * into t from public.accounts where account_code = p_into and profile_code = p_profile_code;
  if f.account_code is null or t.account_code is null then
    raise exception 'both accounts must belong to profile %', p_profile_code using errcode = 'P0002';
  end if;
  if f.account_code = t.account_code then
    raise exception 'cannot merge an account into itself' using errcode = '22023';
  end if;
  if f.bank_code <> t.bank_code then
    raise exception 'cannot merge a % account into a % account', f.bank_code, t.bank_code using errcode = '22023';
  end if;

  update public.cards set account_code = p_into where account_code = p_from;
  get diagnostics v_cards = row_count;
  update public.statements set account_code = p_into where account_code = p_from;
  get diagnostics v_stmts = row_count;
  update public.statement_lines set account_code = p_into where account_code = p_from;
  get diagnostics v_lines = row_count;
  -- line_key hashes the account: re-key the moved lines so a re-parse of their documents (which
  -- now resolves to p_into) finds them unchanged instead of superseding and re-creating them.
  update public.statement_lines l set line_key = k.line_key
  from (
    select x.line_code, private.statement_line_key(p_into, x.txn_date, x.posting_date, x.amount_original,
             x.currency_original, x.amount_aed, x.direction,
             coalesce((select mo.original from private.masked_originals mo
                        where mo.table_name = 'statement_lines' and mo.row_code = x.line_code
                          and mo.column_name = 'description_raw'), x.description_raw)) as line_key
    from public.statement_lines x
    where x.account_code = p_into
  ) k
  where l.line_code = k.line_code and l.line_key is distinct from k.line_key;
  update public.transactions set account_code = p_into where account_code = p_from;
  get diagnostics v_txns = row_count;
  update public.sms_messages set account_code = p_into where account_code = p_from;
  get diagnostics v_sms = row_count;
  update public.match_reviews set account_code = p_into where account_code = p_from;
  get diagnostics v_reviews = row_count;
  -- A card budget follows its card, unless the surviving card already has one for the
  -- same category and start month (that one wins; the other stays on the closed card).
  update public.budgets b set account_code = p_into
  where b.account_code = p_from
    and not exists (select 1 from public.budgets x
                    where x.profile_code = b.profile_code and x.account_code = p_into
                      and x.category_code is not distinct from b.category_code
                      and x.effective_from = b.effective_from);
  get diagnostics v_budgets = row_count;

  update public.accounts set
    credit_limit = coalesce(f.credit_limit, t.credit_limit),   -- the merged-in account is the newer one
    product_name = coalesce(t.product_name, f.product_name),
    nickname = coalesce(t.nickname, f.nickname),
    cycle_close_day = coalesce(t.cycle_close_day, f.cycle_close_day)
  where account_code = p_into;
  update public.accounts set status = 'closed' where account_code = p_from;

  return jsonb_build_object('account_code', p_into, 'merged_account_code', p_from, 'cards', v_cards,
                            'statements', v_stmts, 'statement_lines', v_lines, 'transactions', v_txns,
                            'sms_messages', v_sms, 'match_reviews', v_reviews,
                            'budgets', v_budgets);
end;
$$;

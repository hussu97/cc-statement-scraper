-- Budgets, recurring charges, an insights feed, and an audit trail.

-- ── budgets ─────────────────────────────────────────────────────────────────
create table public.budgets (
  budget_code text primary key default public.gen_code('bud')
    check (budget_code ~ '^bud_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  category_code text,                                -- null = total monthly spend
  amount_aed numeric(14,2) not null check (amount_aed > 0),
  effective_from date not null check (effective_from = date_trunc('month', effective_from)::date),
  effective_to date check (effective_to is null or effective_to >= effective_from),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (profile_code, category_code) references public.categories(profile_code, category_code)
);
create unique index budgets_uq on public.budgets(profile_code, coalesce(category_code, ''), effective_from);
create trigger budgets_touch before update on public.budgets
  for each row execute function private.touch_updated_at();

alter table public.budgets enable row level security;
create policy budgets_member_read on public.budgets for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy budgets_owner_write on public.budgets for all to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));
grant select, insert, update, delete on public.budgets to authenticated;
grant all on public.budgets to service_role;

create or replace function public.budget_status(p_profile_code text, p_month date default null)
returns table (budget_code text, category_code text, category_name text, color_token text,
               budget_aed numeric, spent_aed numeric, projected_aed numeric, share_used numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  with m as (
    select date_trunc('month', coalesce(p_month, public.dubai_date(now())))::date as start
  ),
  b as (
    select distinct on (coalesce(bu.category_code, '')) bu.*
    from public.budgets bu, m
    where bu.profile_code = p_profile_code and bu.effective_from <= m.start
      and (bu.effective_to is null or bu.effective_to >= m.start)
    order by coalesce(bu.category_code, ''), bu.effective_from desc
  ),
  spent as (
    select b.budget_code, coalesce(sum(s.spend_aed), 0) as amount
    from b cross join m
    left join public.v_spend s
      on s.profile_code = p_profile_code
     and s.txn_date >= m.start and s.txn_date < (m.start + interval '1 month')::date
     and (b.category_code is null or s.category_code = b.category_code)
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
         round(sp.amount / b.amount_aed, 4)
  from b
  join spent sp on sp.budget_code = b.budget_code
  cross join days
  left join public.categories c on c.category_code = b.category_code
  order by b.category_code nulls first
$$;
grant execute on function public.budget_status(text, date) to authenticated, service_role;

-- ── recurring charges ───────────────────────────────────────────────────────
create table public.recurring_series (
  recurring_code text primary key default public.gen_code('rec')
    check (recurring_code ~ '^rec_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  merchant_code text not null references public.merchants(merchant_code) on delete cascade,
  cadence text not null check (cadence in ('weekly', 'monthly', 'yearly')),
  expected_amount numeric(14,2) not null,
  last_amount numeric(14,2) not null,
  amount_cv numeric(6,4),
  occurrences integer not null,
  first_date date not null,
  last_date date not null,
  next_expected date not null,
  status text not null default 'active' check (status in ('active', 'ended', 'dismissed')),
  detected_by text not null default 'auto' check (detected_by in ('auto', 'manual')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_code, merchant_code)
);
create trigger recurring_series_touch before update on public.recurring_series
  for each row execute function private.touch_updated_at();
alter table public.transactions
  add column recurring_code text references public.recurring_series(recurring_code) on delete set null;
create index transactions_recurring_idx on public.transactions(recurring_code) where recurring_code is not null;

alter table public.recurring_series enable row level security;
create policy recurring_member_read on public.recurring_series for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy recurring_owner_update on public.recurring_series for update to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));
grant select on public.recurring_series to authenticated;
grant update (status) on public.recurring_series to authenticated;
grant all on public.recurring_series to service_role;

-- ≥3 charges (≥2 for yearly) at a steady cadence and a steady amount (CV < 10%).
create or replace function private.detect_recurring(p_profile_code text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_today date := public.dubai_date(now());
begin
  with charges as (
    select s.merchant_code, s.txn_code, s.txn_date, s.spend_aed,
           s.txn_date - lag(s.txn_date) over (partition by s.merchant_code order by s.txn_date) as gap
    from public.v_spend s
    where s.profile_code = p_profile_code and s.merchant_code is not null and s.spend_aed > 0
      and s.txn_date >= v_today - 400
  ),
  stats as (
    select merchant_code,
           count(*) as n,
           percentile_cont(0.5) within group (order by gap) as median_gap,
           avg(spend_aed) as mean_amount,
           stddev_samp(spend_aed) / nullif(avg(spend_aed), 0) as cv,
           min(txn_date) as first_date,
           max(txn_date) as last_date,
           (array_agg(spend_aed order by txn_date desc))[1] as last_amount
    from charges
    group by merchant_code
  ),
  classified as (
    select *,
           case
             when median_gap between 6 and 8 and n >= 4 then 'weekly'
             when median_gap between 26 and 35 and n >= 3 then 'monthly'
             when median_gap between 355 and 375 and n >= 2 then 'yearly'
           end as cadence
    from stats
  ),
  upserted as (
    insert into public.recurring_series (profile_code, merchant_code, cadence, expected_amount, last_amount,
      amount_cv, occurrences, first_date, last_date, next_expected)
    select p_profile_code, merchant_code, cadence, round(mean_amount, 2), last_amount, round(coalesce(cv, 0), 4), n,
           first_date, last_date,
           last_date + case cadence when 'weekly' then 7 when 'monthly' then 30 else 365 end
    from classified
    where cadence is not null and coalesce(cv, 0) < 0.10
    on conflict (profile_code, merchant_code) do update set
      cadence = excluded.cadence, expected_amount = excluded.expected_amount, last_amount = excluded.last_amount,
      amount_cv = excluded.amount_cv, occurrences = excluded.occurrences, last_date = excluded.last_date,
      next_expected = excluded.next_expected,
      status = case when public.recurring_series.status = 'dismissed' then 'dismissed' else 'active' end
    returning recurring_code, merchant_code
  )
  update public.transactions t set recurring_code = u.recurring_code
  from upserted u
  where t.profile_code = p_profile_code and t.merchant_code = u.merchant_code
    and t.recurring_code is distinct from u.recurring_code;
  get diagnostics v_count = row_count;

  -- A series that missed 1.5 cycles has ended.
  update public.recurring_series set status = 'ended'
  where profile_code = p_profile_code and status = 'active'
    and next_expected < v_today - case cadence when 'weekly' then 4 when 'monthly' then 15 else 60 end;
  return v_count;
end;
$$;

create or replace function public.recurring_list(p_profile_code text)
returns table (recurring_code text, merchant_code text, merchant_name text, category_name text, cadence text,
               expected_amount numeric, last_amount numeric, price_change numeric, occurrences int,
               last_date date, next_expected date, status text, annual_cost numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select r.recurring_code, r.merchant_code, m.display_name,
         (select c.name from public.transactions t join public.categories c on c.category_code = t.effective_category_code
           where t.recurring_code = r.recurring_code order by t.txn_date desc limit 1),
         r.cadence, r.expected_amount, r.last_amount,
         round((r.last_amount - r.expected_amount) / nullif(r.expected_amount, 0), 4),
         r.occurrences, r.last_date, r.next_expected, r.status,
         round(r.expected_amount * case r.cadence when 'weekly' then 52 when 'monthly' then 12 else 1 end, 2)
  from public.recurring_series r
  join public.merchants m on m.merchant_code = r.merchant_code
  where r.profile_code = p_profile_code
  order by r.status, r.next_expected
$$;
grant execute on function public.recurring_list(text) to authenticated, service_role;

-- ── insights feed ───────────────────────────────────────────────────────────
create table public.insights (
  insight_code text primary key default public.gen_code('ins')
    check (insight_code ~ '^ins_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  kind text not null check (kind in
    ('spend_pace', 'category_spike', 'budget_risk', 'price_change', 'new_recurring', 'statement_due',
     'uncategorized', 'review_backlog', 'large_transaction')),
  severity text not null default 'info' check (severity in ('info', 'warn', 'alert')),
  dedupe_key text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  valid_until date,
  dismissed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (profile_code, kind, dedupe_key)
);
create index insights_profile_idx on public.insights(profile_code, created_at desc) where dismissed_at is null;
alter table public.insights enable row level security;
create policy insights_member_read on public.insights for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy insights_owner_dismiss on public.insights for update to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));
grant select on public.insights to authenticated;
grant update (dismissed_at) on public.insights to authenticated;
grant all on public.insights to service_role;

create or replace function private.fmt_aed(v numeric)
returns text language sql immutable set search_path = '' as $$
  select 'AED ' || to_char(round(coalesce(v, 0)), 'FM999,999,990')
$$;

-- Deterministic, template-based insights. Re-running is idempotent (dedupe_key).
create or replace function private.generate_insights(p_profile_code text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
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
         coalesce(b.category_code, 'total') || ':' || v_month,
         b.category_name || case when b.share_used >= 1 then ' budget exceeded' else ' budget at risk' end,
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

  delete from public.insights where profile_code = p_profile_code and valid_until < v_today;
  return v_count;
end;
$$;

create or replace function private.nightly(p_profile_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p text;
  v_void int;
  v_out jsonb := '{}'::jsonb;
begin
  v_void := private.void_released_authorisations();
  for p in select profile_code from public.profiles where p_profile_code is null or profile_code = p_profile_code loop
    v_out := v_out || jsonb_build_object(p, jsonb_build_object(
      'recurring', private.detect_recurring(p),
      'insights', private.generate_insights(p)
    ));
  end loop;
  return v_out || jsonb_build_object('voided', v_void);
end;
$$;

-- ── audit ───────────────────────────────────────────────────────────────────
create table public.audit_events (
  event_code text primary key default public.gen_code('aud')
    check (event_code ~ '^aud_[0-9a-z]{26}$'),
  profile_code text references public.profiles(profile_code) on delete cascade,
  actor uuid,
  action text not null,
  entity text not null,
  entity_code text,
  payload jsonb not null default '{}'::jsonb,
  at timestamptz not null default now()
);
create index audit_events_profile_at_idx on public.audit_events(profile_code, at desc);
alter table public.audit_events enable row level security;
create policy audit_member_read on public.audit_events for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.audit_events to authenticated;
grant all on public.audit_events to service_role;

create or replace function private.trg_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb := to_jsonb(coalesce(new, old));
  v_code text;
begin
  -- Only user actions are audited; system writes (seeding, ingestion) are not.
  if auth.uid() is null then
    return null;
  end if;
  v_code := coalesce(v_row->>'rule_code', v_row->>'txn_code', v_row->>'review_code', v_row->>'budget_code');
  if tg_table_name = 'transactions' and tg_op = 'UPDATE' then
    if (to_jsonb(new) -> 'manual_category_code', to_jsonb(new) -> 'notes', to_jsonb(new) -> 'exclude_from_spend')
       is not distinct from (to_jsonb(old) -> 'manual_category_code', to_jsonb(old) -> 'notes', to_jsonb(old) -> 'exclude_from_spend') then
      return null;
    end if;
  end if;
  insert into public.audit_events (profile_code, actor, action, entity, entity_code, payload)
  values (v_row->>'profile_code', auth.uid(), lower(tg_op), tg_table_name, v_code,
          case when tg_table_name = 'transactions'
               then jsonb_build_object('manual_category_code', v_row->>'manual_category_code',
                                       'exclude_from_spend', v_row->'exclude_from_spend')
               else v_row - 'pattern_upper' end);
  return null;
end;
$$;
create trigger audit_category_rules after insert or update or delete on public.category_rules
  for each row execute function private.trg_audit();
create trigger audit_transactions_user_fields after update of manual_category_code, notes, exclude_from_spend
  on public.transactions for each row execute function private.trg_audit();
create trigger audit_budgets after insert or update or delete on public.budgets
  for each row execute function private.trg_audit();

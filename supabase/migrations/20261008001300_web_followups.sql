-- Web follow-ups:
--   • members: list (with emails and pending invites), remove, cancel invite
--   • preview_rule honours every rule condition (currency, card_code) exactly
--     like private.recategorize, and counts over all matches
--   • overview: per-account utilisation and server-side change fractions
--   • spend_series: optional p_top folds the long tail into "Other"

-- ── members ─────────────────────────────────────────────────────────────────
-- Members (joined to auth.users for their email) plus pending invites from
-- private.pending_members (user_id null, pending true). Any member may read.
create or replace function public.list_profile_members(p_profile_code text)
returns table (user_id uuid, email text, role text, created_at timestamptz, pending boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform private.assert_member(p_profile_code, false);
  return query
    select x.user_id, x.email, x.role, x.created_at, x.pending
    from (
      select m.user_id, u.email::text as email, m.role, m.created_at, false as pending
      from public.profile_members m
      join auth.users u on u.id = m.user_id
      where m.profile_code = p_profile_code
      union all
      select null::uuid, p.email, p.role, p.created_at, true
      from private.pending_members p
      where p.profile_code = p_profile_code
    ) x
    order by x.pending, x.created_at, x.email;
end;
$$;

-- Owner-only. The last owner can never be removed (a ledger always has one).
create or replace function public.remove_profile_member(p_profile_code text, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
begin
  perform private.assert_member(p_profile_code, true);
  -- Serialise membership changes per profile so two owners removing each other
  -- concurrently cannot leave the ledger ownerless.
  perform 1 from public.profiles p where p.profile_code = p_profile_code for update;

  select m.role into v_role
  from public.profile_members m
  where m.profile_code = p_profile_code and m.user_id = p_user_id;
  if not found then
    raise exception 'user is not a member of profile %', p_profile_code using errcode = 'P0002';
  end if;

  if v_role = 'owner' and not exists (
    select 1 from public.profile_members m
    where m.profile_code = p_profile_code and m.role = 'owner' and m.user_id <> p_user_id
  ) then
    raise exception 'cannot remove the last owner of profile %', p_profile_code using errcode = '22023';
  end if;

  delete from public.profile_members m where m.profile_code = p_profile_code and m.user_id = p_user_id;
end;
$$;

-- Owner-only. Withdraws an invite saved by add_profile_member for someone who
-- has not signed up yet.
create or replace function public.cancel_profile_invite(p_profile_code text, p_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, true);
  delete from private.pending_members p
  where p.profile_code = p_profile_code and lower(p.email) = lower(btrim(p_email));
  if not found then
    raise exception 'no pending invite for that email on profile %', p_profile_code using errcode = 'P0002';
  end if;
end;
$$;

grant execute on function public.list_profile_members(text) to authenticated, service_role;
grant execute on function public.remove_profile_member(text, uuid) to authenticated, service_role;
grant execute on function public.cancel_profile_invite(text, text) to authenticated, service_role;

-- ── preview_rule ────────────────────────────────────────────────────────────
-- "This rule would change N transactions": evaluated without saving anything.
-- Matching mirrors private.recategorize (20261008000600_categorization.sql),
-- including the card_code and currency conditions. Counts cover every match;
-- the sample is the 20 most recent.
create or replace function public.preview_rule(
  p_profile_code text,
  p_match_type text,
  p_pattern text,
  p_category_code text,
  p_conditions jsonb default '{}'::jsonb,
  p_priority integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
set statement_timeout = '10s'
as $$
declare
  v_pattern text := upper(btrim(p_pattern));
  v_conditions jsonb := coalesce(p_conditions, '{}'::jsonb);
  v_matched integer;
  v_changed integer;
  v_sample jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_match_type = 'regex' then
    perform regexp_match('', p_pattern);
  end if;

  with m as (
    select t.txn_code, t.description, t.amount_aed, t.txn_date, t.effective_category_code,
           t.manual_category_code, t.merchant_category_source, t.rule_code,
           cr.priority as cur_priority
    from public.transactions t
    join public.accounts a on a.account_code = t.account_code
    left join public.category_rules cr on cr.rule_code = t.rule_code
    where t.profile_code = p_profile_code
      and case p_match_type
            when 'exact' then t.description = v_pattern
            when 'prefix' then starts_with(t.description, v_pattern)
            when 'contains' then strpos(t.description, v_pattern) > 0
            else t.description ~* p_pattern
          end
      and (not v_conditions ? 'amount_min' or t.amount_aed >= (v_conditions->>'amount_min')::numeric)
      and (not v_conditions ? 'amount_max' or t.amount_aed <= (v_conditions->>'amount_max')::numeric)
      and (not v_conditions ? 'bank_code' or a.bank_code = v_conditions->>'bank_code')
      and (not v_conditions ? 'card_code' or t.card_code = v_conditions->>'card_code')
      and (not v_conditions ? 'currency' or t.currency_original = v_conditions->>'currency')
      and (not v_conditions ? 'kind' or t.kind = v_conditions->>'kind')
      and (not v_conditions ? 'direction' or t.direction = v_conditions->>'direction')
  ),
  totals as (
    select count(*)::int as matched,
           count(*) filter (
             where manual_category_code is null
               and coalesce(merchant_category_source, '') <> 'manual'
               and (rule_code is null or cur_priority >= p_priority)
               and effective_category_code is distinct from p_category_code
           )::int as would_change
    from m
  ),
  sample as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'txn_code', s.txn_code, 'description', s.description, 'amount_aed', s.amount_aed::text,
             'txn_date', s.txn_date, 'current_category_code', s.effective_category_code
           ) order by s.txn_date desc, s.txn_code desc), '[]'::jsonb) as rows
    from (select * from m order by txn_date desc, txn_code desc limit 20) s
  )
  select totals.matched, totals.would_change, sample.rows
  into v_matched, v_changed, v_sample
  from totals, sample;

  return jsonb_build_object('matched', v_matched, 'would_change', v_changed, 'sample', v_sample);
end;
$$;

-- ── overview ────────────────────────────────────────────────────────────────
-- Same signature and keys as 20261008000800_analytics.sql, plus:
--   accounts[].utilisation          latest active statement closing_balance /
--                                    coalesce(statement credit_limit, account credit_limit), 4dp
--   change_vs_prev_month_to_date    (spend − base) / base, 4dp decimal string; base is last
--                                    month up to the same day for the current month, and the
--                                    whole previous month for a past month (its "to date" is
--                                    the whole month)
--   change_vs_avg_3m                (spend − spend_avg_3m) / spend_avg_3m, 4dp decimal string
-- Both fractions are null when their base is 0.
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
  v_spend numeric;
  v_prev_month numeric;
  v_prev_mtd numeric;
  v_avg_3m numeric;
  v_base numeric;
  r jsonb;
begin
  v_spend := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_month and txn_date < v_next), 0);
  v_prev_month := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_prev and txn_date < v_month), 0);
  -- same day-of-month last month, for a fair month-to-date comparison
  v_prev_mtd := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_prev and txn_date < v_prev + v_day), 0);
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
    'change_vs_prev_month_to_date', round((v_spend - v_base) / nullif(v_base, 0), 4)::text,
    'change_vs_avg_3m', round((v_spend - v_avg_3m) / nullif(v_avg_3m, 0), 4)::text,
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
        'utilisation', (
          select round(st.closing_balance / nullif(coalesce(st.credit_limit, a.credit_limit), 0), 4)::text
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

-- ── spend_series ────────────────────────────────────────────────────────────
-- Adds p_top: when set and p_group <> 'none', groups outside the top N by total
-- amount over the whole range fold into one group (group_key null, 'Other').
-- A new parameter changes the signature, so the old function is dropped first.
-- Nothing in SQL calls it (clients use PostgREST with named arguments, which
-- keep working because p_top defaults to null).
drop function public.spend_series(text, date, date, text, text);

create function public.spend_series(
  p_profile_code text, p_from date, p_to date, p_grain text default 'month', p_group text default 'none',
  p_top int default null
)
returns table (bucket date, group_key text, group_label text, color_token text, amount numeric, txn_count bigint)
language sql
stable
security invoker
set search_path = ''
as $$
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
        when 'category' then coalesce(c.name, 'Uncategorized')
        when 'merchant' then coalesce(m.display_name, s.description)
        when 'account' then coalesce(a.nickname, a.bank_code)
        when 'card' then coalesce(a.bank_code || ' •' || cd.last4, a.bank_code)
        else 'Total'
      end as group_label,
      case when p_group = 'category' then c.color_token end as color_token,
      s.spend_aed
    from public.v_spend s
    left join public.categories c on c.category_code = s.category_code
    left join public.merchants m on m.merchant_code = s.merchant_code
    left join public.accounts a on a.account_code = s.account_code
    left join public.cards cd on cd.card_code = s.card_code
    where s.profile_code = p_profile_code and s.txn_date between p_from and p_to
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
  select bucket, group_key, group_label, color_token, sum(spend_aed) as amount, count(*) as txn_count
  from folded
  group by 1, 2, 3, 4
  order by 1, 5 desc
$$;

grant execute on function public.spend_series(text, date, date, text, text, int) to authenticated, service_role;

-- UK spelling for the name of "no category" (audit WEB-31): the analytics RPCs labelled it
-- "Uncategorized" while every screen said "Uncategorised", so the Trends legend and the category
-- list disagreed with the rest of the app. Same bodies, signatures and grants as before; only the
-- fallback label changes. Keys and codes stay as they are (`__uncategorized__`,
-- `uncategorized_count`, the `uncategorized` insight kind): they are identifiers, not words a
-- person reads. No seeded category, rule or template carries the old label, so there is no
-- content to migrate (§1.9); the legacy import keeps matching v1's own "Uncategorized".

-- ── category_breakdown ───────────────────────────────────────────────────────
create or replace function public.category_breakdown(p_profile_code text, p_from date, p_to date)
returns table (category_code text, name text, color_token text, amount numeric, txn_count bigint,
               share numeric, prev_amount numeric, change numeric)
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
  select cur.category_code, coalesce(c.name, 'Uncategorised'), c.color_token, cur.amount, cur.n,
         round(cur.amount / tot.total, 4), coalesce(prev.amount, 0),
         round((cur.amount - prev.amount) / nullif(prev.amount, 0), 4)
  from cur
  cross join tot
  left join prev on prev.category_code is not distinct from cur.category_code
  left join public.categories c on c.category_code = cur.category_code
  order by cur.amount desc
$$;

-- ── spend_series ─────────────────────────────────────────────────────────────
create or replace function public.spend_series(
  p_profile_code text, p_from date, p_to date, p_grain text default 'month', p_group text default 'none',
  p_top int default null,
  p_category_codes text[] default null, p_bank_codes text[] default null, p_card_codes text[] default null,
  p_q text default null
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
    from private.filtered_spend(p_profile_code, p_from, p_to, p_category_codes, p_bank_codes, p_card_codes, p_q) s
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

-- ── spend_breakdown ──────────────────────────────────────────────────────────
create or replace function public.spend_breakdown(
  p_profile_code text,
  p_from date,
  p_to date,
  p_group_by text,
  p_top_n integer default 10,
  p_category_codes text[] default null,
  p_bank_codes text[] default null,
  p_card_codes text[] default null,
  p_q text default null
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
    from private.filtered_spend(p_profile_code, p_from, p_to, p_category_codes, p_bank_codes, p_card_codes, p_q) s
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

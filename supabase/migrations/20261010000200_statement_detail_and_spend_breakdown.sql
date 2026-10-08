-- Two read RPCs for the apps (member read; money as decimal strings):
--   public.statement_detail(profile, stmt)  one statement with its debit and credit lines
--   public.spend_breakdown(profile, from, to, group_by, top_n)  monthly spend by category/bank/merchant
-- Both are SECURITY DEFINER with an explicit membership check (private.assert_member is not
-- reachable from an invoker function), so every query below filters by p_profile_code itself.

-- ── statement_detail ────────────────────────────────────────────────────────
-- Lines are the statement's current lines, ordered by txn_date, line_no. `description` is
-- the line as the statement printed it (description_raw; masked text where a merchant mask
-- applies), `merchant_name` / `category_code` come from the transaction the line evidences.
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
        'recon_status', r.status, 'recon_checks', r.checks)
      from (select 1) one
      left join public.statement_recon r on r.stmt_code = st.stmt_code and r.profile_code = p_profile_code),
    'debits', coalesce(v_lines->'debit', jsonb_build_object('count', 0, 'total', '0.00', 'lines', '[]'::jsonb)),
    'credits', coalesce(v_lines->'credit', jsonb_build_object('count', 0, 'total', '0.00', 'lines', '[]'::jsonb))
  );
end;
$$;

-- ── spend_breakdown ─────────────────────────────────────────────────────────
-- Built only on public.v_spend (CLAUDE.md §1.12). The top p_top_n groups by total over the
-- whole range keep their key; the rest fold into '__other__' ("Others"). Every month of the
-- range appears in `series`, zero-filled, and every series row carries every group key.
-- Keys: category → category_code ('__uncategorized__' when none), bank → bank_code,
-- merchant → merchant_code ('__unknown__' when none). Shares are of the range total, 4 dp,
-- clamped to 0..1 (a group of only refunds can be net negative).
create or replace function public.spend_breakdown(
  p_profile_code text,
  p_from date,
  p_to date,
  p_group_by text,
  p_top_n integer default 10
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
             when 'category' then coalesce(c.name, 'Uncategorized')
             when 'bank' then coalesce(b.name, a.bank_code)
             else coalesce(m.display_name, 'Unknown merchant')
           end as label,
           case when p_group_by = 'category' then c.color_token end as color_token,
           case when p_group_by = 'bank' then b.logo_path end as logo_path,
           s.spend_aed
    from public.v_spend s
    join public.accounts a on a.account_code = s.account_code and a.profile_code = p_profile_code
    left join public.banks b on b.bank_code = a.bank_code
    left join public.categories c on c.category_code = s.category_code and c.profile_code = p_profile_code
    left join public.merchants m on m.merchant_code = s.merchant_code
    where s.profile_code = p_profile_code and s.txn_date between p_from and p_to
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

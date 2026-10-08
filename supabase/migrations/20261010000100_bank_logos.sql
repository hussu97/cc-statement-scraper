-- Bank logos: banks.logo_path names an object in the PUBLIC `bank-logos` bucket
-- (e.g. 'FAB.png'). Clients build the URL themselves:
--   <SUPABASE_URL>/storage/v1/object/public/bank-logos/<logo_path>
-- The images are uploaded by the operator (assets/banks/), never by clients.

-- ── storage bucket ──────────────────────────────────────────────────────────
-- Public read (served by the public object endpoint, no RLS involved); no policy
-- grants clients INSERT/UPDATE/DELETE on it, so only the service role writes.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bank-logos', 'bank-logos', true, 1048576,
        array['image/png', 'image/svg+xml', 'image/webp', 'image/jpeg'])
on conflict (id) do nothing;

-- ── banks.logo_path ─────────────────────────────────────────────────────────
alter table public.banks add column if not exists logo_path text
  check (logo_path is null or logo_path ~ '^[A-Za-z0-9_-]{1,40}\.(png|svg|webp|jpg)$');

-- Content seed, guarded (CLAUDE.md §1.9): only rows still holding the old value (null).
update public.banks set logo_path = bank_code || '.png'
where bank_code in ('ADCB', 'EIB', 'ENBD', 'FAB', 'MASHREQ', 'SIB') and logo_path is null;

-- ── RPCs that already return a bank: add logo_path ─────────────────────────
-- statement_cycles: one more output column, so the function is re-created.
drop function if exists public.statement_cycles(text, integer);
create function public.statement_cycles(p_profile_code text, p_limit integer default 24)
returns table (stmt_code text, account_code text, bank_code text, card_last4 text, kind text, statement_date date,
               period_start date, period_end date, due_date date, closing_balance numeric, min_due numeric,
               credit_limit numeric, utilisation numeric, line_count bigint, debits numeric, credits numeric,
               recon_status text, recon_checks jsonb, doc_code text, logo_path text)
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
         r.status, r.checks, st.doc_code, b.logo_path
  from public.statements st
  join public.accounts a on a.profile_code = st.profile_code and a.account_code = st.account_code
  join public.banks b on b.bank_code = a.bank_code
  left join public.statement_recon r on r.stmt_code = st.stmt_code
  where st.profile_code = p_profile_code and st.status = 'active'
  order by st.statement_date desc
  limit least(greatest(p_limit, 1), 5000)
$$;
grant execute on function public.statement_cycles(text, integer) to authenticated, service_role;

-- filter_meta: banks carry logo_path.
create or replace function public.filter_meta(p_profile_code text)
returns jsonb
language sql
stable
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
    'banks', coalesce((select jsonb_agg(jsonb_build_object('bank_code', b.bank_code, 'name', b.name,
                  'logo_path', b.logo_path) order by b.bank_code)
                from public.banks b), '[]'::jsonb),
    'date_range', (select jsonb_build_object('min', min(txn_date), 'max', max(txn_date))
                from public.transactions where profile_code = p_profile_code)
  )
$$;

-- overview: each account carries its bank's logo_path (dues / utilisation cards).
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
    'change_vs_prev_month_to_date', round((v_spend - v_base) / nullif(v_base, 0), 4)::text,
    'change_vs_avg_3m', round((v_spend - v_avg_3m) / nullif(v_avg_3m, 0), 4)::text,
    'payments', coalesce((select sum(amount_aed) from public.transactions
                       where profile_code = p_profile_code and kind = 'payment' and direction = 'credit'
                         and status in ('pending', 'posted') and txn_date >= v_month and txn_date < v_next), 0)::text,
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

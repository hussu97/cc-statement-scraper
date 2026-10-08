-- Web follow-ups that ride along with the audit fixes:
--   • retry_sms_fallback: an owner asks the LLM fallback to try an unparsed SMS again
--   • merchant_search: every merchant of a profile, searchable, not limited by spend
--   • statement_cycles: p_limit up to 5000 (was 500)
--   • distinct seed colours for Medicine, Forex Charge and Apple in-app purchase
--     (guarded content migration: only rows still holding the old value)
-- resolve_review's {"not_a_transaction": true} lives with the rest of
-- resolve_review in 20261008001600_audit_ingest_and_review.sql.

-- ── retry_sms_fallback ──────────────────────────────────────────────────────
create or replace function public.retry_sms_fallback(p_review_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.match_reviews%rowtype;
begin
  select * into r from public.match_reviews where review_code = p_review_code;
  if not found then
    raise exception 'review % is not open', p_review_code using errcode = 'P0002';
  end if;
  perform private.assert_member(r.profile_code, true);
  if r.status <> 'open' or r.reason <> 'unparsed_sms' or r.subject_type <> 'sms' then
    raise exception 'review % is not an open unparsed_sms review', p_review_code using errcode = '22023';
  end if;
  if not exists (select 1 from public.sms_messages s
                 where s.sms_code = r.subject_code and s.profile_code = r.profile_code) then
    raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
  end if;
  update public.match_reviews
  set status = 'dismissed', resolution = jsonb_build_object('retry_fallback', true),
      resolved_by = auth.uid(), resolved_at = now()
  where review_code = p_review_code;
  perform pgmq.send('sms_fallback', jsonb_build_object('sms_code', r.subject_code));
end;
$$;
grant execute on function public.retry_sms_fallback(text) to authenticated, service_role;

-- ── merchant_search ─────────────────────────────────────────────────────────
-- Merchants that appear in the profile's transactions, matched case-insensitively
-- on display name or merchant key (substring, or trigram similarity ≥ 0.3), with
-- the profile's manual merchant category if any. Ordered by match quality, then
-- transaction count. p_limit is capped at 2000.
create or replace function public.merchant_search(
  p_profile_code text, p_q text, p_offset int default 0, p_limit int default 50
)
returns table (merchant_code text, display_name text, merchant_key text, txn_count bigint, last_date date,
               manual_category_code text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q text := nullif(btrim(coalesce(p_q, '')), '');
  v_like text;
begin
  perform private.assert_member(p_profile_code, false);
  v_like := '%' || replace(replace(replace(coalesce(v_q, ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return query
  with mine as (
    select t.merchant_code, count(*)::bigint as n, max(t.txn_date) as last_date
    from public.transactions t
    where t.profile_code = p_profile_code and t.merchant_code is not null
    group by t.merchant_code
  )
  select m.merchant_code, m.display_name, m.merchant_key, mine.n, mine.last_date, mpc.category_code
  from mine
  join public.merchants m on m.merchant_code = mine.merchant_code
  left join public.merchant_profile_category mpc
    on mpc.profile_code = p_profile_code and mpc.merchant_code = m.merchant_code and mpc.source = 'manual'
  where v_q is null
     or m.display_name ilike v_like
     or m.merchant_key ilike v_like
     or extensions.similarity(m.merchant_key, upper(v_q)) >= 0.3
  order by case when v_q is null then 0
                else greatest(extensions.similarity(m.merchant_key, upper(v_q)),
                              case when m.display_name ilike v_like or m.merchant_key ilike v_like then 1 else 0 end)
           end desc,
           mine.n desc, m.display_name, m.merchant_code
  offset greatest(coalesce(p_offset, 0), 0)
  limit least(greatest(coalesce(p_limit, 50), 1), 2000);
end;
$$;
grant execute on function public.merchant_search(text, text, int, int) to authenticated, service_role;

-- ── statement_cycles: up to 5000 rows ──────────────────────────────────────
-- Same signature and columns as 20261008000800_analytics.sql.
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
  join public.accounts a on a.profile_code = st.profile_code and a.account_code = st.account_code
  left join public.statement_recon r on r.stmt_code = st.stmt_code
  where st.profile_code = p_profile_code and st.status = 'active'
  order by st.statement_date desc
  limit least(greatest(p_limit, 1), 5000)
$$;

-- ── seed colours (guarded) ──────────────────────────────────────────────────
update public.categories set color_token = 'cat-9' where name = 'Medicine' and color_token = 'cat-2';
update public.categories set color_token = 'cat-11' where name = 'Forex Charge' and color_token = 'cat-1';
update public.categories set color_token = 'cat-3' where name = 'Apple in-app purchase' and color_token = 'cat-5';
update private.seed_categories set color_token = 'cat-9' where name = 'Medicine' and color_token = 'cat-2';
update private.seed_categories set color_token = 'cat-11' where name = 'Forex Charge' and color_token = 'cat-1';
update private.seed_categories set color_token = 'cat-3' where name = 'Apple in-app purchase' and color_token = 'cat-5';

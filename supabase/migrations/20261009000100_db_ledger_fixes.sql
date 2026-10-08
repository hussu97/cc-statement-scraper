-- Ledger fixes from the audit backlog (docs/audit/BACKLOG.md, Database P2/P3):
--   DB-17r  an unknown_card SMS is re-processed when a statement registers its card
--   DB-18   overview's month-to-date base never runs into the viewed month
--   DB-19r  resolve_merchant reads first; it writes only for a new merchant key
--   DB-20   v_transactions.has_sms / has_statement probe the evidence index per row
--   DB-32r  index for estimate_fx; anomalies with window functions instead of O(n²) laterals
--   DB-34   declined SMS are stored 'ignored' (as the docs say)
--   DB-36   an SMS date more than 7 days from received_at falls back to received_at
--   DB-39   utilisation is never negative when the card is in credit
--   DB-44   new transactions start with their merchant and AED amount, so they are
--           categorised once instead of twice
--   DB-45   overview reports pending transactions that have no AED amount yet
--   DP-04r  ingest rejects a statement dated more than 31 days in the future
--   X-33    transactions.fx_rate is null for AED; a statement fx_rate below 1e-8 is unknown

-- ── DB-18: last month, to the same day ──────────────────────────────────────
-- Exclusive end of the "previous month to date" window for a viewed month: the
-- same day of the previous month, but never past its last day (30 Mar compares
-- with all of February, not 1–2 March).
create or replace function public.prev_month_to_date_end(p_month date, p_today date)
returns date
language sql
immutable
parallel safe
set search_path = ''
as $$
  select least(
    (date_trunc('month', p_month) - interval '1 month')::date
      + least(extract(day from p_today)::int,
              extract(day from ((date_trunc('month', p_month) + interval '1 month')::date - 1))::int),
    date_trunc('month', p_month)::date)
$$;

-- ── DB-18, DB-39, DB-45: overview ───────────────────────────────────────────
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

-- ── DB-39: statement_cycles ─────────────────────────────────────────────────
create or replace function public.statement_cycles(p_profile_code text, p_limit integer default 24)
returns table(stmt_code text, account_code text, bank_code text, card_last4 text, kind text, statement_date date,
              period_start date, period_end date, due_date date, closing_balance numeric, min_due numeric,
              credit_limit numeric, utilisation numeric, line_count bigint, debits numeric, credits numeric,
              recon_status text, recon_checks jsonb, doc_code text)
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
         r.status, r.checks, st.doc_code
  from public.statements st
  join public.accounts a on a.profile_code = st.profile_code and a.account_code = st.account_code
  left join public.statement_recon r on r.stmt_code = st.stmt_code
  where st.profile_code = p_profile_code and st.status = 'active'
  order by st.statement_date desc
  limit least(greatest(p_limit, 1), 5000)
$$;

-- ── DB-20: v_transactions evidence flags via the txn index ──────────────────
-- Same columns, same order. The flags are scalar sub-queries, not EXISTS: an
-- EXISTS became a hashed sub-plan over the whole (RLS-filtered) evidence table;
-- a scalar sub-query probes transaction_evidence_txn_idx, and only for the rows
-- a page returns (the planner evaluates it above ORDER BY … LIMIT).
create or replace view public.v_transactions with (security_invoker = true) as
select t.txn_code,
       t.profile_code,
       t.account_code,
       t.card_code,
       t.status,
       t.kind,
       t.direction,
       t.txn_date,
       t.txn_at,
       t.posting_date,
       t.stmt_code,
       t.merchant_code,
       t.description,
       m.display_name as merchant_name,
       t.amount_original,
       t.currency_original,
       t.amount_aed,
       t.amount_aed_is_estimate,
       t.fx_rate,
       t.auth_amount,
       t.amount_source,
       t.related_txn_code,
       t.exclude_from_spend,
       t.notes,
       t.effective_category_code as category_code,
       c.name as category_name,
       c.color_token as category_color,
       c.kind as category_kind,
       case
         when t.manual_category_code is not null then 'manual'
         when t.merchant_category_source = 'manual' and t.merchant_category_code is not null then 'merchant'
         when t.rule_category_code is not null then 'rule'
         when t.merchant_category_source = 'llm' and t.merchant_category_code is not null then 'suggested'
       end as category_source,
       a.bank_code,
       cd.last4 as card_last4,
       a.nickname as account_nickname,
       coalesce((select true from public.transaction_evidence e
                 where e.txn_code = t.txn_code and e.is_active and e.evidence_type = 'sms'
                 limit 1), false) as has_sms,
       coalesce((select true from public.transaction_evidence e
                 where e.txn_code = t.txn_code and e.is_active and e.evidence_type in ('statement_line', 'history_line')
                 limit 1), false) as has_statement,
       t.created_at,
       t.updated_at
from public.transactions t
join public.accounts a on a.account_code = t.account_code
left join public.cards cd on cd.card_code = t.card_code
left join public.categories c on c.category_code = t.effective_category_code
left join public.merchants m on m.merchant_code = t.merchant_code;

-- ── DB-19r: resolve_merchant reads before it writes ─────────────────────────
-- merchant_aliases stays (manual merges will populate it); the lookup is a PK probe.
create or replace function private.resolve_merchant(p_description text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_key text := public.merchant_key(p_description);
  v_code text;
begin
  if v_key is null then
    return null;
  end if;
  select merchant_code into v_code from public.merchant_aliases where alias_key = v_key;
  if v_code is not null then
    return v_code;
  end if;
  select merchant_code into v_code from public.merchants where merchant_key = v_key;
  if v_code is not null then
    return v_code;
  end if;
  insert into public.merchants (merchant_key, display_name)
  values (v_key, initcap(lower(v_key)))
  on conflict (merchant_key) do nothing
  returning merchant_code into v_code;
  if v_code is null then   -- a concurrent insert won
    select merchant_code into v_code from public.merchants where merchant_key = v_key;
  end if;
  return v_code;
end;
$$;

-- ── DB-44 / X-33: new transactions start fully derived ──────────────────────
-- refresh_transaction() then finds no change in the categorisation inputs, so
-- the statement-level trigger categorises each new transaction once.
create or replace function private.new_transaction_from_line(p_line_code text, p_method text default 'new')
returns text
language plpgsql
set search_path = ''
as $$
declare
  l public.statement_lines%rowtype;
  v_txn text;
  v_aed numeric;
  v_estimate boolean := false;
begin
  select * into l from public.statement_lines where line_code = p_line_code;
  v_aed := l.amount_aed;
  if v_aed is null then
    v_aed := round(l.amount_original * coalesce(l.fx_rate, private.estimate_fx(l.profile_code, l.currency_original)), 2);
    v_estimate := v_aed is not null;
  end if;
  insert into public.transactions (profile_code, account_code, card_code, kind, direction, txn_date,
    posting_date, description, merchant_code, amount_original, currency_original, amount_aed, amount_aed_is_estimate,
    fx_rate, amount_source, stmt_code, status)
  values (l.profile_code, l.account_code, l.card_code, l.kind, l.direction, l.txn_date,
    l.posting_date, l.description, private.resolve_merchant(l.description), l.amount_original, l.currency_original,
    v_aed, v_estimate, case when l.currency_original = 'AED' then null else l.fx_rate end, l.evidence_type,
    l.stmt_code, 'posted')
  returning txn_code into v_txn;
  insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, role, method)
  values (v_txn, l.profile_code, l.evidence_type, l.line_code, 'primary', p_method);
  perform private.refresh_transaction(v_txn);
  return v_txn;
end;
$$;

create or replace function private.new_transaction_from_sms(p_sms_code text, p_method text default 'new')
returns text
language plpgsql
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_txn text;
  v_kind text;
  v_direction text;
  v_desc text;
  v_fx numeric;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code;
  v_kind := case s.msg_kind when 'refund' then 'refund' when 'reversal' then 'refund'
                            when 'payment' then 'payment' else 'purchase' end;
  v_direction := case when s.msg_kind in ('refund', 'reversal', 'payment') then 'credit' else 'debit' end;
  v_desc := coalesce(s.description, 'CARD TRANSACTION');
  if s.currency <> 'AED' then
    v_fx := private.estimate_fx(s.profile_code, s.currency);
  end if;
  insert into public.transactions (profile_code, account_code, card_code, kind, direction, txn_date, txn_at,
    description, merchant_code, amount_original, currency_original, amount_aed, amount_aed_is_estimate, fx_rate,
    amount_source, status)
  values (s.profile_code, s.account_code, s.card_code, v_kind, v_direction, public.dubai_date(s.event_at), s.event_at,
    v_desc, private.resolve_merchant(v_desc), s.amount, s.currency,
    case when s.currency = 'AED' then s.amount else round(s.amount * v_fx, 2) end,
    s.currency <> 'AED', v_fx, 'sms', 'pending')
  returning txn_code into v_txn;
  insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, method)
  values (v_txn, s.profile_code, 'sms', s.sms_code, case when s.msg_kind = 'reversal' then 'reversal' else 'primary' end, p_method);
  perform private.refresh_transaction(v_txn);
  return v_txn;
end;
$$;


-- ── X-33: refresh_transaction (fx_rate is null for AED; otherwise unchanged) ──
CREATE OR REPLACE FUNCTION private.refresh_transaction(p_txn_code text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  t public.transactions%rowtype;
  l public.statement_lines%rowtype;
  s public.sms_messages%rowtype;
  v_has_line boolean := false;
  v_has_sms boolean := false;
  v_fx numeric;
begin
  select * into t from public.transactions where txn_code = p_txn_code for update;
  if not found then
    return;
  end if;

  select sl.* into l
  from public.transaction_evidence e
  join public.statement_lines sl on sl.line_code = e.line_code and sl.profile_code = e.profile_code
  where e.txn_code = p_txn_code and e.profile_code = t.profile_code
    and e.is_active and e.evidence_type in ('statement_line', 'history_line')
  order by case e.evidence_type when 'statement_line' then 0 else 1 end
  limit 1;
  v_has_line := found;

  select sm.* into s
  from public.transaction_evidence e
  join public.sms_messages sm on sm.sms_code = e.sms_code and sm.profile_code = e.profile_code
  where e.txn_code = p_txn_code and e.profile_code = t.profile_code and e.is_active and e.role <> 'duplicate'
  order by sm.event_at
  limit 1;
  v_has_sms := found;

  if v_has_line then
    t.card_code := coalesce(l.card_code, t.card_code);
    t.txn_date := l.txn_date;
    t.posting_date := l.posting_date;
    t.description := l.description;
    t.amount_original := l.amount_original;
    t.currency_original := l.currency_original;
    t.amount_aed := l.amount_aed;
    t.fx_rate := case when l.currency_original = 'AED' then null else l.fx_rate end;  -- X-33
    t.amount_aed_is_estimate := false;
    t.kind := l.kind;
    t.direction := l.direction;
    t.amount_source := l.evidence_type;
    t.stmt_code := l.stmt_code;
    t.status := 'posted';
    t.voided_at := null;
    t.void_reason := null;
    if l.amount_aed is null then
      v_fx := coalesce(l.fx_rate, private.estimate_fx(t.profile_code, l.currency_original));
      t.amount_aed := round(l.amount_original * v_fx, 2);
      t.amount_aed_is_estimate := t.amount_aed is not null;
    end if;
    if v_has_sms then
      t.txn_at := s.event_at;
      t.auth_amount := case when s.amount is distinct from l.amount_original then s.amount end;
    else
      t.txn_at := null;
      t.auth_amount := null;
    end if;
  elsif v_has_sms then
    t.card_code := coalesce(s.card_code, t.card_code);
    t.txn_at := s.event_at;
    t.txn_date := public.dubai_date(s.event_at);
    t.posting_date := null;
    t.description := coalesce(s.description, t.description);
    t.amount_original := s.amount;
    t.currency_original := s.currency;
    t.auth_amount := null;
    t.stmt_code := null;
    t.amount_source := 'sms';
    if s.currency = 'AED' then
      t.amount_aed := s.amount;
      t.fx_rate := null;
      t.amount_aed_is_estimate := false;
    else
      v_fx := private.estimate_fx(t.profile_code, s.currency);
      t.fx_rate := v_fx;
      t.amount_aed := round(s.amount * v_fx, 2);
      t.amount_aed_is_estimate := true;
    end if;
    t.status := case when t.voided_at is not null then 'void' else 'pending' end;
  else
    t.status := case when t.voided_at is not null then 'void' else 'orphaned' end;
  end if;

  t.merchant_code := private.resolve_merchant(t.description);

  update public.transactions set
    card_code = t.card_code, status = t.status, kind = t.kind, direction = t.direction,
    txn_date = t.txn_date, txn_at = t.txn_at, posting_date = t.posting_date, stmt_code = t.stmt_code,
    merchant_code = t.merchant_code, description = t.description,
    amount_original = t.amount_original, currency_original = t.currency_original,
    amount_aed = t.amount_aed, amount_aed_is_estimate = t.amount_aed_is_estimate, fx_rate = t.fx_rate,
    auth_amount = t.auth_amount, amount_source = t.amount_source,
    voided_at = t.voided_at, void_reason = t.void_reason
  where txn_code = p_txn_code
    and (card_code, status, kind, direction, txn_date, txn_at, posting_date, stmt_code, merchant_code,
         description, amount_original, currency_original, amount_aed, amount_aed_is_estimate, fx_rate,
         auth_amount, amount_source, voided_at, void_reason)
      is distinct from
        (t.card_code, t.status, t.kind, t.direction, t.txn_date, t.txn_at, t.posting_date, t.stmt_code, t.merchant_code,
         t.description, t.amount_original, t.currency_original, t.amount_aed, t.amount_aed_is_estimate, t.fx_rate,
         t.auth_amount, t.amount_source, t.voided_at, t.void_reason);

  if t.status = 'orphaned' then
    insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason)
    values (t.profile_code, t.account_code, 'transaction', t.txn_code, 'orphaned')
    on conflict do nothing;
  else
    -- An orphan review raised and answered within the same transaction (a
    -- re-parse that detached a line and re-matched it) was never news: drop it (DP-06).
    delete from public.match_reviews
    where profile_code = t.profile_code and subject_type = 'transaction' and subject_code = t.txn_code
      and reason = 'orphaned' and status = 'open' and created_at = now();
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'evidence_reattached'),
      resolved_at = now()
    where profile_code = t.profile_code and subject_type = 'transaction' and subject_code = t.txn_code
      and reason = 'orphaned' and status = 'open';
  end if;
  if t.status <> 'pending' then
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'no_longer_pending'),
      resolved_at = now()
    where profile_code = t.profile_code and subject_type = 'transaction' and subject_code = t.txn_code
      and reason = 'missing_from_statement' and status = 'open';
  end if;
end;
$function$;

-- ── X-33: ingest_one_statement (an fx_rate that rounds to 0 is unknown; otherwise unchanged)
CREATE OR REPLACE FUNCTION private.ingest_one_statement(p_doc public.documents, p_stmt jsonb, p_parser_version text, p_account text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_kind text := p_stmt->>'kind';
  v_bank text := p_stmt->>'bank_code';
  v_date date := (p_stmt->>'statement_date')::date;
  v_last4 text := nullif(p_stmt->>'primary_card_last4', '');
  v_totals jsonb := coalesce(p_stmt->'totals', '{}'::jsonb);
  v_n_in integer := jsonb_array_length(coalesce(p_stmt->'lines', '[]'::jsonb));
  v_account text := p_account;
  v_profile text := p_doc.profile_code;
  v_doc text := p_doc.doc_code;
  v_stmt text;
  v_status text;
  v_stmt_doc text;
  v_existing boolean;
  v_own boolean;
  v_gone text[];
  v_superseded int := 0;
  v_inserted int := 0;
  v_match jsonb;
  v_recon text;
  v_warnings jsonb := '[]'::jsonb;
begin
  -- The active statement with this identity, else one this same document produced
  -- earlier and a re-parse retired (DB-06): it comes back with its codes intact.
  -- A statement the owner superseded (superseded_by set) is never revived.
  select stmt_code, status, doc_code into v_stmt, v_status, v_stmt_doc from public.statements
  where profile_code = v_profile and account_code = v_account and statement_date = v_date and kind = v_kind
    and (status = 'active' or (status = 'superseded' and superseded_by is null and doc_code = v_doc))
  order by (status = 'active') desc, created_at desc
  limit 1;
  v_existing := v_stmt is not null;

  if v_existing then
    v_own := v_status = 'superseded' or v_stmt_doc is null or v_stmt_doc = v_doc
             or (v_n_in > 0 and not exists (
                   select 1 from public.statement_lines l
                   where l.profile_code = v_profile and l.stmt_code = v_stmt and l.is_current
                     and l.source_doc_codes @> array[v_stmt_doc]));
    if v_own then
      update public.statements set
        status = 'active',
        superseded_by = null,
        doc_code = v_doc,
        statement_reference = p_stmt->>'statement_reference',
        reference_source = p_stmt->>'reference_source',
        period_start = (p_stmt->>'period_start')::date,
        period_end = (p_stmt->>'period_end')::date,
        due_date = (p_stmt->>'due_date')::date,
        opening_balance = (v_totals->>'opening_balance')::numeric,
        closing_balance = (v_totals->>'closing_balance')::numeric,
        total_debits = (v_totals->>'total_debits')::numeric,
        total_credits = (v_totals->>'total_credits')::numeric,
        min_due = (v_totals->>'min_due')::numeric,
        credit_limit = (v_totals->>'credit_limit')::numeric,
        primary_card_last4 = v_last4,
        card_holder = p_stmt->>'card_holder',
        card_type = p_stmt->>'card_type',
        parser_version = p_parser_version,
        warnings = coalesce(p_stmt->'warnings', '[]'::jsonb),
        metadata = coalesce(p_stmt->'metadata', '{}'::jsonb)
      where stmt_code = v_stmt;
    elsif v_n_in > 0 then
      update public.statements s set
        statement_reference = coalesce(s.statement_reference, p_stmt->>'statement_reference'),
        reference_source = case when s.statement_reference is null then p_stmt->>'reference_source'
                                else s.reference_source end,
        period_start = case when s.period_start is null and s.period_end is null
                            then (p_stmt->>'period_start')::date else s.period_start end,
        period_end = case when s.period_start is null and s.period_end is null
                          then (p_stmt->>'period_end')::date else s.period_end end,
        due_date = coalesce(s.due_date, (p_stmt->>'due_date')::date),
        opening_balance = coalesce(s.opening_balance, (v_totals->>'opening_balance')::numeric),
        closing_balance = coalesce(s.closing_balance, (v_totals->>'closing_balance')::numeric),
        total_debits = coalesce(s.total_debits, (v_totals->>'total_debits')::numeric),
        total_credits = coalesce(s.total_credits, (v_totals->>'total_credits')::numeric),
        min_due = coalesce(s.min_due, (v_totals->>'min_due')::numeric),
        credit_limit = coalesce(s.credit_limit, (v_totals->>'credit_limit')::numeric),
        primary_card_last4 = coalesce(s.primary_card_last4, v_last4),
        card_holder = coalesce(s.card_holder, p_stmt->>'card_holder'),
        card_type = coalesce(s.card_type, p_stmt->>'card_type')
      where s.stmt_code = v_stmt;
    end if;
  else
    insert into public.statements (profile_code, account_code, doc_code, kind, statement_reference, reference_source,
      statement_date, period_start, period_end, due_date, opening_balance, closing_balance, total_debits,
      total_credits, min_due, credit_limit, primary_card_last4, card_holder, card_type, parser_version, warnings, metadata)
    values (v_profile, v_account, v_doc, v_kind, p_stmt->>'statement_reference',
      p_stmt->>'reference_source', v_date, (p_stmt->>'period_start')::date, (p_stmt->>'period_end')::date,
      (p_stmt->>'due_date')::date, (v_totals->>'opening_balance')::numeric, (v_totals->>'closing_balance')::numeric,
      (v_totals->>'total_debits')::numeric, (v_totals->>'total_credits')::numeric, (v_totals->>'min_due')::numeric,
      (v_totals->>'credit_limit')::numeric, v_last4, p_stmt->>'card_holder', p_stmt->>'card_type', p_parser_version,
      coalesce(p_stmt->'warnings', '[]'::jsonb), coalesce(p_stmt->'metadata', '{}'::jsonb))
    returning stmt_code into v_stmt;
  end if;

  if v_n_in = 0 then
    v_warnings := v_warnings || to_jsonb(format('%s %s: this document has no transaction rows%s', v_kind, v_date,
      case when v_existing and not v_own then '; the statement and its lines from other documents are kept' else '' end));
  end if;

  -- Incoming lines with their stable identity.
  create temp table if not exists _in_lines (
    line_no int, line_key text, occurrence smallint, txn_date date, txn_time time, posting_date date,
    description_raw text, description text, amount_original numeric, currency_original text, amount_aed numeric,
    fx_rate numeric, direction text, kind text, country_code text, card_last4 text, card_holder text,
    legacy_fingerprint text, raw jsonb
  ) on commit drop;
  truncate _in_lines;

  insert into _in_lines
  select x.line_no, x.line_key,
         row_number() over (partition by x.line_key order by x.line_no)::smallint,
         x.txn_date, x.txn_time, x.posting_date, x.description_raw, x.description, x.amount_original,
         x.currency_original, x.amount_aed, x.fx_rate, x.direction, x.kind, x.country_code, x.card_last4,
         x.card_holder, x.legacy_fingerprint, x.raw
  from (
    select (j->>'line_no')::int as line_no,
           encode(sha256(convert_to(concat_ws('|', v_account, j->>'txn_date', j->>'posting_date',
             (j->>'amount_original')::numeric(14,2), j->>'currency_original', (j->>'amount_aed')::numeric(14,2),
             j->>'direction', regexp_replace(btrim(j->>'description_raw'), '\s+', ' ', 'g')), 'UTF8')), 'hex') as line_key,
           (j->>'txn_date')::date as txn_date,
           (j->>'txn_time')::time as txn_time,
           (j->>'posting_date')::date as posting_date,
           j->>'description_raw' as description_raw,
           coalesce(private.normalize_text(j->>'merchant_normalized'), private.normalize_text(j->>'description_raw'), 'UNKNOWN') as description,
           (j->>'amount_original')::numeric(14,2) as amount_original,
           j->>'currency_original' as currency_original,
           (j->>'amount_aed')::numeric(14,2) as amount_aed,
           nullif((j->>'fx_rate')::numeric(18,8), 0) as fx_rate,  -- below 1e-8 rounds to 0: unknown (X-33)
           j->>'direction' as direction,
           j->>'kind' as kind,
           j->>'country_code' as country_code,
           nullif(j->>'card_last4', '') as card_last4,
           j->>'card_holder' as card_holder,
           j->>'legacy_fingerprint' as legacy_fingerprint,
           j as raw
    from jsonb_array_elements(coalesce(p_stmt->'lines', '[]'::jsonb)) j
  ) x;

  -- This document's lines that vanished from its new parse: withdraw its
  -- evidence; a line nobody evidences any more leaves the ledger.
  with r as (
    update public.statement_lines l set source_doc_codes = array_remove(l.source_doc_codes, v_doc)
    where l.profile_code = v_profile and l.stmt_code = v_stmt and l.is_current
      and l.source_doc_codes @> array[v_doc]
      and not exists (select 1 from _in_lines i where i.line_key = l.line_key and i.occurrence = l.occurrence)
    returning l.line_code, l.source_doc_codes
  )
  select array_agg(line_code) filter (where cardinality(source_doc_codes) = 0) into v_gone from r;
  v_superseded := private.detach_lines(v_profile, v_gone);

  -- Unchanged lines this document also evidences.
  update public.statement_lines l set source_doc_codes = l.source_doc_codes || v_doc
  from _in_lines i
  where l.profile_code = v_profile and l.stmt_code = v_stmt and l.is_current
    and l.line_key = i.line_key and l.occurrence = i.occurrence
    and not (l.source_doc_codes @> array[v_doc]);

  -- New lines (unchanged ones keep their codes and evidence).
  insert into public.statement_lines (stmt_code, profile_code, account_code, card_code, evidence_type, line_no,
    line_key, occurrence, txn_date, txn_time, posting_date, description_raw, description, amount_original,
    currency_original, amount_aed, fx_rate, direction, kind, country_code, card_last4, legacy_fingerprint, raw,
    source_doc_codes)
  select v_stmt, v_profile, v_account,
         private.ensure_card(v_profile, v_account, v_bank, i.card_last4, i.card_holder,
                             i.card_last4 is distinct from v_last4),
         case when v_kind = 'statement' then 'statement_line' else 'history_line' end,
         i.line_no, i.line_key, i.occurrence, i.txn_date, i.txn_time, i.posting_date, i.description_raw,
         i.description, i.amount_original, i.currency_original, i.amount_aed, i.fx_rate, i.direction, i.kind,
         i.country_code, i.card_last4, i.legacy_fingerprint, i.raw, array[v_doc]
  from _in_lines i
  where not exists (select 1 from public.statement_lines l
                    where l.stmt_code = v_stmt and l.line_key = i.line_key and l.occurrence = i.occurrence);
  get diagnostics v_inserted = row_count;

  -- A line that is current again (re-added after a parser fix) is re-activated.
  update public.statement_lines l set is_current = true, superseded_at = null, line_no = i.line_no,
    source_doc_codes = array_append(array_remove(l.source_doc_codes, v_doc), v_doc)
  from _in_lines i
  where l.stmt_code = v_stmt and not l.is_current and l.line_key = i.line_key and l.occurrence = i.occurrence;

  v_match := private.match_statement_lines(v_stmt);

  -- Period overlap with another real statement of the same account.
  if v_kind = 'statement' and (p_stmt->>'period_start') is not null and (p_stmt->>'period_end') is not null then
    insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
    select v_profile, v_account, 'statement', v_stmt, 'period_overlap',
           jsonb_agg(jsonb_build_object('stmt_code', o.stmt_code, 'statement_date', o.statement_date))
    from public.statements o
    where o.profile_code = v_profile and o.account_code = v_account
      and o.kind = 'statement' and o.status = 'active' and o.stmt_code <> v_stmt
      and o.period_start is not null and o.period_end is not null
      and least(o.period_end, (p_stmt->>'period_end')::date) - greatest(o.period_start, (p_stmt->>'period_start')::date) > 3
    having count(*) > 0
    on conflict do nothing;
  end if;

  v_recon := private.reconcile_statement(v_stmt);

  return jsonb_build_object(
    'stmt_code', v_stmt, 'account_code', v_account, 'kind', v_kind, 'replaced', v_existing,
    'lines_new', v_inserted, 'lines_superseded', v_superseded, 'match', v_match, 'recon', v_recon,
    'warnings', v_warnings
  );
end;
$function$;

-- ── DB-34, DB-36: process_sms ───────────────────────────────────────────────
create or replace function private.process_sms(p_sms_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  m record;
  v_card public.cards%rowtype;
  v_account text;
  v_n int;
  v_event timestamptz;
  v_fields jsonb;
  v_ignored boolean;
  v_result text;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code for update;
  if exists (select 1 from public.transaction_evidence e where e.sms_code = p_sms_code and e.is_active) then
    return 'already_linked';
  end if;

  select * into m from private.match_sms_template(s.sender, s.body) limit 1;
  if m.template_code is null then
    update public.sms_messages set parse_status = 'unparsed', template_code = null where sms_code = p_sms_code;
    return 'unparsed';
  end if;
  v_fields := m.fields;

  v_event := s.received_at;
  if m.fields ? 'date' then
    begin
      v_event := ((m.fields->>'date') || ' ' || coalesce(m.fields->>'time', to_char(s.received_at at time zone 'Asia/Dubai', 'HH24:MI:SS')))::timestamp
                 at time zone 'Asia/Dubai';
    exception when others then
      v_event := s.received_at;
    end;
    -- A bank alert arrives within minutes of the charge. A template date far from
    -- the arrival time is a DD/MM vs MM/DD misread: keep the arrival time (DB-36).
    if abs(extract(epoch from v_event - s.received_at)) > 7 * 86400 then
      raise warning 'sms %: template date % is more than 7 days from received_at; using received_at',
        p_sms_code, v_event;
      v_fields := v_fields || jsonb_build_object('event_at_rejected', v_event);
      v_event := s.received_at;
    end if;
  end if;

  if m.fields ? 'last4' then
    select * into v_card from public.cards
    where profile_code = s.profile_code and bank_code = m.bank_code and last4 = m.fields->>'last4';
    v_account := v_card.account_code;
  end if;
  if v_account is null and not (m.fields ? 'last4') then
    select count(*), min(account_code) into v_n, v_account
    from public.accounts where profile_code = s.profile_code and bank_code = m.bank_code and status = 'active';
    if v_n <> 1 then v_account := null; end if;
  end if;

  -- Declined alerts are not transactions: stored 'ignored' like debit-card and other alerts (DB-34).
  v_ignored := m.msg_kind in ('debit_card', 'other', 'declined');
  update public.sms_messages set
    parse_status = case when v_ignored then 'ignored' else 'parsed' end,
    ignore_reason = case when v_ignored then m.msg_kind end,
    template_code = m.template_code,
    template_version = m.template_version,
    bank_code = m.bank_code,
    msg_kind = m.msg_kind,
    card_last4 = m.fields->>'last4',
    card_code = v_card.card_code,
    account_code = v_account,
    amount = (m.fields->>'amount')::numeric,
    currency = coalesce(m.fields->>'currency', 'AED'),
    merchant_raw = m.fields->>'merchant',
    description = private.normalize_text(m.fields->>'merchant'),
    available_limit = (m.fields->>'available')::numeric,
    event_at = v_event,
    parsed_fields = v_fields
  where sms_code = p_sms_code;

  if v_ignored then
    return 'ignored';
  end if;
  if v_account is null then
    insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
    values (s.profile_code, 'sms', p_sms_code, 'unknown_card',
            jsonb_build_array(jsonb_build_object('bank_code', m.bank_code, 'last4', m.fields->>'last4')))
    on conflict do nothing;
    return 'unknown_card';
  end if;

  v_result := private.match_sms(p_sms_code);
  return v_result;
end;
$$;

-- Existing declined alerts: same status as new ones (guarded: only rows still 'parsed').
update public.sms_messages set parse_status = 'ignored'
where msg_kind = 'declined' and parse_status = 'parsed' and ignore_reason = 'declined'
  and not exists (select 1 from public.transaction_evidence e where e.sms_code = sms_messages.sms_code);

-- ── DB-17r: SMS waiting on a card the statement just registered ─────────────
-- Re-processes the profile's SMS held as unknown_card whose card (or, without a
-- card number, whose bank's single active account) now exists, and closes the
-- reviews of every message that found its account. Errors are per message.
create or replace function private.reprocess_waiting_sms(p_profile text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_code text;
  v_state text;
  v_bound integer;
begin
  for v_code in
    select s.sms_code from public.sms_messages s
    where s.profile_code = p_profile and s.account_code is null and s.parse_status = 'parsed'
      and exists (select 1 from public.match_reviews r
                  where r.profile_code = p_profile and r.subject_type = 'sms' and r.subject_code = s.sms_code
                    and r.reason = 'unknown_card' and r.status = 'open')
      and case when s.card_last4 is not null
               then exists (select 1 from public.cards c
                            where c.profile_code = p_profile and c.bank_code = s.bank_code and c.last4 = s.card_last4)
               else (select count(*) from public.accounts a
                     where a.profile_code = p_profile and a.bank_code = s.bank_code and a.status = 'active') = 1
          end
    order by s.received_at, s.sms_code
  loop
    begin
      perform private.process_sms(v_code);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      raise warning 'reprocess_waiting_sms: sms % failed (%)', v_code, v_state;
    end;
  end loop;

  update public.match_reviews r set status = 'resolved', resolution = jsonb_build_object('auto', 'card_registered'),
    resolved_at = now()
  where r.profile_code = p_profile and r.reason = 'unknown_card' and r.status = 'open' and r.subject_type = 'sms'
    and exists (select 1 from public.sms_messages s
                where s.profile_code = p_profile and s.sms_code = r.subject_code and s.account_code is not null);
  get diagnostics v_bound = row_count;
  return v_bound;
end;
$$;

-- ── DP-04r, DB-17r: ingest_parsed_document ──────────────────────────────────
create or replace function public.ingest_parsed_document(p_doc_code text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documents%rowtype;
  v_profile text;
  s jsonb;
  v_ord bigint;
  v_account text;
  v_stmt text;
  v_res jsonb;
  v_results jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_sms integer;
begin
  perform private.assert_service_role();
  select profile_code into v_profile from public.documents where doc_code = p_doc_code;
  if not found then
    raise exception 'unknown document %', p_doc_code using errcode = 'P0002';
  end if;
  perform private.lock_profile(v_profile);
  select * into d from public.documents where doc_code = p_doc_code for update;
  if (p_payload->>'contract_version')::int is distinct from 1 then
    raise exception 'unsupported parser contract %', p_payload->>'contract_version' using errcode = '22023';
  end if;
  -- Defence in depth (DP-04r): the parser validates dates; a statement more than a
  -- month in the future is a misread year and must not reach the ledger.
  -- (`ledger.test_today` lets pgTAP suites with fixed future dates pin "today".)
  if exists (select 1 from jsonb_array_elements(coalesce(p_payload->'statements', '[]'::jsonb)) x
             where (x->>'statement_date')::date
                   > coalesce(nullif(current_setting('ledger.test_today', true), '')::date, public.dubai_date(now())) + 31) then
    raise exception 'statement dated more than 31 days in the future' using errcode = '22023';
  end if;

  create temp table if not exists _doc_stmts (
    ord bigint, account_code text, statement_date date, kind text, body jsonb
  ) on commit drop;
  truncate _doc_stmts;

  for s, v_ord in select value, ordinality from jsonb_array_elements(coalesce(p_payload->'statements', '[]'::jsonb))
                  with ordinality loop
    if nullif(s->>'primary_card_last4', '') is null
       and jsonb_array_length(coalesce(s->'lines', '[]'::jsonb)) = 0 then
      v_warnings := v_warnings || to_jsonb(format('%s %s skipped: no card number and no transaction rows',
                                                  s->>'kind', s->>'statement_date'));
      continue;
    end if;
    v_account := private.resolve_statement_account(
      d.profile_code, s->>'bank_code', nullif(s->>'primary_card_last4', ''), s->>'card_holder', s->>'card_type',
      nullif(s->'totals'->>'credit_limit', '')::numeric, d.doc_code, s->>'statement_reference', s->>'reference_source'
    );
    insert into _doc_stmts values (v_ord, v_account, (s->>'statement_date')::date, s->>'kind', s);
  end loop;

  for v_stmt in
    select st.stmt_code from public.statements st
    where st.profile_code = d.profile_code and st.status = 'active'
      and (st.doc_code = d.doc_code
           or exists (select 1 from public.statement_lines l
                      where l.profile_code = d.profile_code and l.stmt_code = st.stmt_code and l.is_current
                        and l.source_doc_codes @> array[d.doc_code]))
      and not exists (select 1 from _doc_stmts x
                      where x.account_code = st.account_code and x.statement_date = st.statement_date
                        and x.kind = st.kind)
  loop
    perform private.retire_doc_from_statement(v_stmt, d.doc_code);
  end loop;

  for s, v_account in select body, account_code from _doc_stmts order by ord loop
    v_res := private.ingest_one_statement(d, s, p_payload->>'parser_version', v_account);
    v_results := v_results || v_res;
    v_warnings := v_warnings || coalesce(v_res->'warnings', '[]'::jsonb);
  end loop;

  -- SMS held as unknown_card whose card this document registered (DB-17r).
  v_sms := private.reprocess_waiting_sms(d.profile_code);

  update public.documents set
    parse_status = 'parsed',
    kind = p_payload->>'document_kind',
    bank_code = coalesce(p_payload->>'bank_code', bank_code),
    parser_version = p_payload->>'parser_version',
    parse_error_code = null,
    parse_error = null,
    parse_warnings = coalesce((select jsonb_agg(w) from jsonb_array_elements(p_payload->'statements') st,
                                 jsonb_array_elements(coalesce(st->'warnings', '[]'::jsonb)) w), '[]'::jsonb)
                     || v_warnings,
    parsed_at = now()
  where doc_code = p_doc_code;

  return jsonb_build_object('doc_code', p_doc_code, 'statements', v_results, 'warnings', v_warnings,
                            'sms_card_registered', v_sms);
end;
$$;

-- ── DB-32r: estimate_fx index; anomalies in one pass ────────────────────────
create index if not exists statement_lines_fx_estimate_idx
  on public.statement_lines (profile_code, currency_original, txn_date desc)
  where fx_rate is not null;

-- Same output as before: baselines over the 365 days before each transaction
-- (its own day excluded), now as window frames over one scan of v_spend.
create or replace function public.anomalies(p_profile_code text, p_from date, p_to date)
returns table(txn_code text, txn_date date, description text, amount numeric, reason text,
              baseline_mean numeric, baseline_sd numeric)
language sql
stable
set search_path = ''
as $$
  with hist as (
    select s.txn_code, s.txn_date, s.description, s.merchant_code, s.category_code, s.spend_aed
    from public.v_spend s
    where s.profile_code = p_profile_code and s.spend_aed > 0
      and s.txn_date >= p_from - 365 and s.txn_date <= p_to
  ),
  scored as (
    select h.txn_code, h.txn_date, h.description, h.spend_aed,
           case when h.merchant_code is null then 0 else count(*) over mw end as m_n,
           case when h.merchant_code is not null then avg(h.spend_aed) over mw end as m_mean,
           case when h.merchant_code is not null then stddev_samp(h.spend_aed) over mw end as m_sd,
           count(*) over cw as c_n,
           avg(h.spend_aed) over cw as c_mean,
           stddev_samp(h.spend_aed) over cw as c_sd
    from hist h
    window mw as (partition by h.merchant_code order by h.txn_date
                  range between interval '365 days' preceding and interval '1 day' preceding),
           cw as (partition by h.category_code order by h.txn_date
                  range between interval '365 days' preceding and interval '1 day' preceding)
  )
  select txn_code, txn_date, description, spend_aed,
         case
           when m_n >= 5 and spend_aed > m_mean + 3 * coalesce(m_sd, 0) and spend_aed > m_mean * 1.5 then 'merchant_outlier'
           when c_n >= 10 and spend_aed > c_mean + 3 * coalesce(c_sd, 0) then 'category_outlier'
           when m_n = 0 and spend_aed >= 500 then 'new_merchant_large'
         end,
         round(coalesce(case when m_n >= 5 then m_mean end, c_mean), 2),
         round(coalesce(case when m_n >= 5 then m_sd end, c_sd), 2)
  from scored
  where txn_date between p_from and p_to
    and ((m_n >= 5 and spend_aed > m_mean + 3 * coalesce(m_sd, 0) and spend_aed > m_mean * 1.5)
      or (c_n >= 10 and spend_aed > c_mean + 3 * coalesce(c_sd, 0))
      or (m_n = 0 and spend_aed >= 500))
  order by spend_aed desc
$$;

-- ── X-33: derived fx_rate is null for AED ───────────────────────────────────
update public.transactions set fx_rate = null where currency_original = 'AED' and fx_rate is not null;

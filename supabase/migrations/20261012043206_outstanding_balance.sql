-- Outstanding balance per card, and the transactions that must not count in it.
--
-- Audit (2026-10-12): the Activity header's net for the main profile read AED 796.13 in credit
-- while the cards owed about AED 3,500. Two causes:
--   1. The FAB re-parse of 2026-10-11 (lesson: "A row's identity hash names its parent") left 110
--      orphaned transactions beside their re-created twins. Their reviews were dismissed, which
--      closed the review but left the rows live, and activity_summary counted every non-void row
--      (v_spend already counted only pending and posted). Net effect: AED -2,996.20.
--   2. A sum of transactions cannot know the balance carried in before the first document: the
--      first statement's opening balance (ENBD 404.07, FAB 64.38), or for SIB, whose transaction
--      histories print no balance, the old card's balance moved onto the replacement card.
--
-- Fixes:
--   public.v_account_balances: one definition of what a card owes now (CLAUDE.md §1.12, §2.2).
--     Anchor = the latest of
--       * 'statement': the latest active statement with a printed closing balance; then add the
--         live transactions not on it or an earlier statement (on a later statement, or on none
--         yet, e.g. SMS-only). Membership, not dates: a purchase dated before the close that
--         posts in the next cycle is on the next statement.
--       * 'balance_migration': the latest "BALANCE MIGRATION" adjustment on a replacement card
--         (SIB). The bank moved the old card's whole billed balance onto it, so the balance
--         restarts at 0 that day and the migration rows themselves carry it in; add every live
--         transaction dated on or after it.
--       * 'none': no anchor; outstanding_aed is null rather than a guess.
--     Live = pending or posted. outstanding_aed: positive is owed, negative is a credit balance.
--   public.overview: per account outstanding_aed and its anchor; profile total `outstanding`,
--     `outstanding_complete`, `outstanding_has_estimate`.
--   public.activity_summary: net_aed, unpriced_count and has_estimate count pending and posted
--     rows only, like v_spend; void and orphaned rows have no evidence behind them.
--   public.resolve_review: dismissing ("Mark as checked") an orphaned-transaction review voids
--     the transaction (void_reason 'orphan_dismissed').
--   private.void_orphan_duplicates(), run once at the end: void the orphaned transactions that
--     have a live twin on the same statement, paired one to one, and only when the user has not
--     touched them. In production: the 110 FAB rows above (AED -2,996.20). Idempotent.

create view public.v_account_balances with (security_invoker = true) as
select a.profile_code,
       a.account_code,
       k.anchor_kind,
       case k.anchor_kind when 'statement' then s.statement_date when 'balance_migration' then m.migration_date end
         as anchor_date,
       case when k.anchor_kind = 'statement' then s.stmt_code end as anchor_stmt_code,
       case k.anchor_kind when 'statement' then s.closing_balance when 'balance_migration' then 0::numeric(14,2) end
         as anchor_balance,
       case when k.anchor_kind <> 'none' then x.activity_aed end as activity_aed,
       case k.anchor_kind
         when 'statement' then (s.closing_balance + x.activity_aed)::numeric(14,2)
         when 'balance_migration' then x.activity_aed::numeric(14,2)
       end as outstanding_aed,
       x.unpriced_count,
       x.has_estimate
from public.accounts a
left join lateral (
  select st.stmt_code, st.statement_date, st.closing_balance
  from public.statements st
  where st.account_code = a.account_code and st.kind = 'statement' and st.status = 'active'
    and st.closing_balance is not null
  order by st.statement_date desc, st.created_at desc
  limit 1
) s on true
left join lateral (
  select max(t.txn_date) as migration_date
  from public.transactions t
  where t.account_code = a.account_code and t.status in ('pending', 'posted')
    and t.kind = 'adjustment' and t.direction = 'debit' and t.description ilike 'BALANCE MIGRATION%'
) m on true
cross join lateral (
  select case when m.migration_date is not null
                   and (s.statement_date is null or m.migration_date > s.statement_date) then 'balance_migration'
              when s.stmt_code is not null then 'statement'
              else 'none' end as anchor_kind
) k
cross join lateral (
  select coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end), 0)::numeric(14,2)
           as activity_aed,
         count(*) filter (where t.amount_aed is null)::integer as unpriced_count,
         coalesce(bool_or(t.amount_aed_is_estimate), false) as has_estimate
  from public.transactions t
  where t.account_code = a.account_code and t.status in ('pending', 'posted')
    and case k.anchor_kind
          when 'statement' then
            t.stmt_code is null
            or exists (select 1 from public.statements ts
                       where ts.stmt_code = t.stmt_code and ts.statement_date > s.statement_date)
          when 'balance_migration' then t.txn_date >= m.migration_date
          else true
        end
) x;

grant select on public.v_account_balances to authenticated, service_role;

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

create or replace function public.activity_summary(
  p_profile_code text,
  p_from date default null,
  p_to date default null,
  p_account_code text default null,
  p_card_code text default null,
  p_category_code text default null,
  p_uncategorized boolean default false,
  p_status text default null,
  p_source text default null,
  p_q text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pattern text := private.activity_search_pattern(p_q);
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_status is not null and p_status not in ('pending', 'posted', 'void', 'orphaned') then
    raise exception 'p_status must be pending, posted, void or orphaned' using errcode = '22023';
  end if;
  if p_source is not null and p_source not in ('sms', 'statement', 'both') then
    raise exception 'p_source must be sms, statement or both' using errcode = '22023';
  end if;

  select jsonb_build_object(
           'txn_count', count(*),
           'net_aed', coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)
                                 filter (where t.status in ('pending', 'posted')), 0)::numeric(14,2)::text,
           'unpriced_count', count(*) filter (where t.status in ('pending', 'posted') and t.amount_aed is null),
           'has_estimate', coalesce(bool_or(t.amount_aed_is_estimate) filter (where t.status in ('pending', 'posted')), false),
           'earliest_date', min(t.txn_date),
           'latest_date', max(t.txn_date))
  into v_out
  from public.v_transactions t
  where t.profile_code = p_profile_code
    and (p_from is null or t.txn_date >= p_from)
    and (p_to is null or t.txn_date <= p_to)
    and (p_account_code is null or t.account_code = p_account_code)
    and (p_card_code is null or t.card_code = p_card_code)
    and (case when coalesce(p_uncategorized, false) then t.category_code is null
              else p_category_code is null or t.category_code = p_category_code end)
    and (p_status is null or t.status = p_status)
    and (p_source is null
         or (p_source = 'sms' and t.has_sms and not t.has_statement)
         or (p_source = 'statement' and t.has_statement and not t.has_sms)
         or (p_source = 'both' and t.has_sms and t.has_statement))
    and (v_pattern is null or t.description ilike v_pattern or t.merchant_name ilike v_pattern);
  return v_out;
end;
$$;

create or replace function public.resolve_review(p_review_code text, p_action jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.match_reviews%rowtype;
  v_profile text;
  v_txn text;
  v_txn_account text;
  v_account text;
  v_target text;
  v_line public.statement_lines%rowtype;
  v_sms public.sms_messages%rowtype;
  v_displaced text[];
  v_outcome text;
begin
  select profile_code into v_profile from public.match_reviews where review_code = p_review_code;
  if not found then
    raise exception 'review % is not open', p_review_code using errcode = 'P0002';
  end if;
  perform private.assert_member(v_profile, true);
  perform private.lock_profile(v_profile);
  select * into r from public.match_reviews where review_code = p_review_code for update;
  if r.status <> 'open' then
    raise exception 'review % is not open', p_review_code using errcode = 'P0002';
  end if;
  if p_action is null or jsonb_typeof(p_action) <> 'object' then
    raise exception 'unsupported action %', p_action using errcode = '22023';
  end if;

  if p_action ? 'dismiss' then
    -- An orphaned transaction has lost all its evidence (CLAUDE.md §1.10): checking it off voids
    -- it, so it stops counting in every total. One whose evidence came back is no longer orphaned
    -- and stays as it is.
    if r.reason = 'orphaned' and r.subject_type = 'transaction' then
      update public.transactions set voided_at = now(), void_reason = 'orphan_dismissed'
      where txn_code = r.subject_code and profile_code = r.profile_code and status = 'orphaned';
      if found then
        perform private.refresh_transaction(r.subject_code);
        v_txn := r.subject_code;
      end if;
    end if;
    v_outcome := 'dismissed';

  elsif p_action ? 'link' then
    v_txn := p_action->>'link';
    select account_code into v_txn_account from public.transactions
    where txn_code = v_txn and profile_code = r.profile_code;
    if not found then
      raise exception 'unknown transaction %', v_txn using errcode = 'P0002';
    end if;
    if r.subject_type = 'statement_line' then
      select * into v_line from public.statement_lines where line_code = r.subject_code and profile_code = r.profile_code;
      if not found then
        raise exception 'unknown statement line %', r.subject_code using errcode = 'P0002';
      end if;
      if v_line.account_code <> v_txn_account then
        raise exception 'transaction % is on a different account', v_txn using errcode = '22023';
      end if;
      if exists (select 1 from public.transaction_evidence e
                 where e.profile_code = r.profile_code and e.txn_code = v_txn and e.is_active
                   and e.evidence_type = v_line.evidence_type and e.is_locked) then
        raise exception 'transaction % already has a confirmed %', v_txn, v_line.evidence_type using errcode = '22023';
      end if;
      with d as (
        update public.transaction_evidence set is_active = false, deactivated_at = now()
        where profile_code = r.profile_code and txn_code = v_txn and is_active
          and evidence_type = v_line.evidence_type and not is_locked
        returning line_code
      )
      select array_agg(line_code) into v_displaced from d;
      insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, role, method, is_locked)
      values (v_txn, r.profile_code, v_line.evidence_type, v_line.line_code, 'post', 'manual', true);
      perform private.refresh_transaction(v_txn);
      -- A line pushed off the transaction stays in the ledger as its own transaction (DB-27).
      perform private.new_transaction_from_line(x.line_code)
      from unnest(coalesce(v_displaced, '{}')) as x(line_code)
      join public.statement_lines l on l.line_code = x.line_code and l.profile_code = r.profile_code and l.is_current
      where not exists (select 1 from public.transaction_evidence e where e.line_code = x.line_code and e.is_active);
    elsif r.subject_type = 'sms' then
      select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
      if not found then
        raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
      end if;
      if v_sms.account_code is distinct from v_txn_account then
        raise exception 'transaction % is not on this message''s account', v_txn using errcode = '22023';
      end if;
      insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, method, is_locked)
      values (v_txn, r.profile_code, 'sms', v_sms.sms_code, 'auth', 'manual', true);
      perform private.refresh_transaction(v_txn);
    else
      raise exception 'link is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    v_outcome := 'linked';

  elsif p_action ? 'create_new' then
    if r.subject_type = 'statement_line' then
      if not exists (select 1 from public.statement_lines
                     where line_code = r.subject_code and profile_code = r.profile_code) then
        raise exception 'unknown statement line %', r.subject_code using errcode = 'P0002';
      end if;
      v_txn := private.new_transaction_from_line(r.subject_code, 'manual');
    elsif r.subject_type = 'sms' then
      select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
      if not found then
        raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
      end if;
      if v_sms.account_code is null or v_sms.amount is null then
        raise exception 'sms % has no account or amount; register its card first', r.subject_code using errcode = '22023';
      end if;
      v_txn := private.new_transaction_from_sms(r.subject_code, 'manual');
    else
      raise exception 'create_new is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    v_outcome := 'created';

  elsif p_action ? 'card' and r.reason = 'unknown_card' then
    v_account := p_action->'card'->>'account_code';
    select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
    if not found then
      raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
    end if;
    if not exists (select 1 from public.accounts a
                   where a.account_code = v_account and a.profile_code = r.profile_code
                     and a.bank_code = v_sms.bank_code) then
      raise exception 'unknown account %', v_account using errcode = 'P0002';
    end if;
    update public.match_reviews set status = 'resolved', resolution = p_action, resolved_by = auth.uid(), resolved_at = now()
    where review_code = p_review_code;
    if v_sms.card_last4 is null then
      -- No card number to register (DB-43): bind this one message to the chosen account.
      update public.sms_messages set account_code = v_account where sms_code = v_sms.sms_code;
      perform private.match_sms(v_sms.sms_code);
    else
      perform private.ensure_card(r.profile_code, v_account, v_sms.bank_code, v_sms.card_last4, null, true);
      -- Every message waiting on this card can now be processed.
      perform private.process_sms(s.sms_code)
      from public.sms_messages s
      where s.profile_code = r.profile_code and s.bank_code = v_sms.bank_code and s.card_last4 = v_sms.card_last4
        and s.account_code is null;
    end if;
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'card_registered'),
      resolved_at = now()
    where profile_code = r.profile_code and reason = 'unknown_card' and status = 'open'
      and subject_code in (select sms_code from public.sms_messages
                           where profile_code = r.profile_code and account_code is not null);
    return jsonb_build_object('review_code', p_review_code, 'outcome', 'card_registered');

  elsif p_action ? 'not_a_transaction' then
    if r.subject_type <> 'sms' then
      raise exception 'not_a_transaction is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
    if not found then
      raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
    end if;
    if exists (select 1 from public.transaction_evidence e where e.sms_code = v_sms.sms_code and e.is_active) then
      raise exception 'sms % is already part of a transaction', v_sms.sms_code using errcode = '22023';
    end if;
    update public.sms_messages set parse_status = 'ignored', ignore_reason = 'user_not_txn'
    where sms_code = v_sms.sms_code;
    -- Any other open review about the same message is moot now.
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'user_not_txn'),
      resolved_by = auth.uid(), resolved_at = now()
    where profile_code = r.profile_code and subject_type = 'sms' and subject_code = v_sms.sms_code
      and status = 'open' and review_code <> p_review_code;
    v_outcome := 'ignored';

  elsif p_action ? 'supersede' and r.reason = 'period_overlap' then
    select st.stmt_code into v_target
    from public.statements st
    where st.stmt_code = p_action->>'supersede'
      and st.profile_code = r.profile_code
      and st.account_code = r.account_code
      and st.kind = 'statement' and st.status = 'active'
      and st.stmt_code <> r.subject_code
      and r.candidates @> jsonb_build_array(jsonb_build_object('stmt_code', st.stmt_code));
    if v_target is null then
      raise exception 'statement % is not a candidate of review %', p_action->>'supersede', p_review_code
        using errcode = 'P0002';
    end if;
    perform private.supersede_statement(v_target, r.subject_code);
    v_outcome := 'superseded';

  else
    raise exception 'unsupported action %', p_action using errcode = '22023';
  end if;

  update public.match_reviews
  set status = case when v_outcome = 'dismissed' then 'dismissed' else 'resolved' end,
      resolution = p_action, resolved_by = auth.uid(), resolved_at = now()
  where review_code = p_review_code;
  return jsonb_build_object('review_code', p_review_code, 'outcome', v_outcome, 'txn_code', v_txn);
end;
$$;

-- ── data: void orphaned duplicates ──────────────────────────────────────────
-- An orphaned transaction whose twin is live on the same statement (same date, direction, kind,
-- AED amount and description) is the pre-re-parse copy of that twin. Pairs one to one (two
-- orphans and one live twin void one orphan), and skips rows the user annotated. Idempotent.
create or replace function private.void_orphan_duplicates()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer := 0;
  r record;
begin
  for r in
    -- Copies voided by an earlier run rank first, so each live twin is used once across runs.
    with o as (
      select t.txn_code, t.profile_code, t.status,
             row_number() over (partition by t.account_code, t.stmt_code, t.txn_date, t.direction, t.kind,
                                             t.amount_aed, t.description
                                order by (t.status = 'void') desc, t.txn_code) as rn,
             (select count(*) from public.transactions l
              where l.account_code = t.account_code and l.stmt_code = t.stmt_code and l.txn_date = t.txn_date
                and l.direction = t.direction and l.kind = t.kind and l.amount_aed = t.amount_aed
                and l.description = t.description and l.status in ('pending', 'posted')) as live
      from public.transactions t
      where t.stmt_code is not null and t.amount_aed is not null
        and ((t.status = 'void' and t.void_reason = 'orphan_duplicate')
             or (t.status = 'orphaned' and t.voided_at is null and t.manual_category_code is null
                 and t.notes is null and not t.exclude_from_spend))
    )
    select txn_code, profile_code from o where status = 'orphaned' and rn <= live
  loop
    -- Resolve the review first: refresh_transaction would close it as 'evidence_reattached'.
    update public.match_reviews
    set status = 'resolved', resolution = jsonb_build_object('auto', 'orphan_duplicate_voided'), resolved_at = now()
    where profile_code = r.profile_code and subject_type = 'transaction' and subject_code = r.txn_code
      and reason = 'orphaned' and status = 'open';
    update public.transactions set voided_at = now(), void_reason = 'orphan_duplicate'
    where txn_code = r.txn_code;
    perform private.refresh_transaction(r.txn_code);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

select private.void_orphan_duplicates();

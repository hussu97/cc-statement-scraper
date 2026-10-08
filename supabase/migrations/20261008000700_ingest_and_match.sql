-- Ingestion and matching.
--
-- Evidence (statement lines, history lines, SMS) is immutable. Canonical
-- transactions are linked to evidence by transaction_evidence. A transaction's
-- facts are always *derived* from its best active evidence
-- (statement line > history line > SMS) by private.refresh_transaction().
--
-- Matching is deterministic and greedy. Every candidate pair gets a 0–100 score:
--   amount   50 exact same-currency | 40/30 AED within 1%/4% (FX) | 35 variable-amount merchant
--   date     25 same day | 20 ±1 | 12 ±2 | 5 ±3 (or posting date ±1)
--   merchant 15 × (same merchant ? 1 : trigram similarity)
--   card     10 same last4 | 5 unknown | different last4 → rejected
-- ≥75 with no materially different competitor within 15 points → auto-link.
-- 55–75, or a materially different competitor → match_reviews, evidence held.
-- <55 → a new transaction.
-- Identical candidates (two same-day coffees) are interchangeable, not ambiguous.

-- History extracts get the same in-place identity as statements.
create unique index statements_history_identity_uq on public.statements(account_code, statement_date)
  where kind = 'history_extract' and status = 'active';

-- ── scoring ─────────────────────────────────────────────────────────────────
create or replace function private.match_score(
  e_amount numeric, e_currency text, e_amount_aed numeric, e_date date, e_posting date,
  e_desc text, e_merchant text, e_last4 text,
  t_amount numeric, t_currency text, t_amount_aed numeric, t_date date, t_posting date,
  t_desc text, t_merchant text, t_last4 text, t_variable boolean
)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  s_amount numeric;
  s_date numeric;
  s_merchant numeric;
  s_card numeric;
  d int;
  diff numeric;
begin
  -- amount
  if e_currency = t_currency and e_amount = t_amount then
    s_amount := 50;
  elsif e_currency <> t_currency and e_amount_aed is not null and t_amount_aed is not null and t_amount_aed > 0 then
    diff := abs(e_amount_aed - t_amount_aed) / t_amount_aed;
    s_amount := case when diff <= 0.01 then 40 when diff <= 0.04 then 30 end;
  end if;
  if s_amount is null and coalesce(t_variable, false) then
    if e_currency = t_currency and t_amount > 0 and e_amount / t_amount between 0.3 and 1.5 then
      s_amount := 35;
    elsif e_amount_aed is not null and coalesce(t_amount_aed, 0) > 0 and e_amount_aed / t_amount_aed between 0.3 and 1.5 then
      s_amount := 35;
    end if;
  end if;
  if s_amount is null then
    return null;
  end if;

  -- date
  d := abs(e_date - t_date);
  s_date := case d when 0 then 25 when 1 then 20 when 2 then 12 when 3 then 5 end;
  if s_date is null then
    if e_posting is not null and t_posting is not null and abs(e_posting - t_posting) <= 1 then
      s_date := 5;
    else
      return null;
    end if;
  end if;

  -- merchant
  if e_merchant is not null and e_merchant = t_merchant then
    s_merchant := 15;
  else
    s_merchant := round(15 * extensions.similarity(coalesce(e_desc, ''), coalesce(t_desc, ''))::numeric, 2);
  end if;

  -- card
  if e_last4 is not null and t_last4 is not null then
    if e_last4 <> t_last4 then
      return null;
    end if;
    s_card := 10;
  else
    s_card := 5;
  end if;

  return s_amount + s_date + s_merchant + s_card;
end;
$$;

-- ── FX estimate for SMS in foreign currency ────────────────────────────────
-- Latest rate this profile has seen on a statement, else the AED/USD peg.
create or replace function private.estimate_fx(p_profile text, p_currency text)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select l.fx_rate from public.statement_lines l
      where l.profile_code = p_profile and l.currency_original = p_currency and l.fx_rate is not null
      order by l.txn_date desc limit 1),
    case p_currency when 'AED' then 1 when 'USD' then 3.6725 end
  )
$$;

-- ── accounts / cards resolution ─────────────────────────────────────────────
create or replace function private.ensure_card(
  p_profile text, p_account text, p_bank text, p_last4 text, p_holder text, p_supplementary boolean
)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_code text;
begin
  if p_last4 is null then
    return null;
  end if;
  select card_code into v_code from public.cards
  where profile_code = p_profile and bank_code = p_bank and last4 = p_last4;
  if v_code is null then
    insert into public.cards (profile_code, account_code, bank_code, last4, holder_name, is_supplementary)
    values (p_profile, p_account, p_bank, p_last4, p_holder, p_supplementary)
    returning card_code into v_code;
  end if;
  return v_code;
end;
$$;

create or replace function private.resolve_statement_account(
  p_profile text, p_bank text, p_last4 text, p_holder text, p_card_type text, p_credit_limit numeric
)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_account text;
  v_n int;
begin
  if p_last4 is not null then
    select account_code into v_account from public.cards
    where profile_code = p_profile and bank_code = p_bank and last4 = p_last4;
  end if;
  if v_account is null then
    select count(*), min(account_code) into v_n, v_account
    from public.accounts where profile_code = p_profile and bank_code = p_bank and status = 'active';
    if v_n <> 1 or p_last4 is not null then
      v_account := null;
    end if;
  end if;
  if v_account is null then
    insert into public.accounts (profile_code, bank_code, product_name, credit_limit)
    values (p_profile, p_bank, p_card_type, p_credit_limit)
    returning account_code into v_account;
  end if;
  if p_last4 is not null then
    perform private.ensure_card(p_profile, v_account, p_bank, p_last4, p_holder, false);
  end if;
  if p_credit_limit is not null then
    update public.accounts set credit_limit = p_credit_limit
    where account_code = v_account and credit_limit is distinct from p_credit_limit;
  end if;
  return v_account;
end;
$$;

-- ── derived transaction facts ───────────────────────────────────────────────
create or replace function private.refresh_transaction(p_txn_code text)
returns void
language plpgsql
set search_path = ''
as $$
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
  join public.statement_lines sl on sl.line_code = e.line_code
  where e.txn_code = p_txn_code and e.is_active and e.evidence_type in ('statement_line', 'history_line')
  order by case e.evidence_type when 'statement_line' then 0 else 1 end
  limit 1;
  v_has_line := found;

  select sm.* into s
  from public.transaction_evidence e
  join public.sms_messages sm on sm.sms_code = e.sms_code
  where e.txn_code = p_txn_code and e.is_active and e.role <> 'duplicate'
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
    t.fx_rate := l.fx_rate;
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
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'evidence_reattached'),
      resolved_at = now()
    where subject_type = 'transaction' and subject_code = t.txn_code and reason = 'orphaned' and status = 'open';
  end if;
end;
$$;

-- Create a fresh transaction for one piece of evidence and link it.
create or replace function private.new_transaction_from_line(p_line_code text, p_method text default 'new')
returns text
language plpgsql
set search_path = ''
as $$
declare
  l public.statement_lines%rowtype;
  v_txn text;
begin
  select * into l from public.statement_lines where line_code = p_line_code;
  insert into public.transactions (profile_code, account_code, card_code, kind, direction, txn_date,
    posting_date, description, amount_original, currency_original, amount_aed, fx_rate, amount_source, stmt_code, status)
  values (l.profile_code, l.account_code, l.card_code, l.kind, l.direction, l.txn_date,
    l.posting_date, l.description, l.amount_original, l.currency_original, l.amount_aed, l.fx_rate, l.evidence_type,
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
begin
  select * into s from public.sms_messages where sms_code = p_sms_code;
  v_kind := case s.msg_kind when 'refund' then 'refund' when 'reversal' then 'refund'
                            when 'payment' then 'payment' else 'purchase' end;
  v_direction := case when s.msg_kind in ('refund', 'reversal', 'payment') then 'credit' else 'debit' end;
  insert into public.transactions (profile_code, account_code, card_code, kind, direction, txn_date, txn_at,
    description, amount_original, currency_original, amount_source, status)
  values (s.profile_code, s.account_code, s.card_code, v_kind, v_direction, public.dubai_date(s.event_at), s.event_at,
    coalesce(s.description, 'CARD TRANSACTION'), s.amount, s.currency, 'sms', 'pending')
  returning txn_code into v_txn;
  insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, method)
  values (v_txn, s.profile_code, 'sms', s.sms_code, case when s.msg_kind = 'reversal' then 'reversal' else 'primary' end, p_method);
  perform private.refresh_transaction(v_txn);
  return v_txn;
end;
$$;

-- ── matcher: statement / history lines ─────────────────────────────────────
create or replace function private.match_statement_lines(p_stmt_code text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  c record;
  v_linked int := 0;
  v_created int := 0;
  v_held int := 0;
  v_conflict boolean;
  v_tie boolean;
  v_txn text;
  v_line text;
  v_touched text[] := '{}';
begin
  create temp table if not exists _m_lines (line_code text primary key, state text) on commit drop;
  create temp table if not exists _m_txns (txn_code text primary key) on commit drop;
  create temp table if not exists _m_cand (
    line_code text, txn_code text, score numeric, ddays int, line_no int, txn_created timestamptz,
    line_key text, txn_sig text
  ) on commit drop;
  truncate _m_lines, _m_txns, _m_cand;

  -- Lines that need a home: current, no active evidence, not held by an open review.
  insert into _m_lines (line_code, state)
  select l.line_code, 'open'
  from public.statement_lines l
  where l.stmt_code = p_stmt_code and l.is_current
    and not exists (select 1 from public.transaction_evidence e where e.line_code = l.line_code and e.is_active)
    and not exists (select 1 from public.match_reviews r
                    where r.subject_type = 'statement_line' and r.subject_code = l.line_code and r.status = 'open');

  insert into _m_cand
  select l.line_code, t.txn_code,
         private.match_score(
           l.amount_original, l.currency_original, l.amount_aed, l.txn_date, l.posting_date,
           l.description, private.resolve_merchant(l.description), l.card_last4,
           t.amount_original, t.currency_original, t.amount_aed, t.txn_date, t.posting_date,
           t.description, t.merchant_code, cd.last4, coalesce(mr.variable_amount, false)
         ),
         abs(l.txn_date - t.txn_date), l.line_no, t.created_at,
         l.line_key,
         concat_ws('|', t.amount_original, t.currency_original, t.txn_date, t.merchant_code)
  from _m_lines ml
  join public.statement_lines l on l.line_code = ml.line_code
  join public.transactions t
    on t.account_code = l.account_code
   and t.direction = l.direction
   and (abs(t.txn_date - l.txn_date) <= 3
        or (t.posting_date is not null and l.posting_date is not null and abs(t.posting_date - l.posting_date) <= 1))
  left join public.cards cd on cd.card_code = t.card_code
  left join public.merchants mr on mr.merchant_code = t.merchant_code
  where not exists (
    select 1 from public.transaction_evidence e
    where e.txn_code = t.txn_code and e.is_active and e.evidence_type = l.evidence_type
  )
  -- a transaction already posted by a *real* statement can still take a history line, but
  -- never a second statement line (enforced by the partial unique index too).
  ;
  delete from _m_cand where score is null;

  for c in select * from _m_cand order by score desc, ddays, line_no, txn_created, txn_code loop
    if c.score < 55 then
      exit;
    end if;
    if exists (select 1 from _m_lines where line_code = c.line_code and state <> 'open')
       or exists (select 1 from _m_txns where txn_code = c.txn_code) then
      continue;
    end if;

    -- A materially different competitor within 15 points makes this ambiguous.
    v_conflict := exists (
      select 1 from _m_cand x
      where x.score >= c.score - 15
        and not exists (select 1 from _m_txns where txn_code = x.txn_code)
        and not exists (select 1 from _m_lines where line_code = x.line_code and state <> 'open')
        and (
          (x.line_code = c.line_code and x.txn_code <> c.txn_code and x.txn_sig <> c.txn_sig)
          or (x.txn_code = c.txn_code and x.line_code <> c.line_code and x.line_key <> c.line_key)
        )
    );
    v_tie := exists (
      select 1 from _m_cand x
      where x.score >= c.score - 15
        and ((x.line_code = c.line_code and x.txn_code <> c.txn_code and x.txn_sig = c.txn_sig)
          or (x.txn_code = c.txn_code and x.line_code <> c.line_code and x.line_key = c.line_key))
    );

    if v_conflict or c.score < 75 then
      insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
      select l.profile_code, l.account_code, 'statement_line', l.line_code,
             case when v_conflict then 'ambiguous' else 'low_score' end,
             (select coalesce(jsonb_agg(jsonb_build_object('txn_code', x.txn_code, 'score', x.score) order by x.score desc), '[]'::jsonb)
                from (select * from _m_cand x where x.line_code = c.line_code order by x.score desc limit 5) x)
      from public.statement_lines l where l.line_code = c.line_code
      on conflict do nothing;
      update _m_lines set state = 'held' where line_code = c.line_code;
      v_held := v_held + 1;
      continue;
    end if;

    insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, role, score, method)
    select c.txn_code, l.profile_code, l.evidence_type, l.line_code,
           case when exists (select 1 from public.transaction_evidence e
                             where e.txn_code = c.txn_code and e.is_active and e.evidence_type = 'sms')
                then 'post' else 'primary' end,
           c.score,
           case when v_tie then 'tie' when c.score >= 85 then 'exact' else 'scored' end
    from public.statement_lines l where l.line_code = c.line_code;
    update _m_lines set state = 'linked' where line_code = c.line_code;
    insert into _m_txns values (c.txn_code);
    v_touched := v_touched || c.txn_code;
    v_linked := v_linked + 1;
  end loop;

  foreach v_txn in array v_touched loop
    perform private.refresh_transaction(v_txn);
  end loop;

  for v_line in select ml.line_code from _m_lines ml
                join public.statement_lines l on l.line_code = ml.line_code
                where ml.state = 'open' order by l.line_no loop
    perform private.new_transaction_from_line(v_line);
    v_created := v_created + 1;
  end loop;

  return jsonb_build_object('linked', v_linked, 'created', v_created, 'held', v_held);
end;
$$;

-- ── matcher: one SMS ────────────────────────────────────────────────────────
create or replace function private.match_sms(p_sms_code text)
returns text   -- 'linked' | 'duplicate' | 'created' | 'held' | 'skipped'
language plpgsql
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_txn text;
  v_best record;
  v_conflict boolean;
  v_desc_merchant text;
  v_amount_aed numeric;
  v_original text;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code;
  if s.parse_status <> 'parsed' or s.account_code is null
     or s.msg_kind not in ('purchase', 'preauth', 'refund', 'reversal', 'payment') then
    return 'skipped';
  end if;
  if exists (select 1 from public.transaction_evidence e where e.sms_code = s.sms_code and e.is_active) then
    return 'skipped';
  end if;

  -- 1. Same alert delivered twice (bank resend / automation double-fire).
  select e.txn_code into v_txn
  from public.sms_messages o
  join public.transaction_evidence e on e.sms_code = o.sms_code and e.is_active
  where o.profile_code = s.profile_code and o.sms_code <> s.sms_code
    and o.account_code = s.account_code and o.msg_kind = s.msg_kind
    and o.amount = s.amount and o.currency = s.currency
    and (o.body_hash = s.body_hash
         or (abs(extract(epoch from o.event_at - s.event_at)) <= 180
             and extensions.similarity(coalesce(o.description, ''), coalesce(s.description, '')) >= 0.8))
    and abs(extract(epoch from o.received_at - s.received_at)) <= 600
  order by o.received_at
  limit 1;
  if v_txn is not null then
    insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, method)
    values (v_txn, s.profile_code, 'sms', s.sms_code, 'duplicate', 'exact');
    return 'duplicate';
  end if;

  -- 2. A late SMS for a transaction a statement already posted.
  v_desc_merchant := private.resolve_merchant(s.description);
  v_amount_aed := case when s.currency = 'AED' then s.amount
                       else round(s.amount * private.estimate_fx(s.profile_code, s.currency), 2) end;
  create temp table if not exists _s_cand (txn_code text, score numeric, sig text, created timestamptz) on commit drop;
  truncate _s_cand;
  insert into _s_cand
  select t.txn_code,
         private.match_score(
           s.amount, s.currency, v_amount_aed, public.dubai_date(s.event_at), null,
           s.description, v_desc_merchant, s.card_last4,
           t.amount_original, t.currency_original, t.amount_aed, t.txn_date, t.posting_date,
           t.description, t.merchant_code, cd.last4, coalesce(mr.variable_amount, false) or s.msg_kind = 'preauth'
         ),
         concat_ws('|', t.amount_original, t.currency_original, t.txn_date, t.merchant_code),
         t.created_at
  from public.transactions t
  left join public.cards cd on cd.card_code = t.card_code
  left join public.merchants mr on mr.merchant_code = t.merchant_code
  where t.account_code = s.account_code
    and t.direction = case when s.msg_kind in ('refund', 'reversal', 'payment') then 'credit' else 'debit' end
    and abs(t.txn_date - public.dubai_date(s.event_at)) <= 3
    and not exists (select 1 from public.transaction_evidence e
                    where e.txn_code = t.txn_code and e.is_active and e.evidence_type = 'sms');
  delete from _s_cand where score is null or score < 55;

  select * into v_best from _s_cand order by score desc, created, txn_code limit 1;
  if v_best.txn_code is not null then
    v_conflict := exists (select 1 from _s_cand x
                          where x.txn_code <> v_best.txn_code and x.score >= v_best.score - 15 and x.sig <> v_best.sig);
    if v_conflict or v_best.score < 75 then
      insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
      values (s.profile_code, s.account_code, 'sms', s.sms_code,
              case when v_conflict then 'ambiguous' else 'low_score' end,
              (select coalesce(jsonb_agg(jsonb_build_object('txn_code', x.txn_code, 'score', x.score) order by x.score desc), '[]'::jsonb)
                 from (select * from _s_cand order by score desc limit 5) x))
      on conflict do nothing;
      return 'held';
    end if;
    insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, score, method)
    values (v_best.txn_code, s.profile_code, 'sms', s.sms_code, 'auth', v_best.score,
            case when v_best.score >= 85 then 'exact' else 'scored' end);
    perform private.refresh_transaction(v_best.txn_code);
    return 'linked';
  end if;

  -- 3. A brand-new (pending) transaction.
  v_txn := private.new_transaction_from_sms(s.sms_code);

  -- A reversal points at the purchase it reverses.
  if s.msg_kind = 'reversal' then
    select t.txn_code into v_original
    from public.transactions t
    where t.account_code = s.account_code and t.direction = 'debit' and t.txn_code <> v_txn
      and t.amount_original = s.amount and t.currency_original = s.currency
      and t.txn_date between public.dubai_date(s.event_at) - 30 and public.dubai_date(s.event_at)
      and not exists (select 1 from public.transactions r where r.related_txn_code = t.txn_code)
    order by extensions.similarity(t.description, coalesce(s.description, '')) desc, t.txn_date desc
    limit 1;
    if v_original is not null then
      update public.transactions set related_txn_code = v_original where txn_code = v_txn;
    end if;
  end if;
  return 'created';
end;
$$;

-- ── statement reconciliation ────────────────────────────────────────────────
create or replace function private.reconcile_statement(p_stmt_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  st public.statements%rowtype;
  v_debits numeric;
  v_credits numeric;
  v_lines int;
  v_purchase_lines int;
  v_sms_lines int;
  v_held int;
  v_unmatched int;
  v_checks jsonb := '{}'::jsonb;
  v_status text := 'ok';
  v_expected numeric;
begin
  select * into st from public.statements where stmt_code = p_stmt_code;

  select coalesce(sum(amount_aed) filter (where direction = 'debit'), 0),
         coalesce(sum(amount_aed) filter (where direction = 'credit'), 0),
         count(*),
         count(*) filter (where kind = 'purchase' and direction = 'debit')
  into v_debits, v_credits, v_lines, v_purchase_lines
  from public.statement_lines where stmt_code = p_stmt_code and is_current;

  select count(distinct l.line_code) into v_sms_lines
  from public.statement_lines l
  join public.transaction_evidence le on le.line_code = l.line_code and le.is_active
  join public.transaction_evidence se on se.txn_code = le.txn_code and se.is_active and se.evidence_type = 'sms'
  where l.stmt_code = p_stmt_code and l.is_current and l.kind = 'purchase' and l.direction = 'debit';

  select count(*) into v_held
  from public.match_reviews r join public.statement_lines l on l.line_code = r.subject_code
  where r.subject_type = 'statement_line' and r.status = 'open' and l.stmt_code = p_stmt_code;

  v_checks := jsonb_build_object(
    'line_count', v_lines,
    'sum_debits', v_debits::text,
    'sum_credits', v_credits::text,
    'held_lines', v_held,
    'sms_coverage', case when v_purchase_lines > 0 then round(v_sms_lines::numeric / v_purchase_lines, 3) end
  );

  if st.kind = 'statement' then
    if st.total_debits is not null then
      v_checks := v_checks || jsonb_build_object('debits_match', abs(st.total_debits - v_debits) <= 0.01);
      if abs(st.total_debits - v_debits) > 0.01 then v_status := 'fail'; end if;
    end if;
    if st.total_credits is not null then
      v_checks := v_checks || jsonb_build_object('credits_match', abs(st.total_credits - v_credits) <= 0.01);
      if abs(st.total_credits - v_credits) > 0.01 then v_status := 'fail'; end if;
    end if;
    if st.opening_balance is not null and st.closing_balance is not null then
      v_expected := st.opening_balance + v_debits - v_credits;
      v_checks := v_checks || jsonb_build_object('balance_equation', abs(v_expected - st.closing_balance) <= 0.01,
                                                 'expected_closing', v_expected::text);
      if abs(v_expected - st.closing_balance) > 0.01 then v_status := 'fail'; end if;
    end if;
    if st.total_debits is null and st.closing_balance is null and v_status = 'ok' then
      v_status := 'warn';
      v_checks := v_checks || jsonb_build_object('totals', 'not_extracted');
    end if;

    -- SMS-only transactions inside a closed period never posted: flag for review.
    if st.period_start is not null and st.period_end is not null then
      insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason)
      select t.profile_code, t.account_code, 'transaction', t.txn_code, 'missing_from_statement'
      from public.transactions t
      where t.account_code = st.account_code and t.status = 'pending'
        and t.txn_date between st.period_start and st.period_end - 3
      on conflict do nothing;
      get diagnostics v_unmatched = row_count;
      select count(*) into v_unmatched from public.transactions t
      where t.account_code = st.account_code and t.status = 'pending'
        and t.txn_date between st.period_start and st.period_end - 3;
      v_checks := v_checks || jsonb_build_object('unmatched_sms', v_unmatched);
      if v_unmatched > 0 and v_status = 'ok' then v_status := 'warn'; end if;
    end if;
  end if;
  if v_held > 0 and v_status = 'ok' then
    v_status := 'warn';
  end if;

  insert into public.statement_recon (stmt_code, profile_code, status, checks, computed_at)
  values (p_stmt_code, st.profile_code, v_status, v_checks, now())
  on conflict (stmt_code) do update set status = excluded.status, checks = excluded.checks, computed_at = now();
  return v_status;
end;
$$;

-- ── statement ingestion ─────────────────────────────────────────────────────
create or replace function private.ingest_one_statement(p_doc public.documents, p_stmt jsonb, p_parser_version text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_kind text := p_stmt->>'kind';
  v_bank text := p_stmt->>'bank_code';
  v_date date := (p_stmt->>'statement_date')::date;
  v_last4 text := nullif(p_stmt->>'primary_card_last4', '');
  v_totals jsonb := coalesce(p_stmt->'totals', '{}'::jsonb);
  v_account text;
  v_stmt text;
  v_existing boolean;
  v_superseded int := 0;
  v_inserted int := 0;
  v_txn text;
  v_match jsonb;
  v_recon text;
begin
  v_account := private.resolve_statement_account(
    p_doc.profile_code, v_bank, v_last4, p_stmt->>'card_holder', p_stmt->>'card_type',
    nullif(v_totals->>'credit_limit', '')::numeric
  );

  select stmt_code into v_stmt from public.statements
  where account_code = v_account and statement_date = v_date and kind = v_kind and status = 'active';
  v_existing := v_stmt is not null;

  if v_existing then
    update public.statements set
      doc_code = p_doc.doc_code,
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
  else
    insert into public.statements (profile_code, account_code, doc_code, kind, statement_reference, reference_source,
      statement_date, period_start, period_end, due_date, opening_balance, closing_balance, total_debits,
      total_credits, min_due, credit_limit, primary_card_last4, card_holder, card_type, parser_version, warnings, metadata)
    values (p_doc.profile_code, v_account, p_doc.doc_code, v_kind, p_stmt->>'statement_reference',
      p_stmt->>'reference_source', v_date, (p_stmt->>'period_start')::date, (p_stmt->>'period_end')::date,
      (p_stmt->>'due_date')::date, (v_totals->>'opening_balance')::numeric, (v_totals->>'closing_balance')::numeric,
      (v_totals->>'total_debits')::numeric, (v_totals->>'total_credits')::numeric, (v_totals->>'min_due')::numeric,
      (v_totals->>'credit_limit')::numeric, v_last4, p_stmt->>'card_holder', p_stmt->>'card_type', p_parser_version,
      coalesce(p_stmt->'warnings', '[]'::jsonb), coalesce(p_stmt->'metadata', '{}'::jsonb))
    returning stmt_code into v_stmt;
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
           (j->>'fx_rate')::numeric(18,8) as fx_rate,
           j->>'direction' as direction,
           j->>'kind' as kind,
           j->>'country_code' as country_code,
           nullif(j->>'card_last4', '') as card_last4,
           j->>'card_holder' as card_holder,
           j->>'legacy_fingerprint' as legacy_fingerprint,
           j as raw
    from jsonb_array_elements(coalesce(p_stmt->'lines', '[]'::jsonb)) j
  ) x;

  -- Lines that vanished from this statement: supersede, detach, refresh.
  create temp table if not exists _gone (line_code text) on commit drop;
  truncate _gone;
  insert into _gone
  select l.line_code from public.statement_lines l
  where l.stmt_code = v_stmt and l.is_current
    and not exists (select 1 from _in_lines i where i.line_key = l.line_key and i.occurrence = l.occurrence);
  update public.statement_lines set is_current = false, superseded_at = now()
  where line_code in (select line_code from _gone);
  get diagnostics v_superseded = row_count;
  update public.match_reviews set status = 'dismissed', resolution = jsonb_build_object('auto', 'line_superseded'),
    resolved_at = now()
  where subject_type = 'statement_line' and status = 'open' and subject_code in (select line_code from _gone);
  for v_txn in
    update public.transaction_evidence set is_active = false, deactivated_at = now()
    where line_code in (select line_code from _gone) and is_active
    returning txn_code
  loop
    perform private.refresh_transaction(v_txn);
  end loop;

  -- New lines (unchanged ones keep their codes and evidence).
  insert into public.statement_lines (stmt_code, profile_code, account_code, card_code, evidence_type, line_no,
    line_key, occurrence, txn_date, txn_time, posting_date, description_raw, description, amount_original,
    currency_original, amount_aed, fx_rate, direction, kind, country_code, card_last4, legacy_fingerprint, raw)
  select v_stmt, p_doc.profile_code, v_account,
         private.ensure_card(p_doc.profile_code, v_account, v_bank, i.card_last4, i.card_holder,
                             i.card_last4 is distinct from v_last4),
         case when v_kind = 'statement' then 'statement_line' else 'history_line' end,
         i.line_no, i.line_key, i.occurrence, i.txn_date, i.txn_time, i.posting_date, i.description_raw,
         i.description, i.amount_original, i.currency_original, i.amount_aed, i.fx_rate, i.direction, i.kind,
         i.country_code, i.card_last4, i.legacy_fingerprint, i.raw
  from _in_lines i
  where not exists (select 1 from public.statement_lines l
                    where l.stmt_code = v_stmt and l.line_key = i.line_key and l.occurrence = i.occurrence);
  get diagnostics v_inserted = row_count;

  -- A line that is current again (re-added after a parser fix) is re-activated.
  update public.statement_lines l set is_current = true, superseded_at = null, line_no = i.line_no
  from _in_lines i
  where l.stmt_code = v_stmt and not l.is_current and l.line_key = i.line_key and l.occurrence = i.occurrence;

  v_match := private.match_statement_lines(v_stmt);

  -- Period overlap with another real statement of the same account.
  if v_kind = 'statement' and (p_stmt->>'period_start') is not null and (p_stmt->>'period_end') is not null then
    insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
    select p_doc.profile_code, v_account, 'statement', v_stmt, 'period_overlap',
           jsonb_agg(jsonb_build_object('stmt_code', o.stmt_code, 'statement_date', o.statement_date))
    from public.statements o
    where o.account_code = v_account and o.kind = 'statement' and o.status = 'active' and o.stmt_code <> v_stmt
      and o.period_start is not null and o.period_end is not null
      and least(o.period_end, (p_stmt->>'period_end')::date) - greatest(o.period_start, (p_stmt->>'period_start')::date) > 3
    having count(*) > 0
    on conflict do nothing;
  end if;

  v_recon := private.reconcile_statement(v_stmt);

  return jsonb_build_object(
    'stmt_code', v_stmt, 'account_code', v_account, 'kind', v_kind, 'replaced', v_existing,
    'lines_new', v_inserted, 'lines_superseded', v_superseded, 'match', v_match, 'recon', v_recon
  );
end;
$$;

-- Entry point for the worker after the parser returns. One DB transaction.
create or replace function public.ingest_parsed_document(p_doc_code text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
set statement_timeout = '120s'
as $$
declare
  d public.documents%rowtype;
  s jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  perform private.assert_service_role();
  select * into d from public.documents where doc_code = p_doc_code for update;
  if not found then
    raise exception 'unknown document %', p_doc_code using errcode = 'P0002';
  end if;
  if (p_payload->>'contract_version')::int is distinct from 1 then
    raise exception 'unsupported parser contract %', p_payload->>'contract_version' using errcode = '22023';
  end if;

  for s in select * from jsonb_array_elements(coalesce(p_payload->'statements', '[]'::jsonb)) loop
    v_results := v_results || private.ingest_one_statement(d, s, p_payload->>'parser_version');
  end loop;

  update public.documents set
    parse_status = 'parsed',
    kind = p_payload->>'document_kind',
    bank_code = coalesce(p_payload->>'bank_code', bank_code),
    parser_version = p_payload->>'parser_version',
    parse_error_code = null,
    parse_error = null,
    parse_warnings = coalesce((select jsonb_agg(w) from jsonb_array_elements(p_payload->'statements') st,
                                 jsonb_array_elements(coalesce(st->'warnings', '[]'::jsonb)) w), '[]'::jsonb),
    parsed_at = now()
  where doc_code = p_doc_code;

  return jsonb_build_object('doc_code', p_doc_code, 'statements', v_results);
end;
$$;

create or replace function public.fail_document(p_doc_code text, p_error_code text, p_error text, p_permanent boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
 
  update public.documents
  set parse_status = case when p_permanent then 'failed' else 'queued' end,
      parse_error_code = p_error_code,
      parse_error = left(p_error, 2000)
  where doc_code = p_doc_code
$$;

-- ── SMS ingestion ───────────────────────────────────────────────────────────
-- Parse (or re-parse) one stored message and run it through the matcher.
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

  v_event := s.received_at;
  if m.fields ? 'date' then
    begin
      v_event := ((m.fields->>'date') || ' ' || coalesce(m.fields->>'time', to_char(s.received_at at time zone 'Asia/Dubai', 'HH24:MI:SS')))::timestamp
                 at time zone 'Asia/Dubai';
    exception when others then
      v_event := s.received_at;
    end;
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

  update public.sms_messages set
    parse_status = case when m.msg_kind in ('debit_card', 'other') then 'ignored' else 'parsed' end,
    ignore_reason = case when m.msg_kind in ('debit_card', 'other') then m.msg_kind
                         when m.msg_kind = 'declined' then 'declined' end,
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
    parsed_fields = m.fields
  where sms_code = p_sms_code;

  if m.msg_kind in ('debit_card', 'other', 'declined') then
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

-- Batch entry point: the iOS App Intent (via sms-ingest) or the app itself.
-- p_messages: [{client_msg_id, received_at, sender, body}]
create or replace function public.ingest_sms(p_profile_code text, p_messages jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  msg jsonb;
  v_code text;
  v_results jsonb := '[]'::jsonb;
  v_status text;
begin
  perform private.assert_member(p_profile_code, true);
  if jsonb_typeof(p_messages) <> 'array' or jsonb_array_length(p_messages) > 200 then
    raise exception 'p_messages must be an array of at most 200 messages' using errcode = '22023';
  end if;

  for msg in select * from jsonb_array_elements(p_messages) loop
    -- Defence in depth: OTPs are filtered on the device and never stored here.
    if (msg->>'body') ~* '(\motp\M|one[- ]?time (password|passcode|pin)|verification code|passcode|security code)' then
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'status', 'rejected_otp');
      continue;
    end if;

    insert into public.sms_messages (profile_code, client_msg_id, received_at, sender, body, body_hash)
    values (p_profile_code, (msg->>'client_msg_id')::uuid, coalesce((msg->>'received_at')::timestamptz, now()),
            coalesce(msg->>'sender', ''), msg->>'body',
            encode(sha256(convert_to(coalesce(msg->>'sender', '') || '|' || (msg->>'body'), 'UTF8')), 'hex'))
    on conflict (profile_code, client_msg_id) do nothing
    returning sms_code into v_code;

    if v_code is null then
      select sms_code into v_code from public.sms_messages
      where profile_code = p_profile_code and client_msg_id = (msg->>'client_msg_id')::uuid;
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'sms_code', v_code,
                                                   'status', 'duplicate_delivery');
      continue;
    end if;

    v_status := private.process_sms(v_code);
    v_results := v_results || jsonb_build_object(
      'client_msg_id', msg->>'client_msg_id', 'sms_code', v_code, 'status', v_status,
      'txn_code', (select e.txn_code from public.transaction_evidence e where e.sms_code = v_code and e.is_active limit 1)
    );
  end loop;
  return v_results;
end;
$$;

-- New or changed templates re-run every message that is still unparsed.
create or replace function private.trg_sms_templates_reprocess()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  for v_code in
    select sms_code from public.sms_messages
    where parse_status in ('unparsed', 'pending', 'failed')
    order by received_at
    limit 500
  loop
    perform private.process_sms(v_code);
  end loop;
  return null;
end;
$$;
create trigger sms_templates_reprocess
  after insert or update on public.sms_templates
  for each statement execute function private.trg_sms_templates_reprocess();

-- ── review resolution ───────────────────────────────────────────────────────
-- p_action: {"link": "txn_…"} | {"create_new": true} | {"dismiss": true}
--         | {"card": {"account_code": "acc_…"}}  (unknown_card: register the card)
--         | {"supersede": "stm_…"}               (period_overlap)
create or replace function public.resolve_review(p_review_code text, p_action jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.match_reviews%rowtype;
  v_txn text;
  v_type text;
  v_sms public.sms_messages%rowtype;
  v_outcome text;
begin
  select * into r from public.match_reviews where review_code = p_review_code for update;
  if not found or r.status <> 'open' then
    raise exception 'review % is not open', p_review_code using errcode = 'P0002';
  end if;
  perform private.assert_member(r.profile_code, true);

  if p_action ? 'dismiss' then
    v_outcome := 'dismissed';
  elsif p_action ? 'link' then
    v_txn := p_action->>'link';
    if not exists (select 1 from public.transactions where txn_code = v_txn and profile_code = r.profile_code) then
      raise exception 'unknown transaction %', v_txn using errcode = 'P0002';
    end if;
    if r.subject_type = 'statement_line' then
      select evidence_type into v_type from public.statement_lines where line_code = r.subject_code;
      update public.transaction_evidence set is_active = false, deactivated_at = now()
      where txn_code = v_txn and is_active and evidence_type = v_type and not is_locked;
      insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, role, method, is_locked)
      values (v_txn, r.profile_code, v_type, r.subject_code, 'post', 'manual', true);
    elsif r.subject_type = 'sms' then
      insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, method, is_locked)
      values (v_txn, r.profile_code, 'sms', r.subject_code, 'auth', 'manual', true);
    else
      raise exception 'link is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    perform private.refresh_transaction(v_txn);
    v_outcome := 'linked';
  elsif p_action ? 'create_new' then
    if r.subject_type = 'statement_line' then
      v_txn := private.new_transaction_from_line(r.subject_code, 'manual');
    elsif r.subject_type = 'sms' then
      v_txn := private.new_transaction_from_sms(r.subject_code, 'manual');
    else
      raise exception 'create_new is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    v_outcome := 'created';
  elsif p_action ? 'card' and r.reason = 'unknown_card' then
    select * into v_sms from public.sms_messages where sms_code = r.subject_code;
    perform private.ensure_card(r.profile_code, p_action->'card'->>'account_code', v_sms.bank_code,
                                v_sms.card_last4, null, true);
    update public.match_reviews set status = 'resolved', resolution = p_action, resolved_by = auth.uid(), resolved_at = now()
    where review_code = p_review_code;
    -- Every message waiting on this card can now be processed.
    perform private.process_sms(s.sms_code)
    from public.sms_messages s
    where s.profile_code = r.profile_code and s.bank_code = v_sms.bank_code and s.card_last4 = v_sms.card_last4
      and s.account_code is null;
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'card_registered'),
      resolved_at = now()
    where profile_code = r.profile_code and reason = 'unknown_card' and status = 'open'
      and subject_code in (select sms_code from public.sms_messages where account_code is not null);
    return jsonb_build_object('review_code', p_review_code, 'outcome', 'card_registered');
  elsif p_action ? 'supersede' and r.reason = 'period_overlap' then
    update public.statements set status = 'superseded', superseded_by = r.subject_code
    where stmt_code = p_action->>'supersede' and profile_code = r.profile_code;
    for v_txn in
      update public.transaction_evidence e set is_active = false, deactivated_at = now()
      from public.statement_lines l
      where l.line_code = e.line_code and l.stmt_code = p_action->>'supersede' and e.is_active
      returning e.txn_code
    loop
      perform private.refresh_transaction(v_txn);
    end loop;
    update public.statement_lines set is_current = false, superseded_at = now()
    where stmt_code = p_action->>'supersede';
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

-- ── nightly housekeeping ────────────────────────────────────────────────────
-- A pending purchase and its pending reversal that never appeared on a statement
-- that has since closed were an authorisation that got released: void both.
create or replace function private.void_released_authorisations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  r record;
begin
  for r in
    select rev.txn_code as rev_code, rev.related_txn_code as orig_code
    from public.transactions rev
    join public.transactions orig on orig.txn_code = rev.related_txn_code
    where rev.status = 'pending' and orig.status = 'pending'
      and exists (
        select 1 from public.statements st
        where st.account_code = rev.account_code and st.kind = 'statement' and st.status = 'active'
          and st.period_end >= greatest(rev.txn_date, orig.txn_date) + 3
      )
  loop
    update public.transactions set voided_at = now(), void_reason = 'authorisation_released'
    where txn_code in (r.rev_code, r.orig_code);
    perform private.refresh_transaction(r.rev_code);
    perform private.refresh_transaction(r.orig_code);
    v_count := v_count + 2;
  end loop;
  return v_count;
end;
$$;

grant execute on function public.ingest_parsed_document(text, jsonb) to service_role;
grant execute on function public.fail_document(text, text, text, boolean) to service_role;
grant execute on function public.ingest_sms(text, jsonb) to authenticated, service_role;
grant execute on function public.resolve_review(text, jsonb) to authenticated, service_role;

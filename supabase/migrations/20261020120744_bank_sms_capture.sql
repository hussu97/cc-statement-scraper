-- Phase 2b (tasks/todo.md §3): debit-card and bank-account SMS become transactions on the
-- ledger's bank accounts.
--
-- 1. msg_kind adds debit_purchase, account_credit and account_debit (debit_card stays for alerts
--    that are still only noted). transactions.kind adds transfer_in and transfer_out; v_spend's
--    kind list already leaves them out, while a debit_purchase is a purchase and counts as spend
--    (decision 1, approved 2026-10-20).
-- 2. Templates: ADCB account credit and debit (with the account digits and balance), ADCB and FAB
--    debit-card purchases, FAB outward and inward remittances. The seeded "(ignored)" versions are switched
--    off only while they still hold their seeded pattern (§1.9).
-- 3. process_sms resolves these alerts to a bank account (debit card, then the account digits,
--    then the bank's only bank account), registers a new debit card on it, and records the
--    printed balance as a balance_checkpoints row. No matching account: ignored as
--    'no_bank_account' until create_bank_account adds one and re-runs them.
-- 4. refresh_transaction: on a bank account, SMS evidence is final (posted); there's no statement
--    to wait for.
-- Repeats (a message caught by both automations) are dropped by match_sms step 1, as for cards.

-- ── 1. kinds ────────────────────────────────────────────────────────────────
alter table public.sms_templates drop constraint sms_templates_msg_kind_check;
alter table public.sms_templates add constraint sms_templates_msg_kind_check check (msg_kind in
  ('purchase', 'preauth', 'refund', 'reversal', 'payment', 'declined', 'debit_card', 'other', 'statement_summary',
   'debit_purchase', 'account_credit', 'account_debit'));
alter table public.sms_messages drop constraint sms_messages_msg_kind_check;
alter table public.sms_messages add constraint sms_messages_msg_kind_check check (msg_kind in
  ('purchase', 'preauth', 'refund', 'reversal', 'payment', 'declined', 'debit_card', 'other', 'statement_summary',
   'debit_purchase', 'account_credit', 'account_debit'));
alter table public.transactions drop constraint transactions_kind_check;
alter table public.transactions add constraint transactions_kind_check check (kind in
  ('purchase', 'refund', 'payment', 'fee', 'interest', 'cash_advance', 'adjustment', 'transfer_in', 'transfer_out'));

-- ── 2. parsing and resolution ───────────────────────────────────────────────
-- account_ref: the digits a bank prints after the account mask (XXX810001 → 810001).
create or replace function private.validate_sms_template()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  ex jsonb;
  f jsonb;
  k text;
  v text;
begin
  -- Bounded patterns (DB-13): templates run against every incoming SMS.
  if length(new.body_pattern) > 1000 or length(new.sender_pattern) > 200 then
    raise exception 'sms template % pattern is too long', new.name using errcode = '22023';
  end if;
  if new.body_pattern ~ '\\[1-9]' or new.sender_pattern ~ '\\[1-9]' then
    raise exception 'sms template % uses a back-reference', new.name using errcode = '22023';
  end if;
  -- Field groups are applied as `value::int` to every SMS: validate them here (DB-26).
  if jsonb_typeof(new.field_groups) <> 'object' or exists (
    select 1 from jsonb_each(new.field_groups) e
    where e.key not in ('amount', 'currency', 'merchant', 'last4', 'date', 'time', 'available',
                        'due_date', 'min_due', 'account_ref')
       or jsonb_typeof(e.value) <> 'number' or e.value::text !~ '^[1-9][0-9]?$'
  ) then
    raise exception 'sms template % field_groups must map known fields to capture groups 1-99', new.name
      using errcode = '22023';
  end if;
  perform regexp_match('', new.body_pattern);     -- invalid regex raises here
  perform regexp_match('', new.sender_pattern);
  if tg_op = 'UPDATE' and (new.body_pattern, new.sender_pattern, new.field_groups, new.date_format, new.msg_kind)
     is distinct from (old.body_pattern, old.sender_pattern, old.field_groups, old.date_format, old.msg_kind) then
    new.version := old.version + 1;
  end if;
  for ex in select * from jsonb_array_elements(new.examples) loop
    f := private.apply_sms_template(new, coalesce(ex->>'sender', ''), ex->>'body');
    if f is null then
      raise exception 'sms template % does not match its example: %', new.name, left(ex->>'body', 60)
        using errcode = '22023';
    end if;
    for k, v in select key, value from jsonb_each_text(coalesce(ex->'expect', '{}'::jsonb)) loop
      if f->>k is distinct from v then
        raise exception 'sms template % example field % = %, expected %', new.name, k, f->>k, v
          using errcode = '22023';
      end if;
    end loop;
  end loop;
  return new;
end;
$$;

create or replace function private.apply_sms_template(t public.sms_templates, p_sender text, p_body text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  m text[];
  f jsonb := '{}'::jsonb;
  k text;
  g int;
  v text;
begin
  if p_sender !~* t.sender_pattern then
    return null;
  end if;
  m := regexp_match(p_body, t.body_pattern, 'i');
  if m is null then
    return null;
  end if;
  for k, g in select key, value::int from jsonb_each_text(t.field_groups) loop
    v := btrim(m[g]);
    if v is null or v = '' then
      continue;
    end if;
    case k
      when 'amount', 'available', 'min_due' then
        f := f || jsonb_build_object(k, private.parse_amount(v)::text);
      when 'currency' then
        f := f || jsonb_build_object(k, upper(v));
      when 'merchant' then
        f := f || jsonb_build_object(k, private.normalize_text(v));
      when 'last4' then
        f := f || jsonb_build_object(k, right(regexp_replace(v, '[^0-9]', '', 'g'), 4));
      when 'date', 'due_date' then
        begin
          f := f || jsonb_build_object(k, to_char(to_date(v, coalesce(t.date_format, 'DD/MM/YYYY')), 'YYYY-MM-DD'));
        exception when others then
          -- DB-08: an impossible date (31/02) means this template does not apply.
          return null;
        end;
      else
        f := f || jsonb_build_object(k, v);
    end case;
  end loop;
  if t.msg_kind in ('purchase', 'preauth', 'refund', 'reversal', 'payment',
                   'debit_purchase', 'account_credit', 'account_debit') and f->>'amount' is null then
    return null;
  end if;
  if t.msg_kind = 'statement_summary' and (f->>'amount' is null or f->>'due_date' is null) then
    return null;
  end if;
  return f;
end;
$$;

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
  v_bank_kind boolean;
  v_ref text;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code for update;
  if exists (select 1 from public.transaction_evidence e where e.sms_code = p_sms_code and e.is_active) then
    return 'already_linked';
  end if;
  -- A Wallet event names its card by the phone's display name, not by template.
  if s.source = 'wallet' then
    return private.process_wallet_sms(p_sms_code);
  end if;

  select * into m from private.match_sms_template(s.sender, s.body, null, s.profile_code) limit 1;
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

  v_bank_kind := m.msg_kind in ('debit_purchase', 'account_credit', 'account_debit');
  if not v_bank_kind then
    if m.fields ? 'last4' then
      select * into v_card from public.cards
      where profile_code = s.profile_code and bank_code = m.bank_code and last4 = m.fields->>'last4';
      v_account := v_card.account_code;
    end if;
    if v_account is null and not (m.fields ? 'last4') then
      select count(*), min(account_code) into v_n, v_account
      from public.accounts where profile_code = s.profile_code and bank_code = m.bank_code and status = 'active'
        and kind = 'credit_card';
      if v_n <> 1 then v_account := null; end if;
    end if;
  else
    -- A debit-card or account alert goes to a bank account (Phase 2b), never to a card account:
    -- 1. the debit card it names, already on a bank account;
    -- 2. the account it names (the digits after the mask match account_ref from the right);
    -- 3. when it names no account, the bank's one active bank account.
    v_ref := nullif(regexp_replace(coalesce(m.fields->>'account_ref', ''), '[^0-9]', '', 'g'), '');
    if m.fields ? 'last4' then
      select c.* into v_card from public.cards c join public.accounts a on a.account_code = c.account_code
      where c.profile_code = s.profile_code and c.bank_code = m.bank_code and c.last4 = m.fields->>'last4'
        and a.kind in ('current', 'savings');
      v_account := v_card.account_code;
    end if;
    if v_account is null and v_ref is not null then
      select count(*), min(a.account_code) into v_n, v_account
      from public.accounts a
      where a.profile_code = s.profile_code and a.bank_code = m.bank_code and a.status = 'active'
        and a.kind in ('current', 'savings') and a.account_ref is not null
        and (right(v_ref, length(a.account_ref)) = a.account_ref or right(a.account_ref, length(v_ref)) = v_ref);
      if v_n <> 1 then v_account := null; end if;
    end if;
    if v_account is null and v_ref is null then
      select count(*), min(account_code) into v_n, v_account
      from public.accounts where profile_code = s.profile_code and bank_code = m.bank_code and status = 'active'
        and kind in ('current', 'savings');
      if v_n <> 1 then v_account := null; end if;
    end if;
    -- A debit card seen for the first time joins its account. If a card of this bank already has
    -- those digits (a credit card), the alert stays on the account without a card.
    if v_account is not null and v_card.card_code is null and m.fields ? 'last4' then
      insert into public.cards (profile_code, account_code, bank_code, last4)
      values (s.profile_code, v_account, m.bank_code, m.fields->>'last4')
      on conflict (profile_code, bank_code, last4) do nothing;
      select * into v_card from public.cards
      where profile_code = s.profile_code and account_code = v_account and last4 = m.fields->>'last4';
    end if;
  end if;

  -- Declined alerts are not transactions: stored 'ignored' like debit-card and other alerts (DB-34).
  v_ignored := m.msg_kind in ('debit_card', 'other', 'declined');
  -- A bank-account alert for an account the ledger doesn't have yet waits, ignored, until
  -- create_bank_account adds it (private.reprocess_bank_sms).
  if v_bank_kind and v_account is null then
    v_ignored := true;
  end if;
  update public.sms_messages set
    parse_status = case when v_ignored then 'ignored' else 'parsed' end,
    ignore_reason = case when v_bank_kind and v_ignored then 'no_bank_account' when v_ignored then m.msg_kind end,
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

  -- A statement summary is a statement header, not a transaction.
  if m.msg_kind = 'statement_summary' then
    return private.apply_sms_statement(p_sms_code);
  end if;

  -- The same purchase may already be in the ledger from a Wallet event.
  v_result := private.link_wallet_twin(p_sms_code);
  if v_result is null then
    v_result := private.match_sms(p_sms_code);
  end if;
  -- The balance an account alert prints is a checkpoint as of the alert (not for a repeat).
  if v_bank_kind and v_result = 'created' and m.fields ? 'available' then
    insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source, sms_code)
    values (s.profile_code, v_account, v_event, (m.fields->>'available')::numeric, 'sms', p_sms_code);
  end if;
  return v_result;
end;
$$;

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
     or s.msg_kind not in ('purchase', 'preauth', 'refund', 'reversal', 'payment',
                           'debit_purchase', 'account_credit', 'account_debit') then
    return 'skipped';
  end if;
  if exists (select 1 from public.transaction_evidence e where e.sms_code = s.sms_code and e.is_active) then
    return 'skipped';
  end if;

  -- 1. Same alert delivered twice (bank resend / automation double-fire). Two
  --    alerts that print different available limits are two purchases (DB-15).
  --    Two Wallet events are never the same alert: each is a separate tap, and a
  --    redelivery is already caught by client_msg_id at ingest.
  select e.txn_code into v_txn
  from public.sms_messages o
  join public.transaction_evidence e on e.sms_code = o.sms_code and e.is_active
  where o.profile_code = s.profile_code and o.sms_code <> s.sms_code
    and not (o.source = 'wallet' and s.source = 'wallet')
    and o.account_code = s.account_code and o.msg_kind = s.msg_kind
    and o.amount = s.amount and o.currency = s.currency
    and (o.body_hash = s.body_hash
         or (abs(extract(epoch from o.event_at - s.event_at)) <= 180
             and extensions.similarity(coalesce(o.description, ''), coalesce(s.description, '')) >= 0.8
             and (o.available_limit is null or s.available_limit is null or o.available_limit = s.available_limit)))
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
                       else round(s.amount * private.estimate_fx(s.profile_code, s.currency, coalesce(s.bank_code, private.account_bank(s.account_code)),
                                                                 public.dubai_date(s.event_at)), 2) end;
  create temp table if not exists _sx_cand (txn_code text, score numeric, sig text, created timestamptz, maff numeric)
    on commit drop;
  truncate _sx_cand;
  insert into _sx_cand
  select t.txn_code,
         private.match_score(
           s.amount, s.currency, v_amount_aed, public.dubai_date(s.event_at), null,
           s.description, v_desc_merchant, s.card_last4,
           t.amount_original, t.currency_original, t.amount_aed, t.txn_date, t.posting_date,
           t.description, t.merchant_code, cd.last4, coalesce(mr.variable_amount, false) or s.msg_kind = 'preauth'
         ),
         concat_ws('|', t.amount_original, t.currency_original, t.txn_date, t.merchant_code),
         t.created_at,
         private.merchant_affinity(s.description, t.description, v_desc_merchant, t.merchant_code)
  from public.transactions t
  left join public.cards cd on cd.card_code = t.card_code
  left join public.merchants mr on mr.merchant_code = t.merchant_code
  where t.profile_code = s.profile_code
    and t.account_code = s.account_code
    and t.direction = case when s.msg_kind in ('refund', 'reversal', 'payment', 'account_credit') then 'credit' else 'debit' end
    and abs(t.txn_date - public.dubai_date(s.event_at)) <= 3
    and not exists (select 1 from public.transaction_evidence e
                    where e.txn_code = t.txn_code and e.is_active and e.evidence_type = 'sms');
  delete from _sx_cand where score is null or score < 55;

  select * into v_best from _sx_cand order by score desc, created, txn_code limit 1;
  if v_best.txn_code is not null then
    v_conflict := exists (select 1 from _sx_cand x
                          where x.txn_code <> v_best.txn_code and x.score >= v_best.score - 15 and x.sig <> v_best.sig
                            and x.maff > v_best.maff - 0.3);
    if v_conflict or v_best.score < 75 then
      insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
      values (s.profile_code, s.account_code, 'sms', s.sms_code,
              case when v_conflict then 'ambiguous' else 'low_score' end,
              (select coalesce(jsonb_agg(jsonb_build_object('txn_code', x.txn_code, 'score', x.score) order by x.score desc), '[]'::jsonb)
                 from (select * from _sx_cand order by score desc limit 5) x))
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
    where t.profile_code = s.profile_code and t.account_code = s.account_code
      and t.direction = 'debit' and t.txn_code <> v_txn
      and t.amount_original = s.amount and t.currency_original = s.currency
      and t.txn_date between public.dubai_date(s.event_at) - 30 and public.dubai_date(s.event_at)
      and not exists (select 1 from public.transactions r
                      where r.profile_code = s.profile_code and r.related_txn_code = t.txn_code)
    order by extensions.similarity(t.description, coalesce(s.description, '')) desc, t.txn_date desc
    limit 1;
    if v_original is not null then
      update public.transactions set related_txn_code = v_original where txn_code = v_txn;
    end if;
  end if;
  return 'created';
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
                            when 'payment' then 'payment'
                            when 'account_credit' then 'transfer_in' when 'account_debit' then 'transfer_out'
                            else 'purchase' end;
  v_direction := case when s.msg_kind in ('refund', 'reversal', 'payment', 'account_credit') then 'credit' else 'debit' end;
  v_desc := coalesce(s.description, case s.msg_kind when 'account_credit' then 'ACCOUNT CREDIT'
                                                    when 'account_debit' then 'ACCOUNT DEBIT'
                                                    else 'CARD TRANSACTION' end);
  if s.currency <> 'AED' then
    v_fx := private.estimate_fx(s.profile_code, s.currency, coalesce(s.bank_code, private.account_bank(s.account_code)),
                                public.dubai_date(s.event_at));
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
      v_fx := coalesce(l.fx_rate, private.estimate_fx(t.profile_code, l.currency_original, private.account_bank(l.account_code),
                                                    coalesce(l.posting_date, l.txn_date)));
      t.amount_aed := round(l.amount_original * v_fx, 2);
      t.amount_aed_is_estimate := t.amount_aed is not null;
      t.fx_rate := v_fx;  -- the rate the estimate used, as on a pending SMS row
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
      v_fx := private.estimate_fx(t.profile_code, s.currency,
                                  coalesce(s.bank_code, private.account_bank(coalesce(s.account_code, t.account_code))),
                                  public.dubai_date(s.event_at));
      t.fx_rate := v_fx;
      t.amount_aed := round(s.amount * v_fx, 2);
      t.amount_aed_is_estimate := true;
    end if;
    -- A card's SMS waits for its statement; a bank account has none, so its SMS is final (2b).
    t.status := case when t.voided_at is not null then 'void'
                     when exists (select 1 from public.accounts a
                                  where a.account_code = t.account_code and a.kind in ('current', 'savings'))
                       then 'posted'
                     else 'pending' end;
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

-- Re-runs a bank's alerts that waited for a bank account (ignored as 'no_bank_account').
create or replace function private.reprocess_bank_sms(p_profile_code text, p_bank_code text)
returns int
language plpgsql
set search_path = ''
as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select sms_code from public.sms_messages
    where profile_code = p_profile_code and bank_code = p_bank_code
      and parse_status = 'ignored' and ignore_reason = 'no_bank_account'
    order by received_at, sms_code
  loop
    perform private.process_sms(r.sms_code);
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function public.create_bank_account(
  p_profile_code text, p_bank_code text, p_kind text, p_account_ref text,
  p_nickname text default null, p_currency text default 'AED'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_ref text := nullif(btrim(p_account_ref), '');
begin
  perform private.assert_member(p_profile_code, true);
  if p_kind not in ('current', 'savings') then
    raise exception 'a bank account is current or savings, not %', p_kind using errcode = '22023';
  end if;
  if not exists (select 1 from public.banks where bank_code = p_bank_code) then
    raise exception 'unknown bank %', p_bank_code using errcode = 'P0002';
  end if;
  if v_ref is not null and v_ref !~ '^[0-9]{3,12}$' then
    raise exception 'account_ref is the 3–12 digits the bank shows at the end of the account number'
      using errcode = '22023';
  end if;
  if v_ref is not null and exists (select 1 from public.accounts
                                   where profile_code = p_profile_code and bank_code = p_bank_code
                                     and account_ref = v_ref) then
    raise exception 'this ledger already has a % account ending %', p_bank_code, v_ref using errcode = '23505';
  end if;
  insert into public.accounts (profile_code, bank_code, kind, account_ref, nickname, currency)
  values (p_profile_code, p_bank_code, p_kind, v_ref, nullif(btrim(p_nickname), ''), upper(p_currency))
  returning account_code into v_code;
  -- Alerts that arrived before the account was added (Phase 2b).
  perform private.reprocess_bank_sms(p_profile_code, p_bank_code);
  return v_code;
end;
$$;

-- ── 3. templates ────────────────────────────────────────────────────────────
insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 ('ADCB', 'ADCB account credit', '^ADCB',
  'Cr\. transaction of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on your account number X+([0-9]+)(?:.*?Available balance is ([0-9,]+\.[0-9]{2}))?',
  '{"currency":1,"amount":2,"account_ref":3,"available":4}', null, 'account_credit', 60,
  '[{"sender":"ADCBAlert","body":"A Cr. transaction of AED 1100.00 on your account number XXX810001 was successful.Available balance is 1105.04.",
     "expect":{"amount":"1100.00","currency":"AED","account_ref":"810001","available":"1105.04"}}]'),
 ('ADCB', 'ADCB account debit', '^ADCB',
  'Dr\. transaction of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on your account number X+([0-9]+)(?:.*?Available balance is ([0-9,]+\.[0-9]{2}))?',
  '{"currency":1,"amount":2,"account_ref":3,"available":4}', null, 'account_debit', 60,
  '[{"sender":"ADCBAlert","body":"A Dr. transaction of AED 250.00 on your account number XXX810001 was successful.Available balance is 855.04.",
     "expect":{"amount":"250.00","currency":"AED","account_ref":"810001","available":"855.04"}}]'),
 ('ADCB', 'ADCB debit card purchase', '^ADCB',
  'Debit card X+([0-9]{4}) linked to acc\. X+([0-9]+) used for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})(?: \([^)]*\))? on ([A-Z]{3} [0-9]{1,2} [0-9]{4}) +([0-9]{1,2}:[0-9]{2} ?[AP]M) at (.+)\. Avl\.? ?Bal ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})',
  '{"last4":1,"account_ref":2,"currency":3,"amount":4,"date":5,"time":6,"merchant":7,"available":9}', 'Mon DD YYYY', 'debit_purchase', 60,
  '[{"sender":"ADCBAlert","body":"Debit card XXX4467 linked to acc. XXX820001 used for AED3.50 (+2.49% foreign txn fee) on Sep 11 2026  4:33PM at GOOGLEYOUTUBE M,US. Avl.Bal AED 51.54.",
     "expect":{"amount":"3.50","currency":"AED","last4":"4467","account_ref":"820001","merchant":"GOOGLEYOUTUBE M,US","date":"2026-09-11","time":"4:33PM","available":"51.54"}}]'),
 ('FAB', 'FAB debit card purchase', '^FAB',
  'Debit Card Purchase\s*\n\s*Card No X*([0-9]{4})\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*([^\n]+)\n\s*([0-9]{2}/[0-9]{2}/[0-9]{2}) ([0-9]{2}:[0-9]{2})(?:\s*\n\s*Avl Bal ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?',
  '{"last4":1,"currency":2,"amount":3,"merchant":4,"date":5,"time":6,"available":8}', 'DD/MM/YY', 'debit_purchase', 60,
  '[{"sender":"FAB","body":"Debit Card Purchase\nCard No XXXX1234\nAED 20.00\nCARREFOUR DUBAI\n05/10/26 10:40\nAvl Bal AED 100.00",
     "expect":{"amount":"20.00","currency":"AED","last4":"1234","merchant":"CARREFOUR DUBAI","date":"2026-10-05","time":"10:40","available":"100.00"}}]'),
 ('FAB', 'FAB outward remittance', '^FAB',
  'Outward Remittance Debit\s*\n\s*Account X*([0-9]+)\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*Date ([0-9]{2}/[0-9]{2}/[0-9]{4})(?:\s*\n\s*Balance ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?',
  '{"account_ref":1,"currency":2,"amount":3,"date":4,"available":6}', 'DD/MM/YYYY', 'account_debit', 60,
  '[{"sender":"FAB","body":"Outward Remittance Debit\nAccount XXXX9001\nAED 2100.00\nDate 02/10/2026\nBalance AED 3644.98",
     "expect":{"account_ref":"9001","currency":"AED","amount":"2100.00","date":"2026-10-02","available":"3644.98"}}]'),
 ('FAB', 'FAB inward remittance', '^FAB',
  'Inward Remittance Credit\s*\n\s*Account X*([0-9]+)\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*Date ([0-9]{2}/[0-9]{2}/[0-9]{4})(?:\s*\n\s*Balance ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?',
  '{"account_ref":1,"currency":2,"amount":3,"date":4,"available":6}', 'DD/MM/YYYY', 'account_credit', 60,
  '[{"sender":"FAB","body":"Inward Remittance Credit\nAccount XXXX9001\nAED 500.00\nDate 03/10/2026\nBalance AED 4144.98",
     "expect":{"account_ref":"9001","currency":"AED","amount":"500.00","date":"2026-10-03","available":"4144.98"}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);

-- The seeded "(ignored)" versions step aside, only while they still hold their seeded pattern.
update public.sms_templates set active = false
where bank_code = 'ADCB' and name = 'ADCB account credit/debit (ignored)' and msg_kind = 'debit_card' and active
  and body_pattern = '(?:Cr|Dr)\. transaction of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on your account number X+[0-9]+';
update public.sms_templates set active = false
where bank_code = 'ADCB' and name = 'ADCB debit card purchase (ignored)' and msg_kind = 'debit_card' and active
  and body_pattern = 'Debit card X+([0-9]{4}) linked to acc\. X+[0-9]+ used for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})(?: \([^)]*\))? on ([A-Z]{3} [0-9]{1,2} [0-9]{4}) +([0-9]{1,2}:[0-9]{2} ?[AP]M) at (.+)\. Avl\.? ?Bal ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})';
update public.sms_templates set active = false
where bank_code = 'FAB' and name = 'FAB debit card purchase (ignored)' and msg_kind = 'debit_card' and active
  and body_pattern = 'Debit Card Purchase\s*\n\s*Card No X*([0-9]{4})\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*([^\n]+)\n\s*([0-9]{2}/[0-9]{2}/[0-9]{2}) ([0-9]{2}:[0-9]{2})';
update public.sms_templates set active = false
where bank_code = 'FAB' and name = 'FAB outward remittance (ignored)' and msg_kind = 'debit_card' and active
  and body_pattern = 'Outward Remittance Debit\s*\n\s*Account X*[0-9]+\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*Date ([0-9]{2}/[0-9]{2}/[0-9]{4})';

-- SMS clean-up from an audit of unparsed and ignored messages.
--
-- Messages lost from the ledger:
-- 1. FAB's remittance alerts sometimes break the first line ("Inward Remittance \nCredit"): the
--    remittance templates read "Remittance\s+Credit|Debit", so the catch-all no longer hides them.
-- 2. FAB's standing-instruction debit ("Your standing instructions of AED … to <payee> …") gets a
--    seeded template: an account debit on the FAB bank account, described by the payee.
-- 3. Liv (Emirates NBD's digital bank) texts as "Liv": the sender joins ENBD's senders, with its
--    debit-card purchase template. Until the profile has an ENBD bank account the alert waits,
--    ignored as no_bank_account, as every bank-account alert does.
--
-- Noise:
-- 4. Indian senders mark adverts with a "-P" suffix (TRAI DLT): ignored as a promotion, like "AD-".
-- 5. SIB's "update your new Covered Card details" reminder joins SIB's ignored notices.
-- 6. A message the LLM fallback finds is not a transaction (a biller's receipt, a balance notice)
--    is stored ignored ('llm_not_txn') by public.mark_sms_not_transaction instead of staying
--    'unparsed' for good. The unparsed messages already past the LLM go through it again.
--
-- Better use of what arrives:
-- 7. Emirates NBD's mini statement becomes a statement summary. It prints its statement date, so
--    templates gain a statement_date field and private.apply_sms_statement takes the cycle from it.
--
-- The fallback itself:
-- 8. One proposal per format: public.reuse_sms_proposal attaches a message to an open LLM proposal
--    that already reads it, before any LLM call (each message of a new format made its own).
-- 9. A message that parses closes its stale unparsed_sms reviews, and an LLM proposal left with no
--    open review is deleted (as a rejected one is). The review of the proposal that parsed it is
--    left to set_sms_template_active, which records who approved it.
-- 10. A proposal from a sender the bank doesn't list opens a review instead of dead-lettering, where
--    nothing showed it.

-- ── 4. Indian adverts ────────────────────────────────────────────────────────
-- process_sms as in 20261026170630, with a "-P" sender ignored as a promotion.
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
  -- UAE senders must prefix promotional SMS with "AD-" (TDRA), and no alert uses it: an
  -- advert is stored ignored, without a template or an LLM call. Indian headers carry the
  -- category as a suffix instead (TRAI DLT: "-P" promotional, "-S" service, "-T" transactional).
  if s.sender ~* '^AD-' or s.sender ~* '-P$' then
    update public.sms_messages set parse_status = 'ignored', ignore_reason = 'promotion', template_code = null
    where sms_code = p_sms_code;
    return 'ignored';
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

  v_bank_kind := m.msg_kind in ('debit_purchase', 'account_credit', 'account_debit', 'transfer_notice');
  if not v_bank_kind then
    if m.fields ? 'last4' then
      select * into v_card from public.cards
      where profile_code = s.profile_code and bank_code = m.bank_code and last4 = m.fields->>'last4';
      v_account := v_card.account_code;
    elsif m.fields ? 'first6' then
      -- A card named by its first six digits (EIB: "starting with 529205"): the account of the
      -- cards that carry them, else the one account earlier messages with them were put on
      -- (an unknown_card review binds such a message to the account chosen).
      select count(distinct c.account_code), min(c.account_code) into v_n, v_account
      from public.cards c
      where c.profile_code = s.profile_code and c.bank_code = m.bank_code and c.first6 = m.fields->>'first6';
      if v_n = 1 then
        select * into v_card from public.cards c
        where c.profile_code = s.profile_code and c.account_code = v_account and c.first6 = m.fields->>'first6'
        order by c.status <> 'active', c.is_supplementary, c.created_at, c.card_code
        limit 1;
      elsif v_n = 0 then
        select count(distinct o.account_code), min(o.account_code) into v_n, v_account
        from public.sms_messages o
        where o.profile_code = s.profile_code and o.bank_code = m.bank_code and o.sms_code <> s.sms_code
          and o.account_code is not null and o.parsed_fields->>'first6' = m.fields->>'first6';
        if v_n <> 1 then v_account := null; end if;
      else
        v_account := null;   -- cards of two accounts carry these digits: ask
      end if;
    end if;
    if v_account is null and not (m.fields ? 'last4') and not (m.fields ? 'first6') then
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
        -- A credit line that sends money out by account number (Wio Credit …9214) is named this way too.
        and a.kind in ('current', 'savings', 'credit_card') and a.account_ref is not null
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
    -- A bank alert waiting for its account says so (the phone shows any other status as logged).
    return case when v_bank_kind and v_account is null then 'no_bank_account' else 'ignored' end;
  end if;
  -- A transfer notice names where money went; it is read by v_cash_flow, never a transaction.
  if m.msg_kind = 'transfer_notice' then
    return 'noted';
  end if;
  if v_account is null then
    insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
    values (s.profile_code, 'sms', p_sms_code, 'unknown_card',
            jsonb_build_array(jsonb_build_object('bank_code', m.bank_code, 'last4', m.fields->>'last4')
                              || case when m.fields ? 'first6' then jsonb_build_object('first6', m.fields->>'first6')
                                      else '{}'::jsonb end))
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
  -- A card payment the bank draws from its own current account (the Wio Credit autopay) is
  -- money out of that account too: add the other leg (private.add_payment_leg).
  if v_result in ('created', 'linked') and m.msg_kind = 'payment'
     and exists (select 1 from public.sms_templates st
                 where st.template_code = m.template_code and st.pays_from_current_account) then
    perform private.add_payment_leg(e.txn_code)
    from public.transaction_evidence e
    where e.sms_code = p_sms_code and e.is_active and e.role <> 'duplicate';
  end if;
  -- The balance an account alert prints is a checkpoint as of the alert (not for a repeat).
  if v_bank_kind and v_result = 'created' and m.fields ? 'available' then
    insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source, sms_code)
    values (s.profile_code, v_account, v_event, (m.fields->>'available')::numeric, 'sms', p_sms_code);
  end if;
  return v_result;
end;
$$;


-- ── 7. statement_date: a template field, and the cycle of a statement summary ─
-- apply_sms_template as in 20261026170630, reading statement_date as a date.
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
      when 'first6' then
        -- A card's first six digits (its BIN), never its last four; anything shorter is dropped.
        if regexp_replace(v, '[^0-9]', '', 'g') ~ '^[0-9]{6}' then
          f := f || jsonb_build_object(k, left(regexp_replace(v, '[^0-9]', '', 'g'), 6));
        end if;
      when 'date', 'due_date', 'statement_date' then
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
                   'debit_purchase', 'account_credit', 'account_debit', 'transfer_notice')
     and f->>'amount' is null then
    return null;
  end if;
  -- A summary that prints no due date is due the day it arrives (due_on_receipt, Wio); the
  -- date is added by private.apply_sms_statement, which knows when the SMS came.
  if t.msg_kind = 'statement_summary' and (f->>'amount' is null or (f->>'due_date' is null and not t.due_on_receipt)) then
    return null;
  end if;
  return f;
end;
$$;


-- validate_sms_template as in 20261026170630, with statement_date among the fields.
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
                        'due_date', 'min_due', 'account_ref', 'counterparty_ref', 'first6', 'statement_date')
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


-- apply_sms_statement as in 20261020170933, with the cycle taken from a printed statement date.
create or replace function private.apply_sms_statement(p_sms_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_day int;
  v_received date;
  v_close date;
  v_prev date;
  v_due date;
  v_stmt text;
  v_stmt_date date;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code;
  if s.account_code is null or s.amount is null then
    return 'unknown_card';
  end if;

  -- A summary that prints its statement date (Emirates NBD's mini statement) names the cycle
  -- itself; otherwise the close day is the account's, as below.
  v_stmt_date := (s.parsed_fields->>'statement_date')::date;
  if v_stmt_date is not null then
    v_day := extract(day from v_stmt_date)::int;
  else
    select coalesce(a.cycle_close_day,
             (select extract(day from h.period_end)::int from public.statements h
              where h.account_code = a.account_code and h.kind = 'history_extract' and h.status = 'active'
                and h.period_end is not null
              order by h.statement_date desc limit 1))
    into v_day
    from public.accounts a where a.account_code = s.account_code;
  end if;
  if v_day is null then
    update public.sms_messages set parsed_fields = parsed_fields || '{"statement":"cycle_unknown"}'::jsonb
    where sms_code = p_sms_code;
    return 'cycle_unknown';
  end if;

  -- The cycle that closed on or before the day the SMS arrived; day 31 means month end.
  v_received := public.dubai_date(s.received_at);
  if v_stmt_date is not null then
    v_close := v_stmt_date;
  else
    v_close := make_date(extract(year from v_received)::int, extract(month from v_received)::int,
                         least(v_day, extract(day from (date_trunc('month', v_received) + interval '1 month - 1 day'))::int));
    if v_close > v_received then
      v_close := (date_trunc('month', v_received) - interval '1 day')::date;
      v_close := make_date(extract(year from v_close)::int, extract(month from v_close)::int,
                           least(v_day, extract(day from v_close)::int));
    end if;
  end if;
  v_prev := (date_trunc('month', v_close) - interval '1 day')::date;
  v_prev := make_date(extract(year from v_prev)::int, extract(month from v_prev)::int,
                      least(v_day, extract(day from v_prev)::int));
  v_due := (s.parsed_fields->>'due_date')::date;
  -- "Your credit payment is due today" (Wio) prints no date: it is due the day it arrived.
  if v_due is null and exists (select 1 from public.sms_templates t
                               where t.template_code = s.template_code and t.due_on_receipt) then
    v_due := v_received;
    update public.sms_messages set parsed_fields = parsed_fields || jsonb_build_object('due_date', v_due::text)
    where sms_code = p_sms_code;
  end if;
  if v_due <= v_close then
    update public.sms_messages set parsed_fields = parsed_fields || '{"statement":"due_before_close"}'::jsonb
    where sms_code = p_sms_code;
    return 'due_before_close';
  end if;

  select st.stmt_code into v_stmt from public.statements st
  where st.account_code = s.account_code and st.kind = 'statement' and st.status = 'active'
    and st.statement_date = v_close;
  if v_stmt is not null then
    update public.sms_messages set parsed_fields = parsed_fields || jsonb_build_object('stmt_code', v_stmt)
    where sms_code = p_sms_code;
    return 'statement_exists';
  end if;

  insert into public.statements (profile_code, account_code, kind, statement_date, period_start, period_end,
                                 due_date, closing_balance, min_due, primary_card_last4, sms_code, metadata)
  values (s.profile_code, s.account_code, 'statement', v_close, v_prev + 1, v_close,
          v_due, s.amount, (s.parsed_fields->>'min_due')::numeric, s.card_last4, p_sms_code,
          jsonb_build_object('source', 'sms'))
  returning stmt_code into v_stmt;
  update public.sms_messages set parsed_fields = parsed_fields || jsonb_build_object('stmt_code', v_stmt)
  where sms_code = p_sms_code;
  perform private.reconcile_statement(v_stmt);
  return 'statement';
end;
$$;


-- ── 6. the LLM's "not a transaction" is recorded ────────────────────────────
create or replace function public.mark_sms_not_transaction(p_sms_code text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  update public.sms_messages set parse_status = 'ignored', ignore_reason = 'llm_not_txn'
  where sms_code = p_sms_code and parse_status = 'unparsed';
  return found;
end;
$$;
grant execute on function public.mark_sms_not_transaction(text) to service_role;

-- ── 8. one proposal per format ──────────────────────────────────────────────
-- An LLM proposal is inactive until its owner approves it, so the next message of the same format
-- stays unparsed and would be sent to the LLM again. Before that call, the worker asks here for an
-- open proposal of the same profile that reads the message; the message joins it as a review of its
-- own, and approving the proposal parses (and closes) both.
create or replace function public.reuse_sms_proposal(p_sms_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_code text;
begin
  perform private.assert_service_role();
  select * into s from public.sms_messages where sms_code = p_sms_code;
  if not found then
    raise exception 'unknown sms %', p_sms_code using errcode = 'P0002';
  end if;
  select t.template_code into v_code
  from public.sms_templates t
  where t.source = 'llm' and not t.active and t.scope_profile_code = s.profile_code
    and exists (select 1 from public.match_reviews r
                where r.profile_code = s.profile_code and r.reason = 'unparsed_sms' and r.status = 'open'
                  and r.candidates @> jsonb_build_array(jsonb_build_object('template_code', t.template_code)))
    and private.apply_sms_template(t, s.sender, s.body) is not null
  order by t.created_at, t.template_code
  limit 1;
  if v_code is null then
    return null;
  end if;
  insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
  values (s.profile_code, 'sms', s.sms_code, 'unparsed_sms', jsonb_build_array(jsonb_build_object('template_code', v_code)))
  on conflict do nothing;
  return v_code;
end;
$$;
grant execute on function public.reuse_sms_proposal(text) to service_role;

-- ── 9. a message that parses closes its stale reviews ───────────────────────
create or replace function private.close_parsed_sms_reviews()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_templates text[];
begin
  -- The review naming the template that parsed the message is set_sms_template_active's to close.
  with closed as (
    update public.match_reviews r
    set status = 'resolved', resolved_at = now(),
        resolution = jsonb_build_object('auto', 'sms_parsed', 'template_code', new.template_code)
    where r.subject_type = 'sms' and r.subject_code = new.sms_code and r.profile_code = new.profile_code
      and r.reason = 'unparsed_sms' and r.status = 'open'
      and not (new.template_code is not null
               and r.candidates @> jsonb_build_array(jsonb_build_object('template_code', new.template_code)))
    returning r.candidates
  )
  select array_agg(distinct c->>'template_code') into v_templates
  from closed, jsonb_array_elements(closed.candidates) c
  where c ? 'template_code';

  delete from public.sms_templates t
  where t.template_code = any (coalesce(v_templates, '{}'::text[])) and t.source = 'llm' and not t.active
    and not exists (select 1 from public.match_reviews r
                    where r.reason = 'unparsed_sms' and r.status = 'open'
                      and r.candidates @> jsonb_build_array(jsonb_build_object('template_code', t.template_code)));
  return null;
end;
$$;
create trigger sms_messages_close_reviews after update of parse_status on public.sms_messages
  for each row
  when (old.parse_status in ('unparsed', 'pending', 'failed')
        and new.parse_status not in ('unparsed', 'pending', 'failed'))
  execute function private.close_parsed_sms_reviews();

-- ── 10. a sender the bank doesn't list opens a review ───────────────────────
-- propose_sms_template as in 20261009000300, with an unknown sender reviewed instead of raised.
create or replace function public.propose_sms_template(p_sms_code text, p_template jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_bank text := p_template->>'bank_code';
  v_sender_pattern text;
  v_code text;
begin
  perform private.assert_service_role();
  select * into s from public.sms_messages where sms_code = p_sms_code;
  if not found then
    raise exception 'unknown sms %', p_sms_code using errcode = 'P0002';
  end if;
  select '^(' || string_agg(regexp_replace(x.sender, '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g'), '|' order by x.sender) || ')'
  into v_sender_pattern
  from public.banks b, unnest(b.sms_senders) x(sender)
  where b.bank_code = v_bank and btrim(x.sender) <> '';
  -- A sender the bank doesn't list (a new bank, or a bank's new sender id such as Liv for
  -- Emirates NBD): no template can be anchored on it, so none is made. The message gets an open
  -- review instead of a dead letter, so it is seen; the sender is added to banks.sms_senders.
  if v_sender_pattern is null or s.sender !~* v_sender_pattern then
    insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
    values (s.profile_code, 'sms', s.sms_code, 'unparsed_sms',
            jsonb_build_array(jsonb_build_object('bank_code', v_bank, 'unknown_sender', s.sender)))
    on conflict do nothing;
    return null;
  end if;
  insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
    msg_kind, priority, active, examples, source, scope_profile_code)
  values (v_bank, coalesce(p_template->>'name', 'LLM proposal'),
          v_sender_pattern, p_template->>'body_pattern', p_template->'field_groups',
          p_template->>'date_format', p_template->>'msg_kind', 200, false,
          jsonb_build_array(jsonb_build_object('sender', s.sender, 'body', s.body,
                                               'expect', coalesce(p_template->'expect', '{}'::jsonb))),
          'llm', s.profile_code)
  returning template_code into v_code;
  insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
  values (s.profile_code, 'sms', s.sms_code, 'unparsed_sms', jsonb_build_array(jsonb_build_object('template_code', v_code)))
  on conflict do nothing;
  return v_code;
end;
$$;


-- ── content (guarded, CLAUDE.md §1.9) ───────────────────────────────────────
-- Template changes re-run the unparsed messages of their senders (DB-22); the messages an earlier
-- template stored 'ignored' are re-run at the end.

-- 1. FAB remittances whose first line breaks. The split form joins each template's examples.
update public.sms_templates
set body_pattern = replace(body_pattern, 'Inward Remittance Credit\s*', 'Inward Remittance\s+Credit\s*'),
    examples = examples || jsonb_build_array(jsonb_build_object(
      'sender', 'FAB',
      'body', E'Inward Remittance \nCredit  \nAccount XXXX3101 \nAED 250.00\nDate 05/03/2026 \nBalance AED 1234.50',
      'expect', jsonb_build_object('account_ref', '3101', 'currency', 'AED', 'amount', '250.00',
                                   'date', '2026-03-05', 'available', '1234.50')))
where bank_code = 'FAB' and name = 'FAB inward remittance'
  and body_pattern = 'Inward Remittance Credit\s*\n\s*Account X*([0-9]+)\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*Date ([0-9]{2}/[0-9]{2}/[0-9]{4})(?:\s*\n\s*Balance ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?';
update public.sms_templates
set body_pattern = replace(body_pattern, 'Outward Remittance Debit\s*', 'Outward Remittance\s+Debit\s*'),
    examples = examples || jsonb_build_array(jsonb_build_object(
      'sender', 'FAB',
      'body', E'Outward Remittance \nDebit  \nAccount XXXX3101 \nAED 400.00\nDate 06/03/2026 \nBalance AED 834.50',
      'expect', jsonb_build_object('account_ref', '3101', 'currency', 'AED', 'amount', '400.00',
                                   'date', '2026-03-06', 'available', '834.50')))
where bank_code = 'FAB' and name = 'FAB outward remittance'
  and body_pattern = 'Outward Remittance Debit\s*\n\s*Account X*([0-9]+)\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*Date ([0-9]{2}/[0-9]{2}/[0-9]{4})(?:\s*\n\s*Balance ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?';

-- 3. Liv texts as "Liv".
update public.banks set sms_senders = sms_senders || array['Liv']
where bank_code = 'ENBD' and not ('Liv' = any (sms_senders));

-- 7. The ENBD mini statement as a statement summary, ahead of the ignored catch-all (kept for any
-- other wording of it).
insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 -- 2. FAB standing instruction. The consumer number is the payee's, never an own account, so it
 --    is not mapped to counterparty_ref (which v_cash_flow reads as a transfer's destination).
 ('FAB', 'FAB standing instruction', '^FAB',
  'standing instructions? of ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?) to (.+?) for consumer number [0-9]+ has been processed on ([0-9]{2}/[0-9]{2}/[0-9]{4})',
  '{"currency":1,"amount":2,"merchant":3,"date":4}', 'DD/MM/YYYY', 'account_debit', 60,
  '[{"sender":"FAB","body":"Dear Customer, Your standing instructions of AED 123.40 to SAMPLE UTILITY for consumer number 1000000001 has been processed on 05/03/2026.",
     "expect":{"currency":"AED","amount":"123.40","merchant":"SAMPLE UTILITY","date":"2026-03-05"}}]'),
 -- 3. Liv debit-card purchase. The balance is the account's, in AED, whatever the purchase currency.
 ('ENBD', 'Liv debit card purchase', '^Liv$',
  'Purchase of ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?) with Debit Card ending ([0-9]{4}) at (.+?)\.\s+Avl Balance is ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?)',
  '{"currency":1,"amount":2,"last4":3,"merchant":4,"available":6}', null, 'debit_purchase', 10,
  '[{"sender":"Liv","body":"Purchase of USD 12.34 with Debit Card ending 9201 at SAMPLE STORE, Dublin. Avl Balance is AED 2,345.67.  Pls refer stmt for exact amt.",
     "expect":{"currency":"USD","amount":"12.34","last4":"9201","merchant":"SAMPLE STORE, DUBLIN","available":"2345.67"}}]'),
 ('ENBD', 'ENBD credit card mini statement', '^EmiratesNBD',
  'Credit Card Mini Stmt for Card ending ([0-9]{4}): Statement date ([0-9]{2}/[0-9]{2}/[0-9]{2})\. Total Amt Due ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?), Due Date ([0-9]{2}/[0-9]{2}/[0-9]{2})\. Min Amt Due [A-Z]{3} ?([0-9,]+(?:\.[0-9]{1,2})?)',
  '{"last4":1,"statement_date":2,"currency":3,"amount":4,"due_date":5,"min_due":6}', 'DD/MM/YY', 'statement_summary', 10,
  '[{"sender":"EmiratesNBD","body":"Emirates NBD Credit Card Mini Stmt for Card ending 9207: Statement date 15/03/26. Total Amt Due AED 2,345.67, Due Date 09/04/26. Min Amt Due AED 117.28",
     "expect":{"last4":"9207","statement_date":"2026-03-15","currency":"AED","amount":"2345.67","due_date":"2026-04-09","min_due":"117.28"}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);

-- 5. SIB's reminder to move recurring payments to the new card.
update public.sms_templates
set body_pattern = '(txn attempt on Card\.? X*[0-9]{4} .* was not processed|payment is due on [0-9]{1,2}-[A-Za-z]{3},|new Covered Card X*[0-9]{4} has been activated|is ready for Apple Pay|time to activate your new SIB|Your Mobile Banking request for|as part of our card system update|update your new Covered Card details)',
    examples = examples || '[{"sender":"SIB","body":"Reminder: Please update your new Covered Card details with the Merchants, Service Providers & Subscriptions for your recurring bills payment and standing orders, as your old card has been blocked.","expect":{}}]'::jsonb
where bank_code = 'SIB' and name = 'SIB card notices (ignored)'
  and body_pattern = '(txn attempt on Card\.? X*[0-9]{4} .* was not processed|payment is due on [0-9]{1,2}-[A-Za-z]{3},|new Covered Card X*[0-9]{4} has been activated|is ready for Apple Pay|time to activate your new SIB|Your Mobile Banking request for|as part of our card system update)';

-- ── data: messages stored before these rules ────────────────────────────────
-- Re-run what an earlier rule stored 'ignored' (a split FAB remittance under the catch-all, ENBD
-- mini statements) or left 'unparsed' (Indian adverts), as the template trigger does.
do $$
declare
  v_code text;
  v_state text;
begin
  for v_code in
    select s.sms_code
    from public.sms_messages s
    left join public.sms_templates t on t.template_code = s.template_code
    where (s.parse_status = 'ignored' and t.bank_code = 'FAB' and t.name = 'FAB account alert (ignored, catch-all)'
           and s.body ~* 'Inward Remittance\s+Credit|Outward Remittance\s+Debit')
       or (s.parse_status = 'ignored' and t.bank_code = 'ENBD' and t.name = 'ENBD credit card mini statement (ignored)')
       or (s.parse_status = 'unparsed' and s.sender ~* '-P$')
    order by s.received_at, s.sms_code
  loop
    begin
      perform private.process_sms(v_code);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      update public.sms_messages set parse_status = 'failed', ignore_reason = 'error:' || v_state
      where sms_code = v_code;
    end;
  end loop;
end;
$$;

-- 6. Unparsed messages the LLM already passed over (and kept no review) go back to the fallback,
-- which now records its "not a transaction". Delayed 15 minutes, past the deploy of the worker
-- that records it (migrations deploy before functions).
select pgmq.send('sms_fallback', jsonb_build_object('sms_code', s.sms_code), 900)
from public.sms_messages s
where s.parse_status = 'unparsed' and btrim(s.sender) <> ''
  and not exists (select 1 from public.match_reviews r
                  where r.subject_type = 'sms' and r.subject_code = s.sms_code and r.status = 'open');

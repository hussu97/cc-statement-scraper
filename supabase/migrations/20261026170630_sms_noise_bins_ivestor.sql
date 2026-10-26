-- SMS clean-up from the 26 Oct review of production SMS (tasks/todo.md §10).
--
-- 1. Cards gain first6, the first six digits (BIN). EIB's payment confirmation names the card
--    only by them ("towards your Credit Card starting with 542459"); the LLM templates made for
--    it read the BIN as last4, so the reviews registered two cards that do not exist (•2459 and
--    •7828). first6 is now a template field: process_sms finds the account by the cards that
--    carry those digits, else by the one account earlier messages with them were bound to in an
--    unknown_card review (that review binds a message without last4 to the account chosen, so
--    the answer is learned once). Neither registers a card. The review's candidate carries first6.
-- 2. A promotional SMS (sender "AD-…", the TDRA prefix for adverts) is stored 'ignored' with
--    ignore_reason 'promotion', before any template or LLM call.
-- 3. private.merge_cards folds a card registered by mistake into the real one: every row that
--    names it moves over and the emptied card is closed (closed, not deleted, as
--    private.merge_accounts does: a destructive migration stops the deploy).
-- 4. Content, guarded (CLAUDE.md §1.9): "(ignored)" notices for FAB (Key Facts Statement, the
--    payment-due reminder) and EIB (payment reminder); EIB's payment confirmation read by first6
--    (the two LLM templates that read it as last4 are switched off while they still hold their
--    proposed fields); the DFM iVESTOR card: bank DFM (sender "DFM", DFM's own logo file, the
--    scheme-only FX markup of a card with no purchase fee) and its credit alert, an account credit; a "Dividends" income category with a rule that files DFM's
--    "iVESTOR card" money-in under it.
-- 5. Production data, guarded so it is a no-op on any other database and on a second run:
--    Tejasvie's EIB BINs on •6177 and •4557, the two payments moved onto them and the two cards
--    merged into them; the Wallet pass "RTA Platinum Card" named on •4557 (its tap links to the
--    SMS already in the ledger); messages from senders that are not banks (Hussain's e& money and
--    IndusInd notices) and the Shortcut's blank-sender tests (one each) marked not a transaction;
--    Hussain's DFM iVESTOR account, which turns the 16 Oct dividend SMS into a transaction and a
--    balance checkpoint.

-- ── 1. cards.first6 ─────────────────────────────────────────────────────────
alter table public.cards add column first6 text check (first6 ~ '^[0-9]{6}$');
create index cards_first6_idx on public.cards(profile_code, bank_code, first6) where first6 is not null;

-- ── 2. first6: the template field and the card resolution ───────────────────
-- validate_sms_template as in 20261020152032, with first6 among the fields.
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
                        'due_date', 'min_due', 'account_ref', 'counterparty_ref', 'first6')
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

-- apply_sms_template as in 20261020170933, with first6.
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

-- process_sms as in 20261020170933, with AD- adverts ignored and cards found by first6.
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
  -- advert is stored ignored, without a template or an LLM call.
  if s.sender ~* '^AD-' then
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
      -- A card named by its first six digits (EIB: "starting with 542459"): the account of the
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
        -- A credit line that sends money out by account number (Wio Credit …5059) is named this way too.
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

-- ── 3. merge_cards ──────────────────────────────────────────────────────────
-- Fold p_from into p_into (same profile and bank): the transactions, statement lines, messages
-- and rule conditions that name p_from move to p_into, p_into takes any first6 or Wallet name
-- only p_from had, and p_from is closed. Service-only, like private.merge_accounts.
create or replace function private.merge_cards(p_profile_code text, p_into text, p_from text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_into public.cards%rowtype;
  v_from public.cards%rowtype;
  v_txns int;
  v_lines int;
  v_sms int;
  v_rules int;
begin
  select * into v_into from public.cards where card_code = p_into and profile_code = p_profile_code;
  select * into v_from from public.cards where card_code = p_from and profile_code = p_profile_code;
  if v_into.card_code is null or v_from.card_code is null or p_into = p_from then
    raise exception 'merge_cards needs two cards of profile %', p_profile_code using errcode = 'P0002';
  end if;
  if v_into.bank_code <> v_from.bank_code then
    raise exception 'cards % and % are at different banks', p_into, p_from using errcode = '22023';
  end if;

  update public.transactions set card_code = p_into, account_code = v_into.account_code
  where profile_code = p_profile_code and card_code = p_from;
  get diagnostics v_txns = row_count;
  update public.statement_lines set card_code = p_into
  where profile_code = p_profile_code and card_code = p_from;
  get diagnostics v_lines = row_count;
  update public.sms_messages set card_code = p_into, account_code = v_into.account_code
  where profile_code = p_profile_code and card_code = p_from;
  get diagnostics v_sms = row_count;
  update public.category_rules set conditions = jsonb_set(conditions, '{card_code}', to_jsonb(p_into))
  where profile_code = p_profile_code and conditions->>'card_code' = p_from;
  get diagnostics v_rules = row_count;

  -- The Wallet name moves (it is unique per profile); the closed card keeps nothing to match.
  update public.cards set first6 = null, wallet_name = null, status = 'closed' where card_code = p_from;
  update public.cards set first6 = coalesce(v_into.first6, v_from.first6),
                          wallet_name = coalesce(v_into.wallet_name, v_from.wallet_name)
  where card_code = p_into
    and (v_into.first6 is null and v_from.first6 is not null
         or v_into.wallet_name is null and v_from.wallet_name is not null);
  return jsonb_build_object('card_code', p_into, 'merged_card_code', p_from, 'transactions', v_txns,
                            'statement_lines', v_lines, 'sms_messages', v_sms, 'rules', v_rules);
end;
$$;


-- ── 4. content ──────────────────────────────────────────────────────────────
-- DFM: the iVESTOR card (a prepaid card DFM pays dividends onto). Its logo is DFM's own published
-- icon (assets/banks/DFM.png, from dfm.ae), uploaded with scripts/brand/upload-bank-logos.sh.
insert into public.banks (bank_code, name, sms_senders, logo_path)
values ('DFM', 'Dubai Financial Market', array['DFM'], 'DFM.png')
on conflict (bank_code) do nothing;

-- iVESTOR is an Emirates NBD-issued Visa prepaid card: no fee on purchases in the UAE or overseas
-- (iVESTOR user guide, Schedule of Fees), converted at Emirates NBD's rate, so the scheme part alone.
insert into private.bank_fx_fees (bank_code, markup, note)
values ('DFM', 0.011500,
        'iVESTOR (Emirates NBD Visa prepaid): no purchase fee UAE or overseas (user guide, Schedule of Fees 2022); scheme ~1.15%')
on conflict (bank_code) do nothing;

-- Templates. Inserting them re-runs the unparsed messages their senders match (DB-22).
insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 ('EIB', 'EIB credit card payment received', '^(EI ?SMS|EIBank|EmiratesIsl)',
  'confirm receipt of your payment of ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?) towards your Credit Card starting with ([0-9]{6})\s+on ([0-9]{2}/[0-9]{2}/[0-9]{4})\.?\s*Available limit is\s*[A-Z]{3}\s*([0-9,]+(?:\.[0-9]{1,2})?)',
  '{"currency":1,"amount":2,"first6":3,"date":4,"available":5}', 'DD/MM/YYYY', 'payment', 10,
  '[{"sender":"EI SMS","body":"This is to confirm receipt of your payment of AED 62.00 towards your Credit Card starting with 542459  on 24/10/2026. Available limit is   AED 37,969.57.",
     "expect":{"currency":"AED","amount":"62.00","first6":"542459","date":"2026-10-24","available":"37969.57"}}]'),
 ('EIB', 'EIB credit card payment reminder (ignored)', '^(EI ?SMS|EIBank|EmiratesIsl)',
  'Reminder for Credit Card Payment\s*\n\s*Card Starting:? *[0-9]{6}', '{}', null, 'other', 900,
  '[{"sender":"EI SMS","body":"Reminder for Credit Card Payment\nCard Starting: 542459\nDue Date: 25/10/2026\nMinimum Amount Due: AED 61.79\nAmount to be paid to avoid charges: AED 61.79\nPlease pay on or before due date to avoid commitment to donate amount.","expect":{}}]'),
 ('FAB', 'FAB credit card due reminder (ignored)', '^FAB',
  'payment due date of your FAB Credit Card ending with [0-9]{4} is', '{}', null, 'other', 900,
  '[{"sender":"FAB","body":"Dear Customer, the payment due date of your FAB Credit Card ending with 2777 is 26-10-2026. The total amount due is AED 515.26 and the Minimum due amount is AED 100.00. Please ignore the message, if already paid.","expect":{}}]'),
 ('FAB', 'FAB key facts statement notice (ignored)', '^FAB',
  'Key Facts Statement has been updated', '{}', null, 'other', 900,
  '[{"sender":"FAB","body":"Your FAB Credit Card Key Facts Statement has been updated. Please review it to be informed about card terms, conditions and fees. https://vkq.be/etzc5IgH.","expect":{}}]'),
 ('DFM', 'DFM iVESTOR card credit', '^DFM',
  '(iVESTOR card) x*([0-9]{4}) has been credited with ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?)\.?(?:\s*Your available balance is\s*([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?))?',
  '{"merchant":1,"last4":2,"currency":3,"amount":4,"available":6}', null, 'account_credit', 60,
  '[{"sender":"DFM","body":"Dear customer, Your iVESTOR card xxxx5246 has been credited with AED 113.92. Your available balance is  AED 517.78",
     "expect":{"merchant":"IVESTOR CARD","last4":"5246","currency":"AED","amount":"113.92","available":"517.78"}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);

-- The LLM templates that read EIB's BIN as last4 stop matching (only while they still hold the
-- fields the model proposed); the seeded template above reads it as first6.
update public.sms_templates set active = false
where bank_code = 'EIB' and source = 'llm' and active and msg_kind = 'payment'
  and field_groups = '{"date": 4, "last4": 3, "amount": 2, "currency": 1, "available": 5}'::jsonb
  and body_pattern like '%towards your Credit Card starting with ([0-9]{%';

-- Dividends: income, never spend. New ledgers get it from the seed; existing ledgers that have
-- categories get it where no category of that name exists.
insert into private.seed_categories (name, kind, sort_order, color_token)
select 'Dividends', 'income', 154, 'cat-2'
where not exists (select 1 from private.seed_categories where name = 'Dividends');

insert into public.categories (profile_code, name, kind, sort_order, color_token)
select p.profile_code, 'Dividends', 'income', 154, 'cat-2'
from public.profiles p
where exists (select 1 from public.categories c where c.profile_code = p.profile_code)
  and not exists (select 1 from public.categories c where c.profile_code = p.profile_code and lower(c.name) = 'dividends');

insert into private.seed_rules (category_name, pattern, match_type, conditions)
select 'Dividends', 'IVESTOR CARD', 'exact', '{"kind":"transfer_in","bank_code":"DFM"}'::jsonb
where not exists (select 1 from private.seed_rules where category_name = 'Dividends' and pattern = 'IVESTOR CARD');

insert into public.category_rules (profile_code, category_code, name, match_type, pattern, conditions, source)
select c.profile_code, c.category_code, 'seed: IVESTOR CARD (DFM)', 'exact', 'IVESTOR CARD',
       '{"kind":"transfer_in","bank_code":"DFM"}'::jsonb, 'seed'
from public.categories c
where c.name = 'Dividends' and c.kind = 'income'
  and not exists (select 1 from public.category_rules r
                  where r.profile_code = c.profile_code and upper(r.pattern) = 'IVESTOR CARD');

-- Adverts already stored as unparsed become ignored.
select private.process_sms(s.sms_code)
from public.sms_messages s
where s.parse_status = 'unparsed' and s.sender ~* '^AD-'
order by s.received_at, s.sms_code;


-- ── 5. production data ──────────────────────────────────────────────────────
-- Tejasvie's EIB cards: the BIN of each card the reviews chose, the two payments re-read by
-- first6 and moved onto the real cards, and the two cards made from the BINs merged into them.
do $$
declare
  c_profile constant text := 'prf_01m4dnbdrnactkzwekcv1p513w';
  c_amazon constant text := 'crd_01m4qt6j4cm2weegdy2zzqdz5s';   -- EIB Amazon •6177
  c_rta constant text := 'crd_01m4qv60g13b1dhb4448f385hs';      -- EIB RTA •4557
  c_bin_amazon constant text := 'crd_01m5rrv7y75w0j4sbenwwynzbt'; -- "•2459" (BIN 542459)
  c_bin_rta constant text := 'crd_01m5rrvczf8b5568fn332nhg73';    -- "•7828" (BIN 457828)
  v_tpl public.sms_templates%rowtype;
begin
  if (select count(*) from public.cards
      where profile_code = c_profile and bank_code = 'EIB' and first6 is null
        and (card_code, last4) in ((c_amazon, '6177'), (c_rta, '4557'))) <> 2
     or (select count(*) from public.cards
         where status = 'active' and (card_code, profile_code, bank_code, last4, account_code) in (
           (c_bin_amazon, c_profile, 'EIB', '2459', (select account_code from public.cards where card_code = c_amazon)),
           (c_bin_rta, c_profile, 'EIB', '7828', (select account_code from public.cards where card_code = c_rta)))) <> 2 then
    return;
  end if;
  select * into v_tpl from public.sms_templates where bank_code = 'EIB' and name = 'EIB credit card payment received';

  update public.cards set first6 = '542459' where card_code = c_amazon;
  update public.cards set first6 = '457828' where card_code = c_rta;
  update public.sms_messages s set
    card_last4 = null,
    card_code = case s.card_code when c_bin_amazon then c_amazon else c_rta end,
    template_code = v_tpl.template_code,
    template_version = v_tpl.version,
    parsed_fields = (s.parsed_fields - 'last4')
                    || jsonb_build_object('first6', case s.card_code when c_bin_amazon then '542459' else '457828' end)
  where s.profile_code = c_profile and s.card_code in (c_bin_amazon, c_bin_rta);
  perform private.merge_cards(c_profile, c_amazon, c_bin_amazon);
  perform private.merge_cards(c_profile, c_rta, c_bin_rta);
end;
$$;

-- Tejasvie's Wallet pass "RTA Platinum Card" is EIB RTA •4557. Naming it re-runs the waiting
-- Wallet tap (cards_wallet_name_reprocess), which links to the SMS of the same purchase.
update public.cards set wallet_name = 'RTA Platinum Card'
where card_code = 'crd_01m4qv60g13b1dhb4448f385hs' and profile_code = 'prf_01m4dnbdrnactkzwekcv1p513w'
  and wallet_name is null
  and not exists (select 1 from public.cards c
                  where c.profile_code = 'prf_01m4dnbdrnactkzwekcv1p513w' and lower(c.wallet_name) = 'rta platinum card');

-- Hussain's messages from senders that are not banks (e& money's fee notice, IndusInd's limit
-- notice) and two blank-sender tests of the Shortcut: not transactions (as the review action does).
update public.sms_messages set parse_status = 'ignored', ignore_reason = 'user_not_txn'
where profile_code = 'prf_01m4dnbdpbztxjfe7mej2fpqt2' and parse_status = 'unparsed'
  and sms_code in ('sms_01m4gaa7aw5rpbd1egnae7e3g2', 'sms_01m509app8dk9jfy9g3pswhcbv',
                   'sms_01m5f5j7kccdbr4a1z3m4q4624')
  and not exists (select 1 from public.transaction_evidence e where e.sms_code = sms_messages.sms_code and e.is_active);
update public.sms_messages set parse_status = 'ignored', ignore_reason = 'user_not_txn'
where profile_code = 'prf_01m4dnbdrnactkzwekcv1p513w' and parse_status = 'unparsed'
  and sms_code = 'sms_01m4rcavc3xxeanad83pcwbwgc'
  and not exists (select 1 from public.transaction_evidence e where e.sms_code = sms_messages.sms_code and e.is_active);

-- Hussain's DFM iVESTOR card: a current account (cash), which re-runs the alerts that waited for it.
do $$
declare
  c_profile constant text := 'prf_01m4dnbdpbztxjfe7mej2fpqt2';
begin
  if not exists (select 1 from public.profiles where profile_code = c_profile)
     or exists (select 1 from public.accounts where profile_code = c_profile and bank_code = 'DFM') then
    return;
  end if;
  insert into public.accounts (profile_code, bank_code, kind, product_name, nickname, currency)
  values (c_profile, 'DFM', 'current', 'iVESTOR card', 'DFM iVESTOR', 'AED');
  perform private.reprocess_bank_sms(c_profile, 'DFM');
end;
$$;

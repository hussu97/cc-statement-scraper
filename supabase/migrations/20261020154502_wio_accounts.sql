-- Wio (2026-10-20), from Hussain's real Wio alerts. Wio Personal has two accounts: the debit
-- account (…2289) and Wio Credit, a credit line (account …5059, card 3424) that pays the other
-- cards during the month and is cleared by an autopay from the debit account on the 1st.
--
-- 1. Templates: local transfers from either account (the recipient's name is the description, so
--    a recipient can be filed once, like a merchant); the international transfer (its AED amount);
--    the Wio Credit autopay (a payment on the Wio Credit card account); cashback (money in); card
--    purchases that print the AED amount in brackets; due/estimate/beneficiary notices ignored.
-- 2. process_sms: an alert's account digits may name a credit_card account with account_ref
--    (Wio Credit), so "local transfer … from 39XXXX5059" lands on Wio Credit, where it pairs with
--    the card payment it made (card_transfers: transfer_out ↔ payment, same amount, 3 days).
-- 3. refresh_transaction: a transfer is final from its SMS on any account (a credit line's
--    transfers never appear on a statement line here).
-- The Wio Credit autopay and estimate SMS say neither "Card" nor "Account": a third Shortcuts
-- automation on "Wio" catches the autopay (README, SMS capture).

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

  v_bank_kind := m.msg_kind in ('debit_purchase', 'account_credit', 'account_debit', 'transfer_notice');
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
                     -- A transfer out of a credit line is final too: no statement line will post it.
                     when t.kind in ('transfer_in', 'transfer_out') then 'posted'
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

insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 ('WIO', 'Wio local transfer', '^Wio',
  'Your local transfer of ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?) to (.+?) from your account number [0-9]*X+([0-9]+) was processed',
  '{"currency":1,"amount":2,"merchant":3,"account_ref":4}', null, 'account_debit', 55,
  '[{"sender":"WioPersonal","body":"Your local transfer of AED 468 to Hussain Fahim Akhter from your account number 39XXXX5059 was processed.",
     "expect":{"currency":"AED","amount":"468.00","merchant":"HUSSAIN FAHIM AKHTER","account_ref":"5059"}},
    {"sender":"WioPersonal","body":"Your local transfer of AED 23,700 to Fahim Akhter Shabbir Abbasi from your account number 63XXXX2289 was processed.",
     "expect":{"currency":"AED","amount":"23700.00","merchant":"FAHIM AKHTER SHABBIR ABBASI","account_ref":"2289"}}]'),
 ('WIO', 'Wio international transfer', '^Wio',
  'initiated an international transfer of [A-Z]{3} ?[0-9,.]+ to (.+?)\. AED ([0-9,]+(?:\.[0-9]{1,2})?) will be debited from your AED account',
  '{"merchant":1,"amount":2}', null, 'account_debit', 55,
  '[{"sender":"WioPersonal","body":"You have initiated an international transfer of USD 15,000 to HUSSAIN FAHIM AKHTER ABBASI. AED 55,162.50 will be debited from your AED account.",
     "expect":{"merchant":"HUSSAIN FAHIM AKHTER ABBASI","amount":"55162.50"}}]'),
 ('WIO', 'Wio credit autopay', '^Wio',
  'made an autopay of ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?) towards your Wio Credit balance',
  '{"currency":1,"amount":2}', null, 'payment', 55,
  '[{"sender":"WioPersonal","body":"You''ve made an autopay of AED 19,082 towards your Wio Credit balance.",
     "expect":{"currency":"AED","amount":"19082.00"}}]'),
 ('WIO', 'Wio cashback', '^Wio',
  'Your ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?) (cashback) for [A-Za-z]+ has been credited to your account',
  '{"currency":1,"amount":2,"merchant":3}', null, 'account_credit', 55,
  '[{"sender":"WioPersonal","body":"Your AED 205.33 cashback for September has been credited to your account",
     "expect":{"currency":"AED","amount":"205.33","merchant":"CASHBACK"}}]'),
 ('WIO', 'Wio credit card payment (with AED)', '^Wio',
  'Payment of [A-Z]{3} ?[0-9,.]+ \(AED ([0-9,]+(?:\.[0-9]{1,2})?)\) was done at (.+?) using your Wio [A-Za-z ]*card (?:ending (?:with )?)?([0-9]{4}) with Credit money',
  '{"amount":1,"merchant":2,"last4":3}', null, 'purchase', 9,
  '[{"sender":"WioPersonal","body":"Payment of USD 2,000 (AED 7,400) was done at RI using your Wio Personal card 3424 with Credit money",
     "expect":{"amount":"7400.00","merchant":"RI","last4":"3424"}}]'),
 ('WIO', 'Wio credit notices (ignored)', '^Wio',
  '(estimated repayment is|credit payment is due today|has been added as a [a-z ]*beneficiary)',
  '{}', null, 'other', 900,
  '[{"sender":"WioPersonal","body":"Your estimated repayment is AED 19,082. Your statement closes at 11:59 PM on 2026-09-30, and auto-pay runs at 9:00 PM on 2026-10-01. You can adjust your repayment amount any time in the app.","expect":{}},
    {"sender":"WioPersonal","body":"Your credit payment is due today. Statement amount: AED 19,082. Auto-pay will be processed at 9:00 PM tonight. You can adjust the repayment amount in the app before then.","expect":{}},
    {"sender":"WioPersonal","body":"DAWOUD ALI MOHAMED AHMED ALZEYOUDI has been added as a local transfer beneficiary. If it wasn''t you, reset your password right away and call us on 600 500 946","expect":{}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);

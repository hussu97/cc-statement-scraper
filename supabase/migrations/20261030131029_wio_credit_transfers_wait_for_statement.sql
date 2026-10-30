-- Wio Credit transfers wait for their statement, and a statement's autopay line moves money out
-- of the current account (2026-10-30).
--
-- 1. refresh_transaction: a transfer out of a credit line (Wio Credit paying another bank's card
--    by local transfer) is no longer final from its SMS. 20261020154502 assumed a credit line's
--    transfers never appear on a statement line; the Wio credit statement prints every one of them
--    ("<beneficiary> payment"). Posted on arrival, an SMS the statement line failed to match stayed
--    beside it as a second debit that reconcile_statement never flags (it looks only at pending
--    rows). Now it is pending like any card SMS: the line posts it, or reconcile flags it.
-- 2. A card payment drawn from the bank's current account gets its other leg whatever proved it.
--    The SMS path already adds it (process_sms → add_payment_leg); a statement's autopay line
--    ("Credit Repayment Autopay"), alone or before its SMS, now does too, through a trigger. The
--    bank is one whose autopay SMS template says pays_from_current_account, so the leg exists only
--    where the current account has no statement of its own that would already show the debit.
-- 3. Existing autopay payments without a leg get one.

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
  p public.transactions%rowtype;
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
    -- A transfer out of a credit line waits too: its statement prints it (20261030131029).
    t.status := case when t.voided_at is not null then 'void'
                     when exists (select 1 from public.accounts a
                                  where a.account_code = t.account_code and a.kind in ('current', 'savings'))
                       then 'posted'
                     else 'pending' end;
  elsif t.leg_of_txn_code is not null then
    -- The other leg of a card payment drawn from a bank account (the Wio Credit autopay): the
    -- one SMS is the payment's evidence, so this row's facts are the payment's. It stands while
    -- the payment does, and is final (a bank account has no statement to wait for).
    select * into p from public.transactions where txn_code = t.leg_of_txn_code;
    t.txn_at := p.txn_at;
    t.txn_date := p.txn_date;
    t.posting_date := null;
    t.amount_original := p.amount_original;
    t.currency_original := p.currency_original;
    t.amount_aed := p.amount_aed;
    t.amount_aed_is_estimate := p.amount_aed_is_estimate;
    t.fx_rate := p.fx_rate;
    t.auth_amount := null;
    t.stmt_code := null;
    t.amount_source := p.amount_source;
    if p.status in ('pending', 'posted') then
      if t.void_reason = 'payment_gone' then
        t.voided_at := null;
        t.void_reason := null;
      end if;
      t.status := case when t.voided_at is not null then 'void' else 'posted' end;
    else
      t.voided_at := coalesce(t.voided_at, now());
      t.void_reason := coalesce(t.void_reason, 'payment_gone');
      t.status := 'void';
    end if;
  elsif exists (select 1 from public.account_entries x where x.txn_code = t.txn_code)
     or exists (select 1 from public.structured_note_events x where x.txn_code = t.txn_code)
     or exists (select 1 from public.structured_notes x where x.purchase_txn_code = t.txn_code)
     or exists (select 1 from public.broker_transactions x where x.txn_code = t.txn_code) then
    -- Typed evidence (20261027124257): a deposit the user entered, or a note's purchase or
    -- payment; or a broker's own row (20261027165732). Its facts were set from that evidence;
    -- it stands until voided.
    t.status := case when t.voided_at is not null then 'void' else 'posted' end;
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
  -- A payment's other leg follows it.
  perform private.refresh_transaction(x.txn_code)
  from public.transactions x
  where x.profile_code = t.profile_code and x.leg_of_txn_code = p_txn_code;
end;
$function$;

-- SMS transfers on a credit line that were posted on arrival wait for their statement now.
select private.refresh_transaction(t.txn_code)
from public.transactions t
join public.accounts a on a.account_code = t.account_code
where a.kind = 'credit_card' and t.kind in ('transfer_in', 'transfer_out')
  and t.amount_source = 'sms' and t.status = 'posted';

-- ── 2. the current-account leg of an autopay, whatever proved the payment ───
-- An autopay from a bank whose autopay SMS template pays from the current account (Wio).
create or replace function private.is_current_account_autopay(p_txn_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from public.transactions t
    join public.accounts a on a.account_code = t.account_code
    where t.txn_code = p_txn_code
      and t.kind = 'payment' and t.direction = 'credit' and t.status in ('pending', 'posted')
      and a.kind = 'credit_card'
      and t.description ~* '\mautopay\M'
      and exists (select 1 from public.sms_templates st
                  where st.bank_code = a.bank_code and st.pays_from_current_account and st.active)
  );
$$;

create or replace function private.transactions_add_payment_leg()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind = 'payment' and new.direction = 'credit' and new.leg_of_txn_code is null
     and private.is_current_account_autopay(new.txn_code) then
    perform private.add_payment_leg(new.txn_code);
  end if;
  return null;
end;
$$;

-- Named to fire after transactions_card_transfer: add_payment_leg's own pair wins over any
-- pair that trigger made.
create trigger transactions_payment_leg
  after insert or update of kind, direction, status, description, account_code
  on public.transactions
  for each row execute function private.transactions_add_payment_leg();

-- ── 3. existing autopay payments without their leg ──────────────────────────
select private.add_payment_leg(t.txn_code)
from public.transactions t
where private.is_current_account_autopay(t.txn_code)
  and not exists (select 1 from public.transactions x where x.leg_of_txn_code = t.txn_code);

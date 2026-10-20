-- Wio Credit: a statement anchor for what it owes, and the autopay's debit leg (tasks/todo.md §4,
-- Phase 2 leftovers). Wio Credit (a credit_card account with account_ref, bank WIO) has no
-- statement PDF, so v_account_balances had no anchor for it and net_worth marked owed incomplete;
-- and its monthly autopay was a payment on Wio Credit only, so the Wio debit account's running
-- balance (account_ledger) and the balance_drift insight showed a gap every month.
--
-- 1. The statement: "Your credit payment is due today. Statement amount: AED 19,082. Auto-pay
--    will be processed at 9:00 PM tonight…" becomes a statement_summary (the SIB mechanism,
--    20261015091207_sms_statement_summary). It prints no due date, so sms_templates gains
--    due_on_receipt: a summary template with it set may omit due_date, and
--    private.apply_sms_statement takes the day the SMS arrived (Dubai) as the due date. Every
--    other template is unchanged (the flag defaults to false). Wio closes at month end ("statement
--    closes at 11:59 PM on 2026-09-30"), so Wio credit_card accounts get cycle_close_day = 31
--    (month end) where unset; the 1 Oct SMS then makes the 30 Sep statement, which
--    v_account_balances anchors on (activity after it by date, as for every SMS statement).
-- 2. The autopay's debit leg: sms_templates gains pays_from_current_account (payment templates
--    only). When such an SMS creates or links a card payment, private.add_payment_leg adds a
--    transfer_out on the bank's one active current account, marked transactions.leg_of_txn_code
--    = the payment, and pairs the two in card_transfers (cash flow: one card_repayment, counted
--    once). The leg has no evidence of its own (the SMS is the payment's, one active evidence row
--    per SMS): refresh_transaction derives its facts from the payment and refreshes it whenever
--    the payment changes; it is void ('payment_gone') while the payment is not live. A later
--    alert from the bank for the same debit links to the leg as its evidence (match_sms), which
--    is right: it is the same money.
--
-- Content (CLAUDE.md §1.9): the summary template is inserted when absent; the ignored-notices
-- template drops the due-today phrase only while its pattern is the seed's; the autopay template
-- gets the flag only while it is unset; cycle_close_day only where null. On deploy, Wio's ignored
-- due-today SMS are processed again (oldest first, so the first summary of a cycle wins) and every
-- existing autopay payment gets its leg.

-- ── 1. sms_templates flags ──────────────────────────────────────────────────
alter table public.sms_templates
  add column due_on_receipt boolean not null default false,
  add column pays_from_current_account boolean not null default false;
comment on column public.sms_templates.due_on_receipt is
  'statement_summary only: the SMS prints no due date; it is due the day it arrives (Wio "credit payment is due today").';
comment on column public.sms_templates.pays_from_current_account is
  'payment only: the bank draws the payment from its own current account (Wio Credit autopay), so the payment gets a transfer_out leg there.';
alter table public.sms_templates add constraint sms_templates_due_on_receipt_check
  check (not due_on_receipt or msg_kind = 'statement_summary');
alter table public.sms_templates add constraint sms_templates_pays_from_current_check
  check (not pays_from_current_account or msg_kind = 'payment');
alter table public.sms_templates drop constraint sms_templates_summary_fields_check;
alter table public.sms_templates add constraint sms_templates_summary_fields_check
  check (msg_kind <> 'statement_summary' or (field_groups ? 'amount' and (field_groups ? 'due_date' or due_on_receipt)));

-- ── 2. transactions.leg_of_txn_code ─────────────────────────────────────────
alter table public.transactions add column leg_of_txn_code text;
alter table public.transactions add constraint transactions_leg_of_fkey foreign key (profile_code, leg_of_txn_code)
  references public.transactions(profile_code, txn_code) on delete cascade;
create unique index transactions_leg_of_uq on public.transactions(leg_of_txn_code) where leg_of_txn_code is not null;
comment on column public.transactions.leg_of_txn_code is
  'The card payment this row is the other leg of (a payment drawn from a bank account, e.g. the Wio Credit autopay). Its facts derive from that payment (private.refresh_transaction).';

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
begin
  select * into s from public.sms_messages where sms_code = p_sms_code;
  if s.account_code is null or s.amount is null then
    return 'unknown_card';
  end if;

  select coalesce(a.cycle_close_day,
           (select extract(day from h.period_end)::int from public.statements h
            where h.account_code = a.account_code and h.kind = 'history_extract' and h.status = 'active'
              and h.period_end is not null
            order by h.statement_date desc limit 1))
  into v_day
  from public.accounts a where a.account_code = s.account_code;
  if v_day is null then
    update public.sms_messages set parsed_fields = parsed_fields || '{"statement":"cycle_unknown"}'::jsonb
    where sms_code = p_sms_code;
    return 'cycle_unknown';
  end if;

  -- The cycle that closed on or before the day the SMS arrived; day 31 means month end.
  v_received := public.dubai_date(s.received_at);
  v_close := make_date(extract(year from v_received)::int, extract(month from v_received)::int,
                       least(v_day, extract(day from (date_trunc('month', v_received) + interval '1 month - 1 day'))::int));
  if v_close > v_received then
    v_close := (date_trunc('month', v_received) - interval '1 day')::date;
    v_close := make_date(extract(year from v_close)::int, extract(month from v_close)::int,
                         least(v_day, extract(day from v_close)::int));
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
    t.status := case when t.voided_at is not null then 'void'
                     when exists (select 1 from public.accounts a
                                  where a.account_code = t.account_code and a.kind in ('current', 'savings'))
                       then 'posted'
                     -- A transfer out of a credit line is final too: no statement line will post it.
                     when t.kind in ('transfer_in', 'transfer_out') then 'posted'
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


-- ── 3. the payment's other leg ──────────────────────────────────────────────
-- p_txn_code: a live card payment (credit on a credit_card account). Adds a transfer_out on the
-- bank's one active current account (none, or several: no leg) and pairs the two in
-- card_transfers. Idempotent: returns the existing leg.
create or replace function private.add_payment_leg(p_txn_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  t public.transactions%rowtype;
  v_card public.accounts%rowtype;
  v_from text;
  v_n int;
  v_leg text;
  v_desc text;
  v_displaced text[];
begin
  select * into t from public.transactions where txn_code = p_txn_code;
  if not found or t.kind <> 'payment' or t.direction <> 'credit' or t.status not in ('pending', 'posted') then
    return null;
  end if;
  select x.txn_code into v_leg from public.transactions x
  where x.profile_code = t.profile_code and x.leg_of_txn_code = p_txn_code;
  if v_leg is not null then
    return v_leg;
  end if;
  select * into v_card from public.accounts where account_code = t.account_code;
  if v_card.kind <> 'credit_card' then
    return null;
  end if;
  select count(*), min(a.account_code) into v_n, v_from
  from public.accounts a
  where a.profile_code = t.profile_code and a.bank_code = v_card.bank_code and a.status = 'active'
    and a.kind = 'current';
  if v_n <> 1 then
    return null;
  end if;

  v_desc := 'AUTOPAY ' || upper(coalesce(v_card.nickname, v_card.product_name, v_card.bank_code || ' CARD'));
  insert into public.transactions (profile_code, account_code, kind, direction, txn_date, txn_at, description,
    merchant_code, amount_original, currency_original, amount_aed, amount_aed_is_estimate, fx_rate,
    amount_source, status, leg_of_txn_code)
  values (t.profile_code, v_from, 'transfer_out', 'debit', t.txn_date, t.txn_at, v_desc,
    private.resolve_merchant(v_desc), t.amount_original, t.currency_original, t.amount_aed,
    t.amount_aed_is_estimate, t.fx_rate, t.amount_source, 'posted', p_txn_code)
  returning txn_code into v_leg;
  perform private.refresh_transaction(v_leg);

  -- The two legs are the same money. The insert's trigger may have paired either with another
  -- candidate of the same amount; the known pair wins and the displaced side looks again.
  select coalesce(array_agg(case when x.from_txn_code = v_leg then x.to_txn_code else x.from_txn_code end), '{}')
  into v_displaced
  from public.card_transfers x
  where x.from_txn_code = v_leg or x.to_txn_code = p_txn_code;
  delete from public.card_transfers x where x.from_txn_code = v_leg or x.to_txn_code = p_txn_code;
  insert into public.card_transfers (profile_code, from_txn_code, to_txn_code)
  values (t.profile_code, v_leg, p_txn_code);
  perform private.link_card_transfer(d) from unnest(v_displaced) d where d <> v_leg and d <> p_txn_code;
  return v_leg;
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


-- ── 4. content ──────────────────────────────────────────────────────────────
-- Wio Credit closes at month end (day 31 = the month's last day in apply_sms_statement).
update public.accounts set cycle_close_day = 31
where bank_code = 'WIO' and kind = 'credit_card' and cycle_close_day is null;

insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source, due_on_receipt)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed', true
from (values
 ('WIO', 'Wio credit statement summary', '^Wio',
  'credit payment is due today\. Statement amount: ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?)',
  '{"currency":1,"amount":2}', null, 'statement_summary', 10,
  '[{"sender":"WioPersonal","body":"Your credit payment is due today. Statement amount: AED 19,082. Auto-pay will be processed at 9:00 PM tonight. You can adjust the repayment amount in the app before then.",
     "expect":{"currency":"AED","amount":"19082.00"}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);

-- The due-today notice is no longer one of the ignored notices (only while the seed's pattern).
update public.sms_templates
set body_pattern = '(estimated repayment is|has been added as a [a-z ]*beneficiary)',
    examples = (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(examples) e
                where e->>'body' !~* 'credit payment is due today')
where bank_code = 'WIO' and name = 'Wio credit notices (ignored)'
  and body_pattern = '(estimated repayment is|credit payment is due today|has been added as a [a-z ]*beneficiary)';

update public.sms_templates set pays_from_current_account = true
where bank_code = 'WIO' and name = 'Wio credit autopay' and msg_kind = 'payment' and not pays_from_current_account;

-- Due-today notices already stored as ignored become statements, oldest first (the first summary
-- of a cycle wins); then every autopay payment gets its debit leg.
do $$
declare
  r record;
begin
  for r in
    select s.sms_code
    from public.sms_messages s
    join public.sms_templates t on t.bank_code = 'WIO' and t.name = 'Wio credit statement summary'
    where s.bank_code = 'WIO' and s.parse_status = 'ignored'
      and private.apply_sms_template(t, s.sender, s.body) is not null
    order by s.received_at, s.sms_code
  loop
    perform private.process_sms(r.sms_code);
  end loop;

  for r in
    select e.txn_code
    from public.sms_messages s
    join public.sms_templates t on t.template_code = s.template_code and t.pays_from_current_account
    join public.transaction_evidence e on e.sms_code = s.sms_code and e.is_active and e.role <> 'duplicate'
    order by s.received_at, s.sms_code
  loop
    perform private.add_payment_leg(r.txn_code);
  end loop;
end;
$$;

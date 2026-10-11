-- FX estimates only learn from purchase rates, and a posted estimate shows its rate.
--
-- FAB prints a "VAT ON SERVICE CHARGES" row under each foreign purchase with that purchase's
-- currency and original amount beside the AED VAT ("KES 5000.00 … 0.27"). Parsers up to
-- 2026.10.6 stored it as a KES line with fx_rate 0.000054; 2026.10.7 makes it an AED line, and a
-- re-parse (requeue_documents) supersedes the old lines. private.estimate_fx step 1 took the
-- bank's latest statement rate for the currency from any line, so a VAT row's rate priced
-- estimates: SIB USD 249.99 showed as AED 1.72 (rate 0.00689655 from a FAB VAT row), and after
-- 20261011000100 the same would hit FAB's own pending USD SMS.
--
-- Step 1 now reads only current purchase, refund and cash-advance lines: rows whose two amounts
-- are one conversion. Fees, interest, payments and adjustments never set a rate, and a line a
-- re-parse superseded no longer counts. Ties on the date resolve by line_code, not at random.
--
-- refresh_transaction: a posted line without a printed AED amount (SIB history rows) kept
-- fx_rate null even though its amount was estimated with a rate; it now stores that rate, as a
-- pending SMS row already does. Body as in 20261011000100 otherwise.
--
-- Every estimate is re-derived at the end.

create or replace function private.estimate_fx(p_profile text, p_currency text, p_bank text)
returns numeric
language sql
stable
set search_path = ''
as $$
  select case when p_currency = 'AED' then 1::numeric else coalesce(
    (select l.fx_rate from public.statement_lines l
       join public.accounts a on a.account_code = l.account_code
      where l.profile_code = p_profile and l.currency_original = p_currency and l.fx_rate is not null
        and a.bank_code = p_bank and l.is_current and l.kind in ('purchase', 'refund', 'cash_advance')
      order by l.txn_date desc, l.line_code desc limit 1),
    round(coalesce(case p_currency when 'USD' then 3.6725 end,
                   (select r.aed_per_unit from public.fx_rates r where r.currency = p_currency))
          * (1 + coalesce((select f.markup from private.bank_fx_fees f where f.bank_code = p_bank), 0)), 8)
  ) end
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
      v_fx := coalesce(l.fx_rate, private.estimate_fx(t.profile_code, l.currency_original, private.account_bank(l.account_code)));
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
                                  coalesce(s.bank_code, private.account_bank(coalesce(s.account_code, t.account_code))));
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

-- ── re-derive every estimate (pending SMS and posted rows without a printed AED amount) ──
do $$
declare
  r record;
  v_state text;
  v_msg text;
begin
  for r in
    select t.txn_code, t.profile_code from public.transactions t
    where t.amount_aed_is_estimate or (t.amount_aed is null and t.currency_original <> 'AED')
    order by t.txn_code
  loop
    begin
      perform private.refresh_transaction(r.txn_code);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('fx_estimate_purchase_rates_backfill', r.profile_code, r.txn_code, v_state, v_msg);
    end;
  end loop;
end;
$$;

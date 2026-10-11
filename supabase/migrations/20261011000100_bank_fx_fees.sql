-- Bank-aware FX estimates: a foreign amount is estimated with the card's own bank's rate.
--
-- An SIB covered card bought INR 28,400.00 on 2026-10-03; SIB billed AED 1,123.72 (0.03956761
-- AED/INR). The app showed AED 1,147.83 (0.04041655): private.estimate_fx took the profile's
-- latest INR statement rate from *any* bank, so another card's markup and date leaked into SIB.
-- SIB never prints a rate (history exports carry only the foreign amount, monthly statements
-- only AED), so its foreign rows always fall through to the estimate.
--
-- The INR/AED mid-market rate that day was ≈ 0.03816247 (USD/INR ≈ 96.23 at the 3.6725 peg), so
-- SIB billed mid × ≈ 1.0368: its 2.5% non-AED fee on top of the card scheme's charge.
--
-- Markup model, from each bank's published fee (2026 schedules / key facts statements):
--   fee charged on top of scheme charges → (1 + fee) × 1.0115 − 1
--     (Visa/Mastercard ≈ 1.15% incl. VAT: Mastercard 0.9% cross-border + 0.2% conversion, as the
--      ENBD and Emirates Islamic KFS state "approximately 1.15%")
--   margin quoted on the wholesale rate including processing fees → the margin itself
-- It reproduces the SIB bill: 28,400 × 0.03816247 × 1.036788 = AED 1,123.69 (billed 1,123.72).
--   SIB      2.50% + scheme  (covered cards tariff, Cashback/Smiles)          → 0.036788
--   FAB      2.61% + scheme  (Cashback Mastercard World: SoF 07/2026 "up to 2.61%",
--                             = KFS 2.49% + 5% VAT; scheme ≈ 1%)                → 0.037900
--   ENBD     1.99% + scheme  (noon One Visa; credit card KFS, "approx. 1.15%") → 0.031629
--   EIB      2.54% + scheme  (cards SoC, non-AED; Emarati/Skywards Black 2.30%) → 0.037192
--   MASHREQ  2.89% + scheme  (cards KFS 05/2026 spread; VAT n/a)              → 0.040732
--   ADCB     2.99% all-in    (Infinite Visa: margin on the wholesale rate incl. the
--                             processing fee, VAT inclusive; Traveller card 0%) → 0.029900
-- Checked against the cards in use: SIB Cashback covered card, FAB Cashback Mastercard World,
-- ENBD noon One Visa, ADCB Infinite Visa. EIB and MASHREQ use the bank's standard non-AED fee.
-- The table is per bank, not per product: another product with its own FX rate (ADCB Traveller,
-- EIB Emarati) is over-estimated until its first statement prints a rate (step 1 below).
--
-- private.estimate_fx(profile, currency, bank) now:
--   AED                    → 1
--   1. that bank's latest statement rate for the currency on this profile (already marked up)
--   2. the USD peg, else public.fx_rates (mid-market), × (1 + private.bank_fx_fees.markup)
-- Another bank's statement rate is never used. Every bank has a fee row (pgTAP 05_fx_rates);
-- an SMS with no known bank gets the bare mid rate.
-- The bank-blind two-argument estimate_fx is dropped so no caller keeps using it; its callers
-- (new_transaction_from_line/_sms, refresh_transaction, match_sms) are redefined unchanged
-- except for passing the bank. Existing estimates are re-derived at the end.

-- ── reference data: all-in FX markup per bank ───────────────────────────────
create table private.bank_fx_fees (
  bank_code text primary key references public.banks(bank_code),
  markup numeric(8,6) not null check (markup >= 0 and markup < 0.2),  -- fraction over mid-market
  note text not null,
  updated_at timestamptz not null default now()
);
comment on table private.bank_fx_fees is
  'All-in markup a bank''s card adds to the mid-market rate on non-AED spend (network spread + bank fee + VAT). Used only by private.estimate_fx when the bank has no statement rate.';
-- `private` is unreachable for client roles; RLS without any policy and no grants keeps it so.
alter table private.bank_fx_fees enable row level security;
revoke all on private.bank_fx_fees from public, anon, authenticated, service_role;

insert into private.bank_fx_fees (bank_code, markup, note) values
  ('SIB',     0.036788, '2.5% non-AED admin fee + scheme ~1.15%; INR 28,400.00 billed AED 1,123.72 on 2026-10-03 (model 1,123.69)'),
  ('FAB',     0.037900, 'Cashback Mastercard World: 2.61% (2.49% + 5% VAT, SoF 07/2026) + scheme ~1.15%'),
  ('ENBD',    0.031629, 'noon One Visa: 1.99% currency conversion fee + Visa ~1.15% (KFS)'),
  ('EIB',     0.037192, '2.54% non-AED fee + scheme ~1.15% (SoC); Emarati/Skywards Black 2.30%, Amazon 2.34%'),
  ('MASHREQ', 0.040732, 'standard cards: 2.89% FX spread (KFS 05/2026, VAT n/a) + scheme ~1.15%'),
  ('ADCB',    0.029900, 'Infinite Visa: 2.99% margin on wholesale rate incl. processing fee, VAT inclusive; Traveller 0%')
on conflict (bank_code) do nothing;

-- ── estimate ────────────────────────────────────────────────────────────────
create or replace function private.account_bank(p_account_code text)
returns text
language sql
stable
set search_path = ''
as $$
  select a.bank_code from public.accounts a where a.account_code = p_account_code
$$;

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
        and a.bank_code = p_bank
      order by l.txn_date desc limit 1),
    round(coalesce(case p_currency when 'USD' then 3.6725 end,
                   (select r.aed_per_unit from public.fx_rates r where r.currency = p_currency))
          * (1 + coalesce((select f.markup from private.bank_fx_fees f where f.bank_code = p_bank), 0)), 8)
  ) end
$$;

-- ── callers (bodies as in 20261009000100 / 20261008001600; only the bank is new) ──
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
    v_aed := round(l.amount_original * coalesce(l.fx_rate, private.estimate_fx(l.profile_code, l.currency_original, private.account_bank(l.account_code))), 2);
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
    v_fx := private.estimate_fx(s.profile_code, s.currency, coalesce(s.bank_code, private.account_bank(s.account_code)));
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
      v_fx := coalesce(l.fx_rate, private.estimate_fx(t.profile_code, l.currency_original, private.account_bank(l.account_code)));
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

  -- 1. Same alert delivered twice (bank resend / automation double-fire). Two
  --    alerts that print different available limits are two purchases (DB-15).
  select e.txn_code into v_txn
  from public.sms_messages o
  join public.transaction_evidence e on e.sms_code = o.sms_code and e.is_active
  where o.profile_code = s.profile_code and o.sms_code <> s.sms_code
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
                       else round(s.amount * private.estimate_fx(s.profile_code, s.currency, coalesce(s.bank_code, private.account_bank(s.account_code))), 2) end;
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
    and t.direction = case when s.msg_kind in ('refund', 'reversal', 'payment') then 'credit' else 'debit' end
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

drop function private.estimate_fx(text, text);

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
      perform private.log_job_error('bank_fx_fees_backfill', r.profile_code, r.txn_code, v_state, v_msg);
    end;
  end loop;
end;
$$;

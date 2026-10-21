-- ADCB consolidated statement of accounts (tasks/todo.md §9, parse-v1 `account_statement_pdf`).
--
-- One monthly PDF holds every savings/current account (number, IBAN, balance, lines with a
-- running balance), the fixed deposits and the credit-card summaries.
--
-- 1. documents.kind adds 'account_statement_pdf'; statement_lines.kind adds transfer_in and
--    transfer_out (a bank line the parser can't name keeps its direction, as an account SMS does).
-- 2. accounts.account_number / iban: a bank account's full number and IBAN, filled from its
--    statement (account_ref stays the suffix alerts print).
-- 3. balance_checkpoints.source adds 'statement' (with stmt_code): the closing balance as of the
--    period's last moment in Dubai.
-- 4. A bank statement resolves its account by number or ref (never through the card resolver),
--    creating it when absent; its lines are evidence and match the account's SMS transactions
--    like a card statement's. reconcile_statement balances a bank account the other way round
--    (money in adds).
-- 5. Deposits: each statement deposit is a `deposit` holding keyed by holdings.external_ref
--    (created, or the profile's one unnumbered deposit at that bank claimed) with an 'import'
--    valuation; the newest statement sets rate and maturity. A deposit's value is its latest
--    imported value plus simple profit since (capped at maturity); the principal formula stays
--    for days before the first import.
-- 6. Card summaries refresh a known card account's credit limit (ADCB card PDFs don't print it).
-- 7. Card-only statement readers: v_statement_payments and statement_cycles skip bank statements.

-- ── 1. kinds ────────────────────────────────────────────────────────────────
alter table public.documents drop constraint documents_kind_check;
alter table public.documents add constraint documents_kind_check
  check (kind in ('statement_pdf', 'history_pdf', 'account_statement_pdf'));
alter table public.statement_lines drop constraint statement_lines_kind_check;
alter table public.statement_lines add constraint statement_lines_kind_check check (kind in
  ('purchase', 'refund', 'payment', 'fee', 'interest', 'cash_advance', 'adjustment', 'transfer_in', 'transfer_out'));

-- ── 2. accounts ─────────────────────────────────────────────────────────────
alter table public.accounts add column account_number text
  check (account_number is null or account_number ~ '^[0-9]{6,34}$');
alter table public.accounts add column iban text
  check (iban is null or iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$');
alter table public.accounts add constraint accounts_bank_columns_check
  check (kind <> 'credit_card' or (account_number is null and iban is null));
create unique index accounts_bank_number_uq on public.accounts(profile_code, bank_code, account_number)
  where account_number is not null;
comment on column public.accounts.account_number is
  'Bank accounts: the full account number, from the bank''s statement.';
comment on column public.accounts.iban is 'Bank accounts: the IBAN, from the bank''s statement.';

-- ── 3. balance_checkpoints ──────────────────────────────────────────────────
alter table public.balance_checkpoints drop constraint balance_checkpoints_source_check;
alter table public.balance_checkpoints add constraint balance_checkpoints_source_check
  check (source in ('manual', 'sms', 'statement'));
alter table public.balance_checkpoints add column stmt_code text
  references public.statements(stmt_code) on delete cascade;
alter table public.balance_checkpoints add constraint balance_checkpoints_statement_check
  check (source <> 'statement' or stmt_code is not null);
create index balance_checkpoints_stmt_idx on public.balance_checkpoints(stmt_code) where stmt_code is not null;

-- The statement's closing balance as of the end of its last day in Dubai. Evidence: a re-parse
-- with the same balance adds nothing; a different one is a newer checkpoint.
create or replace function private.record_statement_balance(
  p_profile text, p_account text, p_stmt text, p_period_end date, p_balance numeric
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_as_of timestamptz := ((p_period_end + 1)::timestamp at time zone 'Asia/Dubai') - interval '1 millisecond';
begin
  if p_balance is null or p_period_end is null then
    return;
  end if;
  if exists (select 1 from public.balance_checkpoints
             where stmt_code = p_stmt and as_of = v_as_of and balance = p_balance) then
    return;
  end if;
  insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source, stmt_code)
  values (p_profile, p_account, v_as_of, p_balance, 'statement', p_stmt);
end;
$$;

-- ── 4. bank statements ──────────────────────────────────────────────────────
-- The bank account a statement's `account` object names: by full number, else by the suffix
-- alerts print (account_ref, or any ref the number ends with), else a new account.
create or replace function private.resolve_bank_statement_account(p_profile text, p_bank text, p_account jsonb)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_number text := p_account->>'number';
  v_ref text := p_account->>'ref';
  v_iban text := nullif(p_account->>'iban', '');
  v_kind text := p_account->>'kind';
  v_product text := left(nullif(btrim(p_account->>'product'), ''), 120);
  v_currency text := upper(coalesce(p_account->>'currency', 'AED'));
  v_code text;
  v_n int;
  v_currency_have text;
begin
  if v_number is null or v_number !~ '^[0-9]{6,34}$' or v_ref is null or v_ref !~ '^[0-9]{3,12}$'
     or right(v_number, length(v_ref)) <> v_ref or v_kind not in ('current', 'savings') then
    raise exception 'a bank statement names its account by number, ref and kind' using errcode = '22023';
  end if;

  select account_code into v_code from public.accounts
  where profile_code = p_profile and bank_code = p_bank and account_number = v_number;
  if v_code is null then
    select count(*), min(account_code) into v_n, v_code from public.accounts
    where profile_code = p_profile and bank_code = p_bank and kind in ('current', 'savings')
      and account_number is null and account_ref is not null and right(v_number, length(account_ref)) = account_ref;
    if v_n > 1 then
      select account_code into v_code from public.accounts
      where profile_code = p_profile and bank_code = p_bank and kind in ('current', 'savings')
        and account_number is null and account_ref = v_ref;
      if v_code is null then
        raise exception '% has % bank accounts ending like %; cannot choose one', p_bank, v_n, v_ref
          using errcode = '22023';
      end if;
    end if;
  end if;

  if v_code is null then
    if exists (select 1 from public.accounts
               where profile_code = p_profile and bank_code = p_bank and account_ref = v_ref) then
      raise exception 'the % card account holds ref %, which this bank statement names', p_bank, v_ref
        using errcode = '22023';
    end if;
    insert into public.accounts (profile_code, bank_code, kind, account_ref, product_name, currency, account_number, iban)
    values (p_profile, p_bank, v_kind, v_ref, v_product, v_currency, v_number, v_iban)
    returning account_code into v_code;
    return v_code;
  end if;

  select currency into v_currency_have from public.accounts where account_code = v_code;
  if v_currency_have <> v_currency then
    raise exception 'the % account ending % is in %, its statement in %', p_bank, v_ref, v_currency_have, v_currency
      using errcode = '22023';
  end if;
  update public.accounts set
    account_number = coalesce(account_number, v_number),
    iban = coalesce(iban, v_iban),
    product_name = coalesce(product_name, v_product)
  where account_code = v_code
    and (account_number is null or (iban is null and v_iban is not null) or (product_name is null and v_product is not null));
  return v_code;
end;
$$;

CREATE OR REPLACE FUNCTION private.reconcile_statement(p_stmt_code text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  st public.statements%rowtype;
  v_debits numeric;
  v_credits numeric;
  v_lines int;
  v_unpriced int;
  v_dropped int;
  v_purchase_lines int;
  v_sms_lines int;
  v_held int;
  v_unmatched int;
  v_mismatch boolean := false;
  v_checks jsonb := '{}'::jsonb;
  v_status text := 'ok';
  v_expected numeric;
  v_bank boolean;
begin
  select * into st from public.statements where stmt_code = p_stmt_code;
  -- A bank account's balance grows with credits; a card's balance owed grows with debits.
  v_bank := exists (select 1 from public.accounts a where a.account_code = st.account_code
                    and a.kind in ('current', 'savings'));

  -- An SMS statement has no lines: its check is the ledger against the SMS closing balance.
  select v.recon_status, v.recon_checks into v_status, v_checks
  from public.v_sms_statements v where v.stmt_code = p_stmt_code;
  if found then
    insert into public.statement_recon (stmt_code, profile_code, status, checks, computed_at)
    values (p_stmt_code, st.profile_code, v_status, v_checks, now())
    on conflict (stmt_code) do update set status = excluded.status, checks = excluded.checks, computed_at = now();
    return v_status;
  end if;
  v_checks := '{}'::jsonb;
  v_status := 'ok';

  -- A line without a printed AED amount (allowed by parse-v1, e.g. Mashreq FX rows)
  -- counts at its printed rate when there is one.
  select coalesce(sum(coalesce(amount_aed, round(amount_original * fx_rate, 2))) filter (where direction = 'debit'), 0),
         coalesce(sum(coalesce(amount_aed, round(amount_original * fx_rate, 2))) filter (where direction = 'credit'), 0),
         count(*),
         count(*) filter (where amount_aed is null),
         count(*) filter (where kind = 'purchase' and direction = 'debit')
  into v_debits, v_credits, v_lines, v_unpriced, v_purchase_lines
  from public.statement_lines
  where profile_code = st.profile_code and stmt_code = p_stmt_code and is_current;
  select count(*) into v_dropped from public.statement_lines
  where profile_code = st.profile_code and stmt_code = p_stmt_code and not is_current;

  select count(distinct l.line_code) into v_sms_lines
  from public.statement_lines l
  join public.transaction_evidence le on le.line_code = l.line_code and le.is_active
  join public.transaction_evidence se on se.txn_code = le.txn_code and se.is_active and se.evidence_type = 'sms'
  where l.profile_code = st.profile_code and l.stmt_code = p_stmt_code and l.is_current
    and l.kind = 'purchase' and l.direction = 'debit';

  select count(*) into v_held
  from public.match_reviews r join public.statement_lines l on l.line_code = r.subject_code
  where r.profile_code = st.profile_code and r.subject_type = 'statement_line' and r.status = 'open'
    and l.stmt_code = p_stmt_code;

  v_checks := jsonb_build_object(
    'line_count', v_lines,
    'sum_debits', v_debits::text,
    'sum_credits', v_credits::text,
    'held_lines', v_held,
    'sms_coverage', case when v_purchase_lines > 0 then round(v_sms_lines::numeric / v_purchase_lines, 3) end
  );
  if v_unpriced > 0 then
    v_checks := v_checks || jsonb_build_object('unpriced_lines', v_unpriced);
  end if;

  if st.kind = 'statement' then
    if st.total_debits is not null then
      v_checks := v_checks || jsonb_build_object('debits_match', abs(st.total_debits - v_debits) <= 0.01);
      if abs(st.total_debits - v_debits) > 0.01 then v_mismatch := true; end if;
    end if;
    if st.total_credits is not null then
      v_checks := v_checks || jsonb_build_object('credits_match', abs(st.total_credits - v_credits) <= 0.01);
      if abs(st.total_credits - v_credits) > 0.01 then v_mismatch := true; end if;
    end if;
    if st.opening_balance is not null and st.closing_balance is not null then
      v_expected := case when v_bank then st.opening_balance - v_debits + v_credits
                         else st.opening_balance + v_debits - v_credits end;
      v_checks := v_checks || jsonb_build_object('balance_equation', abs(v_expected - st.closing_balance) <= 0.01,
                                                 'expected_closing', v_expected::text);
      if abs(v_expected - st.closing_balance) > 0.01 then v_mismatch := true; end if;
    end if;
    if v_mismatch then
      -- Lines with no AED amount make the sums uncertain, not wrong.
      v_status := case when v_unpriced > 0 then 'warn' else 'fail' end;
    end if;
    -- No lines although the header shows activity, or every line it had was
    -- superseded: never 'ok' (DP-08).
    if v_lines = 0 and v_status = 'ok'
       and (coalesce(st.total_debits, 0) > 0 or coalesce(st.total_credits, 0) > 0
            or st.opening_balance is distinct from st.closing_balance or v_dropped > 0) then
      v_status := 'warn';
      v_checks := v_checks || jsonb_build_object('no_lines', true, 'superseded_lines', v_dropped);
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
      where t.profile_code = st.profile_code and t.account_code = st.account_code and t.status = 'pending'
        and t.txn_date between st.period_start and st.period_end - 3
      on conflict do nothing;
      select count(*) into v_unmatched from public.transactions t
      where t.profile_code = st.profile_code and t.account_code = st.account_code and t.status = 'pending'
        and t.txn_date between st.period_start and st.period_end - 3;
      v_checks := v_checks || jsonb_build_object('unmatched_sms', v_unmatched);
      if v_unmatched > 0 and v_status = 'ok' then v_status := 'warn'; end if;
    end if;
  end if;
  if v_held > 0 and v_status = 'ok' then
    v_status := 'warn';
  end if;
  -- A history extract is a window with no totals: nothing to reconcile (DP-08).
  if st.kind = 'history_extract' then
    v_status := 'n/a';
  end if;

  insert into public.statement_recon (stmt_code, profile_code, status, checks, computed_at)
  values (p_stmt_code, st.profile_code, v_status, v_checks, now())
  on conflict (stmt_code) do update set status = excluded.status, checks = excluded.checks, computed_at = now();

  -- The SMS statement of the same cycle takes its lines from this export: refresh its check.
  if st.kind = 'history_extract' then
    perform private.reconcile_statement(v.stmt_code)
    from public.v_sms_statements v where v.history_stmt_code = p_stmt_code;
  end if;
  return v_status;
end;
$function$;

-- ── 5. deposits ─────────────────────────────────────────────────────────────
-- p_deposits: parse-v1 `deposits[]`. Returns counts and warnings (shown on the document).
create or replace function private.import_statement_deposits(p_profile text, p_bank text, p_deposits jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  e jsonb;
  h public.holdings;
  v_number text;
  v_as_of date;
  v_amount numeric(14,2);
  v_rate numeric;
  v_maturity date;
  v_currency text;
  v_product text;
  v_numbers text[] := '{}';
  v_warnings jsonb := '[]'::jsonb;
  n_created int := 0;
  n_claimed int := 0;
  n_valued int := 0;
begin
  for e in select * from jsonb_array_elements(coalesce(p_deposits, '[]'::jsonb)) loop
    v_number := e->>'number';
    begin
      v_as_of := (e->>'as_of')::date;
      v_amount := (e->>'amount')::numeric(14,2);
      v_rate := (e->>'rate_pct')::numeric;
      v_maturity := (e->>'maturity_on')::date;
    exception when others then
      raise exception 'a statement deposit needs as_of, amount, rate_pct and maturity_on' using errcode = '22023';
    end;
    v_currency := upper(coalesce(e->>'currency', 'AED'));
    v_product := left(coalesce(nullif(btrim(e->>'product'), ''), p_bank || ' deposit'), 80);
    if v_number is null or v_number !~ '^[A-Za-z0-9-]{3,40}$' or v_as_of is null or v_amount is null
       or v_amount <= 0 or v_rate is null or v_rate < 0 or v_rate > 100 or v_maturity is null then
      raise exception 'bad statement deposit' using errcode = '22023';
    end if;
    v_numbers := v_numbers || v_number;

    select * into h from public.holdings where profile_code = p_profile and external_ref = v_number;
    if not found then
      -- The profile's one deposit at this bank without a number is this one.
      update public.holdings set external_ref = v_number
      where holding_code = (
        select min(holding_code) from public.holdings
        where profile_code = p_profile and kind = 'deposit' and status = 'active' and external_ref is null
          and currency = v_currency
          and (institution ilike '%' || p_bank || '%' or name ilike '%' || p_bank || '%')
        having count(*) = 1)
      returning * into h;
      if found then
        n_claimed := n_claimed + 1;
      end if;
    end if;

    if h.holding_code is null then
      if v_maturity <= v_as_of then
        v_warnings := v_warnings || to_jsonb(format(
          'Deposit ending %s matured on %s; it was not added', right(v_number, 4), v_maturity));
        continue;
      end if;
      -- Principal and start are the statement's: the owner corrects them if they know better.
      insert into public.holdings (profile_code, name, kind, currency, institution, principal, rate_pct,
                                   acquired_on, maturity_on, external_ref, notes)
      values (p_profile, v_product, 'deposit', v_currency, p_bank, v_amount, v_rate, v_as_of, v_maturity, v_number,
              format('Added from the %s statement of %s. Set the principal and start date if you know them.',
                     p_bank, to_char(v_as_of, 'DD Mon YYYY')))
      returning * into h;
      perform private.sync_holding_cost_flow(h.holding_code);
      n_created := n_created + 1;
    elsif h.kind <> 'deposit' or h.status <> 'active' then
      v_warnings := v_warnings || to_jsonb(format(
        'Deposit ending %s is in the statement but is closed or not a deposit in this ledger; not updated',
        right(v_number, 4)));
      continue;
    elsif h.currency <> v_currency then
      v_warnings := v_warnings || to_jsonb(format(
        'Deposit ending %s is in %s, its holding in %s; not updated', right(v_number, 4), v_currency, h.currency));
      continue;
    end if;

    -- The newest statement sets the terms (a rollover changes the maturity; the value carries on).
    if not exists (select 1 from public.holding_valuations v
                   where v.holding_code = h.holding_code and v.source = 'import' and v.as_of > v_as_of)
       and (h.rate_pct, h.maturity_on) is distinct from (v_rate, v_maturity) and v_maturity > h.acquired_on then
      update public.holdings set rate_pct = v_rate, maturity_on = v_maturity where holding_code = h.holding_code;
    end if;

    -- Values are evidence: a new row only when the day has no manual value and its latest import differs.
    continue when exists (select 1 from public.holding_valuations
                          where holding_code = h.holding_code and as_of = v_as_of and source = 'manual');
    continue when (select v.value from public.holding_valuations v
                   where v.holding_code = h.holding_code and v.as_of = v_as_of and v.source = 'import'
                   order by v.created_at desc, v.valuation_code desc limit 1) = v_amount;
    insert into public.holding_valuations (profile_code, holding_code, as_of, value, source)
    values (p_profile, h.holding_code, v_as_of, v_amount, 'import');
    n_valued := n_valued + 1;
  end loop;

  -- A deposit this bank's statements used to list and this one doesn't: matured or broken.
  if jsonb_array_length(coalesce(p_deposits, '[]'::jsonb)) > 0 or exists (
       select 1 from public.holdings
       where profile_code = p_profile and kind = 'deposit' and status = 'active' and external_ref is not null
         and institution ilike p_bank) then
    select v_warnings || coalesce(jsonb_agg(to_jsonb(format(
             'Deposit ending %s is not in this statement: it may have matured or been closed. Close it in Wealth if so.',
             right(x.external_ref, 4))) order by x.external_ref), '[]'::jsonb)
    into v_warnings
    from public.holdings x
    where x.profile_code = p_profile and x.kind = 'deposit' and x.status = 'active' and x.external_ref is not null
      and x.institution ilike p_bank and x.external_ref <> all (v_numbers)
      and exists (select 1 from public.holding_valuations v where v.holding_code = x.holding_code and v.source = 'import');
  end if;

  return jsonb_build_object('created', n_created, 'claimed', n_claimed, 'valued', n_valued, 'warnings', v_warnings);
end;
$$;

-- A deposit is worth its latest imported value plus simple profit since, to maturity; before
-- any import (or with none), its principal plus simple profit from the start.
CREATE OR REPLACE FUNCTION private.holding_values(p_profile_code text, p_at timestamp with time zone)
 RETURNS TABLE(holding_code text, quote text, aed_per_gram numeric, price_as_of timestamp with time zone, fine_factor numeric, value numeric, value_aed numeric, value_as_of date, is_stale boolean, is_estimate boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with d as (select public.dubai_date(p_at) as day)
  select h.holding_code, m.quote, m.aed_per_gram, m.as_of, m.factor,
         v.value, case when h.currency = 'AED' then v.value else private.to_aed(v.value, h.currency) end,
         v.as_of, coalesce(v.stale, false), coalesce(v.estimate, false)
  from public.holdings h
  cross join d
  left join lateral (
    select x.quote, x.factor, p.aed_per_gram, p.as_of
    from (select case h.metal when 'gold' then 'gold_' || h.karat || 'k' else 'silver_retail' end as quote,
                 case h.metal when 'gold' then case when h.karat = 24 then private.gold_fineness_factor(h.fineness) else 1 end
                              else h.purity / 0.999 end as factor) x
    left join lateral private.metal_price_at(x.quote, p_at) p on true
    where h.kind = 'metal'
  ) m on true
  left join lateral (
    select hv.value, hv.unit_price, hv.as_of from public.holding_valuations hv
    where hv.holding_code = h.holding_code and hv.as_of <= d.day
    order by hv.as_of desc, hv.created_at desc limit 1
  ) lv on h.kind in ('plan', 'broker', 'security', 'deposit')
  cross join lateral (
    select case h.kind
             when 'metal' then round(h.grams * m.factor * m.aed_per_gram, 2)
             when 'security' then round(h.units * lv.unit_price, 2)
             when 'deposit' then case
               when lv.value is not null then
                 round(lv.value * (1 + h.rate_pct / 100 * greatest(least(d.day, h.maturity_on) - lv.as_of, 0) / 365.0), 2)
               when d.day >= h.acquired_on then
                 round(h.principal * (1 + h.rate_pct / 100 * (least(d.day, h.maturity_on) - h.acquired_on) / 365.0), 2) end
             else lv.value
           end::numeric(14,2) as value,
           case h.kind when 'metal' then public.dubai_date(m.as_of)
                       when 'deposit' then case when lv.value is not null then greatest(lv.as_of, least(d.day, h.maturity_on))
                                                when d.day >= h.acquired_on then least(d.day, h.maturity_on) end
                       else lv.as_of end as as_of,
           case h.kind when 'metal' then m.as_of < p_at - private.metal_price_stale_after()
                       when 'deposit' then false
                       else lv.as_of < d.day - 45 end as stale,
           h.kind = 'deposit' and lv.as_of is distinct from d.day as estimate
  ) v
  where h.profile_code = p_profile_code and h.status = 'active'
$function$;

-- ── 6. card summaries ───────────────────────────────────────────────────────
create or replace function private.apply_card_summaries(p_profile text, p_bank text, p_cards jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  e jsonb;
  v_account text;
  v_limit numeric(14,2);
  n int := 0;
  v_warnings jsonb := '[]'::jsonb;
begin
  for e in select * from jsonb_array_elements(coalesce(p_cards, '[]'::jsonb)) loop
    select c.account_code into v_account
    from public.cards c join public.accounts a on a.account_code = c.account_code
    where c.profile_code = p_profile and c.bank_code = p_bank and c.last4 = e->>'last4' and a.kind = 'credit_card';
    if v_account is null then
      v_warnings := v_warnings || to_jsonb(format('Card ending %s is in the statement but not in this ledger',
                                                  e->>'last4'));
      continue;
    end if;
    v_limit := nullif(e->>'credit_limit', '')::numeric(14,2);
    if v_limit is not null and v_limit > 0 then
      update public.accounts set credit_limit = v_limit
      where account_code = v_account and credit_limit is distinct from v_limit;
      if found then
        n := n + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('limits_updated', n, 'warnings', v_warnings);
end;
$$;

-- ── ingest ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ingest_parsed_document(p_doc_code text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  d public.documents%rowtype;
  v_profile text;
  s jsonb;
  v_ord bigint;
  v_account text;
  v_stmt text;
  v_res jsonb;
  v_results jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_sms integer;
  v_lines_in bigint := 0;
  v_new bigint := 0;
  v_gone bigint := 0;
  v_created bigint := 0;
  v_linked bigint := 0;
  v_held bigint := 0;
  v_cards jsonb;
  v_msg text;
  v_bank_doc boolean := coalesce(p_payload->>'document_kind' = 'account_statement_pdf', false);
  v_bank text;
  v_deposits jsonb;
  v_summaries jsonb;
begin
  perform private.assert_service_role();
  select profile_code into v_profile from public.documents where doc_code = p_doc_code;
  if not found then
    raise exception 'unknown document %', p_doc_code using errcode = 'P0002';
  end if;
  perform private.lock_profile(v_profile);
  select * into d from public.documents where doc_code = p_doc_code for update;
  if (p_payload->>'contract_version')::int is distinct from 1 then
    raise exception 'unsupported parser contract %', p_payload->>'contract_version' using errcode = '22023';
  end if;
  v_bank := coalesce(p_payload->>'bank_code', d.bank_code);
  -- Defence in depth (DP-04r): the parser validates dates; a statement more than a
  -- month in the future is a misread year and must not reach the ledger.
  -- (`ledger.test_today` lets pgTAP suites with fixed future dates pin "today".)
  if exists (select 1 from jsonb_array_elements(coalesce(p_payload->'statements', '[]'::jsonb)) x
             where (x->>'statement_date')::date
                   > coalesce(nullif(current_setting('ledger.test_today', true), '')::date, public.dubai_date(now())) + 31) then
    raise exception 'statement dated more than 31 days in the future' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_payload->'statements', '[]'::jsonb)) x
             where coalesce(jsonb_typeof(x->'account') = 'object', false) <> v_bank_doc) then
    raise exception 'an account_statement_pdf names an account on every statement, and only it does'
      using errcode = '22023';
  end if;

  create temp table if not exists _doc_stmts (
    ord bigint, account_code text, statement_date date, kind text, body jsonb
  ) on commit drop;
  truncate _doc_stmts;

  for s, v_ord in select value, ordinality from jsonb_array_elements(coalesce(p_payload->'statements', '[]'::jsonb))
                  with ordinality loop
    if v_bank_doc then
      -- A bank account's statement stands even without lines: its balance is news.
      v_account := private.resolve_bank_statement_account(d.profile_code, s->>'bank_code', s->'account');
      insert into _doc_stmts values (v_ord, v_account, (s->>'statement_date')::date, s->>'kind', s);
      continue;
    end if;
    if nullif(s->>'primary_card_last4', '') is null
       and jsonb_array_length(coalesce(s->'lines', '[]'::jsonb)) = 0 then
      v_warnings := v_warnings || to_jsonb(format('%s %s skipped: no card number and no transaction rows',
                                                  s->>'kind', s->>'statement_date'));
      continue;
    end if;
    v_account := private.resolve_statement_account(
      d.profile_code, s->>'bank_code', nullif(s->>'primary_card_last4', ''), s->>'card_holder', s->>'card_type',
      nullif(s->'totals'->>'credit_limit', '')::numeric, d.doc_code, s->>'statement_reference', s->>'reference_source',
      s->>'kind',
      (select min((l->>'txn_date')::date) from jsonb_array_elements(coalesce(s->'lines', '[]'::jsonb)) l)
    );
    insert into _doc_stmts values (v_ord, v_account, (s->>'statement_date')::date, s->>'kind', s);
  end loop;

  if v_bank_doc then
    -- The debit cards a bank statement's lines name belong to its account (primary cards, not
    -- supplementary); then the bank's alerts that waited for an account become transactions,
    -- so the statement lines can match them.
    perform private.ensure_card(d.profile_code, x.account_code, x.body->>'bank_code', l->>'card_last4', null, false)
    from _doc_stmts x cross join jsonb_array_elements(coalesce(x.body->'lines', '[]'::jsonb)) l
    where nullif(l->>'card_last4', '') is not null;
    perform private.reprocess_bank_sms(d.profile_code, v_bank);
  end if;

  for v_stmt in
    select st.stmt_code from public.statements st
    where st.profile_code = d.profile_code and st.status = 'active'
      and (st.doc_code = d.doc_code
           or exists (select 1 from public.statement_lines l
                      where l.profile_code = d.profile_code and l.stmt_code = st.stmt_code and l.is_current
                        and l.source_doc_codes @> array[d.doc_code]))
      and not exists (select 1 from _doc_stmts x
                      where x.account_code = st.account_code and x.statement_date = st.statement_date
                        and x.kind = st.kind)
  loop
    perform private.retire_doc_from_statement(v_stmt, d.doc_code);
  end loop;

  for s, v_account in select body, account_code from _doc_stmts order by ord loop
    v_res := private.ingest_one_statement(d, s, p_payload->>'parser_version', v_account);
    if v_bank_doc then
      perform private.record_statement_balance(d.profile_code, v_account, v_res->>'stmt_code',
        coalesce(s->>'period_end', s->>'statement_date')::date, nullif(s->'totals'->>'closing_balance', '')::numeric);
    end if;
    v_results := v_results || v_res;
    -- A bank account with no activity has no rows to warn about (its balance didn't move).
    v_warnings := v_warnings || case
      when v_bank_doc and jsonb_array_length(coalesce(s->'lines', '[]'::jsonb)) = 0
           and s->'totals'->>'opening_balance' is not distinct from s->'totals'->>'closing_balance' then '[]'::jsonb
      else coalesce(v_res->'warnings', '[]'::jsonb) end;
    v_lines_in := v_lines_in + jsonb_array_length(coalesce(s->'lines', '[]'::jsonb));
    v_new := v_new + coalesce((v_res->>'lines_new')::bigint, 0);
    v_gone := v_gone + coalesce((v_res->>'lines_superseded')::bigint, 0);
    v_created := v_created + coalesce((v_res->'match'->>'created')::bigint, 0);
    v_linked := v_linked + coalesce((v_res->'match'->>'linked')::bigint, 0);
    v_held := v_held + coalesce((v_res->'match'->>'held')::bigint, 0);
  end loop;

  if v_bank_doc then
    v_deposits := private.import_statement_deposits(d.profile_code, v_bank, p_payload->'deposits');
    v_summaries := private.apply_card_summaries(d.profile_code, v_bank, p_payload->'card_summaries');
    v_warnings := v_warnings || coalesce(v_deposits->'warnings', '[]'::jsonb)
                  || coalesce(v_summaries->'warnings', '[]'::jsonb);
  end if;

  -- SMS held as unknown_card whose card this document registered (DB-17r).
  v_sms := private.reprocess_waiting_sms(d.profile_code);

  update public.documents set
    parse_status = 'parsed',
    kind = p_payload->>'document_kind',
    bank_code = coalesce(p_payload->>'bank_code', bank_code),
    parser_version = p_payload->>'parser_version',
    parse_error_code = null,
    parse_error = null,
    parse_warnings = coalesce((select jsonb_agg(w) from jsonb_array_elements(p_payload->'statements') st,
                                 jsonb_array_elements(coalesce(st->'warnings', '[]'::jsonb)) w), '[]'::jsonb)
                     || v_warnings,
    parsed_at = now()
  where doc_code = p_doc_code;

  -- Cards this document added (and the cards they replaced), for the event.
  select coalesce(jsonb_agg(jsonb_build_object('bank_code', c.bank_code, 'last4', c.last4,
           'replaces', (select string_agg(o.last4, ', ' order by o.last4) from public.cards o
                        where o.account_code = c.account_code and o.status = 'replaced' and o.updated_at = now()))
           order by c.last4), '[]'::jsonb)
  into v_cards
  from public.cards c where c.profile_code = d.profile_code and c.created_at = now();

  v_msg := format('Imported %s: %s, %s already known, %s withdrawn; %s, %s matched to existing ones.',
                  private.plural(jsonb_array_length(v_results), 'statement', 'statements'),
                  private.plural(v_new, 'new line', 'new lines'), v_lines_in - v_new, v_gone,
                  private.plural(v_created, 'new transaction', 'new transactions'), v_linked);
  if v_held > 0 then
    v_msg := v_msg || ' ' || private.plural(v_held, 'line needs', 'lines need') || ' a review.';
  end if;
  if coalesce((v_deposits->>'created')::int, 0) + coalesce((v_deposits->>'valued')::int, 0) > 0 then
    v_msg := v_msg || format(' Deposits: %s added, %s valued.', v_deposits->>'created', v_deposits->>'valued');
  end if;
  select v_msg || coalesce(' ' || string_agg(format('New card ending %s added%s.', x->>'last4',
           coalesce(' as the replacement of the card ending ' || (x->>'replaces'), '')), ' '), '')
  into v_msg from jsonb_array_elements(v_cards) x;
  perform private.log_document_event(d.profile_code, d.doc_code, 'ingested',
    case when v_held > 0 or jsonb_array_length(v_warnings) > 0 then 'warn' else 'info' end, v_msg,
    jsonb_build_object('statements', jsonb_array_length(v_results), 'lines_in', v_lines_in, 'lines_new', v_new,
                       'lines_unchanged', v_lines_in - v_new, 'lines_withdrawn', v_gone,
                       'transactions_created', v_created, 'transactions_linked', v_linked, 'lines_held', v_held,
                       'cards_added', v_cards, 'sms_card_registered', v_sms,
                       'warnings', jsonb_array_length(v_warnings))
    || case when v_bank_doc then jsonb_build_object(
         'deposits_added', (v_deposits->>'created')::int, 'deposits_claimed', (v_deposits->>'claimed')::int,
         'deposits_valued', (v_deposits->>'valued')::int,
         'card_limits_updated', (v_summaries->>'limits_updated')::int) else '{}'::jsonb end);

  return jsonb_build_object('doc_code', p_doc_code, 'statements', v_results, 'warnings', v_warnings,
                            'sms_card_registered', v_sms, 'deposits', v_deposits, 'card_summaries', v_summaries);
end;
$function$;

-- ── 7. card-only statement readers ──────────────────────────────────────────
-- A bank account's statement is never "unpaid" and is not a card cycle.
create or replace view public.v_statement_payments with (security_invoker = true) as
select st.profile_code, st.stmt_code, st.account_code, p.amount_paid,
       case
         when st.closing_balance is null then null::text
         when st.closing_balance <= 0 or p.amount_paid >= st.closing_balance then 'paid'
         when st.due_date is not null and public.dubai_date(now()) > st.due_date
              and case when st.min_due is null then p.amount_paid <= 0 else p.amount_paid < st.min_due end
           then 'overdue'
         when p.amount_paid > 0 then 'part_paid'
         else 'unpaid'
       end as payment_status
from public.statements st
cross join lateral (
  select min(n.statement_date) as next_statement_date
  from public.statements n
  where n.account_code = st.account_code and n.kind = 'statement' and n.status = 'active'
    and n.statement_date > st.statement_date
) nx
cross join lateral (
  select coalesce(sum(t.amount_aed), 0)::numeric(14,2) as amount_paid
  from public.transactions t
  where t.account_code = st.account_code and t.kind = 'payment' and t.direction = 'credit'
    and t.status in ('pending', 'posted') and t.amount_aed is not null and t.txn_date > st.statement_date
    and (nx.next_statement_date is null or t.txn_date <= nx.next_statement_date)
) p
where st.kind = 'statement'
  and exists (select 1 from public.accounts a where a.account_code = st.account_code and a.kind = 'credit_card');

CREATE OR REPLACE FUNCTION public.statement_cycles(p_profile_code text, p_limit integer DEFAULT 24)
 RETURNS TABLE(stmt_code text, account_code text, bank_code text, card_last4 text, kind text, statement_date date, period_start date, period_end date, due_date date, closing_balance numeric, min_due numeric, credit_limit numeric, utilisation numeric, line_count bigint, debits numeric, credits numeric, recon_status text, recon_checks jsonb, doc_code text, logo_path text, payment_status text, amount_paid text, from_sms boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select st.stmt_code, st.account_code, a.bank_code, st.primary_card_last4, st.kind,
         st.statement_date, st.period_start, st.period_end, st.due_date,
         st.closing_balance, st.min_due, coalesce(st.credit_limit, a.credit_limit),
         round(greatest(st.closing_balance, 0) / nullif(coalesce(st.credit_limit, a.credit_limit), 0), 4),
         (select count(*) from public.statement_lines l where l.stmt_code = ls.code and l.is_current),
         (select coalesce(sum(l.amount_aed), 0) from public.statement_lines l
           where l.stmt_code = ls.code and l.is_current and l.direction = 'debit'),
         (select coalesce(sum(l.amount_aed), 0) from public.statement_lines l
           where l.stmt_code = ls.code and l.is_current and l.direction = 'credit'),
         coalesce(v.recon_status, r.status), coalesce(v.recon_checks, r.checks), st.doc_code, b.logo_path,
         sp.payment_status, sp.amount_paid::text, v.stmt_code is not null
  from public.statements st
  join public.accounts a on a.profile_code = st.profile_code and a.account_code = st.account_code
  join public.banks b on b.bank_code = a.bank_code
  left join public.statement_recon r on r.stmt_code = st.stmt_code
  left join public.v_statement_payments sp on sp.profile_code = st.profile_code and sp.stmt_code = st.stmt_code
  left join public.v_sms_statements v on v.profile_code = st.profile_code and v.stmt_code = st.stmt_code
  cross join lateral (select coalesce(v.history_stmt_code, st.stmt_code) as code) ls
  where st.profile_code = p_profile_code and st.status = 'active'
    and a.kind = 'credit_card'  -- a bank account's statements are its ledger, not a card cycle
    -- A history export merged into its cycle's SMS statement is shown as that statement.
    and not exists (select 1 from public.v_sms_statements m
                    where m.profile_code = st.profile_code and m.history_stmt_code = st.stmt_code)
  order by st.statement_date desc
  limit least(greatest(p_limit, 1), 5000)
$function$;

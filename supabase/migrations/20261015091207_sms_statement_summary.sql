-- Statements from a bank's statement-summary SMS (SIB first).
--
-- SIB sends no statement by email: on the 15th it texts the cycle's outstanding amount,
-- minimum payment and due date ("Covered Card ending with XXXX9213 payment is due on
-- 30-10-2026, outstanding amount is AED 4,396.67, minimum payment due is AED 219.83 …").
-- Until now that SMS was 'unparsed' and SIB had only history exports (no closing balance,
-- no due date), so it had no payment status, no due reminder and no statement anchor for
-- its outstanding balance.
--
--   • sms_templates/sms_messages.msg_kind gain 'statement_summary'. Its template maps
--     amount (the outstanding amount, i.e. the closing balance), due_date and min_due; the
--     validator and private.apply_sms_template learn the two new fields.
--   • statements.sms_code: the SMS a statement was made from. A statement with an sms_code
--     and no doc_code is an "SMS statement": kind 'statement', header only, no lines of its
--     own. If a PDF for the same cycle is ingested later, ingest_one_statement takes the row
--     over (it has no document) and it stops being an SMS statement.
--   • private.apply_sms_statement (called by process_sms): creates the SMS statement for
--     the cycle that closed on or before the day the SMS arrived (Dubai). The close day is
--     accounts.cycle_close_day, else the day the account's latest history export ends on.
--     The first summary of a cycle wins: a reminder re-sent later in the month, or any
--     existing statement for that date, is left alone.
--   • public.v_sms_statements: per SMS statement, the history export of the same cycle (its
--     lines are the statement's lines) and a check of the SMS closing balance against the
--     ledger: previous closing (or the BALANCE MIGRATION anchor) + every pending/posted
--     transaction up to the close, except a charge still pending on the close day: the bank
--     closes with what has posted, so an authorisation made that day lands in the next cycle
--     (SIB, 14 Oct: the DESCO charge is in the available balance but not the closing). A gap means spends are missing or the cycle's history
--     export was never uploaded; uploading it or later SMS close the gap. Computed live, so
--     it is never stale; reconcile_statement stores the same result in statement_recon.
--     No missing_from_statement reviews: without lines there is nothing to be missing from.
--   • statement_cycles (one appended column, from_sms) and statement_detail show an SMS
--     statement merged with its history export: one row per cycle, the export's lines,
--     and the live check. statement_detail of a merged history export returns the SMS
--     statement (activity links point at the export).
--   • v_account_balances: an SMS statement has no lines to tell what it covers, so activity
--     on top of it is by date (after the close, plus close-day charges still pending), not by
--     stmt_code.
--
-- Content (CLAUDE.md §1.9): the SIB template is inserted when no SIB template of that
-- name exists. Inserting it re-processes SIB's unparsed messages (DB-22), which turns the
-- 2026-10-14 summary into the 2026-10-14 statement on deploy (SIB •9213 closes on the 14th).

-- ── msg_kind ────────────────────────────────────────────────────────────────
alter table public.sms_templates drop constraint sms_templates_msg_kind_check;
alter table public.sms_templates add constraint sms_templates_msg_kind_check check (msg_kind in
  ('purchase', 'preauth', 'refund', 'reversal', 'payment', 'declined', 'debit_card', 'other', 'statement_summary'));
alter table public.sms_messages drop constraint sms_messages_msg_kind_check;
alter table public.sms_messages add constraint sms_messages_msg_kind_check check (msg_kind in
  ('purchase', 'preauth', 'refund', 'reversal', 'payment', 'declined', 'debit_card', 'other', 'statement_summary'));
alter table public.sms_templates add constraint sms_templates_summary_fields_check
  check (msg_kind <> 'statement_summary' or (field_groups ? 'amount' and field_groups ? 'due_date'));

-- ── statements.sms_code ─────────────────────────────────────────────────────
alter table public.statements add column sms_code text
  references public.sms_messages(sms_code) on delete set null;
create unique index statements_sms_code_uq on public.statements(sms_code) where sms_code is not null;

-- ── template fields: due_date, min_due ──────────────────────────────────────
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
                        'due_date', 'min_due')
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
  if t.msg_kind in ('purchase', 'preauth', 'refund', 'reversal', 'payment') and f->>'amount' is null then
    return null;
  end if;
  if t.msg_kind = 'statement_summary' and (f->>'amount' is null or f->>'due_date' is null) then
    return null;
  end if;
  return f;
end;
$$;

-- ── SMS statements and their check ──────────────────────────────────────────
create view public.v_sms_statements with (security_invoker = true) as
select st.profile_code,
       st.stmt_code,
       st.account_code,
       h.stmt_code as history_stmt_code,
       k.basis as opening_basis,
       case k.basis when 'statement' then p.statement_date when 'balance_migration' then m.migration_date end
         as opening_date,
       case k.basis when 'statement' then p.closing_balance when 'balance_migration' then 0::numeric(14,2) end
         as opening_balance,
       x.activity_aed,
       e.expected_closing,
       (st.closing_balance - e.expected_closing)::numeric(14,2) as ledger_gap,
       case when e.expected_closing is null then 'n/a'
            when abs(st.closing_balance - e.expected_closing) <= 0.01 and x.unpriced_count = 0 then 'ok'
            else 'warn' end as recon_status,
       jsonb_strip_nulls(jsonb_build_object(
         'source', 'sms',
         'history_uploaded', h.stmt_code is not null,
         'line_count', (select count(*) from public.statement_lines l
                        where l.stmt_code = h.stmt_code and l.is_current)::integer,
         'opening_basis', k.basis,
         'opening_balance', case k.basis when 'statement' then p.closing_balance::text
                                         when 'balance_migration' then '0.00' end,
         'ledger_activity', case when e.expected_closing is not null then x.activity_aed::text end,
         'expected_closing', e.expected_closing::text,
         'ledger_gap', (st.closing_balance - e.expected_closing)::numeric(14,2)::text,
         'balance_equation', case when e.expected_closing is not null
                                  then abs(st.closing_balance - e.expected_closing) <= 0.01 end,
         'unpriced_txns', nullif(x.unpriced_count, 0)
       )) as recon_checks
from public.statements st
-- The history export of the same cycle: its lines are this statement's lines.
left join lateral (
  select h.stmt_code
  from public.statements h
  where h.profile_code = st.profile_code and h.account_code = st.account_code
    and h.kind = 'history_extract' and h.status = 'active'
    and h.statement_date between st.statement_date - 3 and st.statement_date + 3
  order by abs(h.statement_date - st.statement_date), h.statement_date desc
  limit 1
) h on true
left join lateral (
  select pv.statement_date, pv.closing_balance
  from public.statements pv
  where pv.profile_code = st.profile_code and pv.account_code = st.account_code
    and pv.kind = 'statement' and pv.status = 'active' and pv.closing_balance is not null
    and pv.statement_date < st.statement_date
  order by pv.statement_date desc, pv.created_at desc
  limit 1
) p on true
-- Same anchor rule as v_account_balances: a BALANCE MIGRATION starts the balance from 0.
left join lateral (
  select max(t.txn_date) as migration_date
  from public.transactions t
  where t.profile_code = st.profile_code and t.account_code = st.account_code
    and t.status in ('pending', 'posted') and t.kind = 'adjustment' and t.direction = 'debit'
    and t.description ilike 'BALANCE MIGRATION%' and t.txn_date <= st.statement_date
) m on true
cross join lateral (
  select case when m.migration_date is not null
                   and (p.statement_date is null or m.migration_date > p.statement_date) then 'balance_migration'
              when p.statement_date is not null then 'statement'
              else 'none' end as basis
) k
cross join lateral (
  select coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end), 0)::numeric(14,2)
           as activity_aed,
         count(*) filter (where t.amount_aed is null)::integer as unpriced_count
  from public.transactions t
  where t.profile_code = st.profile_code and t.account_code = st.account_code
    and t.status in ('pending', 'posted')
    and (t.txn_date < st.statement_date or (t.txn_date = st.statement_date and t.status = 'posted'))
    and case k.basis
          when 'statement' then t.txn_date > p.statement_date
          when 'balance_migration' then t.txn_date >= m.migration_date
          else false
        end
) x
cross join lateral (
  select case k.basis
           when 'statement' then (p.closing_balance + x.activity_aed)::numeric(14,2)
           when 'balance_migration' then x.activity_aed
         end as expected_closing
) e
where st.kind = 'statement' and st.status = 'active' and st.sms_code is not null and st.doc_code is null;

grant select on public.v_sms_statements to authenticated, service_role;

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

  -- Declined alerts are not transactions: stored 'ignored' like debit-card and other alerts (DB-34).
  v_ignored := m.msg_kind in ('debit_card', 'other', 'declined');
  update public.sms_messages set
    parse_status = case when v_ignored then 'ignored' else 'parsed' end,
    ignore_reason = case when v_ignored then m.msg_kind end,
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
  return v_result;
end;
$$;

-- ── reconcile_statement: SMS statements store the live check ────────────────
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
begin
  select * into st from public.statements where stmt_code = p_stmt_code;

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
      v_expected := st.opening_balance + v_debits - v_credits;
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
$$;

-- ── v_account_balances: activity after an SMS statement is by date ──────────
create or replace view public.v_account_balances with (security_invoker = true) as
select a.profile_code,
       a.account_code,
       k.anchor_kind,
       case k.anchor_kind when 'statement' then s.statement_date when 'balance_migration' then m.migration_date end
         as anchor_date,
       case when k.anchor_kind = 'statement' then s.stmt_code end as anchor_stmt_code,
       case k.anchor_kind when 'statement' then s.closing_balance when 'balance_migration' then 0::numeric(14,2) end
         as anchor_balance,
       case when k.anchor_kind <> 'none' then x.activity_aed end as activity_aed,
       case k.anchor_kind
         when 'statement' then (s.closing_balance + x.activity_aed)::numeric(14,2)
         when 'balance_migration' then x.activity_aed::numeric(14,2)
       end as outstanding_aed,
       x.unpriced_count,
       x.has_estimate
from public.accounts a
left join lateral (
  select st.stmt_code, st.statement_date, st.closing_balance,
         (st.sms_code is not null and st.doc_code is null) as from_sms
  from public.statements st
  where st.account_code = a.account_code and st.kind = 'statement' and st.status = 'active'
    and st.closing_balance is not null
  order by st.statement_date desc, st.created_at desc
  limit 1
) s on true
left join lateral (
  select max(t.txn_date) as migration_date
  from public.transactions t
  where t.account_code = a.account_code and t.status in ('pending', 'posted')
    and t.kind = 'adjustment' and t.direction = 'debit' and t.description ilike 'BALANCE MIGRATION%'
) m on true
cross join lateral (
  select case when m.migration_date is not null
                   and (s.statement_date is null or m.migration_date > s.statement_date) then 'balance_migration'
              when s.stmt_code is not null then 'statement'
              else 'none' end as anchor_kind
) k
cross join lateral (
  select coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end), 0)::numeric(14,2)
           as activity_aed,
         count(*) filter (where t.amount_aed is null)::integer as unpriced_count,
         coalesce(bool_or(t.amount_aed_is_estimate), false) as has_estimate
  from public.transactions t
  where t.account_code = a.account_code and t.status in ('pending', 'posted')
    and case k.anchor_kind
          when 'statement' then
            case when s.from_sms then t.txn_date > s.statement_date
                                      or (t.txn_date = s.statement_date and t.status = 'pending')
                 else t.stmt_code is null
                      or exists (select 1 from public.statements ts
                                 where ts.stmt_code = t.stmt_code and ts.statement_date > s.statement_date)
            end
          when 'balance_migration' then t.txn_date >= m.migration_date
          else true
        end
) x;

-- ── statement_cycles: one row per cycle; from_sms appended ──────────────────
drop function if exists public.statement_cycles(text, integer);
create function public.statement_cycles(p_profile_code text, p_limit integer default 24)
returns table (stmt_code text, account_code text, bank_code text, card_last4 text, kind text,
               statement_date date, period_start date, period_end date, due_date date,
               closing_balance numeric, min_due numeric, credit_limit numeric, utilisation numeric,
               line_count bigint, debits numeric, credits numeric, recon_status text, recon_checks jsonb,
               doc_code text, logo_path text, payment_status text, amount_paid text, from_sms boolean)
language sql
stable
set search_path = ''
as $$
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
    -- A history export merged into its cycle's SMS statement is shown as that statement.
    and not exists (select 1 from public.v_sms_statements m
                    where m.profile_code = st.profile_code and m.history_stmt_code = st.stmt_code)
  order by st.statement_date desc
  limit least(greatest(p_limit, 1), 5000)
$$;
grant execute on function public.statement_cycles(text, integer) to authenticated, service_role;

-- ── statement_detail: SMS statements show their history export's lines ──────
create or replace function public.statement_detail(p_profile_code text, p_stmt_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  st public.statements%rowtype;
  sv public.v_sms_statements%rowtype;
  v_bank text;
  v_lines jsonb;
  v_last4s text[];
  v_lines_stmt text;
begin
  perform private.assert_member(p_profile_code, false);
  select * into st from public.statements s where s.stmt_code = p_stmt_code and s.profile_code = p_profile_code;
  if not found then
    raise exception 'unknown statement %', p_stmt_code using errcode = 'P0002';
  end if;
  -- A history export merged into its cycle's SMS statement opens as that statement.
  select * into sv from public.v_sms_statements v
  where v.profile_code = p_profile_code and v.history_stmt_code = st.stmt_code;
  if found then
    select * into st from public.statements s where s.stmt_code = sv.stmt_code;
  else
    select * into sv from public.v_sms_statements v
    where v.profile_code = p_profile_code and v.stmt_code = st.stmt_code;
  end if;
  v_lines_stmt := coalesce(sv.history_stmt_code, st.stmt_code);
  select a.bank_code into v_bank from public.accounts a
  where a.account_code = st.account_code and a.profile_code = p_profile_code;

  with lines as (
    select l.line_code, l.line_no, l.txn_date, l.posting_date, l.description_raw, l.direction, l.kind,
           l.amount_aed, l.amount_original, l.currency_original,
           coalesce(l.card_last4, cd.last4) as card_last4,
           t.txn_code, t.effective_category_code, m.display_name as merchant_name
    from public.statement_lines l
    left join public.cards cd on cd.card_code = l.card_code and cd.profile_code = p_profile_code
    left join lateral (
      select e.txn_code from public.transaction_evidence e
      where e.line_code = l.line_code and e.profile_code = p_profile_code and e.is_active
      order by e.created_at limit 1
    ) ev on true
    left join public.transactions t on t.txn_code = ev.txn_code and t.profile_code = p_profile_code
    left join public.merchants m on m.merchant_code = t.merchant_code
    where l.stmt_code = v_lines_stmt and l.profile_code = p_profile_code and l.is_current
  ),
  sides as (
    select x.direction,
           count(*) as n,
           sum(x.amount_aed) as total,
           jsonb_agg(jsonb_build_object(
             'line_code', x.line_code, 'txn_code', x.txn_code, 'txn_date', x.txn_date,
             'posting_date', x.posting_date, 'description', x.description_raw,
             'merchant_name', x.merchant_name, 'amount_aed', x.amount_aed::text,
             'amount_original', x.amount_original::text, 'currency_original', x.currency_original,
             'category_code', x.effective_category_code, 'kind', x.kind, 'card_last4', x.card_last4)
             order by x.txn_date, x.line_no, x.line_code) as lines
    from lines x
    group by x.direction
  )
  select jsonb_object_agg(s.direction, jsonb_build_object(
           'count', s.n, 'total', coalesce(s.total, 0)::numeric(14,2)::text, 'lines', s.lines))
  into v_lines
  from sides s;

  select coalesce(array_agg(distinct x.last4 order by x.last4), '{}'::text[]) into v_last4s
  from (
    select st.primary_card_last4 as last4
    union
    select coalesce(l.card_last4, cd.last4)
    from public.statement_lines l
    left join public.cards cd on cd.card_code = l.card_code and cd.profile_code = p_profile_code
    where l.stmt_code = v_lines_stmt and l.profile_code = p_profile_code and l.is_current
  ) x
  where x.last4 is not null;

  return jsonb_build_object(
    'statement', (
      select jsonb_build_object(
        'stmt_code', st.stmt_code, 'kind', st.kind, 'bank_code', v_bank, 'account_code', st.account_code,
        'card_last4s', to_jsonb(v_last4s), 'statement_date', st.statement_date,
        'period_start', st.period_start, 'period_end', st.period_end, 'due_date', st.due_date,
        'opening_balance', st.opening_balance::text, 'closing_balance', st.closing_balance::text,
        'total_debits', st.total_debits::text, 'total_credits', st.total_credits::text,
        'min_due', st.min_due::text, 'credit_limit', st.credit_limit::text, 'doc_code', st.doc_code,
        -- closing / limit, never negative (a card in credit has used none of it, DB-39).
        'utilisation', round(greatest(st.closing_balance, 0) / nullif(coalesce(st.credit_limit,
          (select ac.credit_limit from public.accounts ac where ac.account_code = st.account_code)), 0), 4)::text,
        'recon_status', coalesce(sv.recon_status, r.status), 'recon_checks', coalesce(sv.recon_checks, r.checks),
        -- public.v_statement_payments (UX-1r, WEB-36); null for a history extract.
        'payment_status', sp.payment_status, 'amount_paid', sp.amount_paid::text,
        -- An SMS statement (v_sms_statements): header from the bank's SMS, lines from the
        -- cycle's history export when one was uploaded.
        'from_sms', sv.stmt_code is not null, 'history_stmt_code', sv.history_stmt_code)
      from (select 1) one
      left join public.statement_recon r on r.stmt_code = st.stmt_code and r.profile_code = p_profile_code
      left join public.v_statement_payments sp on sp.profile_code = p_profile_code and sp.stmt_code = st.stmt_code),
    'debits', coalesce(v_lines->'debit', jsonb_build_object('count', 0, 'total', '0.00', 'lines', '[]'::jsonb)),
    'credits', coalesce(v_lines->'credit', jsonb_build_object('count', 0, 'total', '0.00', 'lines', '[]'::jsonb))
  );
end;
$$;

-- ── SIB close day ───────────────────────────────────────────────────────────
-- Alice's SIB Covered Card (•9213) closes on the 14th (confirmed 2026-10-15; the SIB
-- parser's history buckets assume the 12th). Set before the template below so the
-- reprocessed 2026-10-14 summary lands on the 14 Oct cycle. Guarded: only while unset.
update public.accounts set cycle_close_day = 14
where account_code = 'acc_01k4dnjv0ygcmgpn34ztzardjq' and bank_code = 'SIB' and cycle_close_day is null;

-- ── SIB statement summary template ──────────────────────────────────────────
insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 ('SIB', 'SIB covered card statement summary', '^SIB',
  '(?:Covered|Credit) Card ending with X*([0-9]{4}) payment is due on ([0-9]{2}-[0-9]{2}-[0-9]{4}), outstanding amount is ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?), minimum payment due is [A-Z]{3} ?([0-9,]+(?:\.[0-9]{1,2})?)',
  '{"last4":1,"due_date":2,"currency":3,"amount":4,"min_due":5}', 'DD-MM-YYYY', 'statement_summary', 10,
  '[{"sender":"SIB","body":"Covered Card ending with XXXX9213 payment is due on 30-10-2026, outstanding amount is AED 4,396.67, minimum payment due is AED 219.83. Ensure paying before 30-10-2026 to avoid deducting any amount under commitment to donate clause.",
     "expect":{"last4":"9213","due_date":"2026-10-30","currency":"AED","amount":"4396.67","min_due":"219.83"}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);

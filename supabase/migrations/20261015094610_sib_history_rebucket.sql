-- History rows that move to another cycle keep their transaction (SIB closes on the 14th).
--
-- A history export has no statement of its own: the parser buckets its rows into cycles
-- (SIB: the 15th to the 14th; it used the 13th to the 12th until parser 2026.10.15.1).
-- When the bucketing changes, the same row arrives on a statement with a different date,
-- so `ingest_one_statement` (identity: account, statement_date, kind) creates a new
-- statement next to the old one. Its rows have the same line_key and occurrence as rows
-- that are still current on the old statement, whose transactions already carry an
-- active history line, so the matcher could not link them and created a duplicate
-- transaction for every row.
--
-- private.rebucket_history_lines moves such a row instead: the new line takes over the
-- old line's evidence (same transaction, role, score, method and lock) and the documents
-- that evidence it, and the old line stops being current. A history statement left with
-- no current line is superseded by the new one. Transactions keep their codes and every
-- user field. Re-parsing the only document behind a row needs none of this (the re-parse
-- withdraws the old line first and the matcher re-links by lineage); the helper covers a
-- row that another, not yet re-parsed, export still evidences, and a new export.
--
-- ingest_one_statement is unchanged apart from the call, a warning when an export's cycles
-- close on a different day than the account's cycle_close_day, and hashing line_key with
-- private.statement_line_key (the same expression, now in one place).

create index if not exists statement_lines_account_key_idx
  on public.statement_lines (account_code, line_key) where is_current;

create or replace function private.rebucket_history_lines(p_stmt_code text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  st public.statements%rowtype;
  r record;
  v_old text;
  v_moved integer := 0;
begin
  select * into st from public.statements where stmt_code = p_stmt_code;
  if not found or st.kind <> 'history_extract' then
    return 0;
  end if;

  create temp table if not exists _rb_lines (
    new_line text, old_line text, old_stmt text, old_docs text[]
  ) on commit drop;
  truncate _rb_lines;

  -- The same history row, still current on another active history statement of the account.
  insert into _rb_lines
  select n.line_code, o.line_code, o.stmt_code, o.source_doc_codes
  from public.statement_lines n
  join public.statement_lines o
    on o.account_code = n.account_code and o.line_key = n.line_key and o.occurrence = n.occurrence
   and o.profile_code = n.profile_code and o.is_current and o.stmt_code <> n.stmt_code
   and o.evidence_type = 'history_line'
  join public.statements os
    on os.stmt_code = o.stmt_code and os.kind = 'history_extract' and os.status = 'active'
  where n.profile_code = st.profile_code and n.stmt_code = p_stmt_code and n.is_current
    and not exists (select 1 from public.transaction_evidence e where e.line_code = n.line_code and e.is_active);
  if not found then
    return 0;
  end if;

  -- The documents behind the old row evidence the new one.
  update public.statement_lines n
  set source_doc_codes = n.source_doc_codes
        || array(select d from unnest(b.old_docs) d where not (d = any (n.source_doc_codes)))
  from _rb_lines b
  where n.line_code = b.new_line;

  -- Its transaction moves with it (deactivate first: one active history line per transaction).
  for r in
    select b.new_line, e.evidence_code, e.txn_code, e.role, e.score, e.method, e.is_locked
    from _rb_lines b
    join public.transaction_evidence e on e.line_code = b.old_line and e.is_active
  loop
    update public.transaction_evidence set is_active = false, deactivated_at = now()
    where evidence_code = r.evidence_code;
    insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, role, score, method,
                                             is_locked)
    values (r.txn_code, st.profile_code, 'history_line', r.new_line, r.role, r.score, r.method, r.is_locked);
    perform private.refresh_transaction(r.txn_code);
    v_moved := v_moved + 1;
  end loop;

  -- The old rows stop being current (their evidence is already gone; open reviews on them close).
  perform private.detach_lines(st.profile_code, array(select old_line from _rb_lines));

  for v_old in select distinct old_stmt from _rb_lines loop
    if exists (select 1 from public.statement_lines l
               where l.profile_code = st.profile_code and l.stmt_code = v_old and l.is_current) then
      perform private.reconcile_statement(v_old);
    else
      perform private.supersede_statement(v_old, p_stmt_code);
    end if;
  end loop;
  return v_moved;
end;
$$;

-- ── ingest_one_statement: re-bucketed history rows move; close-day drift warns ──
CREATE OR REPLACE FUNCTION private.ingest_one_statement(p_doc public.documents, p_stmt jsonb, p_parser_version text, p_account text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_kind text := p_stmt->>'kind';
  v_bank text := p_stmt->>'bank_code';
  v_date date := (p_stmt->>'statement_date')::date;
  v_last4 text := nullif(p_stmt->>'primary_card_last4', '');
  v_totals jsonb := coalesce(p_stmt->'totals', '{}'::jsonb);
  v_n_in integer := jsonb_array_length(coalesce(p_stmt->'lines', '[]'::jsonb));
  v_account text := p_account;
  v_profile text := p_doc.profile_code;
  v_doc text := p_doc.doc_code;
  v_stmt text;
  v_status text;
  v_stmt_doc text;
  v_existing boolean;
  v_own boolean;
  v_gone text[];
  v_superseded int := 0;
  v_inserted int := 0;
  v_match jsonb;
  v_recon text;
  v_warnings jsonb := '[]'::jsonb;
  v_moved int := 0;
  v_close_day int;
begin
  -- The active statement with this identity, else one this same document produced
  -- earlier and a re-parse retired (DB-06): it comes back with its codes intact.
  -- A statement the owner superseded (superseded_by set) is never revived.
  select stmt_code, status, doc_code into v_stmt, v_status, v_stmt_doc from public.statements
  where profile_code = v_profile and account_code = v_account and statement_date = v_date and kind = v_kind
    and (status = 'active' or (status = 'superseded' and superseded_by is null and doc_code = v_doc))
  order by (status = 'active') desc, created_at desc
  limit 1;
  v_existing := v_stmt is not null;

  if v_existing then
    v_own := v_status = 'superseded' or v_stmt_doc is null or v_stmt_doc = v_doc
             or (v_n_in > 0 and not exists (
                   select 1 from public.statement_lines l
                   where l.profile_code = v_profile and l.stmt_code = v_stmt and l.is_current
                     and l.source_doc_codes @> array[v_stmt_doc]));
    if v_own then
      update public.statements set
        status = 'active',
        superseded_by = null,
        doc_code = v_doc,
        statement_reference = p_stmt->>'statement_reference',
        reference_source = p_stmt->>'reference_source',
        period_start = (p_stmt->>'period_start')::date,
        period_end = (p_stmt->>'period_end')::date,
        due_date = (p_stmt->>'due_date')::date,
        opening_balance = (v_totals->>'opening_balance')::numeric,
        closing_balance = (v_totals->>'closing_balance')::numeric,
        total_debits = (v_totals->>'total_debits')::numeric,
        total_credits = (v_totals->>'total_credits')::numeric,
        min_due = (v_totals->>'min_due')::numeric,
        credit_limit = (v_totals->>'credit_limit')::numeric,
        primary_card_last4 = v_last4,
        card_holder = p_stmt->>'card_holder',
        card_type = p_stmt->>'card_type',
        parser_version = p_parser_version,
        warnings = coalesce(p_stmt->'warnings', '[]'::jsonb),
        metadata = coalesce(p_stmt->'metadata', '{}'::jsonb)
      where stmt_code = v_stmt;
    elsif v_n_in > 0 then
      update public.statements s set
        statement_reference = coalesce(s.statement_reference, p_stmt->>'statement_reference'),
        reference_source = case when s.statement_reference is null then p_stmt->>'reference_source'
                                else s.reference_source end,
        period_start = case when s.period_start is null and s.period_end is null
                            then (p_stmt->>'period_start')::date else s.period_start end,
        period_end = case when s.period_start is null and s.period_end is null
                          then (p_stmt->>'period_end')::date else s.period_end end,
        due_date = coalesce(s.due_date, (p_stmt->>'due_date')::date),
        opening_balance = coalesce(s.opening_balance, (v_totals->>'opening_balance')::numeric),
        closing_balance = coalesce(s.closing_balance, (v_totals->>'closing_balance')::numeric),
        total_debits = coalesce(s.total_debits, (v_totals->>'total_debits')::numeric),
        total_credits = coalesce(s.total_credits, (v_totals->>'total_credits')::numeric),
        min_due = coalesce(s.min_due, (v_totals->>'min_due')::numeric),
        credit_limit = coalesce(s.credit_limit, (v_totals->>'credit_limit')::numeric),
        primary_card_last4 = coalesce(s.primary_card_last4, v_last4),
        card_holder = coalesce(s.card_holder, p_stmt->>'card_holder'),
        card_type = coalesce(s.card_type, p_stmt->>'card_type')
      where s.stmt_code = v_stmt;
    end if;
  else
    insert into public.statements (profile_code, account_code, doc_code, kind, statement_reference, reference_source,
      statement_date, period_start, period_end, due_date, opening_balance, closing_balance, total_debits,
      total_credits, min_due, credit_limit, primary_card_last4, card_holder, card_type, parser_version, warnings, metadata)
    values (v_profile, v_account, v_doc, v_kind, p_stmt->>'statement_reference',
      p_stmt->>'reference_source', v_date, (p_stmt->>'period_start')::date, (p_stmt->>'period_end')::date,
      (p_stmt->>'due_date')::date, (v_totals->>'opening_balance')::numeric, (v_totals->>'closing_balance')::numeric,
      (v_totals->>'total_debits')::numeric, (v_totals->>'total_credits')::numeric, (v_totals->>'min_due')::numeric,
      (v_totals->>'credit_limit')::numeric, v_last4, p_stmt->>'card_holder', p_stmt->>'card_type', p_parser_version,
      coalesce(p_stmt->'warnings', '[]'::jsonb), coalesce(p_stmt->'metadata', '{}'::jsonb))
    returning stmt_code into v_stmt;
  end if;

  -- An export whose cycles close on another day than the account's puts rows in the wrong cycle.
  if v_kind = 'history_extract' and (p_stmt->>'period_end') is not null then
    select a.cycle_close_day into v_close_day from public.accounts a where a.account_code = v_account;
    if v_close_day is not null
       and extract(day from (p_stmt->>'period_end')::date)::int
           <> least(v_close_day, extract(day from (date_trunc('month', (p_stmt->>'period_end')::date)
                                                   + interval '1 month - 1 day'))::int) then
      v_warnings := v_warnings || to_jsonb(format(
        'history_extract %s: the export''s cycles close on day %s; the account''s cycle closes on day %s',
        v_date, extract(day from (p_stmt->>'period_end')::date), v_close_day));
    end if;
  end if;

  if v_n_in = 0 then
    v_warnings := v_warnings || to_jsonb(format('%s %s: this document has no transaction rows%s', v_kind, v_date,
      case when v_existing and not v_own then '; the statement and its lines from other documents are kept' else '' end));
  end if;

  -- Incoming lines with their stable identity.
  create temp table if not exists _in_lines (
    line_no int, line_key text, occurrence smallint, txn_date date, txn_time time, posting_date date,
    description_raw text, description text, amount_original numeric, currency_original text, amount_aed numeric,
    fx_rate numeric, direction text, kind text, country_code text, card_last4 text, card_holder text,
    legacy_fingerprint text, raw jsonb
  ) on commit drop;
  truncate _in_lines;

  insert into _in_lines
  select x.line_no, x.line_key,
         row_number() over (partition by x.line_key order by x.line_no)::smallint,
         x.txn_date, x.txn_time, x.posting_date, x.description_raw, x.description, x.amount_original,
         x.currency_original, x.amount_aed, x.fx_rate, x.direction, x.kind, x.country_code, x.card_last4,
         x.card_holder, x.legacy_fingerprint, x.raw
  from (
    select (j->>'line_no')::int as line_no,
           -- One definition of a line's identity (case-insensitive since 20261015095636).
           private.statement_line_key(v_account, (j->>'txn_date')::date, (j->>'posting_date')::date,
             (j->>'amount_original')::numeric, j->>'currency_original', (j->>'amount_aed')::numeric,
             j->>'direction', j->>'description_raw') as line_key,
           (j->>'txn_date')::date as txn_date,
           (j->>'txn_time')::time as txn_time,
           (j->>'posting_date')::date as posting_date,
           j->>'description_raw' as description_raw,
           coalesce(private.normalize_text(j->>'merchant_normalized'), private.normalize_text(j->>'description_raw'), 'UNKNOWN') as description,
           (j->>'amount_original')::numeric(14,2) as amount_original,
           j->>'currency_original' as currency_original,
           (j->>'amount_aed')::numeric(14,2) as amount_aed,
           nullif((j->>'fx_rate')::numeric(18,8), 0) as fx_rate,  -- below 1e-8 rounds to 0: unknown (X-33)
           j->>'direction' as direction,
           j->>'kind' as kind,
           j->>'country_code' as country_code,
           nullif(j->>'card_last4', '') as card_last4,
           j->>'card_holder' as card_holder,
           j->>'legacy_fingerprint' as legacy_fingerprint,
           j as raw
    from jsonb_array_elements(coalesce(p_stmt->'lines', '[]'::jsonb)) j
  ) x;

  -- This document's lines that vanished from its new parse: withdraw its
  -- evidence; a line nobody evidences any more leaves the ledger.
  with r as (
    update public.statement_lines l set source_doc_codes = array_remove(l.source_doc_codes, v_doc)
    where l.profile_code = v_profile and l.stmt_code = v_stmt and l.is_current
      and l.source_doc_codes @> array[v_doc]
      and not exists (select 1 from _in_lines i where i.line_key = l.line_key and i.occurrence = l.occurrence)
    returning l.line_code, l.source_doc_codes
  )
  select array_agg(line_code) filter (where cardinality(source_doc_codes) = 0) into v_gone from r;
  v_superseded := private.detach_lines(v_profile, v_gone);

  -- Unchanged lines this document also evidences.
  update public.statement_lines l set source_doc_codes = l.source_doc_codes || v_doc
  from _in_lines i
  where l.profile_code = v_profile and l.stmt_code = v_stmt and l.is_current
    and l.line_key = i.line_key and l.occurrence = i.occurrence
    and not (l.source_doc_codes @> array[v_doc]);

  -- New lines (unchanged ones keep their codes and evidence).
  insert into public.statement_lines (stmt_code, profile_code, account_code, card_code, evidence_type, line_no,
    line_key, occurrence, txn_date, txn_time, posting_date, description_raw, description, amount_original,
    currency_original, amount_aed, fx_rate, direction, kind, country_code, card_last4, legacy_fingerprint, raw,
    source_doc_codes)
  select v_stmt, v_profile, v_account,
         private.ensure_card(v_profile, v_account, v_bank, i.card_last4, i.card_holder,
                             i.card_last4 is distinct from v_last4),
         case when v_kind = 'statement' then 'statement_line' else 'history_line' end,
         i.line_no, i.line_key, i.occurrence, i.txn_date, i.txn_time, i.posting_date, i.description_raw,
         i.description, i.amount_original, i.currency_original, i.amount_aed, i.fx_rate, i.direction, i.kind,
         i.country_code, i.card_last4, i.legacy_fingerprint, i.raw, array[v_doc]
  from _in_lines i
  where not exists (select 1 from public.statement_lines l
                    where l.stmt_code = v_stmt and l.line_key = i.line_key and l.occurrence = i.occurrence);
  get diagnostics v_inserted = row_count;

  -- A line that is current again (re-added after a parser fix) is re-activated.
  update public.statement_lines l set is_current = true, superseded_at = null, line_no = i.line_no,
    source_doc_codes = array_append(array_remove(l.source_doc_codes, v_doc), v_doc)
  from _in_lines i
  where l.stmt_code = v_stmt and not l.is_current and l.line_key = i.line_key and l.occurrence = i.occurrence;

  -- A row another history statement still holds (the export's cycles moved) keeps its transaction.
  v_moved := private.rebucket_history_lines(v_stmt);
  v_match := private.match_statement_lines(v_stmt);

  -- Period overlap with another real statement of the same account.
  if v_kind = 'statement' and (p_stmt->>'period_start') is not null and (p_stmt->>'period_end') is not null then
    insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
    select v_profile, v_account, 'statement', v_stmt, 'period_overlap',
           jsonb_agg(jsonb_build_object('stmt_code', o.stmt_code, 'statement_date', o.statement_date))
    from public.statements o
    where o.profile_code = v_profile and o.account_code = v_account
      and o.kind = 'statement' and o.status = 'active' and o.stmt_code <> v_stmt
      and o.period_start is not null and o.period_end is not null
      and least(o.period_end, (p_stmt->>'period_end')::date) - greatest(o.period_start, (p_stmt->>'period_start')::date) > 3
    having count(*) > 0
    on conflict do nothing;
  end if;

  v_recon := private.reconcile_statement(v_stmt);

  return jsonb_build_object(
    'stmt_code', v_stmt, 'account_code', v_account, 'kind', v_kind, 'replaced', v_existing,
    'lines_new', v_inserted, 'lines_superseded', v_superseded, 'lines_moved', v_moved, 'match', v_match, 'recon', v_recon,
    'warnings', v_warnings
  );
end;
$function$;

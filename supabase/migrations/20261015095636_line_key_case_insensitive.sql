-- A line's identity ignores letter case: two exports of one row are one line.
--
-- statement_lines.line_key hashed the description as printed. SIB's two history exports print
-- the same row as 'INTEGRATED GAS SERVICEDubai' (card summary) and 'INTEGRATED GAS
-- SERVICEDUBAI' (billed "Statement details"), so the union of documents by (line_key,
-- occurrence) kept both, the second could not join the first one's transaction (which already
-- held a history line) and became a duplicate transaction: production acc_…ztzardjq, 8 Oct AED
-- 105.75, statement 2026-10-12, lines lin_…kepg and lin_…3frb.
--
-- 1. private.statement_line_key upper-cases the collapsed description. Ingest
--    (20261015094610), merge_accounts and this backfill all hash through it.
-- 2. private.rekey_statement_lines() re-keys every line whose stored key differs. Where two
--    stored keys of one statement now hash the same (case variants of one row), one line per
--    occurrence survives: the current one with a transaction, then the oldest. A duplicate
--    current line gives the survivor its documents and leaves (is_current = false). Its
--    transaction hands its SMS and statement evidence to the survivor's transaction (unless that
--    one already holds a statement line), gives it notes and a manual category it lacks, and is
--    voided ('duplicate_line') once nothing evidences it. Non-surviving lines keep a key
--    prefixed 'merged:' so they cannot collide. Idempotent; it runs once here.
--
-- Evidence text is not changed; only the derived key, is_current and source_doc_codes.

create or replace function private.statement_line_key(
  p_account_code text, p_txn_date date, p_posting_date date, p_amount_original numeric,
  p_currency_original text, p_amount_aed numeric, p_direction text, p_description_raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(concat_ws('|', p_account_code, p_txn_date::text, p_posting_date::text,
    p_amount_original::numeric(14,2), p_currency_original, p_amount_aed::numeric(14,2), p_direction,
    upper(regexp_replace(btrim(p_description_raw), '\s+', ' ', 'g'))), 'UTF8')), 'hex')
$$;

create or replace function private.rekey_statement_lines(p_profile_code text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  r record;
  e record;
  v_keep_txn text;
  v_dup_txn text;
  v_rekeyed int := 0;
  v_merged int := 0;
  v_voided int := 0;
  v_stmt text;
begin
  create temp table if not exists _rk (
    line_code text primary key, profile_code text, stmt_code text, is_current boolean, old_key text,
    new_key text, occurrence smallint, has_ev boolean, created_at timestamptz,
    collides boolean not null default false, keep_code text
  ) on commit drop;
  truncate _rk;

  insert into _rk (line_code, profile_code, stmt_code, is_current, old_key, new_key, occurrence, has_ev, created_at)
  select l.line_code, l.profile_code, l.stmt_code, l.is_current, l.line_key,
         private.statement_line_key(l.account_code, l.txn_date, l.posting_date, l.amount_original,
           l.currency_original, l.amount_aed, l.direction,
           coalesce((select mo.original from private.masked_originals mo
                     where mo.table_name = 'statement_lines' and mo.row_code = l.line_code
                       and mo.column_name = 'description_raw'), l.description_raw)),
         l.occurrence,
         exists (select 1 from public.transaction_evidence x where x.line_code = l.line_code and x.is_active),
         l.created_at
  from public.statement_lines l
  where (p_profile_code is null or l.profile_code = p_profile_code)
    and l.line_key not like 'merged:%';

  -- Two stored keys of one statement that now hash the same: case variants of one row.
  update _rk k set collides = true
  from (select stmt_code, new_key from _rk group by stmt_code, new_key having count(distinct old_key) > 1) g
  where k.stmt_code = g.stmt_code and k.new_key = g.new_key;

  update _rk k set keep_code = s.keep
  from (select line_code,
               first_value(line_code) over (partition by stmt_code, new_key, occurrence
                                            order by is_current desc, has_ev desc, created_at, line_code) as keep
        from _rk where collides) s
  where k.line_code = s.line_code;

  -- Losers first take a key nothing else holds, so the survivors' new keys cannot collide.
  update public.statement_lines l set line_key = 'merged:' || l.line_key
  from _rk k where l.line_code = k.line_code and k.collides and k.keep_code <> k.line_code;
  update public.statement_lines l set line_key = k.new_key
  from _rk k
  where l.line_code = k.line_code and l.line_key <> k.new_key and (not k.collides or k.keep_code = k.line_code);
  get diagnostics v_rekeyed = row_count;

  for r in
    select k.line_code as lose, k.keep_code as keep, k.profile_code, k.stmt_code
    from _rk k where k.collides and k.keep_code <> k.line_code and k.is_current
    order by k.stmt_code, k.created_at
  loop
    update public.statement_lines s
    set source_doc_codes = s.source_doc_codes
          || array(select d from unnest(l.source_doc_codes) d where not (d = any (s.source_doc_codes)))
    from public.statement_lines l
    where s.line_code = r.keep and l.line_code = r.lose;

    select x.txn_code into v_dup_txn from public.transaction_evidence x where x.line_code = r.lose and x.is_active;
    select x.txn_code into v_keep_txn from public.transaction_evidence x where x.line_code = r.keep and x.is_active;
    perform private.detach_lines(r.profile_code, array[r.lose]);
    v_merged := v_merged + 1;

    if v_dup_txn is not null and v_keep_txn is not null and v_dup_txn <> v_keep_txn then
      for e in
        select x.* from public.transaction_evidence x
        where x.txn_code = v_dup_txn and x.is_active
          and (x.evidence_type = 'sms'
               or not exists (select 1 from public.transaction_evidence y
                              where y.txn_code = v_keep_txn and y.is_active and y.evidence_type = x.evidence_type))
      loop
        update public.transaction_evidence set is_active = false, deactivated_at = now()
        where evidence_code = e.evidence_code;
        insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, sms_code, role,
                                                 score, method, is_locked)
        values (v_keep_txn, e.profile_code, e.evidence_type, e.line_code, e.sms_code, e.role, e.score, e.method,
                e.is_locked);
      end loop;
      update public.transactions t
      set notes = coalesce(t.notes, d.notes),
          manual_category_code = coalesce(t.manual_category_code, d.manual_category_code)
      from public.transactions d
      where t.txn_code = v_keep_txn and d.txn_code = v_dup_txn
        and (t.notes is null and d.notes is not null
             or t.manual_category_code is null and d.manual_category_code is not null);
      if not exists (select 1 from public.transaction_evidence x where x.txn_code = v_dup_txn and x.is_active) then
        update public.transactions set voided_at = now(), void_reason = 'duplicate_line' where txn_code = v_dup_txn;
        v_voided := v_voided + 1;
      end if;
      perform private.refresh_transaction(v_dup_txn);
      perform private.refresh_transaction(v_keep_txn);
    end if;
  end loop;

  for v_stmt in select distinct k.stmt_code from _rk k where k.collides and k.is_current loop
    perform private.reconcile_statement(v_stmt);
  end loop;

  return jsonb_build_object('rekeyed', v_rekeyed, 'merged', v_merged, 'voided', v_voided);
end;
$$;

select private.rekey_statement_lines();

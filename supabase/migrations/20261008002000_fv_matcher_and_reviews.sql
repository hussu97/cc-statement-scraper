-- Final-verification fixes (docs/audit/07-final-verification.md):
--   FV-02  re-parse relink no longer holds same-amount repeat purchases as ambiguous
--   FV-03  reviews that name a statement that is no longer active are dismissed

-- ── FV-02: matcher: statement / history lines ──────────────────────────────
-- Same scoring and thresholds as 20261008001600. Two additions:
--   • lineage: a candidate transaction that was previously evidenced by this
--     same line, by a line with the same identity (line_key + occurrence), or
--     by a line of the same source document with the same date and amount, is
--     this line's own transaction coming back (a re-parse that moved the
--     document's lines to a new statement). Lineage pairs are matched first and
--     a rival without lineage does not make them ambiguous.
--   • date proximity: for a same-day pair, a rival one or more days away does
--     not make it ambiguous when that rival has its own same-day partner that
--     scores at least as well (consecutive-day repeat purchases: each line
--     takes the transaction on its own date).
create or replace function private.match_statement_lines(p_stmt_code text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  c record;
  v_linked int := 0;
  v_created int := 0;
  v_held int := 0;
  v_conflict boolean;
  v_tie boolean;
  v_txn text;
  v_line text;
  v_touched text[] := '{}';
begin
  create temp table if not exists _mx_lines (line_code text primary key, merchant_code text, state text) on commit drop;
  create temp table if not exists _mx_txns (txn_code text primary key) on commit drop;
  create temp table if not exists _mx_cand (
    line_code text, txn_code text, score numeric, ddays int, line_no int, txn_created timestamptz,
    line_key text, txn_sig text, maff numeric, lineage boolean
  ) on commit drop;
  truncate _mx_lines, _mx_txns, _mx_cand;

  -- Lines that need a home: current, no active evidence, not held by an open review.
  insert into _mx_lines (line_code, merchant_code, state)
  select l.line_code, private.resolve_merchant(l.description), 'open'
  from public.statement_lines l
  where l.stmt_code = p_stmt_code and l.is_current
    and not exists (select 1 from public.transaction_evidence e where e.line_code = l.line_code and e.is_active)
    and not exists (select 1 from public.match_reviews r
                    where r.profile_code = l.profile_code and r.subject_type = 'statement_line'
                      and r.subject_code = l.line_code and r.status = 'open');

  insert into _mx_cand
  select l.line_code, t.txn_code,
         private.match_score(
           l.amount_original, l.currency_original, l.amount_aed, l.txn_date, l.posting_date,
           l.description, ml.merchant_code, l.card_last4,
           t.amount_original, t.currency_original, t.amount_aed, t.txn_date, t.posting_date,
           t.description, t.merchant_code, cd.last4, coalesce(mr.variable_amount, false)
         ),
         abs(l.txn_date - t.txn_date), l.line_no, t.created_at,
         l.line_key,
         concat_ws('|', t.amount_original, t.currency_original, t.txn_date, t.merchant_code),
         private.merchant_affinity(l.description, t.description, ml.merchant_code, t.merchant_code),
         exists (
           select 1
           from public.transaction_evidence pe
           join public.statement_lines pl on pl.line_code = pe.line_code
           left join public.statements ps on ps.stmt_code = pl.stmt_code
           where pe.txn_code = t.txn_code and pe.profile_code = l.profile_code
             and not pe.is_active and pe.evidence_type = l.evidence_type
             and (pl.line_code = l.line_code
                  or (pl.line_key = l.line_key and pl.occurrence = l.occurrence)
                  or ((ps.doc_code = any (l.source_doc_codes) or pl.source_doc_codes && l.source_doc_codes)
                      and pl.txn_date = l.txn_date and pl.amount_original = l.amount_original
                      and pl.currency_original = l.currency_original and pl.direction = l.direction))
         )
  from _mx_lines ml
  join public.statement_lines l on l.line_code = ml.line_code
  join public.transactions t
    on t.profile_code = l.profile_code
   and t.account_code = l.account_code
   and t.direction = l.direction
   and (abs(t.txn_date - l.txn_date) <= 3
        or (t.posting_date is not null and l.posting_date is not null and abs(t.posting_date - l.posting_date) <= 1))
  left join public.cards cd on cd.card_code = t.card_code
  left join public.merchants mr on mr.merchant_code = t.merchant_code
  where not exists (
    select 1 from public.transaction_evidence e
    where e.txn_code = t.txn_code and e.is_active and e.evidence_type = l.evidence_type
  );
  delete from _mx_cand where score is null;

  for c in select * from _mx_cand
           order by (lineage and score >= 75) desc, score desc, ddays, line_no, txn_created, txn_code loop
    if c.score < 55 then
      exit;  -- lineage pairs come first only when ≥ 75, so the rest is score-ordered
    end if;
    if exists (select 1 from _mx_lines where line_code = c.line_code and state <> 'open')
       or exists (select 1 from _mx_txns where txn_code = c.txn_code) then
      continue;
    end if;

    v_conflict := exists (
      select 1 from _mx_cand x
      where x.score >= c.score - 15
        and x.maff > c.maff - 0.3
        and not (c.lineage and not x.lineage)
        and not exists (select 1 from _mx_txns where txn_code = x.txn_code)
        and not exists (select 1 from _mx_lines where line_code = x.line_code and state <> 'open')
        and (
          -- another transaction for this line…
          (x.line_code = c.line_code and x.txn_code <> c.txn_code and x.txn_sig <> c.txn_sig
           and not (c.ddays = 0 and x.ddays > 0 and exists (
             select 1 from _mx_cand y
             where y.txn_code = x.txn_code and y.line_code <> c.line_code and y.ddays = 0 and y.score >= x.score
               and not exists (select 1 from _mx_lines where line_code = y.line_code and state <> 'open'))))
          -- …or another line for this transaction
          or (x.txn_code = c.txn_code and x.line_code <> c.line_code and x.line_key <> c.line_key
              and not (c.ddays = 0 and x.ddays > 0 and exists (
                select 1 from _mx_cand y
                where y.line_code = x.line_code and y.txn_code <> c.txn_code and y.ddays = 0 and y.score >= x.score
                  and not exists (select 1 from _mx_txns where txn_code = y.txn_code))))
        )
    );
    v_tie := exists (
      select 1 from _mx_cand x
      where x.score >= c.score - 15
        and ((x.line_code = c.line_code and x.txn_code <> c.txn_code and x.txn_sig = c.txn_sig)
          or (x.txn_code = c.txn_code and x.line_code <> c.line_code and x.line_key = c.line_key))
    );

    if v_conflict or c.score < 75 then
      insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
      select l.profile_code, l.account_code, 'statement_line', l.line_code,
             case when v_conflict then 'ambiguous' else 'low_score' end,
             (select coalesce(jsonb_agg(jsonb_build_object('txn_code', x.txn_code, 'score', x.score) order by x.score desc), '[]'::jsonb)
                from (select * from _mx_cand x where x.line_code = c.line_code order by x.score desc limit 5) x)
      from public.statement_lines l where l.line_code = c.line_code
      on conflict do nothing;
      update _mx_lines set state = 'held' where line_code = c.line_code;
      v_held := v_held + 1;
      continue;
    end if;

    insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, role, score, method)
    select c.txn_code, l.profile_code, l.evidence_type, l.line_code,
           case when exists (select 1 from public.transaction_evidence e
                             where e.txn_code = c.txn_code and e.is_active and e.evidence_type = 'sms')
                then 'post' else 'primary' end,
           c.score,
           case when v_tie then 'tie' when c.score >= 85 then 'exact' else 'scored' end
    from public.statement_lines l where l.line_code = c.line_code;
    update _mx_lines set state = 'linked' where line_code = c.line_code;
    insert into _mx_txns values (c.txn_code);
    v_touched := v_touched || c.txn_code;
    v_linked := v_linked + 1;
  end loop;

  foreach v_txn in array v_touched loop
    perform private.refresh_transaction(v_txn);
  end loop;

  for v_line in select ml.line_code from _mx_lines ml
                join public.statement_lines l on l.line_code = ml.line_code
                where ml.state = 'open' order by l.line_no loop
    perform private.new_transaction_from_line(v_line);
    v_created := v_created + 1;
  end loop;

  return jsonb_build_object('linked', v_linked, 'created', v_created, 'held', v_held);
end;
$$;

-- ── FV-03: reviews about a statement that is no longer active ──────────────
-- supersede_statement / retire_doc_from_statement dismiss reviews whose
-- subject is the statement, but not period_overlap reviews of OTHER statements
-- that list it as a candidate. A trigger covers every path that retires a
-- statement:
--   • open reviews whose subject is the statement → dismissed
--   • open period_overlap reviews with no active candidate left → dismissed
create or replace function private.dismiss_stale_statement_reviews(p_profile text, p_stmt_code text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_a integer;
  v_b integer;
begin
  update public.match_reviews set status = 'dismissed',
    resolution = jsonb_build_object('auto', 'statement_superseded'), resolved_at = now()
  where profile_code = p_profile and status = 'open' and subject_type = 'statement' and subject_code = p_stmt_code;
  get diagnostics v_a = row_count;

  update public.match_reviews r set status = 'dismissed',
    resolution = jsonb_build_object('auto', 'overlap_candidates_superseded'), resolved_at = now()
  where r.profile_code = p_profile and r.status = 'open' and r.reason = 'period_overlap'
    and r.candidates @> jsonb_build_array(jsonb_build_object('stmt_code', p_stmt_code))
    and not exists (
      select 1 from jsonb_array_elements(r.candidates) cand
      join public.statements s on s.profile_code = p_profile and s.stmt_code = cand->>'stmt_code'
      where s.status = 'active');
  get diagnostics v_b = row_count;
  return v_a + v_b;
end;
$$;

create or replace function private.trg_statements_dismiss_stale_reviews()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.dismiss_stale_statement_reviews(new.profile_code, new.stmt_code);
  return null;
end;
$$;

create trigger statements_dismiss_stale_reviews
  after update of status on public.statements
  for each row
  when (old.status = 'active' and new.status <> 'active')
  execute function private.trg_statements_dismiss_stale_reviews();

-- One-off: reviews already left stale by earlier supersedes.
do $$
declare
  s record;
begin
  for s in select profile_code, stmt_code from public.statements where status <> 'active' loop
    perform private.dismiss_stale_statement_reviews(s.profile_code, s.stmt_code);
  end loop;
end $$;

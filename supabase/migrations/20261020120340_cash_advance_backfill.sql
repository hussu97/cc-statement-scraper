-- Cash withdrawals already ingested as purchases become cash advances (financial audit 2026-10-20).
--
-- A credit-card ATM withdrawal abroad is printed as the ATM owner's name, so the parser called it
-- a purchase: FAB "DTBKen NAIROBI KEN" KES 5,000 (2026-09-24), ADCB "BANGKOK BANK PHUKET"
-- THB 1,250 (2025-08-29), ENBD "ENBD MEYDAN 14 DUBAI ARE" AED 400 (2025-01-05). The bank's
-- CASH ADVANCE FEE right after it (same card, same date, only fee or VAT lines between) is what
-- says it was cash. Parser 2026.10.20 applies that pairing (ccs_parser.kinds.pair_cash_advances)
-- to new uploads; a re-parse revives an existing line as it was, kind included, so the lines
-- already in the ledger are corrected here, once, with the same rule.
--
-- `kind` is a parse field of the evidence (CLAUDE.md §1.10); the transaction follows through
-- private.refresh_transaction. Only 'purchase' debits change.

create or replace function private.mark_paired_cash_advances(p_stmt_code text default null)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_txns text[];
  v_txn text;
begin
  with paired as (
    update public.statement_lines l set kind = 'cash_advance'
    from public.statement_lines f
    where (p_stmt_code is null or l.stmt_code = p_stmt_code)
      and f.stmt_code = l.stmt_code and f.is_current and l.is_current
      and l.kind = 'purchase' and l.direction = 'debit' and f.direction = 'debit'
      and f.description ~ '^CASH ADV(ANCE)? FEE\M'
      and f.txn_date = l.txn_date and f.card_last4 is not distinct from l.card_last4
      and f.line_no > l.line_no and f.line_no - l.line_no <= 3
      and not exists (select 1 from public.statement_lines m
                      where m.stmt_code = l.stmt_code and m.is_current
                        and m.line_no > l.line_no and m.line_no < f.line_no
                        and m.kind not in ('fee', 'interest'))
    returning l.line_code, l.profile_code
  )
  select array_agg(distinct e.txn_code) into v_txns
  from paired p
  join public.transaction_evidence e on e.line_code = p.line_code and e.profile_code = p.profile_code and e.is_active;

  foreach v_txn in array coalesce(v_txns, '{}') loop
    perform private.refresh_transaction(v_txn);
  end loop;
  return coalesce(cardinality(v_txns), 0);
end;
$$;

select private.mark_paired_cash_advances();

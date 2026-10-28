-- The two Example Bank N credit-linked notes held on Swissquote (tasks/todo.md §15). Their term sheets
-- were stored by swissquote-sync on 27 Oct, but the reader then knew only equity notes, so the
-- read failed once and the ISINs stayed plain broker holdings (in terms_tried, never re-read).
-- Their terms were read from the stored PDFs by hand (28 Oct, no model call) and are created here
-- through create_structured_note, which adopts each broker holding with its flows and marks.
--
-- Guarded content: only a ledger holding that ISIN as a `broker` holding on a synced account and
-- without a note gets one; anywhere else (local, test, a second run) this does nothing. The PDFs
-- are linked only if they are in the `term-sheets` bucket under that ledger.
do $$
declare
  d jsonb;
  h record;
begin
  for d in select x from jsonb_array_elements(jsonb_build_array(
    jsonb_build_object(
      'isin', 'XS0000000108', 'sha', '00000000000000000000000000000000000000000000000000000000000000a1',
      'filename', 'FinalTS-XS0000000108-EXBN-CLN-Example-Airlines-2031.pdf',
      'name', 'Example Bank N CLN Example Airlines 10.5% 2031',
      'terms', jsonb_build_object(
        'note_type', 'credit_linked',
        'product_name', 'Fixed Rate Credit Linked Notes referenced to Example Airlines Group Inc due 20 December 2031',
        'isin', 'XS0000000108', 'issuer', 'Example Bank N Structured Issuance SA', 'guarantor', 'Example Bank N',
        'currency', 'USD', 'denomination', '1000', 'issue_price_pct', '100',
        'issue_date', '2024-10-15', 'maturity_date', '2031-12-20',
        'credit', jsonb_build_object(
          'reference_entity', 'Example Airlines Group Inc', 'seniority', 'Senior',
          'transaction_type', 'Standard North American Corporate', 'reference_obligation_isin', 'US0000AA0001',
          'coupon_rate_pct', '10.5', 'coupon_frequency', 'monthly', 'day_count', '30/360',
          'interest_start_date', '2024-10-15', 'first_coupon_date', '2024-10-20',
          'longstop_maturity_date', '2032-12-20', 'call_dates', '[]'::jsonb))),
    jsonb_build_object(
      'isin', 'XS0000000207', 'sha', '00000000000000000000000000000000000000000000000000000000000000b2',
      'filename', 'FinalTS-XS0000000207-EXBN-CLN-Example-Motors-2034.pdf',
      'name', 'Example Bank N CLN Example Motors 13.25% 2034',
      'terms', jsonb_build_object(
        'note_type', 'credit_linked',
        'product_name', 'Credit Linked Notes referenced to Example Motors Automotive PLC due 20 December 2034, coupon paid at maturity',
        'isin', 'XS0000000207', 'issuer', 'Example Bank N Structured Issuance SA', 'guarantor', 'Example Bank N',
        'currency', 'USD', 'denomination', '1000', 'issue_price_pct', '100',
        'issue_date', '2025-02-13', 'maturity_date', '2034-12-20',
        'credit', jsonb_build_object(
          'reference_entity', 'Example Motors Automotive PLC', 'seniority', 'Senior',
          'transaction_type', 'Standard European Corporate', 'reference_obligation_isin', 'XS0000RB0002',
          'coupon_rate_pct', '13.25', 'coupon_frequency', 'at_maturity', 'day_count', '30/360',
          'interest_start_date', '2025-02-13', 'longstop_maturity_date', '2035-12-20',
          'call_dates', jsonb_build_array('2025-12-20', '2026-12-20', '2027-12-20', '2028-12-20', '2029-12-20',
                                          '2030-12-20', '2031-12-20', '2032-12-20', '2033-12-20'),
          'call_notice_days', 10))))) x
  loop
    for h in
      select ho.profile_code, ho.holding_code,
             (select bt.account_code from public.broker_transactions bt
              where bt.holding_code = ho.holding_code and bt.kind = 'buy' and not bt.is_reversal
              order by bt.booked_at limit 1) as account_code
      from public.holdings ho
      where ho.external_ref = d->>'isin' and ho.kind = 'broker'
        and not exists (select 1 from public.structured_notes n
                        where n.holding_code = ho.holding_code and n.status <> 'cancelled')
    loop
      continue when h.account_code is null or not private.is_broker_account(h.profile_code, h.account_code);
      perform public.create_structured_note(h.profile_code, jsonb_build_object(
        'name', d->>'name', 'institution', 'Swissquote',
        'notes', 'Terms read from the Example Bank N final term sheet (28 Oct 2026).',
        'terms', d->'terms',
        'investment', jsonb_build_object('funding_account_code', h.account_code),
        'termsheet_path', case when exists (select 1 from storage.objects o where o.bucket_id = 'term-sheets'
                                            and o.name = h.profile_code || '/' || (d->>'sha') || '.pdf')
                               then h.profile_code || '/' || (d->>'sha') || '.pdf' end,
        'termsheet_filename', d->>'filename',
        'extracted_terms', jsonb_build_object('read_by', 'hand', 'read_on', '2026-10-28', 'terms', d->'terms')));
    end loop;
  end loop;
end;
$$;

-- ADCB's FX markup is its 2.99% margin plus the card scheme's charge, not 2.99% all-in.
--
-- 20261011000100 read ADCB's price guide ("margin … levied on the wholesale foreign exchange market
-- rate (including any processing fee)") as an all-in 2.99%. Production says otherwise: all 20
-- posted ADCB Infinite Visa USD purchases (2025-01-18 .. 2026-08-22, AED amounts printed by ADCB)
-- were billed at the 3.6725 peg × 1.0402–1.0420, median 1.0418. That is the same model as the other
-- banks: (1 + 2.99%) × 1.0115 (Visa ≈ 1.15%) − 1 = 4.1744%. (FAB USD, 51 rows, and Mashreq USD,
-- 4 rows, match their markups to the second decimal; ADCB was the outlier.)
--
-- Guarded content change: only a row still holding the old value is updated. Estimates are
-- re-derived (ADCB has none pending today; this keeps the rule for any that exist).

update private.bank_fx_fees
set markup = 0.041744,
    note = 'Infinite Visa: 2.99% margin + Visa ~1.15% (USD bills 2025-26: median peg x 1.0418); Traveller 0%',
    updated_at = now()
where bank_code = 'ADCB' and markup = 0.029900;

do $$
declare
  r record;
  v_state text;
  v_msg text;
begin
  for r in
    select t.txn_code, t.profile_code from public.transactions t
    join public.accounts a on a.account_code = t.account_code
    where a.bank_code = 'ADCB' and (t.amount_aed_is_estimate or (t.amount_aed is null and t.currency_original <> 'AED'))
    order by t.txn_code
  loop
    begin
      perform private.refresh_transaction(r.txn_code);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('adcb_fx_markup', r.profile_code, r.txn_code, v_state, v_msg);
    end;
  end loop;
end;
$$;

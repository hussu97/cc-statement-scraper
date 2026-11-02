-- FAB's standing instruction ("Your standing instructions of AED … to DEWA …") is charged to the FAB
-- credit card, not drawn from the bank account: the card's statement carries it as a purchase
-- ("FAB - DEWA …") on the day the SMS reports. 20261102080341 seeded it as an account debit, so it
-- landed on the FAB bank account as a transfer out, which no spend view shows.
--
-- The SMS names no card, so as a card purchase it goes to the bank's one active credit card account
-- (private.process_sms); a profile with none, or several, gets an unknown_card review.

-- ── content (guarded, CLAUDE.md §1.9) ───────────────────────────────────────
update public.sms_templates
set msg_kind = 'purchase'
where bank_code = 'FAB' and name = 'FAB standing instruction' and msg_kind = 'account_debit'
  and body_pattern = 'standing instructions? of ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?) to (.+?) for consumer number [0-9]+ has been processed on ([0-9]{2}/[0-9]{2}/[0-9]{4})';

-- ── data: standing instructions already on a bank account ───────────────────
-- Each moves, with its transaction, to the bank's one active credit card account: the message
-- becomes a purchase and the transaction a card purchase. Only a transaction this message alone
-- evidences moves (a statement line would already have placed it); with no single card account
-- the message stays where it is.
do $$
declare
  r record;
  v_card text;
  v_n int;
begin
  for r in
    select s.sms_code, s.profile_code, s.bank_code, s.account_code
    from public.sms_messages s
    join public.sms_templates t on t.template_code = s.template_code
    join public.accounts a on a.account_code = s.account_code
    where t.bank_code = 'FAB' and t.name = 'FAB standing instruction' and t.msg_kind = 'purchase'
      and s.parse_status = 'parsed' and s.msg_kind = 'account_debit' and a.kind <> 'credit_card'
    order by s.received_at, s.sms_code
  loop
    select count(*), min(a.account_code) into v_n, v_card
    from public.accounts a
    where a.profile_code = r.profile_code and a.bank_code = r.bank_code and a.status = 'active'
      and a.kind = 'credit_card';
    continue when v_n <> 1;

    update public.sms_messages set msg_kind = 'purchase', account_code = v_card
    where sms_code = r.sms_code;
    update public.transactions t set account_code = v_card, kind = 'purchase', direction = 'debit'
    from public.transaction_evidence e
    where e.sms_code = r.sms_code and e.is_active and t.txn_code = e.txn_code
      and t.account_code = r.account_code and t.kind = 'transfer_out'
      and not exists (select 1 from public.transaction_evidence o
                      where o.txn_code = t.txn_code and o.sms_code is distinct from r.sms_code);
    perform private.refresh_transaction(e.txn_code)
    from public.transaction_evidence e
    where e.sms_code = r.sms_code and e.is_active;
  end loop;
end;
$$;

-- An own transfer's other leg is a transfer (2026-10-28). v_cash_flow's rule (a) called a bank
-- transfer a move between the ledger's own accounts when another of its bank accounts had the
-- opposite transfer of the same AED amount within 3 days, whatever that leg was. A salary credit
-- of 50,000 into FAB …9221 therefore made a 50,000 payment to someone else from Wio …9204 look
-- internal (Alice, 28 Oct). The other leg now counts only while it is unfiled or filed under a
-- transfer category: money in filed as income (Salary), or any other kind, is not one side of a
-- move. Only that condition changes.

create or replace view public.v_cash_flow with (security_invoker = true) as
select s.profile_code, s.txn_code, s.account_code, s.txn_date, 'spend'::text as flow, s.instrument,
       s.spend_aed::numeric(14,2) as amount_aed, null::text as holding_code
from public.v_spend s
union all
select t.profile_code, t.txn_code, t.account_code, t.txn_date,
       case
         when lk.holding_code is not null then 'saving'
         when t.direction = 'credit' then
           case c.kind when 'income' then 'income' when 'transfer' then 'internal_in'
                       else case when c.kind is null and own.yes then 'internal_in'
                                 else 'money_in' end end
         when exists (select 1 from public.card_transfers x where x.from_txn_code = t.txn_code) then 'card_repayment'
         else case c.kind when 'support' then 'support' when 'saving' then 'saving'
                          when 'transfer' then 'internal_out'
                          when 'spend' then 'spend_transfer' when 'fee' then 'spend_transfer'
                          else case when c.kind is null and own.yes then 'internal_out'
                                    else 'money_out' end end
       end,
       null::text,
       -- Money back out of a holding into the bank is negative saving.
       (case when lk.holding_code is not null and t.direction = 'credit' then -t.amount_aed else t.amount_aed end)::numeric(14,2),
       lk.holding_code
from public.transactions t
join public.accounts a on a.account_code = t.account_code and a.kind in ('current', 'savings')
left join public.categories c on c.category_code = t.effective_category_code
cross join lateral (select private.active_flow_holding(t.txn_code) as holding_code) lk
cross join lateral (
  select exists (
    -- (a) the other leg, on another of the ledger's bank accounts
    select 1 from public.transactions o
    join public.accounts oa on oa.account_code = o.account_code and oa.kind in ('current', 'savings')
    left join public.categories oc on oc.category_code = o.effective_category_code
    where o.profile_code = t.profile_code and o.account_code <> t.account_code
      and o.kind = case t.kind when 'transfer_out' then 'transfer_in' else 'transfer_out' end
      and o.amount_aed = t.amount_aed and abs(o.txn_date - t.txn_date) <= 3
      and o.status in ('pending', 'posted')
      -- unfiled, or filed as a transfer: a salary credit is nobody's other leg
      and coalesce(oc.kind, 'transfer') = 'transfer'
  ) or (t.kind = 'transfer_out' and exists (
    -- (b) a transfer notice from this account, same amount, naming another of its bank accounts
    select 1 from public.sms_messages n
    join public.accounts d
      on d.profile_code = n.profile_code and d.account_code <> n.account_code
     and d.kind in ('current', 'savings') and d.account_ref is not null
     and right(regexp_replace(coalesce(n.parsed_fields->>'counterparty_ref', ''), '[^0-9]', '', 'g'),
               length(d.account_ref)) = d.account_ref
    where n.profile_code = t.profile_code and n.account_code = t.account_code
      and n.msg_kind = 'transfer_notice' and n.parse_status = 'parsed'
      and n.amount = t.amount_original and abs(public.dubai_date(n.event_at) - t.txn_date) <= 1
  )) as yes
) own
where t.kind in ('transfer_in', 'transfer_out') and t.status in ('pending', 'posted')
  and t.amount_aed is not null and (lk.holding_code is not null or coalesce(c.kind, '') <> 'ignore')
union all
-- A card or debit-card purchase filed under saving or support (an investment plan paid by card),
-- or linked to a holding, is that flow: v_spend leaves it out, so it would otherwise not appear.
select t.profile_code, t.txn_code, t.account_code, t.txn_date,
       case when lk.holding_code is not null then 'saving' else c.kind end,
       case when a.kind = 'credit_card' then 'credit_card' else 'debit_card' end,
       (case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)::numeric(14,2),
       lk.holding_code
from public.transactions t
join public.accounts a on a.account_code = t.account_code
left join public.categories c on c.category_code = t.effective_category_code
cross join lateral (select private.active_flow_holding(t.txn_code) as holding_code) lk
where t.status in ('pending', 'posted') and not t.exclude_from_spend and t.amount_aed is not null
  and (lk.holding_code is not null or c.kind in ('saving', 'support'))
  and ((t.direction = 'debit' and t.kind in ('purchase', 'fee', 'interest', 'cash_advance'))
       or (t.direction = 'credit' and t.kind = 'refund'));

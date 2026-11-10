-- Own-account transfers are linked (2026-11-10). card_transfers paired a card payment with a
-- bank transfer or another payment, and nothing else, so a move between two of the ledger's own
-- bank accounts (a transfer out of a savings account and the same amount into a current account)
-- stayed two unrelated rows.
--
-- 1. private.transfer_pair_ok(t, c): the one definition of a linkable pair. As before, a card
--    repayment (one side a card payment, the other a payment or a bank transfer_out). New: a bank
--    transfer_out (debit) and a bank transfer_in (credit) on two current/savings accounts, each
--    side unfiled or filed under a transfer category, which is v_cash_flow's own-transfer rule (a):
--    a salary credit filed as income is nobody's other leg. Both: same profile, other account,
--    opposite directions, the same AED amount, pending or posted, at most 3 days apart.
--    card_transfer_candidates and link_card_transfer use it; the "each is the other's only
--    candidate" rule is unchanged, so an ambiguous pair stays unlinked.
-- 2. The trigger also runs for transfer_in rows and when a row's category inputs change (filing a
--    leg as income drops its link; filing it back as a transfer relinks it).
-- 3. v_cash_flow: card_repayment only when the linked partner is a card payment; a linked own
--    transfer keeps its flow (internal_in/out, from its category or rule (a)).
-- 4. v_transactions: the peer of a bank-account leg has no card, so transfer_card_last4 falls
--    back to the account's account_ref (clients show "Paid to <bank> •<account_ref>").
-- 5. Existing transfers pick up their partner.

-- ── 1. the pair rule ────────────────────────────────────────────────────────
create or replace function private.transfer_files_as_transfer(p_category_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select c.kind from public.categories c where c.category_code = p_category_code), 'transfer') = 'transfer'
$$;

create or replace function private.transfer_pair_ok(t public.transactions, c public.transactions)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select t.profile_code = c.profile_code
     and t.txn_code <> c.txn_code
     and t.account_code <> c.account_code
     and t.direction <> c.direction
     and t.amount_aed is not null and t.amount_aed = c.amount_aed
     and t.status in ('pending', 'posted') and c.status in ('pending', 'posted')
     and abs(t.txn_date - c.txn_date) <= 3
     and (
       -- a card repayment: a card payment and a payment or bank transfer out
       ((t.kind = 'payment' or (t.kind = 'transfer_out' and t.direction = 'debit'))
        and (c.kind = 'payment' or (c.kind = 'transfer_out' and c.direction = 'debit'))
        and (t.kind = 'payment' or c.kind = 'payment'))
       or
       -- a move between two of the ledger's own bank accounts
       (((t.kind = 'transfer_out' and t.direction = 'debit' and c.kind = 'transfer_in' and c.direction = 'credit')
         or (t.kind = 'transfer_in' and t.direction = 'credit' and c.kind = 'transfer_out' and c.direction = 'debit'))
        and exists (select 1 from public.accounts a where a.account_code = t.account_code and a.kind in ('current', 'savings'))
        and exists (select 1 from public.accounts a where a.account_code = c.account_code and a.kind in ('current', 'savings'))
        and private.transfer_files_as_transfer(t.effective_category_code)
        and private.transfer_files_as_transfer(c.effective_category_code))
     )
$$;

create or replace function private.card_transfer_candidates(p_txn_code text)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select c.txn_code
  from public.transactions t
  join public.transactions c
    on c.profile_code = t.profile_code
   and c.amount_aed = t.amount_aed
   and c.txn_date between t.txn_date - 3 and t.txn_date + 3
  where t.txn_code = p_txn_code
    and private.transfer_pair_ok(t, c)
    and not exists (select 1 from public.card_transfers x
                    where x.from_txn_code = c.txn_code or x.to_txn_code = c.txn_code)
$$;

create or replace function private.link_card_transfer(p_txn_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.transactions%rowtype;
  v_link public.card_transfers%rowtype;
  v_partner text;
  v_count integer;
begin
  select * into t from public.transactions where txn_code = p_txn_code;
  if not found then
    return null;
  end if;

  select * into v_link from public.card_transfers
  where from_txn_code = p_txn_code or to_txn_code = p_txn_code;
  if found then
    v_partner := case when v_link.from_txn_code = p_txn_code then v_link.to_txn_code else v_link.from_txn_code end;
    -- Still a valid pair: keep it.
    if exists (select 1 from public.transactions p where p.txn_code = v_partner and private.transfer_pair_ok(t, p)) then
      return v_link.transfer_code;
    end if;
    delete from public.card_transfers where transfer_code = v_link.transfer_code;
    perform private.link_card_transfer(v_partner);
  end if;

  select count(*), min(c) into v_count, v_partner from private.card_transfer_candidates(p_txn_code) c;
  if v_count <> 1 then
    return null;
  end if;
  -- The partner must have no other candidate either.
  if (select count(*) from private.card_transfer_candidates(v_partner)) <> 1 then
    return null;
  end if;

  insert into public.card_transfers (profile_code, from_txn_code, to_txn_code)
  select t.profile_code,
         case when t.direction = 'debit' then t.txn_code else v_partner end,
         case when t.direction = 'debit' then v_partner else t.txn_code end
  on conflict do nothing
  returning transfer_code into v_link.transfer_code;
  return v_link.transfer_code;
end;
$$;

-- ── 2. the trigger ──────────────────────────────────────────────────────────
create or replace function private.transactions_link_card_transfer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind in ('payment', 'transfer_out', 'transfer_in')
     or (tg_op = 'UPDATE' and old.kind in ('payment', 'transfer_out', 'transfer_in')) then
    perform private.link_card_transfer(new.txn_code);
  end if;
  return null;
end;
$$;

-- effective_category_code is generated, so the trigger watches its inputs.
create or replace trigger transactions_card_transfer
  after insert or update of kind, direction, status, amount_aed, txn_date, account_code,
    manual_category_code, rule_category_code, merchant_category_code, merchant_category_source
  on public.transactions
  for each row execute function private.transactions_link_card_transfer();

comment on table public.card_transfers is
  'A payment between two of the ledger''s accounts (from_txn_code, debit; to_txn_code, credit): a card repayment or a move between own bank accounts, matched by private.link_card_transfer.';

-- ── 3. cash flow: card_repayment needs a card payment on the other side ─────
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
         when exists (select 1 from public.card_transfers x
                      join public.transactions p on p.txn_code = x.to_txn_code and p.kind = 'payment'
                      where x.from_txn_code = t.txn_code) then 'card_repayment'
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

-- ── 4. v_transactions: a bank-account peer is named by its account_ref ────────
create or replace view public.v_transactions with (security_invoker = true) as
select t.txn_code,
       t.profile_code,
       t.account_code,
       t.card_code,
       t.status,
       t.kind,
       t.direction,
       t.txn_date,
       t.txn_at,
       t.posting_date,
       t.stmt_code,
       t.merchant_code,
       t.description,
       m.display_name as merchant_name,
       t.amount_original,
       t.currency_original,
       t.amount_aed,
       t.amount_aed_is_estimate,
       t.fx_rate,
       t.auth_amount,
       t.amount_source,
       t.related_txn_code,
       t.exclude_from_spend,
       t.notes,
       t.effective_category_code as category_code,
       c.name as category_name,
       c.color_token as category_color,
       c.kind as category_kind,
       case
         when t.manual_category_code is not null then 'manual'
         when t.merchant_category_source = 'manual' and t.merchant_category_code is not null then 'merchant'
         when t.rule_category_code is not null then 'rule'
         when t.merchant_category_source = 'llm' and t.merchant_category_code is not null then 'suggested'
       end as category_source,
       a.bank_code,
       cd.last4 as card_last4,
       a.nickname as account_nickname,
       coalesce((select true from public.transaction_evidence e
                 where e.txn_code = t.txn_code and e.is_active and e.evidence_type = 'sms'
                 limit 1), false) as has_sms,
       coalesce((select true from public.transaction_evidence e
                 where e.txn_code = t.txn_code and e.is_active and e.evidence_type in ('statement_line', 'history_line')
                 limit 1), false) as has_statement,
       t.created_at,
       t.updated_at,
       -- Card transfers (appended, so the column order above is unchanged).
       tr.transfer_txn_code,
       tr.transfer_bank_code,
       tr.transfer_card_last4,
       -- Wealth mode (appended): the account's kind, and whether the row is spending business.
       a.kind as account_kind,
       (a.kind = 'credit_card' or t.kind in ('purchase', 'refund', 'fee', 'interest', 'cash_advance')) as in_spending,
       -- Investments (appended): the holding a payment is linked to.
       lk.holding_code,
       lk.holding_name
from public.transactions t
join public.accounts a on a.account_code = t.account_code
left join public.cards cd on cd.card_code = t.card_code
left join public.categories c on c.category_code = t.effective_category_code
left join public.merchants m on m.merchant_code = t.merchant_code
left join lateral (
  select ot.txn_code as transfer_txn_code, oa.bank_code as transfer_bank_code,
         coalesce(oc.last4, oa.account_ref) as transfer_card_last4
  from public.card_transfers ct
  join public.transactions ot
    on ot.txn_code = case when ct.from_txn_code = t.txn_code then ct.to_txn_code else ct.from_txn_code end
  join public.accounts oa on oa.account_code = ot.account_code
  left join public.cards oc on oc.card_code = ot.card_code
  where ct.from_txn_code = t.txn_code or ct.to_txn_code = t.txn_code
  limit 1
) tr on true
left join lateral (
  select f.holding_code, h.name as holding_name
  from public.holding_flows f join public.holdings h on h.holding_code = f.holding_code
  where f.txn_code = t.txn_code and f.removed_at is null
) lk on true;

-- ── 5. existing transfers pick up their partner ─────────────────────────────
select private.link_card_transfer(t.txn_code)
from public.transactions t
where t.kind in ('transfer_out', 'transfer_in') and t.status in ('pending', 'posted')
  and not exists (select 1 from public.card_transfers x
                  where x.from_txn_code = t.txn_code or x.to_txn_code = t.txn_code)
order by t.txn_date, t.txn_code;

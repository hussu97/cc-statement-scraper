-- Card transfers: a payment made from one card to another, linked across the two ledgers.
--
-- Wio's credit card pays other banks' cards from its credit line ("ENBD payment", "EIB AZ
-- payment"): a debit `payment` on the Wio account. The paid card's statement shows the same
-- amount as a credit `payment` ("TRANSFER PAYMENT RECEIVED THANK YOU") the same day or the next.
-- Production, 2026-10-12: Tejasvie's 11 Wio card payments each had exactly one such credit
-- (EIB 6177 ×4, EIB 4557 ×2, ENBD 1287 ×3, Mashreq 4421 ×2).
--
-- `transactions.related_txn_code` already means "this reverses that" (the drawer's Reverses /
-- Reversed by, private.void_released_authorisations), so the pair gets its own table.
--
-- Matching (private.link_card_transfer), on every insert/update of a transaction's matching
-- facts and once here for every profile:
--   * both sides are `payment`, pending or posted, with an AED amount;
--   * opposite directions, different accounts, same profile, the same AED amount;
--   * dates at most 3 days apart;
--   * neither side is already linked, and each is the other's only candidate. An ambiguous
--     pair (two equal payments in the window) stays unlinked rather than guessed.
-- A side that stops qualifying (voided, orphaned, re-kinded) drops its link, and its former
-- partner looks for a new one. Spend is unaffected: payments were never spend (v_spend).

-- ── table ───────────────────────────────────────────────────────────────────
create table public.card_transfers (
  transfer_code text primary key default public.gen_code('trf')
    check (transfer_code ~ '^trf_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  from_txn_code text not null,   -- the debit: the card that paid
  to_txn_code text not null,     -- the credit: the card that was paid
  created_at timestamptz not null default now(),
  constraint card_transfers_from_uq unique (from_txn_code),
  constraint card_transfers_to_uq unique (to_txn_code),
  constraint card_transfers_distinct check (from_txn_code <> to_txn_code),
  constraint card_transfers_from_fkey foreign key (profile_code, from_txn_code)
    references public.transactions(profile_code, txn_code) on delete cascade,
  constraint card_transfers_to_fkey foreign key (profile_code, to_txn_code)
    references public.transactions(profile_code, txn_code) on delete cascade
);
create index card_transfers_profile_idx on public.card_transfers(profile_code);
comment on table public.card_transfers is
  'A payment from one card (from_txn_code, debit) to another (to_txn_code, credit), matched by private.link_card_transfer.';

alter table public.card_transfers enable row level security;
create policy card_transfers_member_read on public.card_transfers for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.card_transfers to authenticated;
grant all on public.card_transfers to service_role;

-- Candidate lookups: payments by profile and amount.
create index if not exists transactions_payment_amount_idx
  on public.transactions(profile_code, amount_aed) where kind = 'payment';

-- ── matching ────────────────────────────────────────────────────────────────
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
   and c.account_code <> t.account_code
   and c.kind = 'payment'
   and c.direction <> t.direction
   and c.amount_aed = t.amount_aed
   and c.status in ('pending', 'posted')
   and abs(c.txn_date - t.txn_date) <= 3
  where t.txn_code = p_txn_code
    and t.kind = 'payment' and t.status in ('pending', 'posted') and t.amount_aed is not null
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
    if exists (
      select 1 from public.transactions p
      where p.txn_code = v_partner
        and t.kind = 'payment' and p.kind = 'payment'
        and t.status in ('pending', 'posted') and p.status in ('pending', 'posted')
        and t.direction <> p.direction and t.account_code <> p.account_code
        and t.amount_aed = p.amount_aed and abs(t.txn_date - p.txn_date) <= 3
    ) then
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

create or replace function private.transactions_link_card_transfer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind = 'payment' or (tg_op = 'UPDATE' and old.kind = 'payment') then
    perform private.link_card_transfer(new.txn_code);
  end if;
  return null;
end;
$$;

create trigger transactions_card_transfer
  after insert or update of kind, direction, status, amount_aed, txn_date, account_code
  on public.transactions
  for each row execute function private.transactions_link_card_transfer();

-- ── v_transactions: the other side of a card transfer ───────────────────────
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
       tr.transfer_card_last4
from public.transactions t
join public.accounts a on a.account_code = t.account_code
left join public.cards cd on cd.card_code = t.card_code
left join public.categories c on c.category_code = t.effective_category_code
left join public.merchants m on m.merchant_code = t.merchant_code
left join lateral (
  select ot.txn_code as transfer_txn_code, oa.bank_code as transfer_bank_code, oc.last4 as transfer_card_last4
  from public.card_transfers ct
  join public.transactions ot
    on ot.txn_code = case when ct.from_txn_code = t.txn_code then ct.to_txn_code else ct.from_txn_code end
  join public.accounts oa on oa.account_code = ot.account_code
  left join public.cards oc on oc.card_code = ot.card_code
  where ct.from_txn_code = t.txn_code or ct.to_txn_code = t.txn_code
  limit 1
) tr on true;

-- ── backfill: every profile's existing payments ─────────────────────────────
select count(private.link_card_transfer(t.txn_code))
from public.transactions t
where t.kind = 'payment' and t.direction = 'debit' and t.status in ('pending', 'posted');

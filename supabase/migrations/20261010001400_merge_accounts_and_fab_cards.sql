-- Merge two accounts of one card relationship, and correct production's FAB cards.
--
-- A FAB account's primary card number changes when the card is replaced, and its statements
-- may name a supplementary card as the card of the statement. Ingest created a new account
-- for a card number it had never seen, so one FAB relationship became two accounts:
--   acc_…qr96: 6290 (original) + 2132 (marked supplementary), statements 2025-03 … 2025-08
--   acc_…zk5j: 2777, statements 2025-09 … 2026-10
-- The owner's account of it: 2132 replaced 6290, and 2777 is the supplementary card.
--
-- private.merge_accounts(profile, from, into) moves every row of `from` (cards, statements,
-- statement lines, transactions, SMS, match reviews) onto `into` and closes the emptied
-- `from` account (closed, not deleted: a destructive migration stops the deploy). Codes stay
-- as they are; nothing is re-derived because nothing about the evidence changes, only the
-- account it belongs to. Refuses accounts of another profile or bank, and fails
-- (statements_identity_uq) if both accounts hold a statement for one date.

create or replace function private.merge_accounts(p_profile_code text, p_from text, p_into text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  f public.accounts%rowtype;
  t public.accounts%rowtype;
  v_cards int; v_stmts int; v_lines int; v_txns int; v_sms int; v_reviews int;
begin
  perform private.lock_profile(p_profile_code);
  select * into f from public.accounts where account_code = p_from and profile_code = p_profile_code;
  select * into t from public.accounts where account_code = p_into and profile_code = p_profile_code;
  if f.account_code is null or t.account_code is null then
    raise exception 'both accounts must belong to profile %', p_profile_code using errcode = 'P0002';
  end if;
  if f.account_code = t.account_code then
    raise exception 'cannot merge an account into itself' using errcode = '22023';
  end if;
  if f.bank_code <> t.bank_code then
    raise exception 'cannot merge a % account into a % account', f.bank_code, t.bank_code using errcode = '22023';
  end if;

  update public.cards set account_code = p_into where account_code = p_from;
  get diagnostics v_cards = row_count;
  update public.statements set account_code = p_into where account_code = p_from;
  get diagnostics v_stmts = row_count;
  update public.statement_lines set account_code = p_into where account_code = p_from;
  get diagnostics v_lines = row_count;
  update public.transactions set account_code = p_into where account_code = p_from;
  get diagnostics v_txns = row_count;
  update public.sms_messages set account_code = p_into where account_code = p_from;
  get diagnostics v_sms = row_count;
  update public.match_reviews set account_code = p_into where account_code = p_from;
  get diagnostics v_reviews = row_count;

  update public.accounts set
    credit_limit = coalesce(f.credit_limit, t.credit_limit),   -- the merged-in account is the newer one
    product_name = coalesce(t.product_name, f.product_name),
    nickname = coalesce(t.nickname, f.nickname),
    cycle_close_day = coalesce(t.cycle_close_day, f.cycle_close_day)
  where account_code = p_into;
  update public.accounts set status = 'closed' where account_code = p_from;

  return jsonb_build_object('account_code', p_into, 'merged_account_code', p_from, 'cards', v_cards,
                            'statements', v_stmts, 'statement_lines', v_lines, 'transactions', v_txns,
                            'sms_messages', v_sms, 'match_reviews', v_reviews);
end;
$$;

-- ── production: the Hussain profile's FAB cards ─────────────────────────────
-- Guarded: runs only while every row still holds exactly the state described above, so it
-- is a no-op on any other database and on a second run.
do $$
declare
  c_profile constant text := 'prf_01m4dnbdpbztxjfe7mej2fpqt2';
  c_old_acc constant text := 'acc_01m4dnfe8fxe24yx3dpn5dqr96';
  c_new_acc constant text := 'acc_01m4dngkehfgmat707swq32k5j';
  c_6290 constant text := 'crd_01m4dnfe8ggnw6hb5ye8xprjvb';
  c_2132 constant text := 'crd_01m4dnfydyxdy5nedpa6gsybw2';
  c_2777 constant text := 'crd_01m4dngkejepkd7s0ss5n2py6k';
begin
  if (select count(*) from public.cards
      where (card_code, profile_code, account_code, bank_code, last4, is_supplementary, status) in (
        (c_6290, c_profile, c_old_acc, 'FAB', '6290', false, 'active'),
        (c_2132, c_profile, c_old_acc, 'FAB', '2132', true, 'active'),
        (c_2777, c_profile, c_new_acc, 'FAB', '2777', false, 'active'))) <> 3
     or (select count(*) from public.cards where account_code in (c_old_acc, c_new_acc)) <> 3 then
    return;
  end if;

  perform private.merge_accounts(c_profile, c_new_acc, c_old_acc);
  update public.cards set is_supplementary = false where card_code = c_2132 and is_supplementary;
  update public.cards set is_supplementary = true where card_code = c_2777 and not is_supplementary;
  update public.cards set status = 'replaced' where card_code = c_6290 and status = 'active';
end;
$$;

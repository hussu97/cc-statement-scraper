-- Replacement cards (a bank re-issues a card with a new number on the same account).
--
-- Before: a statement or history extract for a card number the profile had never seen
-- created a NEW account, so a replaced card split the ledger in two (the SIB card ending
-- 9218 was replaced; the new card's history would have become a second SIB account).
--
-- Now, two ways a new card number joins an existing account:
--   1. The owner says so: public.add_replacement_card(profile, old card_code, new last4)
--      registers the new number on the old card's account and marks the old card 'replaced'.
--   2. Automatically, for a transaction-history extract only (it carries no account
--      identity, totals or statement reference, so it cannot clobber a real statement): the
--      bank has exactly one active account in the profile, the card type matches when both
--      are known, and the new card's first transaction is not earlier than 31 days before
--      the account's last current line. Its older cards are then marked 'replaced'.
--      Anything else still creates a new account, as before (two real cards on two accounts
--      must never merge).
-- Old transactions keep their old card_code; new lines and SMS carry the new card, and SMS
-- held as unknown_card for the new number are re-processed once the card exists.

create or replace function private.successor_card_account(p_profile text, p_bank text, p_card_type text,
                                                          p_first_txn_date date)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_n int;
  v_account text;
  v_product text;
  v_last date;
begin
  if p_first_txn_date is null then
    return null;
  end if;
  select count(*), min(a.account_code) into v_n, v_account
  from public.accounts a where a.profile_code = p_profile and a.bank_code = p_bank and a.status = 'active';
  if v_n <> 1 then
    return null;
  end if;
  select a.product_name into v_product from public.accounts a where a.account_code = v_account;
  if p_card_type is not null and v_product is not null
     and upper(btrim(p_card_type)) <> upper(btrim(v_product)) then
    return null;
  end if;
  select max(l.txn_date) into v_last from public.statement_lines l
  where l.profile_code = p_profile and l.account_code = v_account and l.is_current;
  if v_last is not null and p_first_txn_date < v_last - 31 then
    return null;   -- overlapping activity: a second live card, not a replacement
  end if;
  return v_account;
end;
$$;

-- resolve_statement_account with the statement kind and its first transaction date.
create or replace function private.resolve_statement_account(
  p_profile text, p_bank text, p_last4 text, p_holder text, p_card_type text, p_credit_limit numeric,
  p_doc_code text, p_reference text, p_reference_source text, p_kind text, p_first_txn_date date
)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_account text;
  v_n int;
  v_accounts text[];
  v_new_card boolean := false;
begin
  if p_last4 is not null then
    select account_code into v_account from public.cards
    where profile_code = p_profile and bank_code = p_bank and last4 = p_last4;
    -- An unknown card on a history extract: the successor of the account's card?
    if v_account is null and p_kind = 'history_extract' then
      v_account := private.successor_card_account(p_profile, p_bank, p_card_type, p_first_txn_date);
      v_new_card := v_account is not null;
    end if;
  else
    -- No card number (the parser's "unknown card" sentinel). Never invent an
    -- account when the choice is ambiguous: that duplicated the ledger on every
    -- ingest (DB-07).
    -- 1. A re-parse of the same document keeps its account.
    select array_agg(distinct st.account_code) into v_accounts
    from public.statements st join public.accounts a on a.account_code = st.account_code
    where st.profile_code = p_profile and st.doc_code = p_doc_code and a.bank_code = p_bank;
    if cardinality(v_accounts) = 1 then
      v_account := v_accounts[1];
    end if;
    -- 2. The bank has exactly one active account.
    if v_account is null then
      select count(*), min(account_code) into v_n, v_account
      from public.accounts where profile_code = p_profile and bank_code = p_bank and status = 'active';
      if v_n <> 1 then
        v_account := null;
      end if;
    end if;
    -- 3. An explicit statement reference already seen on exactly one account.
    if v_account is null and p_reference is not null and p_reference_source = 'explicit' then
      select array_agg(distinct st.account_code) into v_accounts
      from public.statements st join public.accounts a on a.account_code = st.account_code
      where st.profile_code = p_profile and a.bank_code = p_bank
        and st.statement_reference = p_reference and st.reference_source = 'explicit';
      if cardinality(v_accounts) = 1 then
        v_account := v_accounts[1];
      end if;
    end if;
    -- 4. Ambiguous: a permanent ingest failure the owner can see, not a new account.
    if v_account is null and v_n > 1 then
      raise exception 'statement has no card number and % has % accounts in this profile; cannot choose one',
        p_bank, v_n using errcode = '22023';
    end if;
  end if;
  if v_account is null then
    insert into public.accounts (profile_code, bank_code, product_name, credit_limit)
    values (p_profile, p_bank, p_card_type, p_credit_limit)
    returning account_code into v_account;
  end if;
  if p_last4 is not null then
    perform private.ensure_card(p_profile, v_account, p_bank, p_last4, p_holder, false);
  end if;
  if v_new_card then
    update public.cards c set status = 'replaced'
    where c.profile_code = p_profile and c.account_code = v_account and c.last4 <> p_last4
      and c.status = 'active' and not c.is_supplementary;
  end if;
  if p_credit_limit is not null then
    update public.accounts set credit_limit = p_credit_limit
    where account_code = v_account and credit_limit is distinct from p_credit_limit;
  end if;
  return v_account;
end;
$$;

-- The old signature (kept for any caller): no kind, no first date, so never a successor.
create or replace function private.resolve_statement_account(
  p_profile text, p_bank text, p_last4 text, p_holder text, p_card_type text, p_credit_limit numeric,
  p_doc_code text, p_reference text, p_reference_source text
)
returns text
language sql
set search_path = ''
as $$
  select private.resolve_statement_account(p_profile, p_bank, p_last4, p_holder, p_card_type, p_credit_limit,
                                           p_doc_code, p_reference, p_reference_source, null, null)
$$;

-- ── owner RPC ───────────────────────────────────────────────────────────────
-- Register the new number of a re-issued card on the same account. The old card is marked
-- 'replaced' (its transactions keep it). Returns the new card_code. Idempotent; refuses a
-- number that already belongs to a different account.
create or replace function public.add_replacement_card(p_profile_code text, p_card_code text, p_new_last4 text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.cards%rowtype;
  v_existing public.cards%rowtype;
  v_new text;
  v_sms integer;
begin
  perform private.assert_member(p_profile_code, true);
  if p_new_last4 is null or p_new_last4 !~ '^[0-9]{4}$' then
    raise exception 'p_new_last4 must be 4 digits' using errcode = '22023';
  end if;
  perform private.lock_profile(p_profile_code);
  select * into c from public.cards where card_code = p_card_code and profile_code = p_profile_code;
  if not found then
    raise exception 'unknown card %', p_card_code using errcode = 'P0002';
  end if;
  if c.last4 = p_new_last4 then
    raise exception 'the new card number is the same as the old one' using errcode = '22023';
  end if;
  select * into v_existing from public.cards
  where profile_code = p_profile_code and bank_code = c.bank_code and last4 = p_new_last4;
  if found and v_existing.account_code <> c.account_code then
    raise exception 'card ending % already belongs to another account', p_new_last4 using errcode = '23505';
  end if;
  v_new := coalesce(v_existing.card_code,
                    private.ensure_card(p_profile_code, c.account_code, c.bank_code, p_new_last4, c.holder_name,
                                        c.is_supplementary));
  update public.cards set status = 'active' where card_code = v_new and status <> 'active';
  update public.cards set status = 'replaced' where card_code = c.card_code and status = 'active';
  v_sms := private.reprocess_waiting_sms(p_profile_code);
  return jsonb_build_object('card_code', v_new, 'account_code', c.account_code, 'replaced_card_code', c.card_code,
                            'sms_card_registered', v_sms);
end;
$$;

-- ── ingest_parsed_document: pass the statement kind and first transaction date ──
-- Same body as 20261010000400 (the document timeline); only the account resolution call
-- changes, so a history extract of an unknown card can join its predecessor's account.
create or replace function public.ingest_parsed_document(p_doc_code text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documents%rowtype;
  v_profile text;
  s jsonb;
  v_ord bigint;
  v_account text;
  v_stmt text;
  v_res jsonb;
  v_results jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_sms integer;
  v_lines_in bigint := 0;
  v_new bigint := 0;
  v_gone bigint := 0;
  v_created bigint := 0;
  v_linked bigint := 0;
  v_held bigint := 0;
  v_cards jsonb;
  v_msg text;
begin
  perform private.assert_service_role();
  select profile_code into v_profile from public.documents where doc_code = p_doc_code;
  if not found then
    raise exception 'unknown document %', p_doc_code using errcode = 'P0002';
  end if;
  perform private.lock_profile(v_profile);
  select * into d from public.documents where doc_code = p_doc_code for update;
  if (p_payload->>'contract_version')::int is distinct from 1 then
    raise exception 'unsupported parser contract %', p_payload->>'contract_version' using errcode = '22023';
  end if;
  -- Defence in depth (DP-04r): the parser validates dates; a statement more than a
  -- month in the future is a misread year and must not reach the ledger.
  -- (`ledger.test_today` lets pgTAP suites with fixed future dates pin "today".)
  if exists (select 1 from jsonb_array_elements(coalesce(p_payload->'statements', '[]'::jsonb)) x
             where (x->>'statement_date')::date
                   > coalesce(nullif(current_setting('ledger.test_today', true), '')::date, public.dubai_date(now())) + 31) then
    raise exception 'statement dated more than 31 days in the future' using errcode = '22023';
  end if;

  create temp table if not exists _doc_stmts (
    ord bigint, account_code text, statement_date date, kind text, body jsonb
  ) on commit drop;
  truncate _doc_stmts;

  for s, v_ord in select value, ordinality from jsonb_array_elements(coalesce(p_payload->'statements', '[]'::jsonb))
                  with ordinality loop
    if nullif(s->>'primary_card_last4', '') is null
       and jsonb_array_length(coalesce(s->'lines', '[]'::jsonb)) = 0 then
      v_warnings := v_warnings || to_jsonb(format('%s %s skipped: no card number and no transaction rows',
                                                  s->>'kind', s->>'statement_date'));
      continue;
    end if;
    v_account := private.resolve_statement_account(
      d.profile_code, s->>'bank_code', nullif(s->>'primary_card_last4', ''), s->>'card_holder', s->>'card_type',
      nullif(s->'totals'->>'credit_limit', '')::numeric, d.doc_code, s->>'statement_reference', s->>'reference_source',
      s->>'kind',
      (select min((l->>'txn_date')::date) from jsonb_array_elements(coalesce(s->'lines', '[]'::jsonb)) l)
    );
    insert into _doc_stmts values (v_ord, v_account, (s->>'statement_date')::date, s->>'kind', s);
  end loop;

  for v_stmt in
    select st.stmt_code from public.statements st
    where st.profile_code = d.profile_code and st.status = 'active'
      and (st.doc_code = d.doc_code
           or exists (select 1 from public.statement_lines l
                      where l.profile_code = d.profile_code and l.stmt_code = st.stmt_code and l.is_current
                        and l.source_doc_codes @> array[d.doc_code]))
      and not exists (select 1 from _doc_stmts x
                      where x.account_code = st.account_code and x.statement_date = st.statement_date
                        and x.kind = st.kind)
  loop
    perform private.retire_doc_from_statement(v_stmt, d.doc_code);
  end loop;

  for s, v_account in select body, account_code from _doc_stmts order by ord loop
    v_res := private.ingest_one_statement(d, s, p_payload->>'parser_version', v_account);
    v_results := v_results || v_res;
    v_warnings := v_warnings || coalesce(v_res->'warnings', '[]'::jsonb);
    v_lines_in := v_lines_in + jsonb_array_length(coalesce(s->'lines', '[]'::jsonb));
    v_new := v_new + coalesce((v_res->>'lines_new')::bigint, 0);
    v_gone := v_gone + coalesce((v_res->>'lines_superseded')::bigint, 0);
    v_created := v_created + coalesce((v_res->'match'->>'created')::bigint, 0);
    v_linked := v_linked + coalesce((v_res->'match'->>'linked')::bigint, 0);
    v_held := v_held + coalesce((v_res->'match'->>'held')::bigint, 0);
  end loop;

  -- SMS held as unknown_card whose card this document registered (DB-17r).
  v_sms := private.reprocess_waiting_sms(d.profile_code);

  update public.documents set
    parse_status = 'parsed',
    kind = p_payload->>'document_kind',
    bank_code = coalesce(p_payload->>'bank_code', bank_code),
    parser_version = p_payload->>'parser_version',
    parse_error_code = null,
    parse_error = null,
    parse_warnings = coalesce((select jsonb_agg(w) from jsonb_array_elements(p_payload->'statements') st,
                                 jsonb_array_elements(coalesce(st->'warnings', '[]'::jsonb)) w), '[]'::jsonb)
                     || v_warnings,
    parsed_at = now()
  where doc_code = p_doc_code;

  -- Cards this document added (and the cards they replaced), for the event.
  select coalesce(jsonb_agg(jsonb_build_object('bank_code', c.bank_code, 'last4', c.last4,
           'replaces', (select string_agg(o.last4, ', ' order by o.last4) from public.cards o
                        where o.account_code = c.account_code and o.status = 'replaced' and o.updated_at = now()))
           order by c.last4), '[]'::jsonb)
  into v_cards
  from public.cards c where c.profile_code = d.profile_code and c.created_at = now();

  v_msg := format('Imported %s: %s, %s already known, %s withdrawn; %s, %s matched to existing ones.',
                  private.plural(jsonb_array_length(v_results), 'statement', 'statements'),
                  private.plural(v_new, 'new line', 'new lines'), v_lines_in - v_new, v_gone,
                  private.plural(v_created, 'new transaction', 'new transactions'), v_linked);
  if v_held > 0 then
    v_msg := v_msg || ' ' || private.plural(v_held, 'line needs', 'lines need') || ' a review.';
  end if;
  select v_msg || coalesce(' ' || string_agg(format('New card ending %s added%s.', x->>'last4',
           coalesce(' as the replacement of the card ending ' || (x->>'replaces'), '')), ' '), '')
  into v_msg from jsonb_array_elements(v_cards) x;
  perform private.log_document_event(d.profile_code, d.doc_code, 'ingested',
    case when v_held > 0 or jsonb_array_length(v_warnings) > 0 then 'warn' else 'info' end, v_msg,
    jsonb_build_object('statements', jsonb_array_length(v_results), 'lines_in', v_lines_in, 'lines_new', v_new,
                       'lines_unchanged', v_lines_in - v_new, 'lines_withdrawn', v_gone,
                       'transactions_created', v_created, 'transactions_linked', v_linked, 'lines_held', v_held,
                       'cards_added', v_cards, 'sms_card_registered', v_sms,
                       'warnings', jsonb_array_length(v_warnings)));

  return jsonb_build_object('doc_code', p_doc_code, 'statements', v_results, 'warnings', v_warnings,
                            'sms_card_registered', v_sms);
end;
$$;

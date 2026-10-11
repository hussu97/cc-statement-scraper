-- merge_accounts re-keys the lines it moves.
--
-- statement_lines.line_key is sha256(account_code | txn_date | posting_date | amount_original |
-- currency_original | amount_aed | direction | description_raw as printed), computed by
-- ingest_parsed_document. 20261010001400 merged the Hussain profile's FAB account acc_…zk5j into
-- acc_…qr96 and moved the lines without re-keying them. On 2026-10-11 parser 2026.10.7 re-parsed
-- the FAB documents: ingest hashed the merged account, every moved line looked new, the old
-- lines were superseded (their source_doc_codes emptied, so re-parse lineage could not pair
-- them) and 115 transactions were orphaned and re-created with the same facts. A second
-- document for a moved statement would have added duplicate lines the same way.
--
-- private.statement_line_key is ingest's expression as a function. merge_accounts now re-keys
-- every line of the kept account whose key does not match it, hashing the original text of a
-- masked line (private.masked_originals) as ingest did. Nothing else changes. Current production
-- keys all match their account already (the re-parse re-keyed them), so no backfill is needed.
-- pgTAP 28_merge_accounts: a re-parse after a merge orphans nothing, and the helper reproduces
-- ingest's key.

create or replace function private.statement_line_key(
  p_account_code text, p_txn_date date, p_posting_date date, p_amount_original numeric,
  p_currency_original text, p_amount_aed numeric, p_direction text, p_description_raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(concat_ws('|', p_account_code, p_txn_date::text, p_posting_date::text,
    p_amount_original::numeric(14,2), p_currency_original, p_amount_aed::numeric(14,2), p_direction,
    regexp_replace(btrim(p_description_raw), '\s+', ' ', 'g')), 'UTF8')), 'hex')
$$;

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
  -- line_key hashes the account: re-key the moved lines so a re-parse of their documents (which
  -- now resolves to p_into) finds them unchanged instead of superseding and re-creating them.
  update public.statement_lines l set line_key = k.line_key
  from (
    select x.line_code, private.statement_line_key(p_into, x.txn_date, x.posting_date, x.amount_original,
             x.currency_original, x.amount_aed, x.direction,
             coalesce((select mo.original from private.masked_originals mo
                        where mo.table_name = 'statement_lines' and mo.row_code = x.line_code
                          and mo.column_name = 'description_raw'), x.description_raw)) as line_key
    from public.statement_lines x
    where x.account_code = p_into
  ) k
  where l.line_code = k.line_code and l.line_key is distinct from k.line_key;
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

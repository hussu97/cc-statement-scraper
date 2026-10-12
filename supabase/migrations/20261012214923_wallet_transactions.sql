-- Wallet transaction capture: card payments logged by the phone's Shortcuts "Transaction"
-- automation (amount, merchant, card display name; no card number) become alert evidence
-- exactly like a parsed SMS.
--
-- 1. sms_messages.source ('sms' | 'wallet') and wallet_pass_name. A Wallet event is a row in
--    sms_messages with source 'wallet', sender 'Wallet' and a synthetic body
--    '<CUR> <amount> at <merchant> (<pass name>)', so match_sms, new_transaction_from_sms,
--    refresh_transaction, the reviews and the evidence_type = 'sms' CHECK all apply
--    (match_sms's duplicate-alert step excepted, see 6). The submitted fields are kept in
--    parsed_fields {amount, currency, merchant, pass_name}.
-- 2. cards.wallet_name: the user-set name the phone shows for the card (unique per profile,
--    case-insensitive). Owners may update it (column grant). Setting it re-processes the
--    profile's Wallet rows that were waiting on that name and auto-resolves their
--    unknown_card reviews ({"auto": "card_registered"}, as DB-17r).
-- 3. public.ingest_wallet_transactions(p_profile_code, p_items): owner-only batch entry
--    point, same shape and statuses as ingest_sms.
-- 4. private.process_sms: Wallet rows take a branch at the top (card by wallet_name, no
--    template). Before the generic matcher, any parsed alert first looks for its twin
--    from the OTHER source (a bank SMS and a Wallet event for the same purchase: same
--    account, amount and currency, within 30 minutes) and joins that transaction as
--    'duplicate' evidence. Merchant names differ between the bank and the phone, so the
--    generic matcher (which never links two SMS) would otherwise make two transactions.
--    Rows of one source never pair with each other here, so SMS-only profiles are unchanged.
-- 5. public.resolve_review: the {"card": …} action needs a card number; for a Wallet row it
--    raises 22023 asking for the card's Wallet name instead.
-- 6. private.match_sms: its duplicate-alert step never pairs two Wallet rows. Their synthetic
--    bodies carry no time, so two genuine identical taps (same card, amount, merchant) would
--    otherwise share a body_hash; a redelivery is already deduped by client_msg_id.

-- ── 1. sms_messages: source and pass name ───────────────────────────────────
alter table public.sms_messages
  add column source text not null default 'sms' check (source in ('sms', 'wallet')),
  add column wallet_pass_name text check (wallet_pass_name is null or length(wallet_pass_name) between 1 and 64);
alter table public.sms_messages add constraint sms_messages_wallet_pass_name_iff_wallet
  check ((source = 'wallet') = (wallet_pass_name is not null));

-- ── 2. cards.wallet_name ────────────────────────────────────────────────────
alter table public.cards
  add column wallet_name text check (wallet_name is null
                                     or (wallet_name = btrim(wallet_name) and length(wallet_name) between 1 and 64));
create unique index cards_wallet_name_uq on public.cards (profile_code, lower(wallet_name)) where wallet_name is not null;
grant update (wallet_name) on public.cards to authenticated;

-- ── 3. ingest ───────────────────────────────────────────────────────────────
-- Why a Wallet item cannot be stored, or null when it can.
create or replace function private.wallet_input_problem(item jsonb)
returns text
language plpgsql
stable
set search_path = ''
as $$
begin
  if jsonb_typeof(item) is distinct from 'object' then
    return 'not_an_object';
  end if;
  if jsonb_typeof(item->'client_msg_id') is distinct from 'string'
     or item->>'client_msg_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return 'invalid_client_msg_id';
  end if;
  if coalesce(jsonb_typeof(item->'occurred_at'), 'null') <> 'null' then
    if jsonb_typeof(item->'occurred_at') <> 'string' or not pg_input_is_valid(item->>'occurred_at', 'timestamptz') then
      return 'invalid_occurred_at';
    end if;
    if (item->>'occurred_at')::timestamptz not between '2000-01-01'::timestamptz and now() + interval '1 day' then
      return 'invalid_occurred_at';
    end if;
  end if;
  -- Money crosses the wire as a decimal string (CLAUDE.md §1.3).
  if jsonb_typeof(item->'amount') is distinct from 'string'
     or item->>'amount' !~ '^[0-9]{1,12}(\.[0-9]{1,4})?$'
     or round((item->>'amount')::numeric, 2) <= 0 then
    return 'invalid_amount';
  end if;
  if jsonb_typeof(item->'currency') is distinct from 'string' or item->>'currency' !~ '^[A-Z]{3}$' then
    return 'invalid_currency';
  end if;
  if jsonb_typeof(item->'merchant') is distinct from 'string'
     or length(btrim(item->>'merchant')) not between 1 and 200 then
    return 'invalid_merchant';
  end if;
  if jsonb_typeof(item->'pass_name') is distinct from 'string'
     or length(btrim(item->>'pass_name')) not between 1 and 64 then
    return 'invalid_pass_name';
  end if;
  return null;
end;
$$;

-- Batch entry point for the iOS "Log Card Payment" App Intent.
-- p_items: [{client_msg_id, occurred_at, amount ("12.50"), currency ("AED"), merchant, pass_name}]
-- Per-item result: {client_msg_id, sms_code, status, txn_code?, reason?} with the statuses of
-- ingest_sms: created | linked | duplicate | held | skipped | unknown_card | already_linked |
-- duplicate_delivery | invalid (not stored; `reason` says why) | failed (stored with
-- parse_status 'failed'; `reason` = 'error:<sqlstate>'). An item never fails the batch.
create or replace function public.ingest_wallet_transactions(p_profile_code text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  v_code text;
  v_results jsonb := '[]'::jsonb;
  v_status text;
  v_problem text;
  v_state text;
  v_amount numeric(14,2);
  v_currency text;
  v_merchant text;
  v_pass text;
  v_body text;
begin
  perform private.assert_member(p_profile_code, true);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 200 then
    raise exception 'p_items must be an array of at most 200 items' using errcode = '22023';
  end if;
  perform private.lock_profile(p_profile_code);

  for item in select * from jsonb_array_elements(p_items) loop
    v_problem := private.wallet_input_problem(item);
    if v_problem is not null then
      v_results := v_results || jsonb_build_object(
        'client_msg_id', case when jsonb_typeof(item) = 'object' then item->>'client_msg_id' end,
        'status', 'invalid', 'reason', v_problem);
      continue;
    end if;

    v_amount := round((item->>'amount')::numeric, 2);
    v_currency := item->>'currency';
    v_merchant := regexp_replace(btrim(item->>'merchant'), '\s+', ' ', 'g');
    v_pass := regexp_replace(btrim(item->>'pass_name'), '\s+', ' ', 'g');
    v_body := v_currency || ' ' || v_amount::text || ' at ' || v_merchant || ' (' || v_pass || ')';

    v_code := null;
    insert into public.sms_messages (profile_code, client_msg_id, received_at, sender, body, body_hash,
                                     source, wallet_pass_name, parsed_fields)
    values (p_profile_code, (item->>'client_msg_id')::uuid, coalesce((item->>'occurred_at')::timestamptz, now()),
            'Wallet', v_body, encode(sha256(convert_to('Wallet|' || v_body, 'UTF8')), 'hex'),
            'wallet', v_pass,
            jsonb_build_object('amount', v_amount::text, 'currency', v_currency, 'merchant', v_merchant,
                               'pass_name', v_pass))
    on conflict (profile_code, client_msg_id) do nothing
    returning sms_code into v_code;

    if v_code is null then
      select sms_code into v_code from public.sms_messages
      where profile_code = p_profile_code and client_msg_id = (item->>'client_msg_id')::uuid;
      v_results := v_results || jsonb_build_object('client_msg_id', item->>'client_msg_id', 'sms_code', v_code,
                                                   'status', 'duplicate_delivery');
      continue;
    end if;

    begin
      v_status := private.process_sms(v_code);
    exception when others then
      -- The event is kept; whatever processing did is rolled back to here.
      get stacked diagnostics v_state = returned_sqlstate;
      update public.sms_messages set parse_status = 'failed', ignore_reason = 'error:' || v_state
      where sms_code = v_code;
      v_results := v_results || jsonb_build_object('client_msg_id', item->>'client_msg_id', 'sms_code', v_code,
                                                   'status', 'failed', 'reason', 'error:' || v_state);
      continue;
    end;
    v_results := v_results || jsonb_build_object(
      'client_msg_id', item->>'client_msg_id', 'sms_code', v_code, 'status', v_status,
      'txn_code', (select e.txn_code from public.transaction_evidence e where e.sms_code = v_code and e.is_active limit 1)
    );
  end loop;
  return v_results;
end;
$$;

-- ── 4. processing ───────────────────────────────────────────────────────────
-- A bank SMS and a Wallet event for the same purchase: the alert joins its twin's
-- transaction as 'duplicate' evidence. Only pairs across sources (never two SMS or two
-- Wallet events), on the same account with the same amount and currency, within 30
-- minutes, and only with a transaction that has no evidence from this alert's source yet
-- (two same-amount purchases pair one to one, nearest first). Returns 'duplicate' when
-- linked, else null.
create or replace function private.link_wallet_twin(p_sms_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_txn text;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code;
  if s.parse_status <> 'parsed' or s.account_code is null or s.msg_kind not in ('purchase', 'preauth') then
    return null;
  end if;
  if exists (select 1 from public.transaction_evidence e where e.sms_code = s.sms_code and e.is_active) then
    return null;
  end if;

  select e.txn_code into v_txn
  from public.sms_messages o
  join public.transaction_evidence e on e.sms_code = o.sms_code and e.profile_code = o.profile_code and e.is_active
  where o.profile_code = s.profile_code and o.sms_code <> s.sms_code
    and o.source <> s.source
    and o.account_code = s.account_code
    and o.msg_kind in ('purchase', 'preauth')
    and o.amount = s.amount and o.currency = s.currency
    and o.event_at between s.event_at - interval '30 minutes' and s.event_at + interval '30 minutes'
    and not exists (select 1 from public.transaction_evidence e2
                    join public.sms_messages o2 on o2.sms_code = e2.sms_code and o2.profile_code = e2.profile_code
                    where e2.txn_code = e.txn_code and e2.is_active and o2.source = s.source)
  order by abs(extract(epoch from o.event_at - s.event_at)), o.sms_code
  limit 1;
  if v_txn is null then
    return null;
  end if;

  insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, method)
  values (v_txn, s.profile_code, 'sms', s.sms_code, 'duplicate', 'scored');
  return 'duplicate';
end;
$$;

-- A Wallet row: the card is the one whose wallet_name is the pass name (case-insensitive);
-- the fields come from parsed_fields as submitted. No card → unknown_card review with
-- candidates [{"wallet_name": "<pass name>"}].
create or replace function private.process_wallet_sms(p_sms_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_card public.cards%rowtype;
  v_result text;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code;
  select * into v_card from public.cards c
  where c.profile_code = s.profile_code and lower(c.wallet_name) = lower(s.wallet_pass_name);

  update public.sms_messages set
    parse_status = 'parsed',
    ignore_reason = null,
    template_code = null,
    template_version = null,
    bank_code = v_card.bank_code,
    msg_kind = 'purchase',
    card_last4 = v_card.last4,
    card_code = v_card.card_code,
    account_code = v_card.account_code,
    amount = (s.parsed_fields->>'amount')::numeric,
    currency = s.parsed_fields->>'currency',
    merchant_raw = s.parsed_fields->>'merchant',
    description = private.normalize_text(s.parsed_fields->>'merchant'),
    available_limit = null,
    event_at = s.received_at
  where sms_code = p_sms_code;

  if v_card.card_code is null then
    insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
    values (s.profile_code, 'sms', p_sms_code, 'unknown_card',
            jsonb_build_array(jsonb_build_object('wallet_name', s.wallet_pass_name)))
    on conflict do nothing;
    return 'unknown_card';
  end if;

  v_result := private.link_wallet_twin(p_sms_code);
  if v_result is null then
    v_result := private.match_sms(p_sms_code);
  end if;
  return v_result;
end;
$$;

-- ── 4b. match_sms: unchanged from 20261011170000 except that the duplicate-alert step
-- (same body_hash, or near-identical text within 180 s) never pairs two Wallet rows.
create or replace function private.match_sms(p_sms_code text)
returns text   -- 'linked' | 'duplicate' | 'created' | 'held' | 'skipped'
language plpgsql
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_txn text;
  v_best record;
  v_conflict boolean;
  v_desc_merchant text;
  v_amount_aed numeric;
  v_original text;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code;
  if s.parse_status <> 'parsed' or s.account_code is null
     or s.msg_kind not in ('purchase', 'preauth', 'refund', 'reversal', 'payment') then
    return 'skipped';
  end if;
  if exists (select 1 from public.transaction_evidence e where e.sms_code = s.sms_code and e.is_active) then
    return 'skipped';
  end if;

  -- 1. Same alert delivered twice (bank resend / automation double-fire). Two
  --    alerts that print different available limits are two purchases (DB-15).
  --    Two Wallet events are never the same alert: each is a separate tap, and a
  --    redelivery is already caught by client_msg_id at ingest.
  select e.txn_code into v_txn
  from public.sms_messages o
  join public.transaction_evidence e on e.sms_code = o.sms_code and e.is_active
  where o.profile_code = s.profile_code and o.sms_code <> s.sms_code
    and not (o.source = 'wallet' and s.source = 'wallet')
    and o.account_code = s.account_code and o.msg_kind = s.msg_kind
    and o.amount = s.amount and o.currency = s.currency
    and (o.body_hash = s.body_hash
         or (abs(extract(epoch from o.event_at - s.event_at)) <= 180
             and extensions.similarity(coalesce(o.description, ''), coalesce(s.description, '')) >= 0.8
             and (o.available_limit is null or s.available_limit is null or o.available_limit = s.available_limit)))
    and abs(extract(epoch from o.received_at - s.received_at)) <= 600
  order by o.received_at
  limit 1;
  if v_txn is not null then
    insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, method)
    values (v_txn, s.profile_code, 'sms', s.sms_code, 'duplicate', 'exact');
    return 'duplicate';
  end if;

  -- 2. A late SMS for a transaction a statement already posted.
  v_desc_merchant := private.resolve_merchant(s.description);
  v_amount_aed := case when s.currency = 'AED' then s.amount
                       else round(s.amount * private.estimate_fx(s.profile_code, s.currency, coalesce(s.bank_code, private.account_bank(s.account_code)),
                                                                 public.dubai_date(s.event_at)), 2) end;
  create temp table if not exists _sx_cand (txn_code text, score numeric, sig text, created timestamptz, maff numeric)
    on commit drop;
  truncate _sx_cand;
  insert into _sx_cand
  select t.txn_code,
         private.match_score(
           s.amount, s.currency, v_amount_aed, public.dubai_date(s.event_at), null,
           s.description, v_desc_merchant, s.card_last4,
           t.amount_original, t.currency_original, t.amount_aed, t.txn_date, t.posting_date,
           t.description, t.merchant_code, cd.last4, coalesce(mr.variable_amount, false) or s.msg_kind = 'preauth'
         ),
         concat_ws('|', t.amount_original, t.currency_original, t.txn_date, t.merchant_code),
         t.created_at,
         private.merchant_affinity(s.description, t.description, v_desc_merchant, t.merchant_code)
  from public.transactions t
  left join public.cards cd on cd.card_code = t.card_code
  left join public.merchants mr on mr.merchant_code = t.merchant_code
  where t.profile_code = s.profile_code
    and t.account_code = s.account_code
    and t.direction = case when s.msg_kind in ('refund', 'reversal', 'payment') then 'credit' else 'debit' end
    and abs(t.txn_date - public.dubai_date(s.event_at)) <= 3
    and not exists (select 1 from public.transaction_evidence e
                    where e.txn_code = t.txn_code and e.is_active and e.evidence_type = 'sms');
  delete from _sx_cand where score is null or score < 55;

  select * into v_best from _sx_cand order by score desc, created, txn_code limit 1;
  if v_best.txn_code is not null then
    v_conflict := exists (select 1 from _sx_cand x
                          where x.txn_code <> v_best.txn_code and x.score >= v_best.score - 15 and x.sig <> v_best.sig
                            and x.maff > v_best.maff - 0.3);
    if v_conflict or v_best.score < 75 then
      insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
      values (s.profile_code, s.account_code, 'sms', s.sms_code,
              case when v_conflict then 'ambiguous' else 'low_score' end,
              (select coalesce(jsonb_agg(jsonb_build_object('txn_code', x.txn_code, 'score', x.score) order by x.score desc), '[]'::jsonb)
                 from (select * from _sx_cand order by score desc limit 5) x))
      on conflict do nothing;
      return 'held';
    end if;
    insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, score, method)
    values (v_best.txn_code, s.profile_code, 'sms', s.sms_code, 'auth', v_best.score,
            case when v_best.score >= 85 then 'exact' else 'scored' end);
    perform private.refresh_transaction(v_best.txn_code);
    return 'linked';
  end if;

  -- 3. A brand-new (pending) transaction.
  v_txn := private.new_transaction_from_sms(s.sms_code);

  -- A reversal points at the purchase it reverses.
  if s.msg_kind = 'reversal' then
    select t.txn_code into v_original
    from public.transactions t
    where t.profile_code = s.profile_code and t.account_code = s.account_code
      and t.direction = 'debit' and t.txn_code <> v_txn
      and t.amount_original = s.amount and t.currency_original = s.currency
      and t.txn_date between public.dubai_date(s.event_at) - 30 and public.dubai_date(s.event_at)
      and not exists (select 1 from public.transactions r
                      where r.profile_code = s.profile_code and r.related_txn_code = t.txn_code)
    order by extensions.similarity(t.description, coalesce(s.description, '')) desc, t.txn_date desc
    limit 1;
    if v_original is not null then
      update public.transactions set related_txn_code = v_original where txn_code = v_txn;
    end if;
  end if;
  return 'created';
end;
$$;


-- process_sms: unchanged from 20261009000300 except the Wallet branch at the top and the
-- Wallet twin check before match_sms.
create or replace function private.process_sms(p_sms_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  m record;
  v_card public.cards%rowtype;
  v_account text;
  v_n int;
  v_event timestamptz;
  v_fields jsonb;
  v_ignored boolean;
  v_result text;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code for update;
  if exists (select 1 from public.transaction_evidence e where e.sms_code = p_sms_code and e.is_active) then
    return 'already_linked';
  end if;
  -- A Wallet event names its card by the phone's display name, not by template.
  if s.source = 'wallet' then
    return private.process_wallet_sms(p_sms_code);
  end if;

  select * into m from private.match_sms_template(s.sender, s.body, null, s.profile_code) limit 1;
  if m.template_code is null then
    update public.sms_messages set parse_status = 'unparsed', template_code = null where sms_code = p_sms_code;
    return 'unparsed';
  end if;
  v_fields := m.fields;

  v_event := s.received_at;
  if m.fields ? 'date' then
    begin
      v_event := ((m.fields->>'date') || ' ' || coalesce(m.fields->>'time', to_char(s.received_at at time zone 'Asia/Dubai', 'HH24:MI:SS')))::timestamp
                 at time zone 'Asia/Dubai';
    exception when others then
      v_event := s.received_at;
    end;
    -- A bank alert arrives within minutes of the charge. A template date far from
    -- the arrival time is a DD/MM vs MM/DD misread: keep the arrival time (DB-36).
    if abs(extract(epoch from v_event - s.received_at)) > 7 * 86400 then
      raise warning 'sms %: template date % is more than 7 days from received_at; using received_at',
        p_sms_code, v_event;
      v_fields := v_fields || jsonb_build_object('event_at_rejected', v_event);
      v_event := s.received_at;
    end if;
  end if;

  if m.fields ? 'last4' then
    select * into v_card from public.cards
    where profile_code = s.profile_code and bank_code = m.bank_code and last4 = m.fields->>'last4';
    v_account := v_card.account_code;
  end if;
  if v_account is null and not (m.fields ? 'last4') then
    select count(*), min(account_code) into v_n, v_account
    from public.accounts where profile_code = s.profile_code and bank_code = m.bank_code and status = 'active';
    if v_n <> 1 then v_account := null; end if;
  end if;

  -- Declined alerts are not transactions: stored 'ignored' like debit-card and other alerts (DB-34).
  v_ignored := m.msg_kind in ('debit_card', 'other', 'declined');
  update public.sms_messages set
    parse_status = case when v_ignored then 'ignored' else 'parsed' end,
    ignore_reason = case when v_ignored then m.msg_kind end,
    template_code = m.template_code,
    template_version = m.template_version,
    bank_code = m.bank_code,
    msg_kind = m.msg_kind,
    card_last4 = m.fields->>'last4',
    card_code = v_card.card_code,
    account_code = v_account,
    amount = (m.fields->>'amount')::numeric,
    currency = coalesce(m.fields->>'currency', 'AED'),
    merchant_raw = m.fields->>'merchant',
    description = private.normalize_text(m.fields->>'merchant'),
    available_limit = (m.fields->>'available')::numeric,
    event_at = v_event,
    parsed_fields = v_fields
  where sms_code = p_sms_code;

  if v_ignored then
    return 'ignored';
  end if;
  if v_account is null then
    insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
    values (s.profile_code, 'sms', p_sms_code, 'unknown_card',
            jsonb_build_array(jsonb_build_object('bank_code', m.bank_code, 'last4', m.fields->>'last4')))
    on conflict do nothing;
    return 'unknown_card';
  end if;

  -- The same purchase may already be in the ledger from a Wallet event.
  v_result := private.link_wallet_twin(p_sms_code);
  if v_result is null then
    v_result := private.match_sms(p_sms_code);
  end if;
  return v_result;
end;
$$;


-- ── 2b. a card's Wallet name re-processes the Wallet rows waiting on it ─────
-- Rows the owner marked as not a transaction ('ignored') stay as they are. Errors are per
-- row (the row is marked failed, as the template re-process does). Then every open
-- unknown_card review of a Wallet row that found its account resolves itself.
create or replace function private.trg_cards_wallet_name_reprocess()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_state text;
begin
  if new.wallet_name is null
     or (tg_op = 'UPDATE' and lower(new.wallet_name) is not distinct from lower(old.wallet_name)) then
    return null;
  end if;

  for v_code in
    select s.sms_code from public.sms_messages s
    where s.profile_code = new.profile_code and s.source = 'wallet' and s.account_code is null
      and s.parse_status in ('pending', 'parsed', 'failed')
      and lower(s.wallet_pass_name) = lower(new.wallet_name)
    order by s.received_at, s.sms_code
  loop
    begin
      perform private.process_sms(v_code);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      update public.sms_messages set parse_status = 'failed', ignore_reason = 'error:' || v_state
      where sms_code = v_code;
    end;
  end loop;

  update public.match_reviews r set status = 'resolved', resolution = jsonb_build_object('auto', 'card_registered'),
    resolved_at = now()
  where r.profile_code = new.profile_code and r.reason = 'unknown_card' and r.status = 'open' and r.subject_type = 'sms'
    and exists (select 1 from public.sms_messages s
                where s.profile_code = new.profile_code and s.sms_code = r.subject_code
                  and s.source = 'wallet' and s.account_code is not null);
  return null;
end;
$$;
create trigger cards_wallet_name_reprocess after insert or update of wallet_name on public.cards
  for each row execute function private.trg_cards_wallet_name_reprocess();


-- ── 5. resolve_review: unchanged from 20261012043206 except that the card action refuses
-- Wallet rows (22023: set the card's Wallet name instead).
create or replace function public.resolve_review(p_review_code text, p_action jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.match_reviews%rowtype;
  v_profile text;
  v_txn text;
  v_txn_account text;
  v_account text;
  v_target text;
  v_line public.statement_lines%rowtype;
  v_sms public.sms_messages%rowtype;
  v_displaced text[];
  v_outcome text;
begin
  select profile_code into v_profile from public.match_reviews where review_code = p_review_code;
  if not found then
    raise exception 'review % is not open', p_review_code using errcode = 'P0002';
  end if;
  perform private.assert_member(v_profile, true);
  perform private.lock_profile(v_profile);
  select * into r from public.match_reviews where review_code = p_review_code for update;
  if r.status <> 'open' then
    raise exception 'review % is not open', p_review_code using errcode = 'P0002';
  end if;
  if p_action is null or jsonb_typeof(p_action) <> 'object' then
    raise exception 'unsupported action %', p_action using errcode = '22023';
  end if;

  if p_action ? 'dismiss' then
    -- An orphaned transaction has lost all its evidence (CLAUDE.md §1.10): checking it off voids
    -- it, so it stops counting in every total. One whose evidence came back is no longer orphaned
    -- and stays as it is.
    if r.reason = 'orphaned' and r.subject_type = 'transaction' then
      update public.transactions set voided_at = now(), void_reason = 'orphan_dismissed'
      where txn_code = r.subject_code and profile_code = r.profile_code and status = 'orphaned';
      if found then
        perform private.refresh_transaction(r.subject_code);
        v_txn := r.subject_code;
      end if;
    end if;
    v_outcome := 'dismissed';

  elsif p_action ? 'link' then
    v_txn := p_action->>'link';
    select account_code into v_txn_account from public.transactions
    where txn_code = v_txn and profile_code = r.profile_code;
    if not found then
      raise exception 'unknown transaction %', v_txn using errcode = 'P0002';
    end if;
    if r.subject_type = 'statement_line' then
      select * into v_line from public.statement_lines where line_code = r.subject_code and profile_code = r.profile_code;
      if not found then
        raise exception 'unknown statement line %', r.subject_code using errcode = 'P0002';
      end if;
      if v_line.account_code <> v_txn_account then
        raise exception 'transaction % is on a different account', v_txn using errcode = '22023';
      end if;
      if exists (select 1 from public.transaction_evidence e
                 where e.profile_code = r.profile_code and e.txn_code = v_txn and e.is_active
                   and e.evidence_type = v_line.evidence_type and e.is_locked) then
        raise exception 'transaction % already has a confirmed %', v_txn, v_line.evidence_type using errcode = '22023';
      end if;
      with d as (
        update public.transaction_evidence set is_active = false, deactivated_at = now()
        where profile_code = r.profile_code and txn_code = v_txn and is_active
          and evidence_type = v_line.evidence_type and not is_locked
        returning line_code
      )
      select array_agg(line_code) into v_displaced from d;
      insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, role, method, is_locked)
      values (v_txn, r.profile_code, v_line.evidence_type, v_line.line_code, 'post', 'manual', true);
      perform private.refresh_transaction(v_txn);
      -- A line pushed off the transaction stays in the ledger as its own transaction (DB-27).
      perform private.new_transaction_from_line(x.line_code)
      from unnest(coalesce(v_displaced, '{}')) as x(line_code)
      join public.statement_lines l on l.line_code = x.line_code and l.profile_code = r.profile_code and l.is_current
      where not exists (select 1 from public.transaction_evidence e where e.line_code = x.line_code and e.is_active);
    elsif r.subject_type = 'sms' then
      select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
      if not found then
        raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
      end if;
      if v_sms.account_code is distinct from v_txn_account then
        raise exception 'transaction % is not on this message''s account', v_txn using errcode = '22023';
      end if;
      insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, method, is_locked)
      values (v_txn, r.profile_code, 'sms', v_sms.sms_code, 'auth', 'manual', true);
      perform private.refresh_transaction(v_txn);
    else
      raise exception 'link is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    v_outcome := 'linked';

  elsif p_action ? 'create_new' then
    if r.subject_type = 'statement_line' then
      if not exists (select 1 from public.statement_lines
                     where line_code = r.subject_code and profile_code = r.profile_code) then
        raise exception 'unknown statement line %', r.subject_code using errcode = 'P0002';
      end if;
      v_txn := private.new_transaction_from_line(r.subject_code, 'manual');
    elsif r.subject_type = 'sms' then
      select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
      if not found then
        raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
      end if;
      if v_sms.account_code is null or v_sms.amount is null then
        raise exception 'sms % has no account or amount; register its card first', r.subject_code using errcode = '22023';
      end if;
      v_txn := private.new_transaction_from_sms(r.subject_code, 'manual');
    else
      raise exception 'create_new is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    v_outcome := 'created';

  elsif p_action ? 'card' and r.reason = 'unknown_card' then
    v_account := p_action->'card'->>'account_code';
    select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
    if not found then
      raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
    end if;
    -- A Wallet event carries no card number to register: its card is found by Wallet name.
    if v_sms.source = 'wallet' then
      raise exception 'this payment names its card "%", not a card number: set the card''s Wallet name to it instead',
        v_sms.wallet_pass_name using errcode = '22023';
    end if;
    if not exists (select 1 from public.accounts a
                   where a.account_code = v_account and a.profile_code = r.profile_code
                     and a.bank_code = v_sms.bank_code) then
      raise exception 'unknown account %', v_account using errcode = 'P0002';
    end if;
    update public.match_reviews set status = 'resolved', resolution = p_action, resolved_by = auth.uid(), resolved_at = now()
    where review_code = p_review_code;
    if v_sms.card_last4 is null then
      -- No card number to register (DB-43): bind this one message to the chosen account.
      update public.sms_messages set account_code = v_account where sms_code = v_sms.sms_code;
      perform private.match_sms(v_sms.sms_code);
    else
      perform private.ensure_card(r.profile_code, v_account, v_sms.bank_code, v_sms.card_last4, null, true);
      -- Every message waiting on this card can now be processed.
      perform private.process_sms(s.sms_code)
      from public.sms_messages s
      where s.profile_code = r.profile_code and s.bank_code = v_sms.bank_code and s.card_last4 = v_sms.card_last4
        and s.account_code is null;
    end if;
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'card_registered'),
      resolved_at = now()
    where profile_code = r.profile_code and reason = 'unknown_card' and status = 'open'
      and subject_code in (select sms_code from public.sms_messages
                           where profile_code = r.profile_code and account_code is not null);
    return jsonb_build_object('review_code', p_review_code, 'outcome', 'card_registered');

  elsif p_action ? 'not_a_transaction' then
    if r.subject_type <> 'sms' then
      raise exception 'not_a_transaction is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
    if not found then
      raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
    end if;
    if exists (select 1 from public.transaction_evidence e where e.sms_code = v_sms.sms_code and e.is_active) then
      raise exception 'sms % is already part of a transaction', v_sms.sms_code using errcode = '22023';
    end if;
    update public.sms_messages set parse_status = 'ignored', ignore_reason = 'user_not_txn'
    where sms_code = v_sms.sms_code;
    -- Any other open review about the same message is moot now.
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'user_not_txn'),
      resolved_by = auth.uid(), resolved_at = now()
    where profile_code = r.profile_code and subject_type = 'sms' and subject_code = v_sms.sms_code
      and status = 'open' and review_code <> p_review_code;
    v_outcome := 'ignored';

  elsif p_action ? 'supersede' and r.reason = 'period_overlap' then
    select st.stmt_code into v_target
    from public.statements st
    where st.stmt_code = p_action->>'supersede'
      and st.profile_code = r.profile_code
      and st.account_code = r.account_code
      and st.kind = 'statement' and st.status = 'active'
      and st.stmt_code <> r.subject_code
      and r.candidates @> jsonb_build_array(jsonb_build_object('stmt_code', st.stmt_code));
    if v_target is null then
      raise exception 'statement % is not a candidate of review %', p_action->>'supersede', p_review_code
        using errcode = 'P0002';
    end if;
    perform private.supersede_statement(v_target, r.subject_code);
    v_outcome := 'superseded';

  else
    raise exception 'unsupported action %', p_action using errcode = '22023';
  end if;

  update public.match_reviews
  set status = case when v_outcome = 'dismissed' then 'dismissed' else 'resolved' end,
      resolution = p_action, resolved_by = auth.uid(), resolved_at = now()
  where review_code = p_review_code;
  return jsonb_build_object('review_code', p_review_code, 'outcome', v_outcome, 'txn_code', v_txn);
end;
$$;


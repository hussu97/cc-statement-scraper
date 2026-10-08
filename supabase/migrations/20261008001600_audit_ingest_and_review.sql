-- Audit fixes for ingestion, matching and review resolution
-- (docs/audit/01-database.md, 06-cross-cutting.md):
--
--   DB-01  resolve_review {"card"}: the account must belong to the review's profile and bank
--   DB-02  resolve_review {"supersede"}: the target must be one of the review's candidates,
--          same profile and account, never the subject itself (also DB-33)
--   DB-03  matcher candidate joins are on (profile_code, account_code)
--   DB-06  re-parsing a document withdraws its evidence from statements it no longer produces
--   DP-01/DP-02 (02-data-parity.md) lines record the documents that evidence them; a
--          document only ever retires its own evidence, so a second (empty, card-less
--          or partial-window) document for the same statement never drops lines; a
--          statement with neither card number nor rows is skipped with a warning
--   DP-06  an orphan review raised and resolved in the same transaction is dropped
--   DP-08  recon: no 'ok' for an empty statement whose header shows activity;
--          history extracts get status 'n/a'
--   DB-07  a statement without a card number never invents an account when the bank
--          has several: same document → same account, then an explicit statement
--          reference seen on exactly one account, else a permanent 22023
--   DB-08  ingest_sms validates and processes each message on its own; one bad
--          message never fails the batch. apply_sms_template treats an impossible
--          date as "template does not apply" instead of raising.
--   DB-10  a competitor that is clearly worse on merchant affinity no longer makes an
--          obvious pair ambiguous
--   DB-13  function-level `SET statement_timeout` removed (it never applied, see below)
--   X-08   ingestion and review resolution are serialised per profile with
--          pg_advisory_xact_lock(hashtext(profile_code))
--
-- Trivial fixes in the same functions: DB-15 (differing available limits prove two
-- alerts are distinct), DB-16 (lines without an AED amount downgrade a recon
-- mismatch to 'warn'), DB-17 (missing_from_statement reviews auto-resolve once the
-- transaction is no longer pending), DB-27 (a line displaced by a manual link gets
-- its own transaction), DB-43 (unknown_card without last4 binds the message to the
-- chosen account), DB-19 (the line's merchant is resolved once, not per candidate).

-- ── helpers ─────────────────────────────────────────────────────────────────
-- One lock per profile for everything that creates accounts, cards, statements or
-- transactions. Taken first, before any row lock, so lock order is always
-- advisory → rows and two writers on the same profile cannot deadlock.
create or replace function private.lock_profile(p_profile_code text)
returns void
language sql
volatile
set search_path = ''
as $$ select pg_advisory_xact_lock(hashtext(p_profile_code)) $$;

-- numeric or null, never an exception (rule conditions, payload fields).
create or replace function private.safe_numeric(p text)
returns numeric
language sql
immutable
parallel safe
set search_path = ''
as $$ select case when btrim(p) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(p)::numeric end $$;

-- How strongly two descriptions name the same merchant, 0–1. Unlike the score's
-- plain trigram similarity it recognises a short SMS merchant ("ENOC") inside a
-- long statement descriptor ("ENOC STATION 1021 DUBAI"). Used only to decide
-- whether a competitor is really a competitor (DB-10), never to score.
create or replace function private.merchant_affinity(a text, b text, ma text, mb text)
returns numeric
language sql
stable
parallel safe
set search_path = ''
as $$
  select case
    when ma is not null and ma = mb then 1
    else greatest(extensions.similarity(coalesce(a, ''), coalesce(b, '')),
                  extensions.word_similarity(coalesce(a, ''), coalesce(b, '')),
                  extensions.word_similarity(coalesce(b, ''), coalesce(a, '')))::numeric
  end
$$;

-- ── DB-13: function-level statement_timeout never applied ──────────────────
-- Postgres arms statement_timeout when the *outer* statement starts; a SET
-- attached to a function changes the GUC inside the call but not the running
-- timer (audit E1: a 1 s function slept 2.5 s). The attribute only misled
-- readers, so it is gone. Regex cost is bounded instead by validating patterns
-- on write (length caps, no back-references: private.validate_rule,
-- private.validate_sms_template, public.preview_rule) and by bounding inputs
-- (ingest_sms rejects bodies over 2000 chars). Callers keep their role-level
-- timeouts (authenticated 8 s through PostgREST).
alter function private.match_sms_template(text, text, text) reset statement_timeout;

-- ── SMS templates: bounded patterns, known field groups, safe dates ────────
create or replace function private.apply_sms_template(t public.sms_templates, p_sender text, p_body text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  m text[];
  f jsonb := '{}'::jsonb;
  k text;
  g int;
  v text;
begin
  if p_sender !~* t.sender_pattern then
    return null;
  end if;
  m := regexp_match(p_body, t.body_pattern, 'i');
  if m is null then
    return null;
  end if;
  for k, g in select key, value::int from jsonb_each_text(t.field_groups) loop
    v := btrim(m[g]);
    if v is null or v = '' then
      continue;
    end if;
    case k
      when 'amount', 'available' then
        f := f || jsonb_build_object(k, private.parse_amount(v)::text);
      when 'currency' then
        f := f || jsonb_build_object(k, upper(v));
      when 'merchant' then
        f := f || jsonb_build_object(k, private.normalize_text(v));
      when 'last4' then
        f := f || jsonb_build_object(k, right(regexp_replace(v, '[^0-9]', '', 'g'), 4));
      when 'date' then
        begin
          f := f || jsonb_build_object(k, to_char(to_date(v, coalesce(t.date_format, 'DD/MM/YYYY')), 'YYYY-MM-DD'));
        exception when others then
          -- DB-08: an impossible date (31/02) means this template does not apply.
          return null;
        end;
      else
        f := f || jsonb_build_object(k, v);
    end case;
  end loop;
  if t.msg_kind in ('purchase', 'preauth', 'refund', 'reversal', 'payment') and f->>'amount' is null then
    return null;
  end if;
  return f;
end;
$$;

create or replace function private.validate_sms_template()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  ex jsonb;
  f jsonb;
  k text;
  v text;
begin
  -- Bounded patterns (DB-13): templates run against every incoming SMS.
  if length(new.body_pattern) > 1000 or length(new.sender_pattern) > 200 then
    raise exception 'sms template % pattern is too long', new.name using errcode = '22023';
  end if;
  if new.body_pattern ~ '\\[1-9]' or new.sender_pattern ~ '\\[1-9]' then
    raise exception 'sms template % uses a back-reference', new.name using errcode = '22023';
  end if;
  -- Field groups are applied as `value::int` to every SMS: validate them here (DB-26).
  if jsonb_typeof(new.field_groups) <> 'object' or exists (
    select 1 from jsonb_each(new.field_groups) e
    where e.key not in ('amount', 'currency', 'merchant', 'last4', 'date', 'time', 'available')
       or jsonb_typeof(e.value) <> 'number' or e.value::text !~ '^[1-9][0-9]?$'
  ) then
    raise exception 'sms template % field_groups must map known fields to capture groups 1-99', new.name
      using errcode = '22023';
  end if;
  perform regexp_match('', new.body_pattern);     -- invalid regex raises here
  perform regexp_match('', new.sender_pattern);
  if tg_op = 'UPDATE' and (new.body_pattern, new.sender_pattern, new.field_groups, new.date_format, new.msg_kind)
     is distinct from (old.body_pattern, old.sender_pattern, old.field_groups, old.date_format, old.msg_kind) then
    new.version := old.version + 1;
  end if;
  for ex in select * from jsonb_array_elements(new.examples) loop
    f := private.apply_sms_template(new, coalesce(ex->>'sender', ''), ex->>'body');
    if f is null then
      raise exception 'sms template % does not match its example: %', new.name, left(ex->>'body', 60)
        using errcode = '22023';
    end if;
    for k, v in select key, value from jsonb_each_text(coalesce(ex->'expect', '{}'::jsonb)) loop
      if f->>k is distinct from v then
        raise exception 'sms template % example field % = %, expected %', new.name, k, f->>k, v
          using errcode = '22023';
      end if;
    end loop;
  end loop;
  return new;
end;
$$;

-- ── accounts (DB-07) ────────────────────────────────────────────────────────
drop function private.resolve_statement_account(text, text, text, text, text, numeric);

create or replace function private.resolve_statement_account(
  p_profile text, p_bank text, p_last4 text, p_holder text, p_card_type text, p_credit_limit numeric,
  p_doc_code text, p_reference text, p_reference_source text
)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_account text;
  v_n int;
  v_accounts text[];
begin
  if p_last4 is not null then
    select account_code into v_account from public.cards
    where profile_code = p_profile and bank_code = p_bank and last4 = p_last4;
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
  if p_credit_limit is not null then
    update public.accounts set credit_limit = p_credit_limit
    where account_code = v_account and credit_limit is distinct from p_credit_limit;
  end if;
  return v_account;
end;
$$;

-- ── derived transaction facts (DB-17: missing_from_statement auto-resolves) ─
create or replace function private.refresh_transaction(p_txn_code text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  t public.transactions%rowtype;
  l public.statement_lines%rowtype;
  s public.sms_messages%rowtype;
  v_has_line boolean := false;
  v_has_sms boolean := false;
  v_fx numeric;
begin
  select * into t from public.transactions where txn_code = p_txn_code for update;
  if not found then
    return;
  end if;

  select sl.* into l
  from public.transaction_evidence e
  join public.statement_lines sl on sl.line_code = e.line_code and sl.profile_code = e.profile_code
  where e.txn_code = p_txn_code and e.profile_code = t.profile_code
    and e.is_active and e.evidence_type in ('statement_line', 'history_line')
  order by case e.evidence_type when 'statement_line' then 0 else 1 end
  limit 1;
  v_has_line := found;

  select sm.* into s
  from public.transaction_evidence e
  join public.sms_messages sm on sm.sms_code = e.sms_code and sm.profile_code = e.profile_code
  where e.txn_code = p_txn_code and e.profile_code = t.profile_code and e.is_active and e.role <> 'duplicate'
  order by sm.event_at
  limit 1;
  v_has_sms := found;

  if v_has_line then
    t.card_code := coalesce(l.card_code, t.card_code);
    t.txn_date := l.txn_date;
    t.posting_date := l.posting_date;
    t.description := l.description;
    t.amount_original := l.amount_original;
    t.currency_original := l.currency_original;
    t.amount_aed := l.amount_aed;
    t.fx_rate := l.fx_rate;
    t.amount_aed_is_estimate := false;
    t.kind := l.kind;
    t.direction := l.direction;
    t.amount_source := l.evidence_type;
    t.stmt_code := l.stmt_code;
    t.status := 'posted';
    t.voided_at := null;
    t.void_reason := null;
    if l.amount_aed is null then
      v_fx := coalesce(l.fx_rate, private.estimate_fx(t.profile_code, l.currency_original));
      t.amount_aed := round(l.amount_original * v_fx, 2);
      t.amount_aed_is_estimate := t.amount_aed is not null;
    end if;
    if v_has_sms then
      t.txn_at := s.event_at;
      t.auth_amount := case when s.amount is distinct from l.amount_original then s.amount end;
    else
      t.txn_at := null;
      t.auth_amount := null;
    end if;
  elsif v_has_sms then
    t.card_code := coalesce(s.card_code, t.card_code);
    t.txn_at := s.event_at;
    t.txn_date := public.dubai_date(s.event_at);
    t.posting_date := null;
    t.description := coalesce(s.description, t.description);
    t.amount_original := s.amount;
    t.currency_original := s.currency;
    t.auth_amount := null;
    t.stmt_code := null;
    t.amount_source := 'sms';
    if s.currency = 'AED' then
      t.amount_aed := s.amount;
      t.fx_rate := null;
      t.amount_aed_is_estimate := false;
    else
      v_fx := private.estimate_fx(t.profile_code, s.currency);
      t.fx_rate := v_fx;
      t.amount_aed := round(s.amount * v_fx, 2);
      t.amount_aed_is_estimate := true;
    end if;
    t.status := case when t.voided_at is not null then 'void' else 'pending' end;
  else
    t.status := case when t.voided_at is not null then 'void' else 'orphaned' end;
  end if;

  t.merchant_code := private.resolve_merchant(t.description);

  update public.transactions set
    card_code = t.card_code, status = t.status, kind = t.kind, direction = t.direction,
    txn_date = t.txn_date, txn_at = t.txn_at, posting_date = t.posting_date, stmt_code = t.stmt_code,
    merchant_code = t.merchant_code, description = t.description,
    amount_original = t.amount_original, currency_original = t.currency_original,
    amount_aed = t.amount_aed, amount_aed_is_estimate = t.amount_aed_is_estimate, fx_rate = t.fx_rate,
    auth_amount = t.auth_amount, amount_source = t.amount_source,
    voided_at = t.voided_at, void_reason = t.void_reason
  where txn_code = p_txn_code
    and (card_code, status, kind, direction, txn_date, txn_at, posting_date, stmt_code, merchant_code,
         description, amount_original, currency_original, amount_aed, amount_aed_is_estimate, fx_rate,
         auth_amount, amount_source, voided_at, void_reason)
      is distinct from
        (t.card_code, t.status, t.kind, t.direction, t.txn_date, t.txn_at, t.posting_date, t.stmt_code, t.merchant_code,
         t.description, t.amount_original, t.currency_original, t.amount_aed, t.amount_aed_is_estimate, t.fx_rate,
         t.auth_amount, t.amount_source, t.voided_at, t.void_reason);

  if t.status = 'orphaned' then
    insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason)
    values (t.profile_code, t.account_code, 'transaction', t.txn_code, 'orphaned')
    on conflict do nothing;
  else
    -- An orphan review raised and answered within the same transaction (a
    -- re-parse that detached a line and re-matched it) was never news: drop it (DP-06).
    delete from public.match_reviews
    where profile_code = t.profile_code and subject_type = 'transaction' and subject_code = t.txn_code
      and reason = 'orphaned' and status = 'open' and created_at = now();
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'evidence_reattached'),
      resolved_at = now()
    where profile_code = t.profile_code and subject_type = 'transaction' and subject_code = t.txn_code
      and reason = 'orphaned' and status = 'open';
  end if;
  if t.status <> 'pending' then
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'no_longer_pending'),
      resolved_at = now()
    where profile_code = t.profile_code and subject_type = 'transaction' and subject_code = t.txn_code
      and reason = 'missing_from_statement' and status = 'open';
  end if;
end;
$$;

-- ── matcher: statement / history lines ─────────────────────────────────────
-- Same scoring as before (20261008000700). Two changes:
--   • candidates are joined on (profile_code, account_code) (DB-03)
--   • a materially different competitor within 15 points only makes the pair
--     ambiguous when it is not clearly worse on merchant affinity: a competitor
--     whose affinity is ≥ 0.3 below the pair's cannot be the same purchase (DB-10).
create or replace function private.match_statement_lines(p_stmt_code text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  c record;
  v_linked int := 0;
  v_created int := 0;
  v_held int := 0;
  v_conflict boolean;
  v_tie boolean;
  v_txn text;
  v_line text;
  v_touched text[] := '{}';
begin
  create temp table if not exists _mx_lines (line_code text primary key, merchant_code text, state text) on commit drop;
  create temp table if not exists _mx_txns (txn_code text primary key) on commit drop;
  create temp table if not exists _mx_cand (
    line_code text, txn_code text, score numeric, ddays int, line_no int, txn_created timestamptz,
    line_key text, txn_sig text, maff numeric
  ) on commit drop;
  truncate _mx_lines, _mx_txns, _mx_cand;

  -- Lines that need a home: current, no active evidence, not held by an open review.
  insert into _mx_lines (line_code, merchant_code, state)
  select l.line_code, private.resolve_merchant(l.description), 'open'
  from public.statement_lines l
  where l.stmt_code = p_stmt_code and l.is_current
    and not exists (select 1 from public.transaction_evidence e where e.line_code = l.line_code and e.is_active)
    and not exists (select 1 from public.match_reviews r
                    where r.profile_code = l.profile_code and r.subject_type = 'statement_line'
                      and r.subject_code = l.line_code and r.status = 'open');

  insert into _mx_cand
  select l.line_code, t.txn_code,
         private.match_score(
           l.amount_original, l.currency_original, l.amount_aed, l.txn_date, l.posting_date,
           l.description, ml.merchant_code, l.card_last4,
           t.amount_original, t.currency_original, t.amount_aed, t.txn_date, t.posting_date,
           t.description, t.merchant_code, cd.last4, coalesce(mr.variable_amount, false)
         ),
         abs(l.txn_date - t.txn_date), l.line_no, t.created_at,
         l.line_key,
         concat_ws('|', t.amount_original, t.currency_original, t.txn_date, t.merchant_code),
         private.merchant_affinity(l.description, t.description, ml.merchant_code, t.merchant_code)
  from _mx_lines ml
  join public.statement_lines l on l.line_code = ml.line_code
  join public.transactions t
    on t.profile_code = l.profile_code
   and t.account_code = l.account_code
   and t.direction = l.direction
   and (abs(t.txn_date - l.txn_date) <= 3
        or (t.posting_date is not null and l.posting_date is not null and abs(t.posting_date - l.posting_date) <= 1))
  left join public.cards cd on cd.card_code = t.card_code
  left join public.merchants mr on mr.merchant_code = t.merchant_code
  where not exists (
    select 1 from public.transaction_evidence e
    where e.txn_code = t.txn_code and e.is_active and e.evidence_type = l.evidence_type
  );
  delete from _mx_cand where score is null;

  for c in select * from _mx_cand order by score desc, ddays, line_no, txn_created, txn_code loop
    if c.score < 55 then
      exit;
    end if;
    if exists (select 1 from _mx_lines where line_code = c.line_code and state <> 'open')
       or exists (select 1 from _mx_txns where txn_code = c.txn_code) then
      continue;
    end if;

    v_conflict := exists (
      select 1 from _mx_cand x
      where x.score >= c.score - 15
        and x.maff > c.maff - 0.3
        and not exists (select 1 from _mx_txns where txn_code = x.txn_code)
        and not exists (select 1 from _mx_lines where line_code = x.line_code and state <> 'open')
        and (
          (x.line_code = c.line_code and x.txn_code <> c.txn_code and x.txn_sig <> c.txn_sig)
          or (x.txn_code = c.txn_code and x.line_code <> c.line_code and x.line_key <> c.line_key)
        )
    );
    v_tie := exists (
      select 1 from _mx_cand x
      where x.score >= c.score - 15
        and ((x.line_code = c.line_code and x.txn_code <> c.txn_code and x.txn_sig = c.txn_sig)
          or (x.txn_code = c.txn_code and x.line_code <> c.line_code and x.line_key = c.line_key))
    );

    if v_conflict or c.score < 75 then
      insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
      select l.profile_code, l.account_code, 'statement_line', l.line_code,
             case when v_conflict then 'ambiguous' else 'low_score' end,
             (select coalesce(jsonb_agg(jsonb_build_object('txn_code', x.txn_code, 'score', x.score) order by x.score desc), '[]'::jsonb)
                from (select * from _mx_cand x where x.line_code = c.line_code order by x.score desc limit 5) x)
      from public.statement_lines l where l.line_code = c.line_code
      on conflict do nothing;
      update _mx_lines set state = 'held' where line_code = c.line_code;
      v_held := v_held + 1;
      continue;
    end if;

    insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, role, score, method)
    select c.txn_code, l.profile_code, l.evidence_type, l.line_code,
           case when exists (select 1 from public.transaction_evidence e
                             where e.txn_code = c.txn_code and e.is_active and e.evidence_type = 'sms')
                then 'post' else 'primary' end,
           c.score,
           case when v_tie then 'tie' when c.score >= 85 then 'exact' else 'scored' end
    from public.statement_lines l where l.line_code = c.line_code;
    update _mx_lines set state = 'linked' where line_code = c.line_code;
    insert into _mx_txns values (c.txn_code);
    v_touched := v_touched || c.txn_code;
    v_linked := v_linked + 1;
  end loop;

  foreach v_txn in array v_touched loop
    perform private.refresh_transaction(v_txn);
  end loop;

  for v_line in select ml.line_code from _mx_lines ml
                join public.statement_lines l on l.line_code = ml.line_code
                where ml.state = 'open' order by l.line_no loop
    perform private.new_transaction_from_line(v_line);
    v_created := v_created + 1;
  end loop;

  return jsonb_build_object('linked', v_linked, 'created', v_created, 'held', v_held);
end;
$$;

-- ── matcher: one SMS ────────────────────────────────────────────────────────
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
  select e.txn_code into v_txn
  from public.sms_messages o
  join public.transaction_evidence e on e.sms_code = o.sms_code and e.is_active
  where o.profile_code = s.profile_code and o.sms_code <> s.sms_code
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
                       else round(s.amount * private.estimate_fx(s.profile_code, s.currency), 2) end;
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

-- ── statement reconciliation (profile-scoped; DB-16, DP-08) ─────────────────
-- 'n/a' is new: history extracts have no totals to reconcile against.
alter table public.statement_recon drop constraint statement_recon_status_check;
alter table public.statement_recon add constraint statement_recon_status_check
  check (status in ('ok', 'warn', 'fail', 'n/a'));

create or replace function private.reconcile_statement(p_stmt_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  st public.statements%rowtype;
  v_debits numeric;
  v_credits numeric;
  v_lines int;
  v_unpriced int;
  v_dropped int;
  v_purchase_lines int;
  v_sms_lines int;
  v_held int;
  v_unmatched int;
  v_mismatch boolean := false;
  v_checks jsonb := '{}'::jsonb;
  v_status text := 'ok';
  v_expected numeric;
begin
  select * into st from public.statements where stmt_code = p_stmt_code;

  -- A line without a printed AED amount (allowed by parse-v1, e.g. Mashreq FX rows)
  -- counts at its printed rate when there is one.
  select coalesce(sum(coalesce(amount_aed, round(amount_original * fx_rate, 2))) filter (where direction = 'debit'), 0),
         coalesce(sum(coalesce(amount_aed, round(amount_original * fx_rate, 2))) filter (where direction = 'credit'), 0),
         count(*),
         count(*) filter (where amount_aed is null),
         count(*) filter (where kind = 'purchase' and direction = 'debit')
  into v_debits, v_credits, v_lines, v_unpriced, v_purchase_lines
  from public.statement_lines
  where profile_code = st.profile_code and stmt_code = p_stmt_code and is_current;
  select count(*) into v_dropped from public.statement_lines
  where profile_code = st.profile_code and stmt_code = p_stmt_code and not is_current;

  select count(distinct l.line_code) into v_sms_lines
  from public.statement_lines l
  join public.transaction_evidence le on le.line_code = l.line_code and le.is_active
  join public.transaction_evidence se on se.txn_code = le.txn_code and se.is_active and se.evidence_type = 'sms'
  where l.profile_code = st.profile_code and l.stmt_code = p_stmt_code and l.is_current
    and l.kind = 'purchase' and l.direction = 'debit';

  select count(*) into v_held
  from public.match_reviews r join public.statement_lines l on l.line_code = r.subject_code
  where r.profile_code = st.profile_code and r.subject_type = 'statement_line' and r.status = 'open'
    and l.stmt_code = p_stmt_code;

  v_checks := jsonb_build_object(
    'line_count', v_lines,
    'sum_debits', v_debits::text,
    'sum_credits', v_credits::text,
    'held_lines', v_held,
    'sms_coverage', case when v_purchase_lines > 0 then round(v_sms_lines::numeric / v_purchase_lines, 3) end
  );
  if v_unpriced > 0 then
    v_checks := v_checks || jsonb_build_object('unpriced_lines', v_unpriced);
  end if;

  if st.kind = 'statement' then
    if st.total_debits is not null then
      v_checks := v_checks || jsonb_build_object('debits_match', abs(st.total_debits - v_debits) <= 0.01);
      if abs(st.total_debits - v_debits) > 0.01 then v_mismatch := true; end if;
    end if;
    if st.total_credits is not null then
      v_checks := v_checks || jsonb_build_object('credits_match', abs(st.total_credits - v_credits) <= 0.01);
      if abs(st.total_credits - v_credits) > 0.01 then v_mismatch := true; end if;
    end if;
    if st.opening_balance is not null and st.closing_balance is not null then
      v_expected := st.opening_balance + v_debits - v_credits;
      v_checks := v_checks || jsonb_build_object('balance_equation', abs(v_expected - st.closing_balance) <= 0.01,
                                                 'expected_closing', v_expected::text);
      if abs(v_expected - st.closing_balance) > 0.01 then v_mismatch := true; end if;
    end if;
    if v_mismatch then
      -- Lines with no AED amount make the sums uncertain, not wrong.
      v_status := case when v_unpriced > 0 then 'warn' else 'fail' end;
    end if;
    -- No lines although the header shows activity, or every line it had was
    -- superseded: never 'ok' (DP-08).
    if v_lines = 0 and v_status = 'ok'
       and (coalesce(st.total_debits, 0) > 0 or coalesce(st.total_credits, 0) > 0
            or st.opening_balance is distinct from st.closing_balance or v_dropped > 0) then
      v_status := 'warn';
      v_checks := v_checks || jsonb_build_object('no_lines', true, 'superseded_lines', v_dropped);
    end if;
    if st.total_debits is null and st.closing_balance is null and v_status = 'ok' then
      v_status := 'warn';
      v_checks := v_checks || jsonb_build_object('totals', 'not_extracted');
    end if;

    -- SMS-only transactions inside a closed period never posted: flag for review.
    if st.period_start is not null and st.period_end is not null then
      insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason)
      select t.profile_code, t.account_code, 'transaction', t.txn_code, 'missing_from_statement'
      from public.transactions t
      where t.profile_code = st.profile_code and t.account_code = st.account_code and t.status = 'pending'
        and t.txn_date between st.period_start and st.period_end - 3
      on conflict do nothing;
      select count(*) into v_unmatched from public.transactions t
      where t.profile_code = st.profile_code and t.account_code = st.account_code and t.status = 'pending'
        and t.txn_date between st.period_start and st.period_end - 3;
      v_checks := v_checks || jsonb_build_object('unmatched_sms', v_unmatched);
      if v_unmatched > 0 and v_status = 'ok' then v_status := 'warn'; end if;
    end if;
  end if;
  if v_held > 0 and v_status = 'ok' then
    v_status := 'warn';
  end if;
  -- A history extract is a window with no totals: nothing to reconcile (DP-08).
  if st.kind = 'history_extract' then
    v_status := 'n/a';
  end if;

  insert into public.statement_recon (stmt_code, profile_code, status, checks, computed_at)
  values (p_stmt_code, st.profile_code, v_status, v_checks, now())
  on conflict (stmt_code) do update set status = excluded.status, checks = excluded.checks, computed_at = now();
  return v_status;
end;
$$;

-- ── line provenance (DP-01, DP-02) ──────────────────────────────────────────
-- A statement can be evidenced by several documents: the same statement PDF
-- received twice (email and scraper), a card-less companion PDF with no rows
-- (ADCB), or overlapping history-extract windows (SIB). Each line records the
-- documents that evidence it. A document can only ever retire its *own*
-- evidence: a line leaves the ledger when no document evidences it any more.
-- Lines are therefore the union by (line_key, occurrence) of every document
-- of the statement, and only a re-parse of the same document removes lines.
alter table public.statement_lines add column source_doc_codes text[] not null default '{}';
comment on column public.statement_lines.source_doc_codes is
  'Documents whose parse contains this line. The line stays current while any of them does.';
update public.statement_lines l set source_doc_codes = array[s.doc_code]
from public.statements s
where s.stmt_code = l.stmt_code and s.doc_code is not null and l.source_doc_codes = '{}';
create index statement_lines_source_docs_idx on public.statement_lines using gin (source_doc_codes);

-- Take lines out of the ledger: not current, open line reviews dismissed,
-- evidence deactivated, transactions re-derived. Returns the number of lines.
create or replace function private.detach_lines(p_profile text, p_lines text[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer;
  v_txn text;
begin
  if coalesce(cardinality(p_lines), 0) = 0 then
    return 0;
  end if;
  update public.statement_lines set is_current = false, superseded_at = now()
  where profile_code = p_profile and line_code = any (p_lines) and is_current;
  get diagnostics v_n = row_count;
  update public.match_reviews set status = 'dismissed', resolution = jsonb_build_object('auto', 'line_superseded'),
    resolved_at = now()
  where profile_code = p_profile and subject_type = 'statement_line' and status = 'open'
    and subject_code = any (p_lines);
  for v_txn in
    update public.transaction_evidence set is_active = false, deactivated_at = now()
    where profile_code = p_profile and line_code = any (p_lines) and is_active
    returning txn_code
  loop
    perform private.refresh_transaction(v_txn);
  end loop;
  return v_n;
end;
$$;

-- ── retiring a statement (period-overlap resolution by the owner) ──────────
-- Marks the statement superseded and takes all its lines out of the ledger;
-- their transactions become 'orphaned' until another line claims them.
create or replace function private.supersede_statement(p_stmt_code text, p_by text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  st public.statements%rowtype;
begin
  select * into st from public.statements where stmt_code = p_stmt_code and status = 'active' for update;
  if not found then
    return;
  end if;
  update public.statements set status = 'superseded', superseded_by = p_by where stmt_code = p_stmt_code;
  update public.match_reviews set status = 'dismissed', resolution = jsonb_build_object('auto', 'statement_superseded'),
    resolved_at = now()
  where profile_code = st.profile_code and status = 'open' and subject_type = 'statement' and subject_code = p_stmt_code;
  perform private.detach_lines(st.profile_code, array(
    select l.line_code from public.statement_lines l
    where l.profile_code = st.profile_code and l.stmt_code = p_stmt_code and l.is_current));
end;
$$;

-- ── a re-parsed document no longer produces this statement (DB-06) ─────────
-- Withdraws the document's evidence from the statement. Lines another document
-- still evidences stay. A statement left with no current lines, whose own
-- document this was, is superseded (superseded_by null: a later re-parse of the
-- same document that produces it again revives it with its codes).
create or replace function private.retire_doc_from_statement(p_stmt_code text, p_doc_code text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  st public.statements%rowtype;
  v_gone text[];
  v_n integer;
begin
  select * into st from public.statements where stmt_code = p_stmt_code and status = 'active' for update;
  if not found then
    return 0;
  end if;
  with r as (
    update public.statement_lines l set source_doc_codes = array_remove(l.source_doc_codes, p_doc_code)
    where l.profile_code = st.profile_code and l.stmt_code = p_stmt_code and l.is_current
      and l.source_doc_codes @> array[p_doc_code]
    returning l.line_code, l.source_doc_codes
  )
  select array_agg(line_code) filter (where cardinality(source_doc_codes) = 0) into v_gone from r;
  v_n := private.detach_lines(st.profile_code, v_gone);

  if not exists (select 1 from public.statement_lines l
                 where l.profile_code = st.profile_code and l.stmt_code = p_stmt_code and l.is_current) then
    if st.doc_code is null or st.doc_code = p_doc_code then
      update public.statements set status = 'superseded', superseded_by = null where stmt_code = p_stmt_code;
      update public.match_reviews set status = 'dismissed',
        resolution = jsonb_build_object('auto', 'statement_superseded'), resolved_at = now()
      where profile_code = st.profile_code and status = 'open' and subject_type = 'statement'
        and subject_code = p_stmt_code;
    end if;
  elsif st.doc_code = p_doc_code then
    -- Another document still evidences it: that one becomes its document.
    update public.statements s set doc_code = (
      select d.doc_code from public.statement_lines l
      cross join lateral unnest(l.source_doc_codes) as u(doc_code)
      join public.documents d on d.profile_code = st.profile_code and d.doc_code = u.doc_code
      where l.profile_code = st.profile_code and l.stmt_code = p_stmt_code and l.is_current
      order by l.line_no limit 1)
    where s.stmt_code = p_stmt_code;
  end if;
  return v_n;
end;
$$;

-- ── statement ingestion ─────────────────────────────────────────────────────
-- The account is resolved by the caller (ingest_parsed_document, phase 1).
-- Header ownership: the statement's own document (statements.doc_code) writes
-- the header. Another document with the same identity only fills header fields
-- that are still null, and a document without rows never touches it (DP-01).
-- A document with rows takes the header over from one that contributed none.
drop function private.ingest_one_statement(public.documents, jsonb, text);

create or replace function private.ingest_one_statement(
  p_doc public.documents, p_stmt jsonb, p_parser_version text, p_account text
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_kind text := p_stmt->>'kind';
  v_bank text := p_stmt->>'bank_code';
  v_date date := (p_stmt->>'statement_date')::date;
  v_last4 text := nullif(p_stmt->>'primary_card_last4', '');
  v_totals jsonb := coalesce(p_stmt->'totals', '{}'::jsonb);
  v_n_in integer := jsonb_array_length(coalesce(p_stmt->'lines', '[]'::jsonb));
  v_account text := p_account;
  v_profile text := p_doc.profile_code;
  v_doc text := p_doc.doc_code;
  v_stmt text;
  v_status text;
  v_stmt_doc text;
  v_existing boolean;
  v_own boolean;
  v_gone text[];
  v_superseded int := 0;
  v_inserted int := 0;
  v_match jsonb;
  v_recon text;
  v_warnings jsonb := '[]'::jsonb;
begin
  -- The active statement with this identity, else one this same document produced
  -- earlier and a re-parse retired (DB-06): it comes back with its codes intact.
  -- A statement the owner superseded (superseded_by set) is never revived.
  select stmt_code, status, doc_code into v_stmt, v_status, v_stmt_doc from public.statements
  where profile_code = v_profile and account_code = v_account and statement_date = v_date and kind = v_kind
    and (status = 'active' or (status = 'superseded' and superseded_by is null and doc_code = v_doc))
  order by (status = 'active') desc, created_at desc
  limit 1;
  v_existing := v_stmt is not null;

  if v_existing then
    v_own := v_status = 'superseded' or v_stmt_doc is null or v_stmt_doc = v_doc
             or (v_n_in > 0 and not exists (
                   select 1 from public.statement_lines l
                   where l.profile_code = v_profile and l.stmt_code = v_stmt and l.is_current
                     and l.source_doc_codes @> array[v_stmt_doc]));
    if v_own then
      update public.statements set
        status = 'active',
        superseded_by = null,
        doc_code = v_doc,
        statement_reference = p_stmt->>'statement_reference',
        reference_source = p_stmt->>'reference_source',
        period_start = (p_stmt->>'period_start')::date,
        period_end = (p_stmt->>'period_end')::date,
        due_date = (p_stmt->>'due_date')::date,
        opening_balance = (v_totals->>'opening_balance')::numeric,
        closing_balance = (v_totals->>'closing_balance')::numeric,
        total_debits = (v_totals->>'total_debits')::numeric,
        total_credits = (v_totals->>'total_credits')::numeric,
        min_due = (v_totals->>'min_due')::numeric,
        credit_limit = (v_totals->>'credit_limit')::numeric,
        primary_card_last4 = v_last4,
        card_holder = p_stmt->>'card_holder',
        card_type = p_stmt->>'card_type',
        parser_version = p_parser_version,
        warnings = coalesce(p_stmt->'warnings', '[]'::jsonb),
        metadata = coalesce(p_stmt->'metadata', '{}'::jsonb)
      where stmt_code = v_stmt;
    elsif v_n_in > 0 then
      update public.statements s set
        statement_reference = coalesce(s.statement_reference, p_stmt->>'statement_reference'),
        reference_source = case when s.statement_reference is null then p_stmt->>'reference_source'
                                else s.reference_source end,
        period_start = case when s.period_start is null and s.period_end is null
                            then (p_stmt->>'period_start')::date else s.period_start end,
        period_end = case when s.period_start is null and s.period_end is null
                          then (p_stmt->>'period_end')::date else s.period_end end,
        due_date = coalesce(s.due_date, (p_stmt->>'due_date')::date),
        opening_balance = coalesce(s.opening_balance, (v_totals->>'opening_balance')::numeric),
        closing_balance = coalesce(s.closing_balance, (v_totals->>'closing_balance')::numeric),
        total_debits = coalesce(s.total_debits, (v_totals->>'total_debits')::numeric),
        total_credits = coalesce(s.total_credits, (v_totals->>'total_credits')::numeric),
        min_due = coalesce(s.min_due, (v_totals->>'min_due')::numeric),
        credit_limit = coalesce(s.credit_limit, (v_totals->>'credit_limit')::numeric),
        primary_card_last4 = coalesce(s.primary_card_last4, v_last4),
        card_holder = coalesce(s.card_holder, p_stmt->>'card_holder'),
        card_type = coalesce(s.card_type, p_stmt->>'card_type')
      where s.stmt_code = v_stmt;
    end if;
  else
    insert into public.statements (profile_code, account_code, doc_code, kind, statement_reference, reference_source,
      statement_date, period_start, period_end, due_date, opening_balance, closing_balance, total_debits,
      total_credits, min_due, credit_limit, primary_card_last4, card_holder, card_type, parser_version, warnings, metadata)
    values (v_profile, v_account, v_doc, v_kind, p_stmt->>'statement_reference',
      p_stmt->>'reference_source', v_date, (p_stmt->>'period_start')::date, (p_stmt->>'period_end')::date,
      (p_stmt->>'due_date')::date, (v_totals->>'opening_balance')::numeric, (v_totals->>'closing_balance')::numeric,
      (v_totals->>'total_debits')::numeric, (v_totals->>'total_credits')::numeric, (v_totals->>'min_due')::numeric,
      (v_totals->>'credit_limit')::numeric, v_last4, p_stmt->>'card_holder', p_stmt->>'card_type', p_parser_version,
      coalesce(p_stmt->'warnings', '[]'::jsonb), coalesce(p_stmt->'metadata', '{}'::jsonb))
    returning stmt_code into v_stmt;
  end if;

  if v_n_in = 0 then
    v_warnings := v_warnings || to_jsonb(format('%s %s: this document has no transaction rows%s', v_kind, v_date,
      case when v_existing and not v_own then '; the statement and its lines from other documents are kept' else '' end));
  end if;

  -- Incoming lines with their stable identity.
  create temp table if not exists _in_lines (
    line_no int, line_key text, occurrence smallint, txn_date date, txn_time time, posting_date date,
    description_raw text, description text, amount_original numeric, currency_original text, amount_aed numeric,
    fx_rate numeric, direction text, kind text, country_code text, card_last4 text, card_holder text,
    legacy_fingerprint text, raw jsonb
  ) on commit drop;
  truncate _in_lines;

  insert into _in_lines
  select x.line_no, x.line_key,
         row_number() over (partition by x.line_key order by x.line_no)::smallint,
         x.txn_date, x.txn_time, x.posting_date, x.description_raw, x.description, x.amount_original,
         x.currency_original, x.amount_aed, x.fx_rate, x.direction, x.kind, x.country_code, x.card_last4,
         x.card_holder, x.legacy_fingerprint, x.raw
  from (
    select (j->>'line_no')::int as line_no,
           encode(sha256(convert_to(concat_ws('|', v_account, j->>'txn_date', j->>'posting_date',
             (j->>'amount_original')::numeric(14,2), j->>'currency_original', (j->>'amount_aed')::numeric(14,2),
             j->>'direction', regexp_replace(btrim(j->>'description_raw'), '\s+', ' ', 'g')), 'UTF8')), 'hex') as line_key,
           (j->>'txn_date')::date as txn_date,
           (j->>'txn_time')::time as txn_time,
           (j->>'posting_date')::date as posting_date,
           j->>'description_raw' as description_raw,
           coalesce(private.normalize_text(j->>'merchant_normalized'), private.normalize_text(j->>'description_raw'), 'UNKNOWN') as description,
           (j->>'amount_original')::numeric(14,2) as amount_original,
           j->>'currency_original' as currency_original,
           (j->>'amount_aed')::numeric(14,2) as amount_aed,
           (j->>'fx_rate')::numeric(18,8) as fx_rate,
           j->>'direction' as direction,
           j->>'kind' as kind,
           j->>'country_code' as country_code,
           nullif(j->>'card_last4', '') as card_last4,
           j->>'card_holder' as card_holder,
           j->>'legacy_fingerprint' as legacy_fingerprint,
           j as raw
    from jsonb_array_elements(coalesce(p_stmt->'lines', '[]'::jsonb)) j
  ) x;

  -- This document's lines that vanished from its new parse: withdraw its
  -- evidence; a line nobody evidences any more leaves the ledger.
  with r as (
    update public.statement_lines l set source_doc_codes = array_remove(l.source_doc_codes, v_doc)
    where l.profile_code = v_profile and l.stmt_code = v_stmt and l.is_current
      and l.source_doc_codes @> array[v_doc]
      and not exists (select 1 from _in_lines i where i.line_key = l.line_key and i.occurrence = l.occurrence)
    returning l.line_code, l.source_doc_codes
  )
  select array_agg(line_code) filter (where cardinality(source_doc_codes) = 0) into v_gone from r;
  v_superseded := private.detach_lines(v_profile, v_gone);

  -- Unchanged lines this document also evidences.
  update public.statement_lines l set source_doc_codes = l.source_doc_codes || v_doc
  from _in_lines i
  where l.profile_code = v_profile and l.stmt_code = v_stmt and l.is_current
    and l.line_key = i.line_key and l.occurrence = i.occurrence
    and not (l.source_doc_codes @> array[v_doc]);

  -- New lines (unchanged ones keep their codes and evidence).
  insert into public.statement_lines (stmt_code, profile_code, account_code, card_code, evidence_type, line_no,
    line_key, occurrence, txn_date, txn_time, posting_date, description_raw, description, amount_original,
    currency_original, amount_aed, fx_rate, direction, kind, country_code, card_last4, legacy_fingerprint, raw,
    source_doc_codes)
  select v_stmt, v_profile, v_account,
         private.ensure_card(v_profile, v_account, v_bank, i.card_last4, i.card_holder,
                             i.card_last4 is distinct from v_last4),
         case when v_kind = 'statement' then 'statement_line' else 'history_line' end,
         i.line_no, i.line_key, i.occurrence, i.txn_date, i.txn_time, i.posting_date, i.description_raw,
         i.description, i.amount_original, i.currency_original, i.amount_aed, i.fx_rate, i.direction, i.kind,
         i.country_code, i.card_last4, i.legacy_fingerprint, i.raw, array[v_doc]
  from _in_lines i
  where not exists (select 1 from public.statement_lines l
                    where l.stmt_code = v_stmt and l.line_key = i.line_key and l.occurrence = i.occurrence);
  get diagnostics v_inserted = row_count;

  -- A line that is current again (re-added after a parser fix) is re-activated.
  update public.statement_lines l set is_current = true, superseded_at = null, line_no = i.line_no,
    source_doc_codes = array_append(array_remove(l.source_doc_codes, v_doc), v_doc)
  from _in_lines i
  where l.stmt_code = v_stmt and not l.is_current and l.line_key = i.line_key and l.occurrence = i.occurrence;

  v_match := private.match_statement_lines(v_stmt);

  -- Period overlap with another real statement of the same account.
  if v_kind = 'statement' and (p_stmt->>'period_start') is not null and (p_stmt->>'period_end') is not null then
    insert into public.match_reviews (profile_code, account_code, subject_type, subject_code, reason, candidates)
    select v_profile, v_account, 'statement', v_stmt, 'period_overlap',
           jsonb_agg(jsonb_build_object('stmt_code', o.stmt_code, 'statement_date', o.statement_date))
    from public.statements o
    where o.profile_code = v_profile and o.account_code = v_account
      and o.kind = 'statement' and o.status = 'active' and o.stmt_code <> v_stmt
      and o.period_start is not null and o.period_end is not null
      and least(o.period_end, (p_stmt->>'period_end')::date) - greatest(o.period_start, (p_stmt->>'period_start')::date) > 3
    having count(*) > 0
    on conflict do nothing;
  end if;

  v_recon := private.reconcile_statement(v_stmt);

  return jsonb_build_object(
    'stmt_code', v_stmt, 'account_code', v_account, 'kind', v_kind, 'replaced', v_existing,
    'lines_new', v_inserted, 'lines_superseded', v_superseded, 'match', v_match, 'recon', v_recon,
    'warnings', v_warnings
  );
end;
$$;

-- Entry point for the worker after the parser returns. One DB transaction,
-- serialised per profile (X-08). Three phases:
--   1. resolve each statement's account (may create accounts and cards). A
--      statement with neither a card number nor rows is not evidence of
--      anything and is skipped with a warning (DP-01).
--   2. withdraw this document's evidence from statements it no longer produces
--      (a corrected date or account, DB-06), freeing their transactions
--   3. ingest each statement; its lines re-claim the freed transactions
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
      nullif(s->'totals'->>'credit_limit', '')::numeric, d.doc_code, s->>'statement_reference', s->>'reference_source'
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
  end loop;

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

  return jsonb_build_object('doc_code', p_doc_code, 'statements', v_results, 'warnings', v_warnings);
end;
$$;

-- ── SMS ingestion (DB-08) ───────────────────────────────────────────────────
-- Why a message cannot be stored, or null when it can.
create or replace function private.sms_input_problem(msg jsonb)
returns text
language plpgsql
stable
set search_path = ''
as $$
begin
  if jsonb_typeof(msg) is distinct from 'object' then
    return 'not_an_object';
  end if;
  if jsonb_typeof(msg->'client_msg_id') is distinct from 'string'
     or msg->>'client_msg_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return 'invalid_client_msg_id';
  end if;
  if jsonb_typeof(msg->'body') is distinct from 'string' or btrim(msg->>'body') = '' then
    return 'missing_body';
  end if;
  if length(msg->>'body') > 2000 then
    return 'body_too_long';
  end if;
  if coalesce(jsonb_typeof(msg->'sender'), 'null') not in ('string', 'null') or length(msg->>'sender') > 100 then
    return 'invalid_sender';
  end if;
  if coalesce(jsonb_typeof(msg->'received_at'), 'null') <> 'null' then
    if jsonb_typeof(msg->'received_at') <> 'string' or not pg_input_is_valid(msg->>'received_at', 'timestamptz') then
      return 'invalid_received_at';
    end if;
    if (msg->>'received_at')::timestamptz not between '2000-01-01'::timestamptz and now() + interval '1 day' then
      return 'invalid_received_at';
    end if;
  end if;
  return null;
end;
$$;

-- Batch entry point: the iOS App Intent (via sms-ingest) or the app itself.
-- p_messages: [{client_msg_id, received_at, sender, body}]
-- Per-message result statuses: created | linked | duplicate | held | skipped |
-- ignored | unparsed | unknown_card | already_linked | duplicate_delivery |
-- rejected_otp, plus (new) 'invalid' (not stored; `reason` says why) and
-- 'failed' (stored with parse_status 'failed'; `reason` = 'error:<sqlstate>',
-- retried when templates change). Neither ever fails the batch.
create or replace function public.ingest_sms(p_profile_code text, p_messages jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  msg jsonb;
  v_code text;
  v_results jsonb := '[]'::jsonb;
  v_status text;
  v_problem text;
  v_state text;
begin
  perform private.assert_member(p_profile_code, true);
  if p_messages is null or jsonb_typeof(p_messages) <> 'array' or jsonb_array_length(p_messages) > 200 then
    raise exception 'p_messages must be an array of at most 200 messages' using errcode = '22023';
  end if;
  perform private.lock_profile(p_profile_code);

  for msg in select * from jsonb_array_elements(p_messages) loop
    v_problem := private.sms_input_problem(msg);
    if v_problem is not null then
      v_results := v_results || jsonb_build_object(
        'client_msg_id', case when jsonb_typeof(msg) = 'object' then msg->>'client_msg_id' end,
        'status', 'invalid', 'reason', v_problem);
      continue;
    end if;

    -- Defence in depth: OTPs are filtered on the device and never stored here.
    if (msg->>'body') ~* '(\motp\M|one[- ]?time (password|passcode|pin)|verification code|passcode|security code)' then
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'status', 'rejected_otp');
      continue;
    end if;

    v_code := null;
    insert into public.sms_messages (profile_code, client_msg_id, received_at, sender, body, body_hash)
    values (p_profile_code, (msg->>'client_msg_id')::uuid, coalesce((msg->>'received_at')::timestamptz, now()),
            coalesce(msg->>'sender', ''), msg->>'body',
            encode(sha256(convert_to(coalesce(msg->>'sender', '') || '|' || (msg->>'body'), 'UTF8')), 'hex'))
    on conflict (profile_code, client_msg_id) do nothing
    returning sms_code into v_code;

    if v_code is null then
      select sms_code into v_code from public.sms_messages
      where profile_code = p_profile_code and client_msg_id = (msg->>'client_msg_id')::uuid;
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'sms_code', v_code,
                                                   'status', 'duplicate_delivery');
      continue;
    end if;

    begin
      v_status := private.process_sms(v_code);
    exception when others then
      -- The message is kept; whatever processing did is rolled back to here.
      get stacked diagnostics v_state = returned_sqlstate;
      update public.sms_messages set parse_status = 'failed', ignore_reason = 'error:' || v_state
      where sms_code = v_code;
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'sms_code', v_code,
                                                   'status', 'failed', 'reason', 'error:' || v_state);
      continue;
    end;
    v_results := v_results || jsonb_build_object(
      'client_msg_id', msg->>'client_msg_id', 'sms_code', v_code, 'status', v_status,
      'txn_code', (select e.txn_code from public.transaction_evidence e where e.sms_code = v_code and e.is_active limit 1)
    );
  end loop;
  return v_results;
end;
$$;

-- New or changed templates re-run every message that is still unparsed. A
-- message that errors is marked failed instead of aborting the template write.
create or replace function private.trg_sms_templates_reprocess()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_state text;
begin
  for v_code in
    select sms_code from public.sms_messages
    where parse_status in ('unparsed', 'pending', 'failed')
    order by received_at
    limit 500
  loop
    begin
      perform private.process_sms(v_code);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      update public.sms_messages set parse_status = 'failed', ignore_reason = 'error:' || v_state
      where sms_code = v_code;
    end;
  end loop;
  return null;
end;
$$;

-- ── review resolution (DB-01, DB-02, DB-27, DB-33, DB-43) ──────────────────
-- p_action: {"link": "txn_…"} | {"create_new": true} | {"dismiss": true}
--         | {"card": {"account_code": "acc_…"}}  (unknown_card: register the card)
--         | {"supersede": "stm_…"}               (period_overlap: one of the review's candidates)
--         | {"not_a_transaction": true}           (sms subjects: the owner says it is not a card
--                                                 transaction → parse_status 'ignored', reason 'user_not_txn')
-- Every code in p_action must belong to the review's profile (P0002 otherwise);
-- a link must stay on the subject's account (22023).
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

-- ── LLM template proposals: decisions stay within the caller's profiles ────
create or replace function public.set_sms_template_active(p_template_code text, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mine text[];
  v_ref jsonb := jsonb_build_array(jsonb_build_object('template_code', p_template_code));
begin
  -- Only LLM proposals are decided here, and only by an owner of a profile whose
  -- unparsed SMS the proposal was made for.
  select array_agg(distinct r.profile_code) into v_mine
  from public.match_reviews r
  join public.sms_templates t on t.template_code = p_template_code and t.source = 'llm'
  where r.reason = 'unparsed_sms' and r.candidates @> v_ref
    and r.profile_code = any ((select authz.my_owned_profile_codes())::text[]);
  if v_mine is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  if p_active then
    update public.sms_templates set active = true where template_code = p_template_code and source = 'llm';
  end if;
  update public.match_reviews set status = case when p_active then 'resolved' else 'dismissed' end,
    resolution = jsonb_build_object('template_code', p_template_code, 'active', p_active),
    resolved_by = auth.uid(), resolved_at = now()
  where reason = 'unparsed_sms' and status = 'open' and candidates @> v_ref
    and profile_code = any (v_mine);
  if p_active then
    -- Other profiles' messages were just re-processed by the template trigger;
    -- close their reviews only where the message now parses.
    update public.match_reviews r set status = 'resolved',
      resolution = jsonb_build_object('auto', 'sms_parsed', 'template_code', p_template_code), resolved_at = now()
    where r.reason = 'unparsed_sms' and r.status = 'open' and r.candidates @> v_ref
      and exists (select 1 from public.sms_messages s
                  where s.sms_code = r.subject_code and s.profile_code = r.profile_code
                    and s.parse_status not in ('unparsed', 'pending', 'failed'));
  else
    -- A rejected proposal is deleted only when no other profile is still waiting on it.
    delete from public.sms_templates t
    where t.template_code = p_template_code and t.source = 'llm' and not t.active
      and not exists (select 1 from public.match_reviews r
                      where r.reason = 'unparsed_sms' and r.status = 'open' and r.candidates @> v_ref);
  end if;
end;
$$;

-- ── nightly housekeeping (profile-scoped joins) ─────────────────────────────
create or replace function private.void_released_authorisations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  r record;
begin
  for r in
    select rev.txn_code as rev_code, rev.related_txn_code as orig_code
    from public.transactions rev
    join public.transactions orig on orig.profile_code = rev.profile_code and orig.txn_code = rev.related_txn_code
    where rev.status = 'pending' and orig.status = 'pending'
      and exists (
        select 1 from public.statements st
        where st.profile_code = rev.profile_code and st.account_code = rev.account_code
          and st.kind = 'statement' and st.status = 'active'
          and st.period_end >= greatest(rev.txn_date, orig.txn_date) + 3
      )
  loop
    update public.transactions set voided_at = now(), void_reason = 'authorisation_released'
    where txn_code in (r.rev_code, r.orig_code);
    perform private.refresh_transaction(r.rev_code);
    perform private.refresh_transaction(r.orig_code);
    v_count := v_count + 2;
  end loop;
  return v_count;
end;
$$;

grant execute on function public.ingest_parsed_document(text, jsonb) to service_role;
grant execute on function public.ingest_sms(text, jsonb) to authenticated, service_role;
grant execute on function public.resolve_review(text, jsonb) to authenticated, service_role;
grant execute on function public.set_sms_template_active(text, boolean) to authenticated, service_role;

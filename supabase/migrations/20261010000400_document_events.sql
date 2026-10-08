-- Statement upload / parse event log: a per-document timeline the apps show live.
--
-- public.document_events is member-readable and in the supabase_realtime publication, so a
-- client that uploads a PDF (statements-upload returns its doc_code) can subscribe to
-- `doc_code=eq.<code>` and follow it. Writers:
--   Edge (statements-upload, gmail-push, outlook-poll via storeDocument):
--       received, stored, queued, duplicate        → public.log_document_event (service role)
--   begin_document_parse                            → parsing
--   worker, after the parser answers                → parsed (bank, statements, lines, warnings)
--   ingest_parsed_document                          → ingested (statements, lines new/unchanged/
--                                                     withdrawn, transactions created/linked, cards)
--   fail_document                                   → failed (permanent) / retry (transient)
--   requeue_documents, resubmit_document            → retry
-- Messages are sentences for end users. They never carry passwords, PDF text, statement
-- line text or SMS bodies; `detail` holds codes and counts only.
-- doc_code has no foreign key on purpose: `received` and `stored` are written before the
-- documents row exists (the row's INSERT trigger enqueues the parse, so the PDF must be in
-- Storage first). Rows go with their profile (cascade) and are purged after 90 days.

create table public.document_events (
  event_code text primary key default public.gen_code('dev') check (event_code ~ '^dev_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  doc_code text not null check (doc_code ~ '^doc_[0-9a-z]{26}$'),
  created_at timestamptz not null default clock_timestamp(),   -- not now(): events of one transaction keep their order
  stage text not null check (stage in
    ('received', 'stored', 'duplicate', 'queued', 'parsing', 'parsed', 'ingested', 'failed', 'retry')),
  level text not null default 'info' check (level in ('info', 'warn', 'error')),
  message text not null check (length(message) between 1 and 500),
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object')
);
create index document_events_doc_idx on public.document_events(doc_code, created_at);
create index document_events_profile_created_idx on public.document_events(profile_code, created_at desc);

alter table public.document_events enable row level security;
create policy document_events_member_read on public.document_events for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.document_events to authenticated;
grant all on public.document_events to service_role;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'document_events') then
    alter publication supabase_realtime add table public.document_events;
  end if;
end;
$$;

-- ── writers ─────────────────────────────────────────────────────────────────
create or replace function private.log_document_event(p_profile text, p_doc text, p_stage text, p_level text,
                                                      p_message text, p_detail jsonb default '{}'::jsonb)
returns text
language sql
security definer
set search_path = ''
as $$
  insert into public.document_events (profile_code, doc_code, stage, level, message, detail)
  values (p_profile, p_doc, p_stage, coalesce(p_level, 'info'), left(p_message, 500),
          case when jsonb_typeof(p_detail) = 'object' then p_detail else '{}'::jsonb end)
  returning event_code
$$;

-- Edge Functions (service role) log upload-side stages. When the document already exists it
-- must belong to p_profile_code.
create or replace function public.log_document_event(p_profile_code text, p_doc_code text, p_stage text,
                                                     p_level text, p_message text, p_detail jsonb default '{}'::jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  if exists (select 1 from public.documents d where d.doc_code = p_doc_code and d.profile_code <> p_profile_code) then
    raise exception 'document % belongs to another profile', p_doc_code using errcode = '42501';
  end if;
  return private.log_document_event(p_profile_code, p_doc_code, p_stage, p_level, p_message, p_detail);
end;
$$;

-- "1 line" / "3 lines".
create or replace function private.plural(p_n bigint, p_one text, p_many text)
returns text
language sql
immutable
set search_path = ''
as $$ select p_n || ' ' || case when p_n = 1 then p_one else p_many end $$;

-- The end-user sentence for a parse/ingest failure code (contract parse-v1 error codes, worker
-- codes, INGEST_<sqlstate>). Never the raw parser or database message.
create or replace function private.document_failure_message(p_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_code = 'PDF_DECRYPT_FAILED' then
      'We couldn''t open this PDF: its password is missing or wrong. Check the statement password for this bank, then upload it again.'
    when p_code = 'UNSUPPORTED_BANK' then 'Statements from this bank aren''t supported yet.'
    when p_code = 'BANK_UNDETECTED' then
      'We couldn''t tell which bank this statement is from. Upload it again and choose the bank.'
    when p_code = 'UNSUPPORTED_LAYOUT' then
      'This statement''s layout isn''t one we can read yet, so nothing was imported.'
    when p_code = 'PDF_TOO_LARGE' then 'This PDF is too large to process.'
    when p_code = 'PARSE_TIMEOUT' then 'Reading this PDF took too long and was stopped.'
    when p_code in ('DOWNLOAD_FAILED', 'DOCUMENT_MISSING') then
      'The stored PDF couldn''t be read. Upload it again.'
    when p_code = 'INVALID_REQUEST' then 'The statement reader rejected this file.'
    when p_code = 'PARSE_OUTPUT_INVALID' or p_code like 'INGEST_%' then
      'The statement was read, but its contents didn''t pass our checks, so nothing was imported.'
    when p_code = 'MAX_ATTEMPTS' then 'Processing failed after several attempts and was stopped.'
    else 'Processing this statement failed.'
  end
$$;

-- ── begin_document_parse: + 'parsing' ───────────────────────────────────────
create or replace function public.begin_document_parse(p_doc_code text, p_attempt integer default 1)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documents%rowtype;
begin
  perform private.assert_service_role();
  select * into d from public.documents where doc_code = p_doc_code for update;
  if not found then
    return null;
  end if;
  if d.parse_status in ('parsed', 'failed') then
    return jsonb_build_object('skip', d.parse_status, 'doc_code', d.doc_code);
  end if;
  update public.documents set parse_status = 'parsing',
    parse_attempts = least(greatest(coalesce(p_attempt, 1), 0), 32767)
  where doc_code = p_doc_code
  returning * into d;
  perform private.log_document_event(d.profile_code, d.doc_code, 'parsing', 'info',
    case when d.parse_attempts > 1 then format('Reading the statement again (attempt %s).', d.parse_attempts)
         else 'Reading the statement.' end,
    jsonb_build_object('attempt', d.parse_attempts));
  return jsonb_build_object(
    'skip', null,
    'doc', to_jsonb(d),
    'settings', coalesce((
      select jsonb_object_agg(split_part(s.name, ':', 3), s.decrypted_secret)
      from vault.decrypted_secrets s
      where s.name like 'profile:' || d.profile_code || ':%'), '{}'::jsonb)
  );
end;
$$;

-- ── fail_document: + 'failed' / 'retry' ─────────────────────────────────────
create or replace function public.fail_document(p_doc_code text, p_error_code text, p_error text, p_permanent boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile text;
begin
  perform private.assert_service_role();
  update public.documents
  set parse_status = case when p_permanent then 'failed' else 'queued' end,
      parse_error_code = p_error_code,
      parse_error = left(p_error, 2000)
  where doc_code = p_doc_code and parse_status <> 'parsed'
  returning profile_code into v_profile;
  if v_profile is null then
    return;
  end if;
  if p_permanent then
    perform private.log_document_event(v_profile, p_doc_code, 'failed', 'error',
      private.document_failure_message(p_error_code), jsonb_build_object('error_code', p_error_code));
  else
    perform private.log_document_event(v_profile, p_doc_code, 'retry', 'warn',
      'Processing hit a temporary problem; it will be retried automatically.',
      jsonb_build_object('error_code', p_error_code));
  end if;
end;
$$;

-- ── requeue_documents / resubmit_document: + 'retry' ────────────────────────
create or replace function public.requeue_documents(p_profile_code text, p_doc_codes text[] default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doc text;
  v_count integer := 0;
begin
  perform private.assert_member(p_profile_code, true);
  for v_doc in
    update public.documents set parse_status = 'queued', parse_error = null, parse_error_code = null
    where profile_code = p_profile_code and (p_doc_codes is null or doc_code = any (p_doc_codes))
    returning doc_code
  loop
    perform pgmq.send('parse_document', jsonb_build_object('doc_code', v_doc));
    perform private.log_document_event(p_profile_code, v_doc, 'retry', 'info', 'Queued to be read again.',
                                       jsonb_build_object('reason', 'requeued'));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.resubmit_document(p_profile_code text, p_doc_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  perform private.assert_service_role();
  select parse_status into v_status from public.documents
  where doc_code = p_doc_code and profile_code = p_profile_code
  for update;
  if not found then
    raise exception 'unknown document %', p_doc_code using errcode = 'P0002';
  end if;
  if v_status <> 'failed' then
    return jsonb_build_object('doc_code', p_doc_code, 'parse_status', v_status, 'requeued', false);
  end if;
  update public.documents set parse_status = 'queued', parse_error = null, parse_error_code = null, parse_attempts = 0
  where doc_code = p_doc_code;
  perform pgmq.send('parse_document', jsonb_build_object('doc_code', p_doc_code));
  perform private.log_document_event(p_profile_code, p_doc_code, 'retry', 'info',
    'The same file was sent again after it failed; it will be read again.',
    jsonb_build_object('reason', 'resubmitted'));
  return jsonb_build_object('doc_code', p_doc_code, 'parse_status', 'queued', 'requeued', true);
end;
$$;

-- ── ingest_parsed_document: + 'ingested' ──────────────────────────────────────
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

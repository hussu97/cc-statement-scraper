-- Documents (PDFs as received), statements and statement lines (immutable evidence).

-- ── storage bucket ──────────────────────────────────────────────────────────
-- Objects live at `<profile_code>/<doc_code>.pdf`. Clients never write here
-- directly; Edge Functions upload with the service role after auth + dedup.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('statements', 'statements', false, 26214400, array['application/pdf'])
on conflict (id) do nothing;

create policy statements_bucket_member_read on storage.objects for select to authenticated
  using (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = any ((select authz.my_profile_codes())::text[])
  );

-- ── documents ───────────────────────────────────────────────────────────────
create table public.documents (
  doc_code text primary key default public.gen_code('doc')
    check (doc_code ~ '^doc_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  kind text check (kind in ('statement_pdf', 'history_pdf')),        -- known after parse
  bank_code text references public.banks(bank_code),                  -- hint, then parsed
  storage_path text not null,
  original_filename text not null,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes integer not null check (size_bytes > 0),
  source text not null check (source in ('scraper', 'upload', 'ios', 'gmail', 'outlook', 'legacy')),
  source_ref text,                       -- e.g. gmail message/attachment id
  parse_status text not null default 'queued'
    check (parse_status in ('queued', 'parsing', 'parsed', 'failed')),
  parse_attempts smallint not null default 0,
  parser_version text,
  parse_error_code text,
  parse_error text,
  parse_warnings jsonb not null default '[]'::jsonb,
  parsed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_code, sha256)
);
create index documents_profile_status_idx on public.documents(profile_code, parse_status);
create trigger documents_touch before update on public.documents
  for each row execute function private.touch_updated_at();

-- ── statements ──────────────────────────────────────────────────────────────
create table public.statements (
  stmt_code text primary key default public.gen_code('stm')
    check (stmt_code ~ '^stm_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null references public.accounts(account_code) on delete restrict,
  doc_code text references public.documents(doc_code) on delete set null,
  kind text not null check (kind in ('statement', 'history_extract')),
  statement_reference text,
  reference_source text check (reference_source in ('explicit', 'fallback')),
  statement_date date not null,
  period_start date,
  period_end date,
  due_date date,
  opening_balance numeric(14,2),
  closing_balance numeric(14,2),
  total_debits numeric(14,2),
  total_credits numeric(14,2),
  min_due numeric(14,2),
  credit_limit numeric(14,2),
  primary_card_last4 text check (primary_card_last4 ~ '^[0-9]{4}$'),
  card_holder text,
  card_type text,
  status text not null default 'active' check (status in ('active', 'superseded')),
  superseded_by text references public.statements(stmt_code),
  parser_version text,
  warnings jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (period_start is null or period_end is null or period_start <= period_end)
);
-- A real statement is identified by (account, statement date). Re-ingesting the
-- same statement updates it in place; history extracts never collide with it.
create unique index statements_identity_uq on public.statements(account_code, statement_date)
  where kind = 'statement' and status = 'active';
create index statements_profile_date_idx on public.statements(profile_code, statement_date desc);
create index statements_doc_idx on public.statements(doc_code);
create trigger statements_touch before update on public.statements
  for each row execute function private.touch_updated_at();

-- ── statement lines ─────────────────────────────────────────────────────────
-- Immutable evidence. Only `is_current` / `superseded_at` ever change.
-- `line_key` hashes the raw facts of the row; `occurrence` is the ordinal among
-- identical keys within the statement, so two identical same-day purchases are
-- two distinct lines.
create table public.statement_lines (
  line_code text primary key default public.gen_code('lin')
    check (line_code ~ '^lin_[0-9a-z]{26}$'),
  stmt_code text not null references public.statements(stmt_code) on delete cascade,
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null references public.accounts(account_code) on delete restrict,
  card_code text references public.cards(card_code),
  evidence_type text not null check (evidence_type in ('statement_line', 'history_line')),
  line_no integer not null check (line_no > 0),
  line_key text not null,
  occurrence smallint not null default 1 check (occurrence >= 1),
  txn_date date not null,
  txn_time time,
  posting_date date,
  description_raw text not null,
  description text not null,          -- uppercase, collapsed; what rules match on
  amount_original numeric(14,2) not null check (amount_original >= 0),
  currency_original text not null check (currency_original ~ '^[A-Z]{3}$'),
  amount_aed numeric(14,2) check (amount_aed is null or amount_aed >= 0),
  fx_rate numeric(18,8) check (fx_rate is null or fx_rate > 0),
  direction text not null check (direction in ('debit', 'credit')),
  kind text not null check (kind in ('purchase', 'refund', 'payment', 'fee', 'interest', 'cash_advance', 'adjustment')),
  country_code text,
  card_last4 text check (card_last4 ~ '^[0-9]{4}$'),
  legacy_fingerprint text,
  raw jsonb not null default '{}'::jsonb,
  is_current boolean not null default true,
  superseded_at timestamptz,
  created_at timestamptz not null default now(),
  unique (stmt_code, line_key, occurrence)
);
create index statement_lines_account_date_idx on public.statement_lines(account_code, txn_date) where is_current;
create index statement_lines_legacy_fp_idx on public.statement_lines(legacy_fingerprint) where legacy_fingerprint is not null;

alter table public.documents enable row level security;
alter table public.statements enable row level security;
alter table public.statement_lines enable row level security;
create policy documents_member_read on public.documents for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy statements_member_read on public.statements for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy statement_lines_member_read on public.statement_lines for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.documents, public.statements, public.statement_lines to authenticated;
grant all on public.documents, public.statements, public.statement_lines to service_role;

-- ── email ingestion (Gmail push / Outlook poll) ─────────────────────────────
create table public.email_mailboxes (
  mailbox_code text primary key default public.gen_code('mbx')
    check (mailbox_code ~ '^mbx_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  provider text not null check (provider in ('gmail', 'outlook')),
  mailbox_email text not null,
  enabled boolean not null default true,
  sync_state jsonb not null default '{}'::jsonb,   -- gmail historyId / graph deltaLink
  watch_expires_at timestamptz,
  last_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_code, provider, mailbox_email)
);
create trigger email_mailboxes_touch before update on public.email_mailboxes
  for each row execute function private.touch_updated_at();

create table public.email_routes (
  route_code text primary key default public.gen_code('rte')
    check (route_code ~ '^rte_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  mailbox_code text not null references public.email_mailboxes(mailbox_code) on delete cascade,
  bank_code text not null references public.banks(bank_code),
  enabled boolean not null default true,
  sender_allowlist text[] not null default '{}',
  subject_keywords text[] not null default '{}',
  attachment_filename_regex text,
  gmail_label_filter text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_code, bank_code)
);
create trigger email_routes_touch before update on public.email_routes
  for each row execute function private.touch_updated_at();

create table public.email_events (
  event_code text primary key default public.gen_code('eml')
    check (event_code ~ '^eml_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  route_code text references public.email_routes(route_code) on delete set null,
  provider_message_id text not null,
  provider_attachment_id text not null,
  attachment_filename text,
  attachment_sha256 text,
  status text not null check (status in ('ingested', 'duplicate', 'ignored', 'failed')),
  doc_code text references public.documents(doc_code) on delete set null,
  detail text,
  created_at timestamptz not null default now(),
  unique (profile_code, provider_message_id, provider_attachment_id)
);
create index email_events_profile_created_idx on public.email_events(profile_code, created_at desc);

alter table public.email_mailboxes enable row level security;
alter table public.email_routes enable row level security;
alter table public.email_events enable row level security;
create policy email_mailboxes_member_read on public.email_mailboxes for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy email_mailboxes_owner_write on public.email_mailboxes for all to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));
create policy email_routes_member_read on public.email_routes for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy email_routes_owner_write on public.email_routes for all to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));
create policy email_events_member_read on public.email_events for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.email_mailboxes, public.email_routes, public.email_events to authenticated;
grant insert, delete on public.email_mailboxes, public.email_routes to authenticated;
grant update (enabled) on public.email_mailboxes to authenticated;
grant update (enabled, sender_allowlist, subject_keywords, attachment_filename_regex, gmail_label_filter, mailbox_code)
  on public.email_routes to authenticated;
grant all on public.email_mailboxes, public.email_routes, public.email_events to service_role;

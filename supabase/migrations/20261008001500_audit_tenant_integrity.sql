-- Audit fixes DB-03 / DB-14 (docs/audit/01-database.md): tenant integrity is
-- structural, not by convention.
--
-- Every child row already carries its own profile_code (RLS stays a single
-- predicate). Until now nothing tied that value to the parent row's profile, so
-- one mis-bound code (DB-01, DB-02, DB-14) crossed tenants. Each parent now has
-- UNIQUE (profile_code, <code>) and each child references it through a
-- composite FK, so a child can only ever point at a parent of its own profile.
--
-- The single-column FKs they replace are dropped: they are implied by the
-- composite ones, and keeping both would give PostgREST two relationships
-- between the same tables (ambiguous embeds, PGRST201).
--
-- ON DELETE SET NULL uses a column list (PG15+) so only the code column is
-- cleared, never the NOT NULL profile_code.

-- ── parents: (profile_code, code) is unique ────────────────────────────────
alter table public.accounts add constraint accounts_profile_account_uq unique (profile_code, account_code);
alter table public.cards add constraint cards_profile_card_uq unique (profile_code, card_code);
alter table public.documents add constraint documents_profile_doc_uq unique (profile_code, doc_code);
alter table public.statements add constraint statements_profile_stmt_uq unique (profile_code, stmt_code);
alter table public.statement_lines add constraint statement_lines_profile_line_uq unique (profile_code, line_code);
alter table public.sms_messages add constraint sms_messages_profile_sms_uq unique (profile_code, sms_code);
alter table public.transactions add constraint transactions_profile_txn_uq unique (profile_code, txn_code);
alter table public.category_rules add constraint category_rules_profile_rule_uq unique (profile_code, rule_code);
alter table public.recurring_series add constraint recurring_series_profile_recurring_uq unique (profile_code, recurring_code);
alter table public.email_mailboxes add constraint email_mailboxes_profile_mailbox_uq unique (profile_code, mailbox_code);
alter table public.email_routes add constraint email_routes_profile_route_uq unique (profile_code, route_code);

-- ── cards ───────────────────────────────────────────────────────────────────
alter table public.cards drop constraint cards_account_code_fkey;
alter table public.cards add constraint cards_account_fkey
  foreign key (profile_code, account_code) references public.accounts(profile_code, account_code) on delete cascade;

-- ── statements ──────────────────────────────────────────────────────────────
alter table public.statements drop constraint statements_account_code_fkey;
alter table public.statements drop constraint statements_doc_code_fkey;
alter table public.statements drop constraint statements_superseded_by_fkey;
alter table public.statements add constraint statements_account_fkey
  foreign key (profile_code, account_code) references public.accounts(profile_code, account_code) on delete restrict;
alter table public.statements add constraint statements_doc_fkey
  foreign key (profile_code, doc_code) references public.documents(profile_code, doc_code) on delete set null (doc_code);
alter table public.statements add constraint statements_superseded_by_fkey
  foreign key (profile_code, superseded_by) references public.statements(profile_code, stmt_code);

-- ── statement lines ─────────────────────────────────────────────────────────
alter table public.statement_lines drop constraint statement_lines_stmt_code_fkey;
alter table public.statement_lines drop constraint statement_lines_account_code_fkey;
alter table public.statement_lines drop constraint statement_lines_card_code_fkey;
alter table public.statement_lines add constraint statement_lines_stmt_fkey
  foreign key (profile_code, stmt_code) references public.statements(profile_code, stmt_code) on delete cascade;
alter table public.statement_lines add constraint statement_lines_account_fkey
  foreign key (profile_code, account_code) references public.accounts(profile_code, account_code) on delete restrict;
alter table public.statement_lines add constraint statement_lines_card_fkey
  foreign key (profile_code, card_code) references public.cards(profile_code, card_code);

-- ── SMS ─────────────────────────────────────────────────────────────────────
alter table public.sms_messages drop constraint sms_messages_account_code_fkey;
alter table public.sms_messages drop constraint sms_messages_card_code_fkey;
alter table public.sms_messages add constraint sms_messages_account_fkey
  foreign key (profile_code, account_code) references public.accounts(profile_code, account_code);
alter table public.sms_messages add constraint sms_messages_card_fkey
  foreign key (profile_code, card_code) references public.cards(profile_code, card_code);

-- ── transactions ────────────────────────────────────────────────────────────
alter table public.transactions drop constraint transactions_account_code_fkey;
alter table public.transactions drop constraint transactions_card_code_fkey;
alter table public.transactions drop constraint transactions_stmt_code_fkey;
alter table public.transactions drop constraint transactions_related_txn_code_fkey;
alter table public.transactions drop constraint transactions_rule_code_fkey;
alter table public.transactions drop constraint transactions_recurring_code_fkey;
alter table public.transactions add constraint transactions_account_fkey
  foreign key (profile_code, account_code) references public.accounts(profile_code, account_code) on delete restrict;
alter table public.transactions add constraint transactions_card_fkey
  foreign key (profile_code, card_code) references public.cards(profile_code, card_code);
alter table public.transactions add constraint transactions_stmt_fkey
  foreign key (profile_code, stmt_code) references public.statements(profile_code, stmt_code) on delete set null (stmt_code);
alter table public.transactions add constraint transactions_related_txn_fkey
  foreign key (profile_code, related_txn_code) references public.transactions(profile_code, txn_code)
  on delete set null (related_txn_code);
alter table public.transactions add constraint transactions_rule_fkey
  foreign key (profile_code, rule_code) references public.category_rules(profile_code, rule_code)
  on delete set null (rule_code);
alter table public.transactions add constraint transactions_recurring_fkey
  foreign key (profile_code, recurring_code) references public.recurring_series(profile_code, recurring_code)
  on delete set null (recurring_code);

-- ── evidence ────────────────────────────────────────────────────────────────
alter table public.transaction_evidence drop constraint transaction_evidence_txn_code_fkey;
alter table public.transaction_evidence drop constraint transaction_evidence_line_code_fkey;
alter table public.transaction_evidence drop constraint transaction_evidence_sms_code_fkey;
alter table public.transaction_evidence add constraint transaction_evidence_txn_fkey
  foreign key (profile_code, txn_code) references public.transactions(profile_code, txn_code) on delete cascade;
alter table public.transaction_evidence add constraint transaction_evidence_line_fkey
  foreign key (profile_code, line_code) references public.statement_lines(profile_code, line_code) on delete cascade;
alter table public.transaction_evidence add constraint transaction_evidence_sms_fkey
  foreign key (profile_code, sms_code) references public.sms_messages(profile_code, sms_code) on delete cascade;

-- ── reviews & reconciliation ────────────────────────────────────────────────
alter table public.match_reviews drop constraint match_reviews_account_code_fkey;
alter table public.match_reviews add constraint match_reviews_account_fkey
  foreign key (profile_code, account_code) references public.accounts(profile_code, account_code) on delete cascade;
alter table public.statement_recon drop constraint statement_recon_stmt_code_fkey;
alter table public.statement_recon add constraint statement_recon_stmt_fkey
  foreign key (profile_code, stmt_code) references public.statements(profile_code, stmt_code) on delete cascade;

-- ── email (DB-14: a route can only use a mailbox of its own profile) ───────
alter table public.email_routes drop constraint email_routes_mailbox_code_fkey;
alter table public.email_routes add constraint email_routes_mailbox_fkey
  foreign key (profile_code, mailbox_code) references public.email_mailboxes(profile_code, mailbox_code) on delete cascade;
alter table public.email_events drop constraint email_events_route_code_fkey;
alter table public.email_events drop constraint email_events_doc_code_fkey;
alter table public.email_events add constraint email_events_route_fkey
  foreign key (profile_code, route_code) references public.email_routes(profile_code, route_code)
  on delete set null (route_code);
alter table public.email_events add constraint email_events_doc_fkey
  foreign key (profile_code, doc_code) references public.documents(profile_code, doc_code)
  on delete set null (doc_code);

-- FK-side indexes the composite keys need for cascades / SET NULL scans (DB-32).
create index if not exists transactions_stmt_idx on public.transactions(stmt_code) where stmt_code is not null;
create index if not exists transactions_related_idx on public.transactions(related_txn_code) where related_txn_code is not null;
create index if not exists transactions_rule_idx on public.transactions(rule_code) where rule_code is not null;

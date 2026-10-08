-- FV-01 defence in depth: re-assert the exact client (anon / authenticated)
-- privileges on every table and view in `public`, whatever the database's
-- default privileges were when the tables were created.
--
-- 20261008000000_quarantine_legacy.sql already removes production's legacy
-- defaults (GRANT ALL ON TABLES TO anon, authenticated) before any v2 table
-- exists. This migration makes the end state independent of that: it revokes
-- everything from anon and authenticated, then replays the grant statements
-- the earlier migrations issue, verbatim and in order.
--
-- MAINTENANCE: the privilege matrix is pinned by supabase/tests/11_privileges.test.sql.
-- A later migration that changes a client grant must also update that test
-- (it fails otherwise). This file need not change: it runs once, and later
-- migrations apply their grants after it.

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- 20261008000200_identity.sql
grant select on public.profiles, public.profile_members, public.profile_state to authenticated;
grant update (name, base_currency) on public.profiles to authenticated;
-- token_hash is deliberately not readable by clients.
grant select (token_code, profile_code, name, token_prefix, scopes, created_at, last_used_at, revoked_at)
  on public.service_tokens to authenticated;
grant select on public.banks to authenticated;
grant select on public.accounts, public.cards to authenticated;
grant update (product_name, nickname, credit_limit, cycle_close_day, status) on public.accounts to authenticated;
grant update (holder_name, is_supplementary, status) on public.cards to authenticated;

-- 20261008000300_documents_statements.sql
grant select on public.documents, public.statements, public.statement_lines to authenticated;
grant select on public.email_mailboxes, public.email_routes, public.email_events to authenticated;
grant insert, delete on public.email_mailboxes, public.email_routes to authenticated;
grant update (enabled) on public.email_mailboxes to authenticated;
grant update (enabled, sender_allowlist, subject_keywords, attachment_filename_regex, gmail_label_filter, mailbox_code)
  on public.email_routes to authenticated;

-- 20261008000400_sms.sql, narrowed by 20261008001800_audit_visibility_and_legacy.sql
-- (column grants hide `examples` from clients).
grant select on public.sms_messages to authenticated;
grant select (template_code, bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind,
              priority, active, version, source, created_at, updated_at)
  on public.sms_templates to authenticated;

-- 20261008000500_ledger.sql
grant select on public.merchants, public.merchant_aliases, public.categories, public.category_rules,
  public.merchant_profile_category, public.transactions, public.transaction_evidence,
  public.match_reviews, public.statement_recon to authenticated;
grant insert on public.categories to authenticated;
grant update (name, parent_code, kind, color_token, icon, sort_order, archived_at) on public.categories to authenticated;
grant insert, update, delete on public.category_rules, public.merchant_profile_category to authenticated;
grant update (manual_category_code, notes, exclude_from_spend) on public.transactions to authenticated;

-- 20261008000800_analytics.sql
grant select on public.v_spend, public.v_transactions to authenticated;

-- 20261008000850_insights.sql
grant select, insert, update, delete on public.budgets to authenticated;
grant select on public.recurring_series to authenticated;
grant update (status) on public.recurring_series to authenticated;
grant select on public.insights to authenticated;
grant update (dismissed_at) on public.insights to authenticated;
grant select on public.audit_events to authenticated;

-- 20261008001200_fx_rates.sql
grant select on public.fx_rates to authenticated;

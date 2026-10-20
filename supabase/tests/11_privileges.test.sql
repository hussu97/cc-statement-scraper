-- Guard (FV-01): the exact privileges clients (anon, authenticated) hold on
-- public tables and views. Production was created with Supabase's older
-- defaults (GRANT ALL ON TABLES TO anon, authenticated); a migration that
-- relied on defaults would silently re-open table-wide grants there.
--
-- When a migration intentionally changes a client grant, update the matrix
-- below in the same change. Entries are 'table:role:PRIVILEGE' for table-level
-- grants and 'table.column:role:PRIVILEGE' for column-level grants.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ── default privileges: nothing new in public is granted to clients ─────────
select is(
  (select array_agg(format('%s:%s:%s', d.defaclobjtype, a.grantee::regrole, a.privilege_type) order by 1)
   from pg_default_acl d cross join lateral aclexplode(d.defaclacl) a
   where d.defaclrole = 'postgres'::regrole and d.defaclnamespace = 'public'::regnamespace
     and d.defaclobjtype in ('r', 'S')
     and a.grantee in ('anon'::regrole, 'authenticated'::regrole)),
  null,
  'postgres default privileges in public grant no table or sequence rights to anon/authenticated'
);

-- ── anon: no table privilege of any kind ────────────────────────────────────
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'p', 'f', 'S')
     and (exists (select 1 from aclexplode(c.relacl) a where a.grantee = 'anon'::regrole)
          or exists (select 1 from pg_attribute att cross join lateral aclexplode(att.attacl) a
                     where att.attrelid = c.oid and a.grantee = 'anon'::regrole))),
  null,
  'anon holds no privilege on any public table, view or sequence (incl. columns)'
);
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'p', 'f')
     and (has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
          or has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES'))),
  null,
  'anon has no effective privilege on any public table or view (incl. via PUBLIC)'
);

-- ── authenticated: no destructive table-level rights, column-limited UPDATE ─
select is(
  (select array_agg(c.relname::text order by c.relname) from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'p', 'f')
     and has_table_privilege('authenticated', c.oid, 'TRUNCATE,REFERENCES,TRIGGER')),
  null,
  'authenticated has no TRUNCATE/REFERENCES/TRIGGER on any public table'
);
select is(
  (select array_agg(t order by t) from unnest(array[
     'accounts', 'cards', 'categories', 'email_mailboxes', 'email_routes', 'insights', 'profiles',
     'recurring_series', 'transactions', 'statements', 'statement_lines', 'documents', 'service_tokens',
     'transaction_evidence', 'match_reviews', 'sms_templates', 'sms_messages']) t
   where has_table_privilege('authenticated', format('public.%I', t), 'UPDATE')),
  null,
  'authenticated UPDATE on ledger/identity tables is column-limited, never table-wide'
);
select is(
  (select array_agg(t order by t) from unnest(array[
     'accounts', 'cards', 'profiles', 'transactions', 'statements', 'statement_lines', 'documents',
     'service_tokens', 'transaction_evidence', 'match_reviews', 'insights', 'recurring_series', 'document_events',
     'anomaly_dismissals']) t
   where has_table_privilege('authenticated', format('public.%I', t), 'INSERT,DELETE')),
  null,
  'authenticated cannot INSERT or DELETE ledger/identity tables directly'
);
select ok(not has_column_privilege('authenticated', 'public.service_tokens', 'token_hash', 'SELECT'),
          'service_tokens.token_hash is not selectable by authenticated');
select ok(not has_column_privilege('authenticated', 'public.sms_templates', 'examples', 'SELECT'),
          'sms_templates.examples is not selectable by authenticated');
select ok(not has_column_privilege('authenticated', 'public.transactions', 'amount_aed', 'UPDATE'),
          'transactions.amount_aed is not updatable by authenticated');
select ok(not has_column_privilege('authenticated', 'public.transactions', 'status', 'UPDATE'),
          'transactions.status is not updatable by authenticated');

-- ── the exact matrix ────────────────────────────────────────────────────────
select set_eq(
  $$ select format('%s:%s:%s', c.relname, a.grantee::regrole, a.privilege_type)
     from pg_class c cross join lateral aclexplode(c.relacl) a
     where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'p', 'f', 'S')
       and a.grantee in ('anon'::regrole, 'authenticated'::regrole)
     union all
     select format('%s.%s:%s:%s', c.relname, att.attname, a.grantee::regrole, a.privilege_type)
     from pg_class c
     join pg_attribute att on att.attrelid = c.oid and att.attnum > 0 and not att.attisdropped
     cross join lateral aclexplode(att.attacl) a
     where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'p', 'f')
       and a.grantee in ('anon'::regrole, 'authenticated'::regrole) $$,
  array[
    'accounts.credit_limit:authenticated:UPDATE', 'accounts.cycle_close_day:authenticated:UPDATE', 'accounts.nickname:authenticated:UPDATE',
    'accounts.product_name:authenticated:UPDATE', 'accounts.status:authenticated:UPDATE', 'accounts:authenticated:SELECT',
    'anomaly_dismissals:authenticated:SELECT',
    'audit_events:authenticated:SELECT', 'balance_checkpoints:authenticated:SELECT', 'banks:authenticated:SELECT', 'budgets:authenticated:DELETE',
    'budgets:authenticated:INSERT', 'budgets:authenticated:SELECT', 'budgets:authenticated:UPDATE',
    'cards.holder_name:authenticated:UPDATE', 'cards.is_supplementary:authenticated:UPDATE', 'cards.status:authenticated:UPDATE',
    'cards.wallet_name:authenticated:UPDATE',
    'card_transfers:authenticated:SELECT', 'cards:authenticated:SELECT', 'categories.archived_at:authenticated:UPDATE', 'categories.color_token:authenticated:UPDATE',
    'categories.icon:authenticated:UPDATE', 'categories.kind:authenticated:UPDATE', 'categories.name:authenticated:UPDATE',
    'categories.parent_code:authenticated:UPDATE', 'categories.sort_order:authenticated:UPDATE', 'categories:authenticated:INSERT',
    'categories:authenticated:SELECT', 'category_rules:authenticated:DELETE', 'category_rules:authenticated:INSERT',
    'category_rules:authenticated:SELECT', 'category_rules:authenticated:UPDATE', 'document_events:authenticated:SELECT', 'documents:authenticated:SELECT',
    'email_events:authenticated:SELECT', 'email_mailboxes.enabled:authenticated:UPDATE', 'email_mailboxes:authenticated:DELETE',
    'email_mailboxes:authenticated:INSERT', 'email_mailboxes:authenticated:SELECT', 'email_routes.attachment_filename_regex:authenticated:UPDATE',
    'email_routes.enabled:authenticated:UPDATE', 'email_routes.gmail_label_filter:authenticated:UPDATE', 'email_routes.mailbox_code:authenticated:UPDATE',
    'email_routes.sender_allowlist:authenticated:UPDATE', 'email_routes.subject_keywords:authenticated:UPDATE', 'email_routes:authenticated:DELETE',
    'email_routes:authenticated:INSERT', 'email_routes:authenticated:SELECT', 'fx_rates:authenticated:SELECT',
    'insights.dismissed_at:authenticated:UPDATE', 'insights:authenticated:SELECT', 'match_reviews:authenticated:SELECT',
    'merchant_aliases:authenticated:SELECT', 'merchant_category_skips:authenticated:SELECT', 'merchant_profile_category:authenticated:DELETE', 'merchant_profile_category:authenticated:INSERT',
    'merchant_profile_category:authenticated:SELECT', 'merchant_profile_category:authenticated:UPDATE', 'merchants:authenticated:SELECT',
    'profile_members:authenticated:SELECT', 'profile_state:authenticated:SELECT', 'profiles.base_currency:authenticated:UPDATE',
    'profiles.name:authenticated:UPDATE', 'profiles:authenticated:SELECT', 'recurring_series.status:authenticated:UPDATE',
    'recurring_series:authenticated:SELECT', 'service_tokens.created_at:authenticated:SELECT', 'service_tokens.last_used_at:authenticated:SELECT',
    'service_tokens.name:authenticated:SELECT', 'service_tokens.profile_code:authenticated:SELECT', 'service_tokens.revoked_at:authenticated:SELECT',
    'service_tokens.scopes:authenticated:SELECT', 'service_tokens.token_code:authenticated:SELECT', 'service_tokens.token_prefix:authenticated:SELECT',
    'sms_messages:authenticated:SELECT', 'sms_templates.active:authenticated:SELECT', 'sms_templates.bank_code:authenticated:SELECT',
    'sms_templates.body_pattern:authenticated:SELECT', 'sms_templates.created_at:authenticated:SELECT', 'sms_templates.date_format:authenticated:SELECT',
    'sms_templates.field_groups:authenticated:SELECT', 'sms_templates.msg_kind:authenticated:SELECT', 'sms_templates.name:authenticated:SELECT',
    'sms_templates.priority:authenticated:SELECT', 'sms_templates.sender_pattern:authenticated:SELECT', 'sms_templates.source:authenticated:SELECT',
    'sms_templates.template_code:authenticated:SELECT', 'sms_templates.updated_at:authenticated:SELECT', 'sms_templates.version:authenticated:SELECT',
    'statement_lines:authenticated:SELECT', 'statement_recon:authenticated:SELECT', 'statements:authenticated:SELECT',
    'transaction_evidence:authenticated:SELECT', 'transactions.exclude_from_spend:authenticated:UPDATE', 'transactions.manual_category_code:authenticated:UPDATE',
    'transactions.notes:authenticated:UPDATE', 'transactions:authenticated:SELECT', 'v_account_balances:authenticated:SELECT',
    'v_bank_balances:authenticated:SELECT', 'v_cash_flow:authenticated:SELECT', 'v_sms_statements:authenticated:SELECT', 'v_spend:authenticated:SELECT', 'v_statement_payments:authenticated:SELECT',
    'v_transactions:authenticated:SELECT'
  ]::text[],
  'client privileges on public tables match the intended matrix exactly'
);

select * from finish();
rollback;

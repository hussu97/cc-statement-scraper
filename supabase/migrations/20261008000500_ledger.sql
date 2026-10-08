-- The canonical ledger: merchants, categories, rules, transactions and the
-- evidence that links each transaction to statement lines and/or SMS.

-- ── merchants (global) ──────────────────────────────────────────────────────
-- merchant_key collapses noise so "CARREFOUR CITY CENTRE 1234 DUBAI AE" and
-- "CARREFOUR CITY CENTRE" resolve to the same merchant.
create or replace function public.merchant_key(p text)
returns text
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  v text := upper(coalesce(p, ''));
  prev text;
begin
  v := regexp_replace(v, '[^A-Z0-9& ]', ' ', 'g');
  v := regexp_replace(v, '\s+', ' ', 'g');
  v := btrim(v);
  v := regexp_replace(v, '^(POS|PURCHASE|SALE|APPLE PAY|GOOGLE PAY|SAMSUNG PAY|ECOM|E COM|ONLINE|PAYPAL)\s+', '');
  loop
    prev := v;
    v := regexp_replace(v, '\s+(AE|ARE|UAE|US|USA|GB|GBR|UK|IN|IND|SA|SAU|DUBAI|DXB|ABU DHABI|ABUDHABI|AUH|SHARJAH|SHJ|AJMAN|AL AIN|RAS AL KHAIMAH|FUJAIRAH|UMM AL QUWAIN|LONDON|NEW YORK|NL|IE|IRL|SG|SGP)$', '');
    v := regexp_replace(v, '\s+[0-9]{3,}$', '');
    exit when v = prev;
  end loop;
  return nullif(btrim(v), '');
end;
$$;

create table public.merchants (
  merchant_code text primary key default public.gen_code('mer')
    check (merchant_code ~ '^mer_[0-9a-z]{26}$'),
  merchant_key text not null unique,
  display_name text not null,
  -- Fuel, hotels, car rental: the posted amount can differ from the authorisation.
  variable_amount boolean not null default false,
  created_at timestamptz not null default now()
);
create index merchants_key_trgm_idx on public.merchants using gin (merchant_key extensions.gin_trgm_ops);

create table public.merchant_aliases (
  alias_key text primary key,
  merchant_code text not null references public.merchants(merchant_code) on delete cascade,
  source text not null default 'auto' check (source in ('auto', 'manual', 'llm')),
  created_at timestamptz not null default now()
);
create index merchant_aliases_merchant_idx on public.merchant_aliases(merchant_code);

create or replace function private.resolve_merchant(p_description text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_key text := public.merchant_key(p_description);
  v_code text;
begin
  if v_key is null then
    return null;
  end if;
  select merchant_code into v_code from public.merchant_aliases where alias_key = v_key;
  if v_code is not null then
    return v_code;
  end if;
  insert into public.merchants (merchant_key, display_name)
  values (v_key, initcap(lower(v_key)))
  on conflict (merchant_key) do update set merchant_key = excluded.merchant_key
  returning merchant_code into v_code;
  return v_code;
end;
$$;

-- ── categories & rules (per profile) ────────────────────────────────────────
create table public.categories (
  category_code text primary key default public.gen_code('cat')
    check (category_code ~ '^cat_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  name text not null check (length(name) between 1 and 60),
  parent_code text,
  kind text not null default 'spend' check (kind in ('spend', 'income', 'transfer', 'fee', 'ignore')),
  color_token text,          -- e.g. 'cat-3' → resolved by the design tokens
  icon text,
  sort_order integer not null default 100,
  archived_at timestamptz,   -- never deleted: transactions keep pointing at it
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_code, category_code),
  foreign key (profile_code, parent_code) references public.categories(profile_code, category_code)
);
create unique index categories_profile_name_uq on public.categories(profile_code, lower(name));
create trigger categories_touch before update on public.categories
  for each row execute function private.touch_updated_at();

create table public.category_rules (
  rule_code text primary key default public.gen_code('rul')
    check (rule_code ~ '^rul_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  category_code text not null,
  name text,
  priority integer not null default 100,  -- lower wins; ties → longer pattern → exact>prefix>contains>regex
  match_type text not null check (match_type in ('exact', 'prefix', 'contains', 'regex')),
  pattern text not null check (length(btrim(pattern)) > 0),
  pattern_upper text generated always as (upper(btrim(pattern))) stored,
  -- optional extra predicates: amount_min, amount_max, bank_code, card_code,
  -- currency, kind, direction
  conditions jsonb not null default '{}'::jsonb check (jsonb_typeof(conditions) = 'object'),
  source text not null default 'user' check (source in ('seed', 'user', 'llm_promoted', 'legacy')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (profile_code, category_code) references public.categories(profile_code, category_code)
);
create index category_rules_profile_active_idx on public.category_rules(profile_code) where active;
create trigger category_rules_touch before update on public.category_rules
  for each row execute function private.touch_updated_at();

create or replace function private.validate_rule()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.match_type = 'regex' then
    perform regexp_match('', new.pattern);   -- invalid regex raises
  end if;
  return new;
end;
$$;
create trigger category_rules_validate before insert or update on public.category_rules
  for each row execute function private.validate_rule();

-- "Apply to merchant": a profile-level category for every transaction of a merchant.
create table public.merchant_profile_category (
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  merchant_code text not null references public.merchants(merchant_code) on delete cascade,
  category_code text not null,
  source text not null check (source in ('manual', 'llm')),
  confidence numeric(4,3) check (confidence is null or confidence between 0 and 1),
  model text,
  category_set_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (profile_code, merchant_code),
  foreign key (profile_code, category_code) references public.categories(profile_code, category_code)
);
create trigger merchant_profile_category_touch before update on public.merchant_profile_category
  for each row execute function private.touch_updated_at();

-- ── transactions ────────────────────────────────────────────────────────────
-- Fields marked (derived) are recomputed from evidence by
-- private.refresh_transaction(); only the (user) fields are ever edited.
create table public.transactions (
  txn_code text primary key default public.gen_code('txn')
    check (txn_code ~ '^txn_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null references public.accounts(account_code) on delete restrict,
  card_code text references public.cards(card_code),                      -- (derived)
  status text not null default 'pending'
    check (status in ('pending', 'posted', 'void', 'orphaned')),           -- (derived)
  kind text not null check (kind in
    ('purchase', 'refund', 'payment', 'fee', 'interest', 'cash_advance', 'adjustment')),
  direction text not null check (direction in ('debit', 'credit')),
  txn_date date not null,                                                  -- (derived)
  txn_at timestamptz,                                                      -- (derived) exact time from SMS
  posting_date date,                                                       -- (derived)
  stmt_code text references public.statements(stmt_code) on delete set null, -- (derived)
  merchant_code text references public.merchants(merchant_code),           -- (derived)
  description text not null,                                               -- (derived)
  amount_original numeric(14,2) not null check (amount_original >= 0),     -- (derived)
  currency_original text not null check (currency_original ~ '^[A-Z]{3}$'),
  amount_aed numeric(14,2) check (amount_aed is null or amount_aed >= 0),  -- (derived)
  amount_aed_is_estimate boolean not null default false,                   -- (derived)
  fx_rate numeric(18,8),                                                   -- (derived)
  auth_amount numeric(14,2),                                               -- (derived) SMS amount when it differs
  amount_source text not null check (amount_source in ('statement_line', 'history_line', 'sms', 'manual')),
  related_txn_code text references public.transactions(txn_code) on delete set null,
  voided_at timestamptz,
  void_reason text,
  exclude_from_spend boolean not null default false,                       -- (user)
  notes text,                                                              -- (user)
  -- categorisation
  manual_category_code text,                                               -- (user)
  manual_at timestamptz,
  rule_category_code text,
  rule_code text references public.category_rules(rule_code) on delete set null,
  rules_version bigint not null default 0,
  merchant_category_code text,
  merchant_category_source text check (merchant_category_source in ('manual', 'llm')),
  effective_category_code text generated always as (
    coalesce(
      manual_category_code,
      case when merchant_category_source = 'manual' then merchant_category_code end,
      rule_category_code,
      case when merchant_category_source = 'llm' then merchant_category_code end
    )
  ) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (profile_code, manual_category_code) references public.categories(profile_code, category_code),
  foreign key (profile_code, rule_category_code) references public.categories(profile_code, category_code),
  foreign key (profile_code, merchant_category_code) references public.categories(profile_code, category_code)
);
create index transactions_profile_date_idx on public.transactions(profile_code, txn_date desc);
create index transactions_account_date_idx on public.transactions(account_code, txn_date);
create index transactions_merchant_idx on public.transactions(merchant_code);
create index transactions_category_idx on public.transactions(profile_code, effective_category_code);
create index transactions_desc_trgm_idx on public.transactions using gin (description extensions.gin_trgm_ops);
create trigger transactions_touch before update on public.transactions
  for each row execute function private.touch_updated_at();

create or replace function private.stamp_manual_category()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.manual_category_code is distinct from old.manual_category_code then
    new.manual_at := case when new.manual_category_code is null then null else now() end;
  end if;
  return new;
end;
$$;
create trigger transactions_manual_stamp before update of manual_category_code on public.transactions
  for each row execute function private.stamp_manual_category();

-- ── evidence ────────────────────────────────────────────────────────────────
create table public.transaction_evidence (
  evidence_code text primary key default public.gen_code('evd')
    check (evidence_code ~ '^evd_[0-9a-z]{26}$'),
  txn_code text not null references public.transactions(txn_code) on delete cascade,
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  evidence_type text not null check (evidence_type in ('statement_line', 'history_line', 'sms')),
  line_code text references public.statement_lines(line_code) on delete cascade,
  sms_code text references public.sms_messages(sms_code) on delete cascade,
  role text not null default 'primary' check (role in ('primary', 'auth', 'post', 'reversal', 'duplicate')),
  score numeric(5,2),
  method text not null check (method in ('new', 'exact', 'scored', 'tie', 'manual', 'legacy')),
  is_active boolean not null default true,
  is_locked boolean not null default false,   -- set by manual review; never auto-unlinked
  created_at timestamptz not null default now(),
  deactivated_at timestamptz,
  check (num_nonnulls(line_code, sms_code) = 1),
  check ((evidence_type = 'sms') = (sms_code is not null))
);
create unique index transaction_evidence_line_uq on public.transaction_evidence(line_code) where is_active and line_code is not null;
create unique index transaction_evidence_sms_uq on public.transaction_evidence(sms_code) where is_active and sms_code is not null;
-- At most one active statement line and one active history line per transaction.
create unique index transaction_evidence_one_stmt_uq on public.transaction_evidence(txn_code, evidence_type)
  where is_active and evidence_type in ('statement_line', 'history_line');
create index transaction_evidence_txn_idx on public.transaction_evidence(txn_code) where is_active;

-- ── reviews & reconciliation ────────────────────────────────────────────────
create table public.match_reviews (
  review_code text primary key default public.gen_code('rev')
    check (review_code ~ '^rev_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text references public.accounts(account_code) on delete cascade,
  subject_type text not null check (subject_type in ('statement_line', 'sms', 'transaction', 'statement')),
  subject_code text not null,
  reason text not null check (reason in
    ('ambiguous', 'low_score', 'amount_drift', 'orphaned', 'missing_from_statement',
     'period_overlap', 'unknown_card', 'unparsed_sms')),
  candidates jsonb not null default '[]'::jsonb,
  status text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  resolution jsonb,
  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index match_reviews_open_subject_uq on public.match_reviews(subject_type, subject_code, reason)
  where status = 'open';
create index match_reviews_profile_open_idx on public.match_reviews(profile_code) where status = 'open';

create table public.statement_recon (
  stmt_code text primary key references public.statements(stmt_code) on delete cascade,
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  status text not null check (status in ('ok', 'warn', 'fail')),
  checks jsonb not null,
  computed_at timestamptz not null default now()
);

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table public.merchants enable row level security;
alter table public.merchant_aliases enable row level security;
alter table public.categories enable row level security;
alter table public.category_rules enable row level security;
alter table public.merchant_profile_category enable row level security;
alter table public.transactions enable row level security;
alter table public.transaction_evidence enable row level security;
alter table public.match_reviews enable row level security;
alter table public.statement_recon enable row level security;

create policy merchants_read on public.merchants for select to authenticated using (true);
create policy merchant_aliases_read on public.merchant_aliases for select to authenticated using (true);

create policy categories_member_read on public.categories for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy categories_owner_insert on public.categories for insert to authenticated
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));
create policy categories_owner_update on public.categories for update to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));

create policy category_rules_member_read on public.category_rules for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy category_rules_owner_write on public.category_rules for all to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));

create policy mpc_member_read on public.merchant_profile_category for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy mpc_owner_write on public.merchant_profile_category for all to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));

create policy transactions_member_read on public.transactions for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy transactions_owner_update on public.transactions for update to authenticated
  using (profile_code = any ((select authz.my_owned_profile_codes())::text[]))
  with check (profile_code = any ((select authz.my_owned_profile_codes())::text[]));

create policy transaction_evidence_member_read on public.transaction_evidence for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy match_reviews_member_read on public.match_reviews for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
create policy statement_recon_member_read on public.statement_recon for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));

grant select on public.merchants, public.merchant_aliases, public.categories, public.category_rules,
  public.merchant_profile_category, public.transactions, public.transaction_evidence,
  public.match_reviews, public.statement_recon to authenticated;
grant insert on public.categories to authenticated;
grant update (name, parent_code, kind, color_token, icon, sort_order, archived_at) on public.categories to authenticated;
grant insert, update, delete on public.category_rules, public.merchant_profile_category to authenticated;
grant update (manual_category_code, notes, exclude_from_spend) on public.transactions to authenticated;
grant all on public.merchants, public.merchant_aliases, public.categories, public.category_rules,
  public.merchant_profile_category, public.transactions, public.transaction_evidence,
  public.match_reviews, public.statement_recon to service_role;

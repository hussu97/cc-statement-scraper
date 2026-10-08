-- Private merchant masking.
--
-- The database owner can make chosen transactions appear under a generic merchant name to
-- everyone using the apps, for existing and future data. It is configured ONLY in the
-- database (no RPC, view, policy or UI reads or edits it):
--
--   insert into private.merchant_masks (pattern, replacement_merchant_name, replacement_category_name)
--   values ('<case-insensitive POSIX regex>', '<generic name>', '<category name or null>');
--
-- Inserting or updating a mask applies it at once (statement trigger → apply_merchant_masks).
-- From then on every write path masks at the source:
--   * statement_lines   BEFORE INSERT/UPDATE of the text: description_raw, description and
--                       every string of `raw` that matches are replaced by the generic name.
--                       line_key (the line's identity, hashed from the ORIGINAL text by
--                       ingest) is never touched, so a re-parse of the same statement finds
--                       the line unchanged: no duplicate, nothing unmasked.
--   * sms_messages      BEFORE INSERT/UPDATE: the merchant as it appears in the body (located
--                       through the SMS template) and any other matching word are replaced;
--                       merchant_raw / description / parsed_fields.merchant become the generic
--                       name. body_hash (dedup) keeps hashing the original body.
--   * transactions      safety net for any other path: a matching description is replaced.
--   * merchants         a new merchant row whose key or name matches resolves to the mask's
--                       generic merchant instead (resolve_merchant's upsert lands on it).
-- Transactions derive their text and merchant from evidence (refresh_transaction), so they
-- follow the evidence. Originals are kept, for the database owner only, in
-- private.masked_originals. Deactivating a mask does not unmask existing rows.
--
-- Category: when replacement_category_name is set, each affected profile gets a merchant-level
-- MANUAL category on the generic merchant (merchant_profile_category, source 'manual'), the
-- same mechanism as "apply to merchant": it outranks rules and LLM suggestions, while a
-- transaction's own manual category still wins (effective_category_code precedence). The
-- category is found by name in the profile, or created (kind 'spend'). A merchant-level choice
-- the owner later makes in the app is kept (only an LLM row is overwritten).

-- ── tables ──────────────────────────────────────────────────────────────────
create table private.merchant_masks (
  mask_code text primary key default public.gen_code('msk') check (mask_code ~ '^msk_[0-9a-z]{26}$'),
  pattern text not null check (length(btrim(pattern)) between 1 and 200),
  replacement_merchant_name text not null check (length(btrim(replacement_merchant_name)) between 1 and 80),
  replacement_category_name text check (replacement_category_name is null
                                        or length(btrim(replacement_category_name)) between 1 and 60),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- One row per masked value: what the column held before the first mask touched it.
create table private.masked_originals (
  table_name text not null check (table_name in
    ('statement_lines', 'sms_messages', 'transactions', 'merchants', 'merchant_aliases', 'insights')),
  row_code text not null,
  column_name text not null,
  profile_code text,                 -- null for global rows (merchants, merchant_aliases)
  mask_code text references private.merchant_masks(mask_code) on delete set null,
  original text,
  masked_at timestamptz not null default now(),
  primary key (table_name, row_code, column_name)
);
create index masked_originals_profile_idx on private.masked_originals(profile_code);

-- `private` is unreachable for client roles; RLS without any policy and no grants makes the
-- tables unreadable even for service_role. Only the database owner (postgres) reads them.
alter table private.merchant_masks enable row level security;
alter table private.masked_originals enable row level security;
revoke all on private.merchant_masks, private.masked_originals from public, anon, authenticated, service_role;

-- ── helpers ─────────────────────────────────────────────────────────────────
-- Every string inside a jsonb value (the root included).
create or replace function private.jsonb_strings(j jsonb)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(v #>> '{}'), '{}'::text[])
  from jsonb_path_query(coalesce(j, 'null'::jsonb), 'strict $.**') v
  where jsonb_typeof(v) = 'string'
$$;

-- The first active mask (oldest first) matching any of the texts, else null.
create or replace function private.mask_for(p_texts text[])
returns private.merchant_masks
language sql
stable
security definer
set search_path = ''
as $$
  select m.* from private.merchant_masks m
  where m.active and exists (select 1 from unnest(p_texts) t where t is not null and t ~* m.pattern)
  order by m.created_at, m.mask_code
  limit 1
$$;

-- Replace every string of a jsonb value that matches the pattern with the replacement.
create or replace function private.mask_jsonb(j jsonb, p_pattern text, p_replacement text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
begin
  case jsonb_typeof(j)
    when 'object' then
      return (select coalesce(jsonb_object_agg(e.key, private.mask_jsonb(e.value, p_pattern, p_replacement)), '{}'::jsonb)
              from jsonb_each(j) e);
    when 'array' then
      return (select coalesce(jsonb_agg(private.mask_jsonb(e.value, p_pattern, p_replacement) order by e.ord), '[]'::jsonb)
              from jsonb_array_elements(j) with ordinality e(value, ord));
    when 'string' then
      return case when (j #>> '{}') ~* p_pattern then to_jsonb(p_replacement) else j end;
    else
      return j;
  end case;
end;
$$;

-- A regex that finds normalised text (upper-cased, whitespace collapsed) as it was written:
-- each word escaped, words joined by any whitespace; used case-insensitively.
create or replace function private.loose_literal_regex(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select string_agg(regexp_replace(w, '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g'), '[[:space:]]+' order by o)
  from regexp_split_to_table(btrim(coalesce(p_text, '')), '\s+') with ordinality x(w, o)
  where w <> ''
$$;

-- Mask the free text of an alert or insight: the whole whitespace-delimited words that
-- contain a match are replaced by the generic name.
create or replace function private.mask_words(p_text text, p_pattern text, p_replacement text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(p_text, '[^[:space:]]*(' || p_pattern || ')[^[:space:]]*', p_replacement, 'gi')
$$;

-- The masked SMS body: first the template's merchant as written in the body (so the masked
-- body still parses to exactly the generic name), then any other matching word.
create or replace function private.mask_sms_body(p_body text, p_sender text, p_profile text, m private.merchant_masks)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v text := p_body;
  v_merchant text;
  v_re text;
begin
  begin
    select t.fields->>'merchant' into v_merchant
    from private.match_sms_template(coalesce(p_sender, ''), p_body, null, p_profile) t limit 1;
  exception when others then
    v_merchant := null;
  end;
  if v_merchant is not null and v_merchant ~* m.pattern then
    v_re := private.loose_literal_regex(v_merchant);
    if v_re is not null then
      v := regexp_replace(v, v_re, m.replacement_merchant_name, 'gi');
    end if;
  end if;
  return private.mask_words(v, m.pattern, m.replacement_merchant_name);
end;
$$;

-- Remember a column's value before masking (the first original wins: never overwritten).
create or replace function private.keep_original(p_table text, p_row text, p_column text, p_profile text,
                                                 p_mask text, p_original text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into private.masked_originals (table_name, row_code, column_name, profile_code, mask_code, original)
  values (p_table, p_row, p_column, p_profile, p_mask, p_original)
  on conflict (table_name, row_code, column_name) do nothing
$$;

-- The global generic merchant row of a mask (created when absent).
create or replace function private.mask_merchant_code(m private.merchant_masks)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := public.merchant_key(m.replacement_merchant_name);
  v_code text;
begin
  select merchant_code into v_code from public.merchants where merchant_key = v_key;
  if v_code is null then
    insert into public.merchants (merchant_key, display_name)
    values (v_key, btrim(m.replacement_merchant_name))
    on conflict (merchant_key) do nothing;
    select merchant_code into v_code from public.merchants where merchant_key = v_key;
  end if;
  return v_code;
end;
$$;

-- The mask's category in one profile: the category of that name (created when absent, kind
-- 'spend') as a merchant-level MANUAL choice on the generic merchant. An LLM row is upgraded;
-- a manual row (the owner's own "apply to merchant") is left alone. Called by apply and by
-- the masking triggers, so a profile whose first masked transaction arrives later gets it too.
create or replace function private.ensure_mask_category(p_profile text, m private.merchant_masks)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_generic text;
  v_cat text;
begin
  if m.replacement_category_name is null or p_profile is null then
    return;
  end if;
  v_generic := private.mask_merchant_code(m);
  if exists (select 1 from public.merchant_profile_category mpc
             where mpc.profile_code = p_profile and mpc.merchant_code = v_generic and mpc.source = 'manual') then
    return;
  end if;
  select c.category_code into v_cat from public.categories c
  where c.profile_code = p_profile and lower(c.name) = lower(m.replacement_category_name);
  if v_cat is null then
    insert into public.categories (profile_code, name, kind, sort_order, color_token)
    values (p_profile, m.replacement_category_name, 'spend', 500,
            'cat-' || ((select count(*) from public.categories c where c.profile_code = p_profile) % 12 + 1))
    returning category_code into v_cat;
  end if;
  insert into public.merchant_profile_category (profile_code, merchant_code, category_code, source)
  values (p_profile, v_generic, v_cat, 'manual')
  on conflict (profile_code, merchant_code) do update
    set category_code = excluded.category_code, source = 'manual', confidence = null, model = null,
        category_set_hash = null
    where public.merchant_profile_category.source = 'llm';
end;
$$;

-- ── validation ──────────────────────────────────────────────────────────────
create or replace function private.validate_merchant_mask()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.pattern := btrim(new.pattern);
  new.replacement_merchant_name := btrim(new.replacement_merchant_name);
  new.replacement_category_name := nullif(btrim(new.replacement_category_name), '');
  begin
    perform regexp_match('', new.pattern, 'i');        -- an invalid regex raises here
  exception when others then
    raise exception 'merchant mask pattern is not a valid regular expression' using errcode = '22023';
  end;
  begin
    perform private.mask_words('', new.pattern, 'x');  -- must also work inside a group
  exception when others then
    raise exception 'merchant mask pattern cannot be embedded in a group (no embedded options)' using errcode = '22023';
  end;
  if '' ~* new.pattern or ' ' ~* new.pattern then
    raise exception 'merchant mask pattern must not match empty text' using errcode = '22023';
  end if;
  if public.merchant_key(new.replacement_merchant_name) is null then
    raise exception 'replacement_merchant_name needs letters or digits' using errcode = '22023';
  end if;
  if new.replacement_merchant_name ~* new.pattern or private.normalize_text(new.replacement_merchant_name) ~* new.pattern then
    raise exception 'replacement_merchant_name must not match its own pattern' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger merchant_masks_validate before insert or update on private.merchant_masks
  for each row execute function private.validate_merchant_mask();

-- ── masking at the source ───────────────────────────────────────────────────
create or replace function private.trg_mask_statement_line()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m private.merchant_masks;
begin
  m := private.mask_for(array[new.description_raw, new.description, new.raw->>'description_raw',
                              new.raw->>'merchant_normalized']);
  if m.mask_code is null then
    return new;
  end if;
  if new.description_raw is distinct from m.replacement_merchant_name then
    perform private.keep_original('statement_lines', new.line_code, 'description_raw', new.profile_code,
                                  m.mask_code, new.description_raw);
  end if;
  if new.description is distinct from private.normalize_text(m.replacement_merchant_name) then
    perform private.keep_original('statement_lines', new.line_code, 'description', new.profile_code,
                                  m.mask_code, new.description);
  end if;
  if exists (select 1 from unnest(private.jsonb_strings(new.raw)) s where s ~* m.pattern) then
    perform private.keep_original('statement_lines', new.line_code, 'raw', new.profile_code, m.mask_code, new.raw::text);
  end if;
  new.description_raw := m.replacement_merchant_name;
  new.description := private.normalize_text(m.replacement_merchant_name);
  new.raw := private.mask_jsonb(new.raw, m.pattern, m.replacement_merchant_name);
  perform private.ensure_mask_category(new.profile_code, m);
  return new;
end;
$$;
create trigger statement_lines_mask before insert or update of description_raw, description, raw
  on public.statement_lines for each row execute function private.trg_mask_statement_line();

create or replace function private.trg_mask_sms()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m private.merchant_masks;
  v_norm text;
  v_body text;
begin
  m := private.mask_for(array[new.body, new.merchant_raw, new.description, new.parsed_fields->>'merchant']);
  if m.mask_code is null then
    return new;
  end if;
  v_norm := private.normalize_text(m.replacement_merchant_name);
  if new.body ~* m.pattern then
    v_body := private.mask_sms_body(new.body, new.sender, new.profile_code, m);
    if v_body is distinct from new.body then
      perform private.keep_original('sms_messages', new.sms_code, 'body', new.profile_code, m.mask_code, new.body);
      new.body := v_body;
    end if;
  end if;
  if new.merchant_raw ~* m.pattern or new.description ~* m.pattern or (new.parsed_fields->>'merchant') ~* m.pattern then
    perform private.keep_original('sms_messages', new.sms_code, 'merchant_raw', new.profile_code, m.mask_code, new.merchant_raw);
    perform private.keep_original('sms_messages', new.sms_code, 'description', new.profile_code, m.mask_code, new.description);
    perform private.keep_original('sms_messages', new.sms_code, 'parsed_fields', new.profile_code, m.mask_code,
                                  new.parsed_fields::text);
    new.merchant_raw := v_norm;
    new.description := v_norm;
    if new.parsed_fields ? 'merchant' then
      new.parsed_fields := jsonb_set(new.parsed_fields, '{merchant}', to_jsonb(v_norm));
    end if;
  end if;
  perform private.ensure_mask_category(new.profile_code, m);
  return new;
end;
$$;
create trigger sms_messages_mask before insert or update of body, merchant_raw, description, parsed_fields
  on public.sms_messages for each row execute function private.trg_mask_sms();

-- Safety net: a transaction description that still matches (a path that bypassed evidence).
create or replace function private.trg_mask_transaction()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m private.merchant_masks;
begin
  m := private.mask_for(array[new.description]);
  if m.mask_code is null then
    return new;
  end if;
  perform private.keep_original('transactions', new.txn_code, 'description', new.profile_code, m.mask_code, new.description);
  new.description := private.normalize_text(m.replacement_merchant_name);
  new.merchant_code := private.mask_merchant_code(m);
  perform private.ensure_mask_category(new.profile_code, m);
  return new;
end;
$$;
create trigger transactions_mask before insert or update of description, merchant_code
  on public.transactions for each row execute function private.trg_mask_transaction();

-- A new merchant whose key or name matches becomes the mask's generic merchant: the upsert
-- in resolve_merchant then conflicts on that key and returns the generic row.
create or replace function private.trg_mask_merchant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m private.merchant_masks;
begin
  m := private.mask_for(array[new.merchant_key, new.display_name]);
  if m.mask_code is null then
    return new;
  end if;
  new.merchant_key := public.merchant_key(m.replacement_merchant_name);
  new.display_name := m.replacement_merchant_name;
  return new;
end;
$$;
create trigger merchants_mask before insert on public.merchants
  for each row execute function private.trg_mask_merchant();

-- ── re-mask existing data ───────────────────────────────────────────────────
-- private.apply_merchant_masks(p_profile_code default null): service role or the database
-- owner only. Masks evidence and transactions of one profile (or all), and always the global
-- rows (merchants, aliases). Idempotent.
create or replace function private.apply_merchant_masks(p_profile_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  m private.merchant_masks;
  v_generic text;
  v_txns text[] := '{}';
  v_t text;
  v_profile text;
  v_lines int := 0;
  v_sms int := 0;
  v_merchants int := 0;
  v_insights int := 0;
  v_n int;
begin
  perform private.assert_service_role();

  for m in select * from private.merchant_masks where active order by created_at, mask_code loop
    v_generic := private.mask_merchant_code(m);

    -- Statement lines: the BEFORE UPDATE trigger does the masking and keeps the originals.
    with u as (
      update public.statement_lines l set description_raw = l.description_raw
      where (p_profile_code is null or l.profile_code = p_profile_code)
        and (l.description_raw ~* m.pattern or l.description ~* m.pattern
             or (l.raw->>'description_raw') ~* m.pattern or (l.raw->>'merchant_normalized') ~* m.pattern)
      returning l.line_code
    )
    select count(*), coalesce(array_agg(distinct e.txn_code) filter (where e.txn_code is not null), '{}')
    into v_n, v_txns
    from u left join public.transaction_evidence e on e.line_code = u.line_code;
    v_lines := v_lines + v_n;

    -- SMS: same, through the sms_messages trigger.
    with u as (
      update public.sms_messages s set body = s.body
      where (p_profile_code is null or s.profile_code = p_profile_code)
        and (s.body ~* m.pattern or s.merchant_raw ~* m.pattern or s.description ~* m.pattern
             or (s.parsed_fields->>'merchant') ~* m.pattern)
      returning s.sms_code
    )
    select count(*), v_txns || coalesce(array_agg(distinct e.txn_code) filter (where e.txn_code is not null), '{}')
    into v_n, v_txns
    from u left join public.transaction_evidence e on e.sms_code = u.sms_code;
    v_sms := v_sms + v_n;

    -- Transactions: re-derived from their (now masked) evidence; the rest directly.
    v_txns := v_txns || array(
      select t.txn_code from public.transactions t
      where (p_profile_code is null or t.profile_code = p_profile_code) and t.description ~* m.pattern);
    for v_t in select distinct x from unnest(v_txns) x loop
      perform private.refresh_transaction(v_t);
    end loop;
    update public.transactions t set description = t.description
    where (p_profile_code is null or t.profile_code = p_profile_code) and t.description ~* m.pattern;

    -- Global merchant rows and aliases that still name the original: renamed to their own
    -- code (natural keys never contain '_', so this cannot collide), never shared.
    with u as (
      update public.merchants mm
      set merchant_key = upper(mm.merchant_code), display_name = m.replacement_merchant_name
      where mm.merchant_code <> v_generic and (mm.merchant_key ~* m.pattern or mm.display_name ~* m.pattern)
      returning mm.merchant_code
    )
    select count(*) into v_n from u;
    v_merchants := v_merchants + v_n;
    update public.merchant_aliases a set alias_key = upper(public.gen_code('als'))
    where a.alias_key ~* m.pattern;

    -- Insight cards already written (titles and bodies name merchants).
    with u as (
      update public.insights i
      set title = private.mask_words(i.title, m.pattern, m.replacement_merchant_name),
          body = private.mask_words(i.body, m.pattern, m.replacement_merchant_name)
      where (p_profile_code is null or i.profile_code = p_profile_code)
        and (i.title ~* m.pattern or i.body ~* m.pattern)
      returning i.insight_code
    )
    select count(*) into v_n from u;
    v_insights := v_insights + v_n;

    -- The mask's category, as a merchant-level manual choice in every affected profile.
    if m.replacement_category_name is not null then
      for v_profile in
        select distinct t.profile_code from public.transactions t
        where t.merchant_code = v_generic and (p_profile_code is null or t.profile_code = p_profile_code)
      loop
        perform private.ensure_mask_category(v_profile, m);
      end loop;
    end if;
  end loop;

  return jsonb_build_object('statement_lines', v_lines, 'sms', v_sms, 'merchants', v_merchants,
                            'insights', v_insights);
end;
$$;

-- Inserting or changing a mask applies it immediately.
create or replace function private.trg_merchant_masks_apply()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.apply_merchant_masks(null);
  return null;
end;
$$;
create trigger merchant_masks_apply after insert or update on private.merchant_masks
  for each statement execute function private.trg_merchant_masks_apply();

-- The mask's text rows are also masked before any rule or LLM sees them: insights are
-- generated from transactions and merchants, which are masked at the source above.

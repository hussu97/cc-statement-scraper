-- Bank SMS alerts captured by the iPhone app (Shortcuts automation → App Intent).
-- Parsing is data-driven: each bank's formats are rows in sms_templates, so a
-- new format needs an INSERT, not a deploy. Unparsed messages are kept and
-- re-run automatically when a template is added or changed.

create table public.sms_templates (
  template_code text primary key default public.gen_code('tpl')
    check (template_code ~ '^tpl_[0-9a-z]{26}$'),
  bank_code text not null references public.banks(bank_code),
  name text not null,
  sender_pattern text not null default '.*',     -- case-insensitive regex on sender
  body_pattern text not null,                     -- case-insensitive regex on body
  -- Postgres regex has no named groups, so map each field to its capture group:
  -- {"amount":2,"currency":1,"merchant":4,"last4":3,"date":5,"time":6,"available":7}
  field_groups jsonb not null,
  date_format text,                                -- to_date() format for the date group
  msg_kind text not null check (msg_kind in
    ('purchase', 'preauth', 'refund', 'reversal', 'payment', 'declined', 'debit_card', 'other')),
  priority integer not null default 100,
  active boolean not null default true,
  version integer not null default 1,
  -- [{ "sender": "ADCBAlert", "body": "...", "expect": {"amount":"52.25","currency":"AED","last4":"9208","merchant":"CARREFOUR"} }]
  examples jsonb not null default '[]'::jsonb check (jsonb_typeof(examples) = 'array'),
  source text not null default 'manual' check (source in ('seed', 'manual', 'llm')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (field_groups ? 'amount')
);
create trigger sms_templates_touch before update on public.sms_templates
  for each row execute function private.touch_updated_at();

create table public.sms_messages (
  sms_code text primary key default public.gen_code('sms')
    check (sms_code ~ '^sms_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  client_msg_id uuid not null,               -- device-generated idempotency key
  received_at timestamptz not null,
  sender text not null,
  body text not null,
  body_hash text not null,
  parse_status text not null default 'pending'
    check (parse_status in ('pending', 'parsed', 'ignored', 'unparsed', 'failed')),
  ignore_reason text,
  template_code text references public.sms_templates(template_code) on delete set null,
  template_version integer,
  bank_code text references public.banks(bank_code),
  msg_kind text check (msg_kind in
    ('purchase', 'preauth', 'refund', 'reversal', 'payment', 'declined', 'debit_card', 'other')),
  card_last4 text check (card_last4 ~ '^[0-9]{4}$'),
  card_code text references public.cards(card_code),
  account_code text references public.accounts(account_code),
  amount numeric(14,2) check (amount is null or amount >= 0),
  currency text check (currency ~ '^[A-Z]{3}$'),
  merchant_raw text,
  description text,                          -- uppercase, collapsed merchant text
  available_limit numeric(14,2),
  event_at timestamptz,                      -- date/time printed in the SMS, else received_at
  parsed_fields jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_code, client_msg_id)
);
create index sms_messages_profile_status_idx on public.sms_messages(profile_code, parse_status);
create index sms_messages_account_event_idx on public.sms_messages(account_code, event_at);
create index sms_messages_dup_idx on public.sms_messages(profile_code, body_hash);
create trigger sms_messages_touch before update on public.sms_messages
  for each row execute function private.touch_updated_at();

alter table public.sms_templates enable row level security;
alter table public.sms_messages enable row level security;
-- Templates are global bank formats: readable by any signed-in user, writable
-- only through service_role (seed migrations, admin tooling, LLM fallback review).
create policy sms_templates_read on public.sms_templates for select to authenticated using (true);
create policy sms_messages_member_read on public.sms_messages for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.sms_templates, public.sms_messages to authenticated;
grant all on public.sms_templates, public.sms_messages to service_role;

-- ── parsing ─────────────────────────────────────────────────────────────────
create or replace function private.normalize_text(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$ select nullif(btrim(regexp_replace(upper(coalesce(p, '')), '\s+', ' ', 'g'), ' .,-'), '') $$;

-- Parse an amount like "1,234.50" → 1234.50. Returns null when not numeric.
create or replace function private.parse_amount(p text)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := replace(btrim(coalesce(p, '')), ',', '');
begin
  if v !~ '^[0-9]+(\.[0-9]+)?$' then
    return null;
  end if;
  return round(v::numeric, 2);
end;
$$;

-- Apply one template to a message. Returns null when the template doesn't match.
-- The returned jsonb holds normalized fields: amount, currency, merchant, last4,
-- date (ISO), time, available.
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
        f := f || jsonb_build_object(k, to_char(to_date(v, coalesce(t.date_format, 'DD/MM/YYYY')), 'YYYY-MM-DD'));
      else
        f := f || jsonb_build_object(k, v);
    end case;
  end loop;
  if f->>'amount' is null then
    return null;
  end if;
  return f;
end;
$$;

-- Pick the first matching active template (by priority) for a sender/body.
create or replace function private.match_sms_template(p_sender text, p_body text, p_only_template text default null)
returns table (template_code text, template_version int, bank_code text, msg_kind text, fields jsonb)
language plpgsql
stable
set search_path = ''
set statement_timeout = '2s'                    -- guard against pathological regex
as $$
declare
  t public.sms_templates;
  f jsonb;
begin
  for t in
    select * from public.sms_templates s
    where s.active and (p_only_template is null or s.template_code = p_only_template)
    order by s.priority, s.template_code
  loop
    f := private.apply_sms_template(t, p_sender, p_body);
    if f is not null then
      template_code := t.template_code;
      template_version := t.version;
      bank_code := t.bank_code;
      msg_kind := t.msg_kind;
      fields := f;
      return next;
      return;
    end if;
  end loop;
end;
$$;

-- A template is only accepted when every example parses to its expected fields.
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
create trigger sms_templates_validate before insert or update on public.sms_templates
  for each row execute function private.validate_sms_template();

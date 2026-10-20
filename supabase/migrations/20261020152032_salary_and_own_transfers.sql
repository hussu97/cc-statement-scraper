-- Phase 2 follow-up (2026-10-20): FAB salary and moves between your own accounts, from Alice's
-- real FAB alerts (salary into …9221, then a transfer out to …9204).
--
-- 1. "Salary Credit / Account XXXX9221 / AED … / date / Balance AED …" is an account_credit whose
--    description is SALARY CREDIT, and a seed rule files SALARY CREDIT money-in under Salary.
-- 2. FAB's funds-transfer notice ("… to IBAN/Account/Card XXXX9204 … from your account/ card
--    XXXX9221 …") becomes msg_kind transfer_notice: parsed against the sending account, never a
--    transaction, with the destination digits in parsed_fields.counterparty_ref.
-- 3. Own transfers (in v_cash_flow, inline: clients can't use the private schema): an unfiled bank transfer is a move between the ledger's own accounts
--    when (a) another of its bank accounts has the opposite transfer of the same AED amount within
--    3 days, or (b) a transfer notice for it names one of its bank accounts. v_cash_flow then shows
--    it as internal_in/out, which never changes net. A category the user chose always wins.
-- 4. A bank alert waiting for its account returns 'no_bank_account' (the phone said "not a card
--    purchase").

alter table public.sms_templates drop constraint sms_templates_msg_kind_check;
alter table public.sms_templates add constraint sms_templates_msg_kind_check check (msg_kind in
  ('purchase', 'preauth', 'refund', 'reversal', 'payment', 'declined', 'debit_card', 'other', 'statement_summary',
   'debit_purchase', 'account_credit', 'account_debit', 'transfer_notice'));
alter table public.sms_messages drop constraint sms_messages_msg_kind_check;
alter table public.sms_messages add constraint sms_messages_msg_kind_check check (msg_kind in
  ('purchase', 'preauth', 'refund', 'reversal', 'payment', 'declined', 'debit_card', 'other', 'statement_summary',
   'debit_purchase', 'account_credit', 'account_debit', 'transfer_notice'));

-- counterparty_ref: the digits of the account a transfer went to.
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
    where e.key not in ('amount', 'currency', 'merchant', 'last4', 'date', 'time', 'available',
                        'due_date', 'min_due', 'account_ref', 'counterparty_ref')
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
      when 'amount', 'available', 'min_due' then
        f := f || jsonb_build_object(k, private.parse_amount(v)::text);
      when 'currency' then
        f := f || jsonb_build_object(k, upper(v));
      when 'merchant' then
        f := f || jsonb_build_object(k, private.normalize_text(v));
      when 'last4' then
        f := f || jsonb_build_object(k, right(regexp_replace(v, '[^0-9]', '', 'g'), 4));
      when 'date', 'due_date' then
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
  if t.msg_kind in ('purchase', 'preauth', 'refund', 'reversal', 'payment',
                   'debit_purchase', 'account_credit', 'account_debit', 'transfer_notice')
     and f->>'amount' is null then
    return null;
  end if;
  if t.msg_kind = 'statement_summary' and (f->>'amount' is null or f->>'due_date' is null) then
    return null;
  end if;
  return f;
end;
$$;

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
  v_bank_kind boolean;
  v_ref text;
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

  v_bank_kind := m.msg_kind in ('debit_purchase', 'account_credit', 'account_debit', 'transfer_notice');
  if not v_bank_kind then
    if m.fields ? 'last4' then
      select * into v_card from public.cards
      where profile_code = s.profile_code and bank_code = m.bank_code and last4 = m.fields->>'last4';
      v_account := v_card.account_code;
    end if;
    if v_account is null and not (m.fields ? 'last4') then
      select count(*), min(account_code) into v_n, v_account
      from public.accounts where profile_code = s.profile_code and bank_code = m.bank_code and status = 'active'
        and kind = 'credit_card';
      if v_n <> 1 then v_account := null; end if;
    end if;
  else
    -- A debit-card or account alert goes to a bank account (Phase 2b), never to a card account:
    -- 1. the debit card it names, already on a bank account;
    -- 2. the account it names (the digits after the mask match account_ref from the right);
    -- 3. when it names no account, the bank's one active bank account.
    v_ref := nullif(regexp_replace(coalesce(m.fields->>'account_ref', ''), '[^0-9]', '', 'g'), '');
    if m.fields ? 'last4' then
      select c.* into v_card from public.cards c join public.accounts a on a.account_code = c.account_code
      where c.profile_code = s.profile_code and c.bank_code = m.bank_code and c.last4 = m.fields->>'last4'
        and a.kind in ('current', 'savings');
      v_account := v_card.account_code;
    end if;
    if v_account is null and v_ref is not null then
      select count(*), min(a.account_code) into v_n, v_account
      from public.accounts a
      where a.profile_code = s.profile_code and a.bank_code = m.bank_code and a.status = 'active'
        and a.kind in ('current', 'savings') and a.account_ref is not null
        and (right(v_ref, length(a.account_ref)) = a.account_ref or right(a.account_ref, length(v_ref)) = v_ref);
      if v_n <> 1 then v_account := null; end if;
    end if;
    if v_account is null and v_ref is null then
      select count(*), min(account_code) into v_n, v_account
      from public.accounts where profile_code = s.profile_code and bank_code = m.bank_code and status = 'active'
        and kind in ('current', 'savings');
      if v_n <> 1 then v_account := null; end if;
    end if;
    -- A debit card seen for the first time joins its account. If a card of this bank already has
    -- those digits (a credit card), the alert stays on the account without a card.
    if v_account is not null and v_card.card_code is null and m.fields ? 'last4' then
      insert into public.cards (profile_code, account_code, bank_code, last4)
      values (s.profile_code, v_account, m.bank_code, m.fields->>'last4')
      on conflict (profile_code, bank_code, last4) do nothing;
      select * into v_card from public.cards
      where profile_code = s.profile_code and account_code = v_account and last4 = m.fields->>'last4';
    end if;
  end if;

  -- Declined alerts are not transactions: stored 'ignored' like debit-card and other alerts (DB-34).
  v_ignored := m.msg_kind in ('debit_card', 'other', 'declined');
  -- A bank-account alert for an account the ledger doesn't have yet waits, ignored, until
  -- create_bank_account adds it (private.reprocess_bank_sms).
  if v_bank_kind and v_account is null then
    v_ignored := true;
  end if;
  update public.sms_messages set
    parse_status = case when v_ignored then 'ignored' else 'parsed' end,
    ignore_reason = case when v_bank_kind and v_ignored then 'no_bank_account' when v_ignored then m.msg_kind end,
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
    -- A bank alert waiting for its account says so (the phone shows any other status as logged).
    return case when v_bank_kind and v_account is null then 'no_bank_account' else 'ignored' end;
  end if;
  -- A transfer notice names where money went; it is read by v_cash_flow, never a transaction.
  if m.msg_kind = 'transfer_notice' then
    return 'noted';
  end if;
  if v_account is null then
    insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
    values (s.profile_code, 'sms', p_sms_code, 'unknown_card',
            jsonb_build_array(jsonb_build_object('bank_code', m.bank_code, 'last4', m.fields->>'last4')))
    on conflict do nothing;
    return 'unknown_card';
  end if;

  -- A statement summary is a statement header, not a transaction.
  if m.msg_kind = 'statement_summary' then
    return private.apply_sms_statement(p_sms_code);
  end if;

  -- The same purchase may already be in the ledger from a Wallet event.
  v_result := private.link_wallet_twin(p_sms_code);
  if v_result is null then
    v_result := private.match_sms(p_sms_code);
  end if;
  -- The balance an account alert prints is a checkpoint as of the alert (not for a repeat).
  if v_bank_kind and v_result = 'created' and m.fields ? 'available' then
    insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source, sms_code)
    values (s.profile_code, v_account, v_event, (m.fields->>'available')::numeric, 'sms', p_sms_code);
  end if;
  return v_result;
end;
$$;

-- ── own transfers ───────────────────────────────────────────────────────────

create or replace view public.v_cash_flow with (security_invoker = true) as
select s.profile_code, s.txn_code, s.account_code, s.txn_date, 'spend'::text as flow, s.instrument,
       s.spend_aed::numeric(14,2) as amount_aed
from public.v_spend s
union all
select t.profile_code, t.txn_code, t.account_code, t.txn_date,
       case
         when t.direction = 'credit' then
           case c.kind when 'income' then 'income' when 'transfer' then 'internal_in'
                       else case when c.kind is null and own.yes then 'internal_in'
                                 else 'money_in' end end
         when exists (select 1 from public.card_transfers x where x.from_txn_code = t.txn_code) then 'card_repayment'
         else case c.kind when 'support' then 'support' when 'saving' then 'saving'
                          when 'transfer' then 'internal_out'
                          when 'spend' then 'spend_transfer' when 'fee' then 'spend_transfer'
                          else case when c.kind is null and own.yes then 'internal_out'
                                    else 'money_out' end end
       end,
       null::text,
       t.amount_aed::numeric(14,2)
from public.transactions t
join public.accounts a on a.account_code = t.account_code and a.kind in ('current', 'savings')
left join public.categories c on c.category_code = t.effective_category_code
cross join lateral (
  select exists (
    -- (a) the other leg, on another of the ledger's bank accounts
    select 1 from public.transactions o
    join public.accounts oa on oa.account_code = o.account_code and oa.kind in ('current', 'savings')
    where o.profile_code = t.profile_code and o.account_code <> t.account_code
      and o.kind = case t.kind when 'transfer_out' then 'transfer_in' else 'transfer_out' end
      and o.amount_aed = t.amount_aed and abs(o.txn_date - t.txn_date) <= 3
      and o.status in ('pending', 'posted')
  ) or (t.kind = 'transfer_out' and exists (
    -- (b) a transfer notice from this account, same amount, naming another of its bank accounts
    select 1 from public.sms_messages n
    join public.accounts d
      on d.profile_code = n.profile_code and d.account_code <> n.account_code
     and d.kind in ('current', 'savings') and d.account_ref is not null
     and right(regexp_replace(coalesce(n.parsed_fields->>'counterparty_ref', ''), '[^0-9]', '', 'g'),
               length(d.account_ref)) = d.account_ref
    where n.profile_code = t.profile_code and n.account_code = t.account_code
      and n.msg_kind = 'transfer_notice' and n.parse_status = 'parsed'
      and n.amount = t.amount_original and abs(public.dubai_date(n.event_at) - t.txn_date) <= 1
  )) as yes
) own
where t.kind in ('transfer_in', 'transfer_out') and t.status in ('pending', 'posted')
  and t.amount_aed is not null and coalesce(c.kind, '') <> 'ignore';

-- ── templates ───────────────────────────────────────────────────────────────
insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 ('FAB', 'FAB salary credit', '^FAB',
  '(Salary Credit)\s*\n\s*Account X*([0-9]+)\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*([0-9]{2}/[0-9]{2}/[0-9]{4})(?:\s*\n\s*Balance ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?',
  '{"merchant":1,"account_ref":2,"currency":3,"amount":4,"date":5,"available":7}', 'DD/MM/YYYY', 'account_credit', 55,
  '[{"sender":"FAB","body":"Salary Credit\nAccount XXXX9221\nAED 41250.00\n28/09/2026\nBalance AED 44481.07",
     "expect":{"merchant":"SALARY CREDIT","account_ref":"9221","currency":"AED","amount":"41250.00","date":"2026-09-28","available":"44481.07"}}]'),
 ('FAB', 'FAB funds transfer', '^FAB',
  'funds transfer request of +([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) to IBAN/Account/Card X*([0-9]+) +has been processed successfully from your account/ ?card X*([0-9]+) on ([0-9]{2}/[0-9]{2}/[0-9]{4}) ([0-9]{2}:[0-9]{2})',
  '{"currency":1,"amount":2,"counterparty_ref":3,"account_ref":4,"date":5,"time":6}', 'DD/MM/YYYY', 'transfer_notice', 55,
  '[{"sender":"FAB","body":"Dear Customer, your funds transfer request of  AED 50,000.00 to IBAN/Account/Card XXXX9204  has been processed successfully from your account/ card XXXX9221 on 28/09/2026 13:58",
     "expect":{"currency":"AED","amount":"50000.00","counterparty_ref":"9204","account_ref":"9221","date":"2026-09-28","time":"13:58"}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);

update public.sms_templates set active = false
where bank_code = 'FAB' and name = 'FAB funds transfer (ignored)' and msg_kind = 'other' and active
  and body_pattern = 'funds transfer request of +([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) to .+ has been processed successfully.* on ([0-9]{2}/[0-9]{2}/[0-9]{4}) ([0-9]{2}:[0-9]{2})';

-- ── Salary rule ─────────────────────────────────────────────────────────────
-- Rules may test the transfer kinds (Phase 2b added them to transactions).
create or replace function private.rule_problem(
  p_profile_code text, p_match_type text, p_pattern text, p_conditions jsonb
)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  e record;
begin
  if p_pattern is null or length(p_pattern) > 200 then
    return 'pattern must be at most 200 characters';
  end if;
  if p_match_type = 'regex' then
    if p_pattern ~ '\\[1-9]' then
      return 'regex back-references are not allowed';
    end if;
    begin
      perform regexp_match('', p_pattern);
    exception when others then
      return 'invalid regex: ' || sqlerrm;
    end;
  end if;
  if p_conditions is null or jsonb_typeof(p_conditions) <> 'object' then
    return 'conditions must be an object';
  end if;
  for e in select key, value from jsonb_each(p_conditions) loop
    case e.key
      when 'amount_min', 'amount_max' then
        if jsonb_typeof(e.value) not in ('number', 'string')
           or private.safe_numeric(e.value #>> '{}') is null or private.safe_numeric(e.value #>> '{}') < 0 then
          return format('%s must be a non-negative number', e.key);
        end if;
      when 'bank_code' then
        if jsonb_typeof(e.value) <> 'string'
           or not exists (select 1 from public.banks b where b.bank_code = e.value #>> '{}') then
          return 'bank_code must be a known bank';
        end if;
      when 'card_code' then
        if jsonb_typeof(e.value) <> 'string'
           or not exists (select 1 from public.cards c
                          where c.card_code = e.value #>> '{}' and c.profile_code = p_profile_code) then
          return 'card_code must be a card of this profile';
        end if;
      when 'currency' then
        if jsonb_typeof(e.value) <> 'string' or (e.value #>> '{}') !~ '^[A-Z]{3}$' then
          return 'currency must be a 3-letter ISO code';
        end if;
      when 'kind' then
        if jsonb_typeof(e.value) <> 'string' or (e.value #>> '{}') not in
           ('purchase', 'refund', 'payment', 'fee', 'interest', 'cash_advance', 'adjustment',
            'transfer_in', 'transfer_out') then
          return 'kind must be a transaction kind';
        end if;
      when 'direction' then
        if jsonb_typeof(e.value) <> 'string' or (e.value #>> '{}') not in ('debit', 'credit') then
          return 'direction must be debit or credit';
        end if;
      else
        return format('unknown condition %s', e.key);
    end case;
  end loop;
  if private.safe_numeric(p_conditions->>'amount_min') > private.safe_numeric(p_conditions->>'amount_max') then
    return 'amount_min must not exceed amount_max';
  end if;
  return null;
end;
$$;

insert into private.seed_rules (category_name, pattern, match_type, conditions)
select 'Salary', 'SALARY CREDIT', 'exact', '{"kind":"transfer_in"}'::jsonb
where not exists (select 1 from private.seed_rules where category_name = 'Salary' and pattern = 'SALARY CREDIT');

insert into public.category_rules (profile_code, category_code, name, match_type, pattern, conditions, source)
select c.profile_code, c.category_code, 'seed: SALARY CREDIT', 'exact', 'SALARY CREDIT', '{"kind":"transfer_in"}'::jsonb, 'seed'
from public.categories c
where c.name = 'Salary' and c.kind = 'income'
  and not exists (select 1 from public.category_rules r
                  where r.profile_code = c.profile_code and upper(r.pattern) = 'SALARY CREDIT');

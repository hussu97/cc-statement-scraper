-- SMS template safety and re-processing from the audit backlog (docs/audit/BACKLOG.md):
--   DB-22   a template change re-processes only the messages it can affect: its senders
--           (and scope), newest first, and only when it is live and its pattern changed
--   DB-26r  every template has at least one example; LLM proposals take their sender
--           pattern from the bank's known senders and stay scoped to the proposing
--           profile until promoted (public.promote_sms_template)

-- ── DB-26r: examples are required ───────────────────────────────────────────
-- NOT VALID keeps the migration safe on any database; it is validated right
-- away when no existing row lacks an example (true for every seeded template).
alter table public.sms_templates add constraint sms_templates_examples_required
  check (jsonb_typeof(examples) = 'array' and jsonb_array_length(examples) >= 1) not valid;
do $$
begin
  if not exists (select 1 from public.sms_templates
                 where jsonb_typeof(examples) <> 'array' or jsonb_array_length(examples) < 1) then
    alter table public.sms_templates validate constraint sms_templates_examples_required;
  else
    raise notice 'sms_templates_examples_required left NOT VALID: some templates have no example';
  end if;
end;
$$;

-- ── DB-26r: per-profile LLM templates ───────────────────────────────────────
-- null = global (seeded or promoted); otherwise only this profile's messages use it.
alter table public.sms_templates
  add column scope_profile_code text references public.profiles(profile_code) on delete cascade;
create index sms_templates_scope_idx on public.sms_templates (scope_profile_code) where scope_profile_code is not null;

drop function if exists private.match_sms_template(text, text, text);
create or replace function private.match_sms_template(p_sender text, p_body text, p_only_template text default null,
                                                      p_profile_code text default null)
returns table(template_code text, template_version integer, bank_code text, msg_kind text, fields jsonb)
language plpgsql
stable
set search_path = ''
as $$
declare
  t public.sms_templates;
  f jsonb;
begin
  for t in
    select * from public.sms_templates s
    where s.active and (p_only_template is null or s.template_code = p_only_template)
      and (s.scope_profile_code is null or s.scope_profile_code = p_profile_code)
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


-- process_sms: unchanged from 20261009000100 except that it passes the message's profile to the template match.
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
begin
  select * into s from public.sms_messages where sms_code = p_sms_code for update;
  if exists (select 1 from public.transaction_evidence e where e.sms_code = p_sms_code and e.is_active) then
    return 'already_linked';
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

  if m.fields ? 'last4' then
    select * into v_card from public.cards
    where profile_code = s.profile_code and bank_code = m.bank_code and last4 = m.fields->>'last4';
    v_account := v_card.account_code;
  end if;
  if v_account is null and not (m.fields ? 'last4') then
    select count(*), min(account_code) into v_n, v_account
    from public.accounts where profile_code = s.profile_code and bank_code = m.bank_code and status = 'active';
    if v_n <> 1 then v_account := null; end if;
  end if;

  -- Declined alerts are not transactions: stored 'ignored' like debit-card and other alerts (DB-34).
  v_ignored := m.msg_kind in ('debit_card', 'other', 'declined');
  update public.sms_messages set
    parse_status = case when v_ignored then 'ignored' else 'parsed' end,
    ignore_reason = case when v_ignored then m.msg_kind end,
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
    return 'ignored';
  end if;
  if v_account is null then
    insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
    values (s.profile_code, 'sms', p_sms_code, 'unknown_card',
            jsonb_build_array(jsonb_build_object('bank_code', m.bank_code, 'last4', m.fields->>'last4')))
    on conflict do nothing;
    return 'unknown_card';
  end if;

  v_result := private.match_sms(p_sms_code);
  return v_result;
end;
$$;

-- LLM proposals: the sender pattern is built from the bank's known senders (the
-- model's own pattern, often '.*', is ignored), the message must come from one
-- of them, and the template is scoped to the message's profile.
create or replace function public.propose_sms_template(p_sms_code text, p_template jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_bank text := p_template->>'bank_code';
  v_sender_pattern text;
  v_code text;
begin
  perform private.assert_service_role();
  select * into s from public.sms_messages where sms_code = p_sms_code;
  if not found then
    raise exception 'unknown sms %', p_sms_code using errcode = 'P0002';
  end if;
  select '^(' || string_agg(regexp_replace(x.sender, '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g'), '|' order by x.sender) || ')'
  into v_sender_pattern
  from public.banks b, unnest(b.sms_senders) x(sender)
  where b.bank_code = v_bank and btrim(x.sender) <> '';
  if v_sender_pattern is null then
    raise exception 'bank % has no known SMS senders', coalesce(v_bank, '(none)') using errcode = '22023';
  end if;
  if s.sender !~* v_sender_pattern then
    raise exception 'the message sender is not one of bank %''s SMS senders', v_bank using errcode = '22023';
  end if;
  insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
    msg_kind, priority, active, examples, source, scope_profile_code)
  values (v_bank, coalesce(p_template->>'name', 'LLM proposal'),
          v_sender_pattern, p_template->>'body_pattern', p_template->'field_groups',
          p_template->>'date_format', p_template->>'msg_kind', 200, false,
          jsonb_build_array(jsonb_build_object('sender', s.sender, 'body', s.body,
                                               'expect', coalesce(p_template->'expect', '{}'::jsonb))),
          'llm', s.profile_code)
  returning template_code into v_code;
  insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
  values (s.profile_code, 'sms', s.sms_code, 'unparsed_sms', jsonb_build_array(jsonb_build_object('template_code', v_code)))
  on conflict do nothing;
  return v_code;
end;
$$;

-- An operator makes an approved LLM template global (every profile's messages).
create or replace function public.promote_sms_template(p_template_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  update public.sms_templates set scope_profile_code = null
  where template_code = p_template_code and active;
  if not found then
    raise exception 'template % is not an active template', p_template_code using errcode = 'P0002';
  end if;
end;
$$;

-- ── DB-22: targeted re-processing ───────────────────────────────────────────
-- Fires per statement with transition tables. Re-processes only when a template
-- is live and something that decides matching changed (a new active template,
-- an activation, or a pattern/priority/scope edit of an active one); only the
-- messages its sender pattern (and scope) can reach; newest first, 500 at most.
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
  create temp table if not exists _tpl_changed (sender_pattern text, scope_profile_code text) on commit drop;
  truncate _tpl_changed;
  if tg_op = 'INSERT' then
    insert into _tpl_changed select n.sender_pattern, n.scope_profile_code from new_rows n where n.active;
  else
    insert into _tpl_changed
    select n.sender_pattern, n.scope_profile_code
    from new_rows n join old_rows o on o.template_code = n.template_code
    where n.active
      and (not o.active
           or (n.body_pattern, n.sender_pattern, n.field_groups, n.date_format, n.msg_kind, n.priority,
               n.scope_profile_code)
              is distinct from
              (o.body_pattern, o.sender_pattern, o.field_groups, o.date_format, o.msg_kind, o.priority,
               o.scope_profile_code));
  end if;
  if not exists (select 1 from _tpl_changed) then
    return null;
  end if;

  for v_code in
    select s.sms_code from public.sms_messages s
    where s.parse_status in ('unparsed', 'pending', 'failed')
      and exists (select 1 from _tpl_changed c
                  where s.sender ~* c.sender_pattern
                    and (c.scope_profile_code is null or c.scope_profile_code = s.profile_code))
    order by s.received_at desc, s.sms_code
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

drop trigger if exists sms_templates_reprocess on public.sms_templates;
create trigger sms_templates_reprocess_insert
  after insert on public.sms_templates
  referencing new table as new_rows
  for each statement execute function private.trg_sms_templates_reprocess();
create trigger sms_templates_reprocess_update
  after update on public.sms_templates
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.trg_sms_templates_reprocess();

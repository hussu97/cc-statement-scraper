-- Background work: pgmq queues consumed by the `worker` Edge Function, Vault-held
-- secrets (PDF passwords, mailbox OAuth tokens), pg_cron schedules, Realtime.

-- ── queues ──────────────────────────────────────────────────────────────────
select pgmq.create('parse_document');
select pgmq.create('parse_document_dlq');
select pgmq.create('llm_categorize');
select pgmq.create('llm_categorize_dlq');
select pgmq.create('sms_fallback');
select pgmq.create('sms_fallback_dlq');

create or replace function private.enqueue_document()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pgmq.send('parse_document', jsonb_build_object('doc_code', new.doc_code));
  return null;
end;
$$;
create trigger documents_enqueue after insert on public.documents
  for each row execute function private.enqueue_document();

create or replace function private.enqueue_sms_fallback()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.parse_status = 'unparsed' and old.parse_status is distinct from 'unparsed' then
    perform pgmq.send('sms_fallback', jsonb_build_object('sms_code', new.sms_code));
  end if;
  return null;
end;
$$;
create trigger sms_messages_fallback after update of parse_status on public.sms_messages
  for each row execute function private.enqueue_sms_fallback();

-- Thin wrappers so Edge Functions (service_role) can use pgmq over PostgREST.
create or replace function public.queue_read(p_queue text, p_vt integer, p_qty integer)
returns table (msg_id bigint, read_ct integer, message jsonb)
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
  select r.msg_id, r.read_ct, r.message from pgmq.read(p_queue, p_vt, p_qty) r $$;

create or replace function public.queue_delete(p_queue text, p_msg_id bigint)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
  select pgmq.delete(p_queue, p_msg_id) $$;

create or replace function public.queue_to_dlq(p_queue text, p_msg_id bigint, p_message jsonb, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  perform pgmq.send(p_queue || '_dlq', p_message || jsonb_build_object('dlq_reason', left(p_reason, 1000), 'dlq_at', now()));
  perform pgmq.delete(p_queue, p_msg_id);
end;
$$;

create or replace function public.queue_send(p_queue text, p_message jsonb, p_delay integer default 0)
returns bigint
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
  select pgmq.send(p_queue, p_message, p_delay) $$;

grant execute on function public.queue_read(text, integer, integer) to service_role;
grant execute on function public.queue_delete(text, bigint) to service_role;
grant execute on function public.queue_to_dlq(text, bigint, jsonb, text) to service_role;
grant execute on function public.queue_send(text, jsonb, integer) to service_role;

-- Owners can ask for a document to be parsed again (e.g. after a parser fix).
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
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
grant execute on function public.requeue_documents(text, text[]) to authenticated, service_role;

-- ── secrets (Supabase Vault) ────────────────────────────────────────────────
-- Vault names: profile:<profile_code>:<KEY>  and  mailbox:<mailbox_code>:<KEY>.
-- Clients can set and list secrets; they can never read values back.
create or replace function private.vault_upsert(p_name text, p_value text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from vault.secrets where name = p_name;
  if v_id is null then
    perform vault.create_secret(p_value, p_name);
  else
    perform vault.update_secret(v_id, p_value);
  end if;
end;
$$;

create or replace function public.set_profile_secret(p_profile_code text, p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, true);
  if p_key !~ '^(FAB|ADCB|ENBD|EIB|SIB|MASHREQ)_PDF_PASSWORD$' and p_key <> 'ADCB_CID' then
    raise exception 'unsupported secret key %', p_key using errcode = '22023';
  end if;
  if p_value is null or p_value = '' then
    delete from vault.secrets where name = 'profile:' || p_profile_code || ':' || p_key;
  else
    perform private.vault_upsert('profile:' || p_profile_code || ':' || p_key, p_value);
  end if;
end;
$$;

create or replace function public.list_profile_secrets(p_profile_code text)
returns table (key text, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, false);
  return query
  select split_part(s.name, ':', 3), s.updated_at
  from vault.secrets s
  where s.name like 'profile:' || p_profile_code || ':%'
  order by 1;
end;
$$;

create or replace function public.set_mailbox_secret(p_mailbox_code text, p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile text;
begin
  select profile_code into v_profile from public.email_mailboxes where mailbox_code = p_mailbox_code;
  if v_profile is null then
    raise exception 'unknown mailbox %', p_mailbox_code using errcode = 'P0002';
  end if;
  perform private.assert_member(v_profile, true);
  if p_key not in ('refresh_token') then
    raise exception 'unsupported mailbox secret %', p_key using errcode = '22023';
  end if;
  perform private.vault_upsert('mailbox:' || p_mailbox_code || ':' || p_key, p_value);
end;
$$;

-- Worker-only: everything needed to parse one document.
create or replace function public.worker_document_context(p_doc_code text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
 
  select jsonb_build_object(
    'doc', to_jsonb(d),
    'settings', coalesce((
      select jsonb_object_agg(split_part(s.name, ':', 3), s.decrypted_secret)
      from vault.decrypted_secrets s
      where s.name like 'profile:' || d.profile_code || ':%'), '{}'::jsonb)
  )
  from public.documents d where d.doc_code = p_doc_code
$$;

create or replace function public.worker_mailbox_secret(p_mailbox_code text, p_key text)
returns text
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
 
  select decrypted_secret from vault.decrypted_secrets where name = 'mailbox:' || p_mailbox_code || ':' || p_key
$$;

grant execute on function public.set_profile_secret(text, text, text) to authenticated, service_role;
grant execute on function public.list_profile_secrets(text) to authenticated, service_role;
grant execute on function public.set_mailbox_secret(text, text, text) to authenticated, service_role;
grant execute on function public.worker_document_context(text) to service_role;
grant execute on function public.worker_mailbox_secret(text, text) to service_role;

-- ── LLM categorisation queue ────────────────────────────────────────────────
create or replace function private.category_set_hash(p_profile_code text)
returns text
language sql
stable
set search_path = ''
as $$
  select md5(coalesce(string_agg(c.category_code || '=' || c.name || '/' || c.kind, ',' order by c.category_code), ''))
  from public.categories c
  where c.profile_code = p_profile_code and c.archived_at is null and c.kind <> 'ignore'
$$;

-- Merchants that no rule and no manual choice covers (or whose LLM suggestion was
-- made against a different category list) go to the LLM in batches of 25.
create or replace function private.enqueue_llm_categorize()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  p text;
  v_hash text;
  v_batch text[];
  v_count integer := 0;
begin
  for p in select profile_code from public.profiles loop
    v_hash := private.category_set_hash(p);
    for v_batch in
      select array_agg(merchant_code) from (
        select merchant_code, (row_number() over (order by merchant_code) - 1) / 25 as grp
        from (
          select distinct t.merchant_code
          from public.transactions t
          left join public.merchant_profile_category mpc
            on mpc.profile_code = t.profile_code and mpc.merchant_code = t.merchant_code
          where t.profile_code = p and t.merchant_code is not null and t.rule_category_code is null
            and t.manual_category_code is null
            and (mpc.merchant_code is null or (mpc.source = 'llm' and mpc.category_set_hash is distinct from v_hash))
        ) m
      ) g group by grp
    loop
      perform pgmq.send('llm_categorize', jsonb_build_object('profile_code', p, 'merchant_codes', v_batch,
                                                             'category_set_hash', v_hash));
      v_count := v_count + 1;
    end loop;
  end loop;
  return v_count;
end;
$$;

-- Worker-only: everything the LLM prompt needs for one batch.
create or replace function public.worker_llm_context(p_profile_code text, p_merchant_codes text[])
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
 
  select jsonb_build_object(
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('category_code', c.category_code, 'name', c.name,
                     'kind', c.kind) order by c.sort_order), '[]'::jsonb)
                   from public.categories c
                   where c.profile_code = p_profile_code and c.archived_at is null and c.kind <> 'ignore'),
    'merchants', (select coalesce(jsonb_agg(jsonb_build_object('merchant_code', m.merchant_code,
                     'name', m.display_name,
                     'examples', (select jsonb_agg(distinct t.description) from (
                                    select description from public.transactions t
                                    where t.merchant_code = m.merchant_code and t.profile_code = p_profile_code
                                    limit 3) t))), '[]'::jsonb)
                  from public.merchants m where m.merchant_code = any (p_merchant_codes)),
    'category_set_hash', private.category_set_hash(p_profile_code)
  )
$$;

-- Worker-only: store suggestions. Never overrides a manual merchant choice.
-- p_suggestions: [{merchant_code, category_code, confidence}]
create or replace function public.apply_llm_suggestions(
  p_profile_code text, p_suggestions jsonb, p_model text, p_category_set_hash text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  perform private.assert_service_role();
  insert into public.merchant_profile_category (profile_code, merchant_code, category_code, source, confidence, model,
    category_set_hash)
  select p_profile_code, s->>'merchant_code', s->>'category_code', 'llm',
         least(greatest((s->>'confidence')::numeric, 0), 1), p_model, p_category_set_hash
  from jsonb_array_elements(p_suggestions) s
  where exists (select 1 from public.categories c
                where c.profile_code = p_profile_code and c.category_code = s->>'category_code' and c.archived_at is null)
    and exists (select 1 from public.merchants m where m.merchant_code = s->>'merchant_code')
    and coalesce((s->>'confidence')::numeric, 0) >= 0.5
  on conflict (profile_code, merchant_code) do update set
    category_code = excluded.category_code, confidence = excluded.confidence, model = excluded.model,
    category_set_hash = excluded.category_set_hash
  where public.merchant_profile_category.source = 'llm';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Worker-only: a template the LLM proposed for an unparsed SMS. Stored inactive;
-- the owner activates it from the review inbox. Its example is the message itself,
-- so the validation trigger proves it parses before it can be saved.
create or replace function public.propose_sms_template(p_sms_code text, p_template jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  v_code text;
begin
  perform private.assert_service_role();
  select * into s from public.sms_messages where sms_code = p_sms_code;
  insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
    msg_kind, priority, active, examples, source)
  values (p_template->>'bank_code', coalesce(p_template->>'name', 'LLM proposal'),
          coalesce(p_template->>'sender_pattern', '.*'), p_template->>'body_pattern', p_template->'field_groups',
          p_template->>'date_format', p_template->>'msg_kind', 200, false,
          jsonb_build_array(jsonb_build_object('sender', s.sender, 'body', s.body,
                                               'expect', coalesce(p_template->'expect', '{}'::jsonb))),
          'llm')
  returning template_code into v_code;
  insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
  values (s.profile_code, 'sms', s.sms_code, 'unparsed_sms', jsonb_build_array(jsonb_build_object('template_code', v_code)))
  on conflict do nothing;
  return v_code;
end;
$$;

-- Worker-only: SMS context for the fallback prompt.
create or replace function public.worker_sms_context(p_sms_code text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
 
  select jsonb_build_object('sms_code', s.sms_code, 'sender', s.sender, 'body', s.body,
                            'parse_status', s.parse_status,
                            'banks', (select jsonb_agg(jsonb_build_object('bank_code', b.bank_code, 'senders', b.sms_senders))
                                      from public.banks b))
  from public.sms_messages s where s.sms_code = p_sms_code
$$;

-- Owners activate (or reject) an LLM-proposed template.
create or replace function public.set_sms_template_active(p_template_code text, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profiles text[];
begin
  -- Proposals are global, so any owner whose SMS it was proposed for may decide.
  select array_agg(distinct r.profile_code) into v_profiles
  from public.match_reviews r
  where r.reason = 'unparsed_sms' and r.candidates @> jsonb_build_array(jsonb_build_object('template_code', p_template_code));
  if v_profiles is null or not (v_profiles && (select authz.my_owned_profile_codes())) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_active then
    update public.sms_templates set active = true where template_code = p_template_code;
  else
    delete from public.sms_templates where template_code = p_template_code and source = 'llm' and not active;
  end if;
  update public.match_reviews set status = case when p_active then 'resolved' else 'dismissed' end,
    resolution = jsonb_build_object('template_code', p_template_code, 'active', p_active),
    resolved_by = auth.uid(), resolved_at = now()
  where reason = 'unparsed_sms' and status = 'open'
    and candidates @> jsonb_build_array(jsonb_build_object('template_code', p_template_code));
end;
$$;

grant execute on function public.worker_llm_context(text, text[]) to service_role;
grant execute on function public.apply_llm_suggestions(text, jsonb, text, text) to service_role;
grant execute on function public.propose_sms_template(text, jsonb) to service_role;
grant execute on function public.worker_sms_context(text) to service_role;
grant execute on function public.set_sms_template_active(text, boolean) to authenticated, service_role;

-- ── health for ops-monitor (Sentry) ─────────────────────────────────────────
create or replace function public.ops_health()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();
 
  select jsonb_build_object(
    'queues', (select jsonb_object_agg(m.queue_name, jsonb_build_object('depth', m.queue_length,
                 'oldest_age_s', m.oldest_msg_age_sec))
               from pgmq.metrics_all() m),
    'cron_failures_15m', (select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'message', left(d.return_message, 300))), '[]'::jsonb)
               from cron.job_run_details d join cron.job j on j.jobid = d.jobid
               where d.status = 'failed' and d.start_time > now() - interval '15 minutes'),
    'cron_last_success', (select jsonb_object_agg(j.jobname, (select max(d.end_time) from cron.job_run_details d
                                                               where d.jobid = j.jobid and d.status = 'succeeded'))
               from cron.job j),
    'documents_failed_24h', (select count(*) from public.documents
                             where parse_status = 'failed' and updated_at > now() - interval '24 hours'),
    'documents_stuck', (select count(*) from public.documents
                        where parse_status in ('queued', 'parsing') and updated_at < now() - interval '1 hour'),
    'sms_unparsed_24h', (select count(*) from public.sms_messages
                         where parse_status = 'unparsed' and created_at > now() - interval '24 hours'),
    'recon_failed', (select count(*) from public.statement_recon where status = 'fail'),
    'open_reviews', (select count(*) from public.match_reviews where status = 'open')
  )
$$;
grant execute on function public.ops_health() to service_role;

-- ── pg_cron → Edge Functions ────────────────────────────────────────────────
-- Needs two Vault secrets (set once per environment, see PRODUCTION.md):
--   project_url        https://<ref>.supabase.co   (local: http://host.docker.internal:54321)
--   edge_cron_secret   random string, also set as the CRON_SECRET function secret
create or replace function private.invoke_edge(p_function text, p_body jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'edge_cron_secret';
  if v_url is null or v_secret is null then
    raise notice 'invoke_edge(%): project_url / edge_cron_secret not configured', p_function;
    return null;
  end if;
  return net.http_post(
    url := v_url || '/functions/v1/' || p_function,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    body := p_body,
    timeout_milliseconds := 5000
  );
end;
$$;

-- Only wake the worker when there is visible work.
create or replace function private.kick_worker()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from pgmq.q_parse_document where vt <= now())
     or exists (select 1 from pgmq.q_llm_categorize where vt <= now())
     or exists (select 1 from pgmq.q_sms_fallback where vt <= now()) then
    return private.invoke_edge('worker');
  end if;
  return null;
end;
$$;

select cron.schedule('ledger-worker-kick', '* * * * *', $$select private.kick_worker()$$);
select cron.schedule('ledger-recategorize-sweep', '17 */3 * * *', $$select private.recategorize_stale()$$);
-- 22:00 UTC = 02:00 Asia/Dubai
select cron.schedule('ledger-nightly', '0 22 * * *', $$select private.nightly()$$);
select cron.schedule('ledger-llm-enqueue', '30 22 * * *', $$select private.enqueue_llm_categorize()$$);
select cron.schedule('ledger-ops-monitor', '*/15 * * * *', $$select private.invoke_edge('ops-monitor')$$);
select cron.schedule('ledger-gmail-watch-renew', '0 3 * * *', $$select private.invoke_edge('gmail-watch-renew')$$);
select cron.schedule('ledger-outlook-poll', '5 * * * *', $$select private.invoke_edge('outlook-poll')$$);

-- ── Realtime ────────────────────────────────────────────────────────────────
-- Clients subscribe to these (RLS still applies to every change event).
alter publication supabase_realtime add table public.transactions, public.sms_messages, public.documents,
  public.match_reviews, public.insights;

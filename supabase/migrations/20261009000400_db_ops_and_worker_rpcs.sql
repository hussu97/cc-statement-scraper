-- Ops health and worker RPCs from the audit backlog (docs/audit/BACKLOG.md):
--   SRV-10  ops_health reports stale mailboxes, expiring Gmail watches and mailbox errors
--   DB-38   ops_health's recon_failed / open_reviews are 7-day windows; the cron scan is bounded
--   SRV-22  documents_stuck means 'parsing' for over an hour; queue metrics carry the newest
--           message age (alert on a DLQ only when it grew); drain_dlq / requeue_dlq
--   DB-25   ops_health reports private.job_errors of the last 24 h
--   SRV-15  save_mailbox_sync_state merges sync_state in SQL and never moves a Gmail cursor back
--   SRV-20  begin_document_parse skips a duplicate message for a parsed or failed document;
--           resubmit_document re-queues a failed PDF that is uploaded again;
--           fail_document never flips a parsed document back

-- ── ops_health ──────────────────────────────────────────────────────────────
-- Keys kept from before: queues (now with newest_age_s / total), cron_failures_15m,
-- cron_last_success (last 7 days), documents_failed_24h, documents_stuck ('parsing'
-- > 1 h only), sms_unparsed_24h, recon_failed (7 d), open_reviews (opened in 7 d).
-- New: documents_queued_oldest_age_s, open_reviews_total, job_errors_24h,
-- mailboxes_stale, gmail_watch_expiring, mailbox_errors. Mailbox entries carry
-- opaque codes only.
create or replace function public.ops_health()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();

  select jsonb_build_object(
    'queues', (select jsonb_object_agg(m.queue_name, jsonb_build_object('depth', m.queue_length,
                 'oldest_age_s', m.oldest_msg_age_sec, 'newest_age_s', m.newest_msg_age_sec,
                 'total', m.total_messages))
               from pgmq.metrics_all() m),
    'cron_failures_15m', (select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'message', left(d.return_message, 300))), '[]'::jsonb)
               from cron.job_run_details d join cron.job j on j.jobid = d.jobid
               where d.status = 'failed' and d.start_time > now() - interval '15 minutes'),
    'cron_last_success', (select jsonb_object_agg(j.jobname, (select max(d.end_time) from cron.job_run_details d
                                                               where d.jobid = j.jobid and d.status = 'succeeded'
                                                                 and d.start_time > now() - interval '7 days'))
               from cron.job j),
    'documents_failed_24h', (select count(*) from public.documents
                             where parse_status = 'failed' and updated_at > now() - interval '24 hours'),
    'documents_stuck', (select count(*) from public.documents
                        where parse_status = 'parsing' and updated_at < now() - interval '1 hour'),
    'documents_queued_oldest_age_s', (select floor(extract(epoch from now() - min(updated_at)))::bigint
                                      from public.documents where parse_status = 'queued'),
    'sms_unparsed_24h', (select count(*) from public.sms_messages
                         where parse_status = 'unparsed' and created_at > now() - interval '24 hours'),
    'recon_failed', (select count(*) from public.statement_recon
                     where status = 'fail' and computed_at > now() - interval '7 days'),
    'open_reviews', (select count(*) from public.match_reviews
                     where status = 'open' and created_at > now() - interval '7 days'),
    'open_reviews_total', (select count(*) from public.match_reviews where status = 'open'),
    'job_errors_24h', (select count(*) from private.job_errors where created_at > now() - interval '24 hours'),
    'mailboxes_stale', (select coalesce(jsonb_agg(jsonb_build_object('mailbox_code', mb.mailbox_code,
                          'provider', mb.provider, 'last_synced_at', mb.last_synced_at) order by mb.mailbox_code), '[]'::jsonb)
                        from public.email_mailboxes mb
                        where mb.enabled and coalesce(mb.last_synced_at, mb.created_at) < now() - interval '2 days'),
    'gmail_watch_expiring', (select coalesce(jsonb_agg(jsonb_build_object('mailbox_code', mb.mailbox_code,
                               'watch_expires_at', mb.watch_expires_at) order by mb.mailbox_code), '[]'::jsonb)
                             from public.email_mailboxes mb
                             where mb.enabled and mb.provider = 'gmail'
                               and (mb.watch_expires_at is null or mb.watch_expires_at < now() + interval '24 hours')),
    'mailbox_errors', (select coalesce(jsonb_agg(jsonb_build_object('mailbox_code', mb.mailbox_code,
                         'provider', mb.provider, 'code', mb.sync_state->'last_error'->>'code',
                         'at', mb.sync_state->'last_error'->>'at') order by mb.mailbox_code), '[]'::jsonb)
                       from public.email_mailboxes mb
                       where mb.enabled and jsonb_typeof(mb.sync_state->'last_error') = 'object')
  )
$$;

-- ── SRV-22: dead-letter queue tools (service role) ──────────────────────────
-- p_queue is the work queue's name (parse_document, llm_categorize, sms_fallback);
-- the DLQ is <p_queue>_dlq.
create or replace function private.assert_known_queue(p_queue text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_queue is null or p_queue not in ('parse_document', 'llm_categorize', 'sms_fallback') then
    raise exception 'unknown queue %', coalesce(p_queue, '(null)') using errcode = '22023';
  end if;
end;
$$;

-- Deletes every message in <p_queue>_dlq; returns how many.
create or replace function public.drain_dlq(p_queue text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_service_role();
  perform private.assert_known_queue(p_queue);
  return pgmq.purge_queue(p_queue || '_dlq');
end;
$$;

-- Moves up to p_limit messages from <p_queue>_dlq back to <p_queue> with a fresh
-- attempt count. A parse_document message re-opens its failed document.
create or replace function public.requeue_dlq(p_queue text, p_limit integer default 100)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_msg jsonb;
  v_count integer := 0;
begin
  perform private.assert_service_role();
  perform private.assert_known_queue(p_queue);
  for r in select * from pgmq.read(p_queue || '_dlq', 60, least(greatest(coalesce(p_limit, 100), 1), 1000)) loop
    v_msg := r.message - 'dlq_reason' - 'dlq_at' - 'attempt';
    if p_queue = 'parse_document' then
      update public.documents set parse_status = 'queued', parse_error = null, parse_error_code = null,
        parse_attempts = 0
      where doc_code = v_msg->>'doc_code' and parse_status = 'failed';
    end if;
    perform pgmq.send(p_queue, v_msg);
    perform pgmq.delete(p_queue || '_dlq', r.msg_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ── SRV-15: mailbox sync state, merged in SQL ───────────────────────────────
-- Merges p_patch into sync_state key by key under a row lock, so concurrent
-- writers no longer overwrite each other's keys with a stale snapshot. The Gmail
-- history cursor only moves forward. last_synced_at / watch_expires_at only move
-- forward too (null = leave as is). Returns the merged sync_state.
create or replace function public.save_mailbox_sync_state(p_mailbox_code text, p_patch jsonb,
                                                          p_last_synced_at timestamptz default null,
                                                          p_watch_expires_at timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb;
  v_new jsonb;
begin
  perform private.assert_service_role();
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'patch must be an object' using errcode = '22023';
  end if;
  select sync_state into v_old from public.email_mailboxes where mailbox_code = p_mailbox_code for update;
  if not found then
    raise exception 'unknown mailbox %', p_mailbox_code using errcode = 'P0002';
  end if;
  v_new := coalesce(v_old, '{}'::jsonb) || p_patch || jsonb_build_object('updated_at', now());
  if (v_old->>'gmail_history_id') ~ '^[0-9]{1,30}$' and (v_new->>'gmail_history_id') ~ '^[0-9]{1,30}$'
     and (v_old->>'gmail_history_id')::numeric > (v_new->>'gmail_history_id')::numeric then
    v_new := jsonb_set(v_new, '{gmail_history_id}', v_old->'gmail_history_id');
  end if;
  update public.email_mailboxes set
    sync_state = v_new,
    last_synced_at = case when p_last_synced_at is null then last_synced_at
                          else greatest(coalesce(last_synced_at, p_last_synced_at), p_last_synced_at) end,
    watch_expires_at = case when p_watch_expires_at is null then watch_expires_at
                            else greatest(coalesce(watch_expires_at, p_watch_expires_at), p_watch_expires_at) end
  where mailbox_code = p_mailbox_code;
  return v_new;
end;
$$;

-- ── SRV-20: idempotent parse claims ─────────────────────────────────────────
-- The worker calls this instead of worker_document_context + its own UPDATE.
-- Returns null for a deleted document. For a document already 'parsed' or
-- 'failed' (a duplicate or stale queue message) it returns {skip: <status>} and
-- changes nothing; requeue_documents / resubmit_document / requeue_dlq put a
-- document back to 'queued' first. Otherwise it marks the document 'parsing'
-- and returns {doc, settings, skip: null}, as worker_document_context does.
create or replace function public.begin_document_parse(p_doc_code text, p_attempt integer default 1)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documents%rowtype;
begin
  perform private.assert_service_role();
  select * into d from public.documents where doc_code = p_doc_code for update;
  if not found then
    return null;
  end if;
  if d.parse_status in ('parsed', 'failed') then
    return jsonb_build_object('skip', d.parse_status, 'doc_code', d.doc_code);
  end if;
  update public.documents set parse_status = 'parsing',
    parse_attempts = least(greatest(coalesce(p_attempt, 1), 0), 32767)
  where doc_code = p_doc_code
  returning * into d;
  return jsonb_build_object(
    'skip', null,
    'doc', to_jsonb(d),
    'settings', coalesce((
      select jsonb_object_agg(split_part(s.name, ':', 3), s.decrypted_secret)
      from vault.decrypted_secrets s
      where s.name like 'profile:' || d.profile_code || ':%'), '{}'::jsonb)
  );
end;
$$;

-- A PDF uploaded again whose earlier copy failed to parse: put it back in the
-- queue. Returns {doc_code, parse_status, requeued}; any other status is
-- returned unchanged (the upload is then a plain duplicate).
create or replace function public.resubmit_document(p_profile_code text, p_doc_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  perform private.assert_service_role();
  select parse_status into v_status from public.documents
  where doc_code = p_doc_code and profile_code = p_profile_code
  for update;
  if not found then
    raise exception 'unknown document %', p_doc_code using errcode = 'P0002';
  end if;
  if v_status <> 'failed' then
    return jsonb_build_object('doc_code', p_doc_code, 'parse_status', v_status, 'requeued', false);
  end if;
  update public.documents set parse_status = 'queued', parse_error = null, parse_error_code = null, parse_attempts = 0
  where doc_code = p_doc_code;
  perform pgmq.send('parse_document', jsonb_build_object('doc_code', p_doc_code));
  return jsonb_build_object('doc_code', p_doc_code, 'parse_status', 'queued', 'requeued', true);
end;
$$;

-- A late failure from a duplicate or stale message never undoes a successful parse.
create or replace function public.fail_document(p_doc_code text, p_error_code text, p_error text, p_permanent boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();

  update public.documents
  set parse_status = case when p_permanent then 'failed' else 'queued' end,
      parse_error_code = p_error_code,
      parse_error = left(p_error, 2000)
  where doc_code = p_doc_code and parse_status <> 'parsed'
$$;

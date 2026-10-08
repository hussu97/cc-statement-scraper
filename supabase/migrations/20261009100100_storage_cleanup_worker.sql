-- DB-21e: the worker drains storage_cleanup (paths of a deleted profile's PDFs, queued by
-- delete_profile in 20261009000500) by deleting the objects through the Storage API.
--   * kick_worker also wakes the worker for visible storage_cleanup messages;
--   * storage_cleanup_dlq holds batches that kept failing (ops-monitor alerts on every
--     *_dlq queue), and drain_dlq / requeue_dlq accept 'storage_cleanup'.

select pgmq.create('storage_cleanup_dlq');

create or replace function private.kick_worker()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from pgmq.q_parse_document where vt <= now())
     or exists (select 1 from pgmq.q_llm_categorize where vt <= now())
     or exists (select 1 from pgmq.q_sms_fallback where vt <= now())
     or exists (select 1 from pgmq.q_storage_cleanup where vt <= now()) then
    return private.invoke_edge('worker');
  end if;
  return null;
end;
$$;

create or replace function private.assert_known_queue(p_queue text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_queue is null or p_queue not in ('parse_document', 'llm_categorize', 'sms_fallback', 'storage_cleanup') then
    raise exception 'unknown queue %', coalesce(p_queue, '(null)') using errcode = '22023';
  end if;
end;
$$;

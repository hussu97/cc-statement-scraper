-- SRV-15: merge a patch into email_mailboxes.sync_state atomically instead of writing
-- back a whole snapshot the Edge Function read at the start of its request.
--
-- Overlapping writers (two Pub/Sub deliveries, a push during gmail-watch-renew, an
-- outlook-poll run that outlives the next cron tick) used to overwrite each other's
-- keys with stale values and could move the Gmail cursor backwards. Now:
--   * keys in p_patch are merged (`||`), keys not in it are kept;
--   * `gmail_history_id` only ever moves forward (numeric max); a null or non-numeric
--     value in the patch never replaces a stored cursor;
--   * `updated_at` in sync_state is stamped by the database;
--   * last_synced_at / watch_expires_at change only when passed (null = keep).
-- Service role only (the Edge Functions after authenticating their caller).

create or replace function public.merge_mailbox_sync_state(
  p_mailbox_code text,
  p_patch jsonb,
  p_last_synced_at timestamptz default null,
  p_watch_expires_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb;
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_old text;
  v_new text;
begin
  perform private.assert_service_role();
  if jsonb_typeof(v_patch) <> 'object' then
    raise exception 'sync_state patch must be a JSON object' using errcode = '22023';
  end if;

  select m.sync_state into v_state
  from public.email_mailboxes m
  where m.mailbox_code = p_mailbox_code
  for update;
  if not found then
    raise exception 'unknown mailbox %', p_mailbox_code using errcode = 'P0002';
  end if;

  if v_patch ? 'gmail_history_id' then
    v_old := v_state ->> 'gmail_history_id';
    v_new := v_patch ->> 'gmail_history_id';
    v_patch := v_patch - 'gmail_history_id';
    if v_new ~ '^[0-9]{1,30}$'
       and (v_old is null or v_old !~ '^[0-9]{1,30}$' or v_new::numeric > v_old::numeric) then
      v_patch := v_patch || jsonb_build_object('gmail_history_id', v_new);
    end if;
  end if;

  update public.email_mailboxes m
  set sync_state = coalesce(m.sync_state, '{}'::jsonb) || v_patch
                   || jsonb_build_object('updated_at', to_jsonb(now())),
      last_synced_at = coalesce(p_last_synced_at, m.last_synced_at),
      watch_expires_at = coalesce(p_watch_expires_at, m.watch_expires_at)
  where m.mailbox_code = p_mailbox_code
  returning m.sync_state into v_state;
  return v_state;
end;
$$;

grant execute on function public.merge_mailbox_sync_state(text, jsonb, timestamptz, timestamptz) to service_role;

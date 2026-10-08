-- Document events are kept for 90 days. The nightly job (ledger-nightly, 22:00 UTC) purges
-- older rows. This is the only DELETE in the release, kept in its own migration so the
-- deploy gate's "destructive statement" flag points at exactly this retention job.

create or replace function private.purge_document_events(p_keep interval default interval '90 days')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  perform private.assert_service_role();
  delete from public.document_events where created_at < now() - greatest(p_keep, interval '1 day');
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function private.nightly(p_profile_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p text;
  v_void int;
  v_purged int;
  v_out jsonb := '{}'::jsonb;
  v_state text;
  v_msg text;
begin
  begin
    v_void := private.void_released_authorisations();
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    perform private.log_job_error('nightly.void_released_authorisations', null, null, v_state, v_msg);
  end;
  if p_profile_code is null then
    begin
      v_purged := private.purge_document_events();
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('nightly.purge_document_events', null, null, v_state, v_msg);
    end;
  end if;
  for p in select profile_code from public.profiles where p_profile_code is null or profile_code = p_profile_code loop
    begin
      v_out := v_out || jsonb_build_object(p, jsonb_build_object(
        'recurring', private.detect_recurring(p),
        'insights', private.generate_insights(p)
      ));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('nightly', p, null, v_state, v_msg);
      v_out := v_out || jsonb_build_object(p, jsonb_build_object('error', v_state));
    end;
  end loop;
  return v_out || jsonb_build_object('voided', v_void, 'document_events_purged', v_purged);
end;
$$;

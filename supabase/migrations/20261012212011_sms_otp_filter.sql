-- One OTP filter for the phone and the server (audit IOS-10).
--
-- The App Intent drops one-time passcodes on the device; `ingest_sms` drops them again as
-- defence in depth. The two regexes had drifted apart and both missed real wordings:
-- "Use 482913 as the code to complete your purchase…", "Your authentication code for … is
-- 552211", "3-D Secure password", "Never share this code", Arabic "رمز التحقق" / "كلمة المرور".
--
-- The pattern now lives in one function, `private.sms_otp_pattern()`, and is written in the
-- subset of regex syntax that Postgres AREs and ICU (NSRegularExpression) read the same way:
-- literals, bracket sets, bounded repeats, groups, ^ and $; no \b, \d, \s or `.` (they differ
-- between the engines). Both sides match it case-insensitively. LedgerKit's `SMSCapture` holds
-- the identical string; the shared fixture in `supabase/tests/38_sms_otp_filter.test.sql` pins
-- both to it (pgTAP and `swift test` each read that fixture) and lists every `sms_templates`
-- example as a message that must NOT be dropped: a false positive loses a transaction for good.
--
-- Deliberately not matched: bare "code" near digits (merchants like CODEFORGE.IO and every
-- card's last four digits), "auth code" / "approval code" (purchase alerts quote them), and a
-- bare "3-D Secure" mention (a declined-transaction alert can say it); bare Arabic "رمز" or "لمرة واحدة" (a one-off fee says it).

create or replace function private.sms_otp_pattern()
returns text
language sql
immutable
set search_path = ''
as $$
  select '(^|[^a-zA-Z0-9_])otp([^a-zA-Z_]|$)|one[^a-zA-Z0-9]{0,3}time[^a-zA-Z0-9]{0,3}(password|pin|code)|verification[^a-zA-Z0-9]{0,3}(code|pin)|pass[^a-zA-Z0-9]?code|security[^a-zA-Z0-9]{0,3}code|authentication[^a-zA-Z0-9]{0,3}(code|pin|password)|secure[^a-zA-Z0-9]{0,3}code|3[^a-zA-Z0-9]?d[^a-zA-Z0-9]?secure[^a-zA-Z0-9]{1,3}(password|pin)|(^|[^a-zA-Z0-9.,])[0-9]{4,8}[^a-zA-Z0-9]{1,3}(is|as)[^a-zA-Z0-9]{1,3}(your|the)[^a-zA-Z0-9]{1,3}([a-zA-Z-]{1,20}[^a-zA-Z0-9]{1,3}){0,3}(code|pin|password|passcode)([^a-zA-Z]|$)|(do[^a-zA-Z0-9]{1,3}not|don[^a-zA-Z0-9]{0,2}t|never)[^a-zA-Z0-9]{1,3}share[^a-zA-Z0-9]{1,3}((this|the|your|it)[^a-zA-Z0-9]{1,3})?(otp|code|password|passcode)|رمز (ال)?تحقق|رمز (ال)?مرور|كلمة (ال)?مرور|كلمة (ال)?سر|(رمز|كود) لمرة واحدة'::text
$$;

-- Whether an SMS body is a one-time passcode (case-insensitive, as on the device).
create or replace function private.sms_is_otp(p_body text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_body ~* private.sms_otp_pattern(), false)
$$;

-- ingest_sms as in 20261008001600, with the inline regex replaced by private.sms_is_otp.
create or replace function public.ingest_sms(p_profile_code text, p_messages jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  msg jsonb;
  v_code text;
  v_results jsonb := '[]'::jsonb;
  v_status text;
  v_problem text;
  v_state text;
begin
  perform private.assert_member(p_profile_code, true);
  if p_messages is null or jsonb_typeof(p_messages) <> 'array' or jsonb_array_length(p_messages) > 200 then
    raise exception 'p_messages must be an array of at most 200 messages' using errcode = '22023';
  end if;
  perform private.lock_profile(p_profile_code);

  for msg in select * from jsonb_array_elements(p_messages) loop
    v_problem := private.sms_input_problem(msg);
    if v_problem is not null then
      v_results := v_results || jsonb_build_object(
        'client_msg_id', case when jsonb_typeof(msg) = 'object' then msg->>'client_msg_id' end,
        'status', 'invalid', 'reason', v_problem);
      continue;
    end if;

    -- Defence in depth: OTPs are filtered on the device and never stored here.
    if private.sms_is_otp(msg->>'body') then
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'status', 'rejected_otp');
      continue;
    end if;

    v_code := null;
    insert into public.sms_messages (profile_code, client_msg_id, received_at, sender, body, body_hash)
    values (p_profile_code, (msg->>'client_msg_id')::uuid, coalesce((msg->>'received_at')::timestamptz, now()),
            coalesce(msg->>'sender', ''), msg->>'body',
            encode(sha256(convert_to(coalesce(msg->>'sender', '') || '|' || (msg->>'body'), 'UTF8')), 'hex'))
    on conflict (profile_code, client_msg_id) do nothing
    returning sms_code into v_code;

    if v_code is null then
      select sms_code into v_code from public.sms_messages
      where profile_code = p_profile_code and client_msg_id = (msg->>'client_msg_id')::uuid;
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'sms_code', v_code,
                                                   'status', 'duplicate_delivery');
      continue;
    end if;

    begin
      v_status := private.process_sms(v_code);
    exception when others then
      -- The message is kept; whatever processing did is rolled back to here.
      get stacked diagnostics v_state = returned_sqlstate;
      update public.sms_messages set parse_status = 'failed', ignore_reason = 'error:' || v_state
      where sms_code = v_code;
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'sms_code', v_code,
                                                   'status', 'failed', 'reason', 'error:' || v_state);
      continue;
    end;
    v_results := v_results || jsonb_build_object(
      'client_msg_id', msg->>'client_msg_id', 'sms_code', v_code, 'status', v_status,
      'txn_code', (select e.txn_code from public.transaction_evidence e where e.sms_code = v_code and e.is_active limit 1)
    );
  end loop;
  return v_results;
end;
$$;

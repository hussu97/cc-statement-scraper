-- One SMS, several Shortcuts automations (2026-10-28). The phone runs one automation per word
-- ("Card", "AED", "Account", "Wio"), and an alert holding two of them is sent twice, each time
-- with a fresh client_msg_id. A card alert holds "Card" and "AED", so most alerts now arrive twice.
--
-- 1. ingest_sms: a message whose sender and text (body_hash) match one this ledger stored less
--    than 10 minutes earlier (by received_at) is a repeat delivery. It is stored, parse_status
--    'ignored', ignore_reason 'repeat', parsed_fields.repeat_of = the first sms_code, and never
--    processed: no second transaction, review, checkpoint or LLM fallback. The phone is told
--    'duplicate_delivery' ("Already logged."), as for a resent client_msg_id.
--    Before this only a parsed transaction alert was caught (match_sms step 1, same window); an
--    unparsed or held alert went to the LLM fallback or into review twice.
--    A different text (another available limit or balance) is never a repeat, and Wallet events
--    don't come through ingest_sms.
-- 2. Template: Wio's money-in alert ("AED 48,500 sent by NAME and has been credited into your
--    account number 63XXXX9204.") is an account_credit on the account it names, so a move from
--    FAB …9221 to Wio …9204 pairs as an own transfer in v_cash_flow.

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
  v_sender text;
  v_received timestamptz;
  v_hash text;
  v_first text;
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

    v_sender := coalesce(msg->>'sender', '');
    v_received := coalesce((msg->>'received_at')::timestamptz, now());
    v_hash := encode(sha256(convert_to(v_sender || '|' || (msg->>'body'), 'UTF8')), 'hex');

    -- The same text from the same sender within 10 minutes is one SMS that two automations sent
    -- (or the bank resent). A failed first copy doesn't count: the repeat is processed instead.
    select o.sms_code into v_first
    from public.sms_messages o
    where o.profile_code = p_profile_code and o.body_hash = v_hash and o.source = 'sms'
      and o.parse_status <> 'failed' and coalesce(o.ignore_reason, '') <> 'repeat'
      and abs(extract(epoch from o.received_at - v_received)) <= 600
    order by o.received_at, o.sms_code
    limit 1;

    v_code := null;
    insert into public.sms_messages (profile_code, client_msg_id, received_at, sender, body, body_hash,
                                     parse_status, ignore_reason, parsed_fields)
    values (p_profile_code, (msg->>'client_msg_id')::uuid, v_received, v_sender, msg->>'body', v_hash,
            case when v_first is null then 'pending' else 'ignored' end,
            case when v_first is not null then 'repeat' end,
            case when v_first is null then '{}'::jsonb else jsonb_build_object('repeat_of', v_first) end)
    on conflict (profile_code, client_msg_id) do nothing
    returning sms_code into v_code;

    if v_code is null then
      select sms_code into v_code from public.sms_messages
      where profile_code = p_profile_code and client_msg_id = (msg->>'client_msg_id')::uuid;
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'sms_code', v_code,
                                                   'status', 'duplicate_delivery');
      continue;
    end if;

    if v_first is not null then
      v_results := v_results || jsonb_build_object('client_msg_id', msg->>'client_msg_id', 'sms_code', v_code,
                                                   'status', 'duplicate_delivery', 'repeat_of', v_first,
        'txn_code', (select e.txn_code from public.transaction_evidence e where e.sms_code = v_first and e.is_active limit 1));
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

insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 ('WIO', 'Wio money in', '^Wio',
  '([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?) sent by (.+?) and has been credited into your account number [0-9]*X+([0-9]+)',
  '{"currency":1,"amount":2,"merchant":3,"account_ref":4}', null, 'account_credit', 55,
  '[{"sender":"WioPersonal","body":"AED 48,500 sent by JOHN QUINCY PUBLIC SAMPLE and has been credited into your account number 63XXXX9204.",
     "expect":{"currency":"AED","amount":"48500.00","merchant":"JOHN QUINCY PUBLIC SAMPLE","account_ref":"9204"}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);

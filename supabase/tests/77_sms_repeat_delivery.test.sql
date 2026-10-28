-- One SMS, several Shortcuts automations (20261028110327_sms_repeat_delivery): the same sender and
-- text within 10 minutes is stored once as a message and once as an ignored repeat. From Alice's
-- real FAB and Wio alerts of 28 Oct: salary into FAB …9221, 48,500 moved to Wio …9204, 50,000 out.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.sms(p_sender text, p_body text, p_at timestamptz, p_id uuid default gen_random_uuid()) returns jsonb
language sql as $$
  select public.ingest_sms(pg_temp.v('p'), jsonb_build_array(jsonb_build_object(
    'client_msg_id', p_id, 'received_at', p_at, 'sender', p_sender, 'body', p_body))) -> 0
$$;
create function pg_temp.at(p_minutes int) returns timestamptz language sql as $$
  select pg_temp.v('t0')::timestamptz + make_interval(mins => p_minutes) $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't77-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't77-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t77-' || left(pg_temp.v('uid'), 8), 'Repeats'));
select pg_temp.set('fab', public.create_bank_account(pg_temp.v('p'), 'FAB', 'current', '9221', 'FAB'));
select pg_temp.set('wio', public.create_bank_account(pg_temp.v('p'), 'WIO', 'current', '9204', 'Wio'));
reset role;
select set_config('request.jwt.claims', '', true);

-- Yesterday 10:54 Dubai, so the template dates are within a day of arrival.
select pg_temp.set('t0', ((((now() at time zone 'Asia/Dubai')::date - 1) + time '10:54') at time zone 'Asia/Dubai')::text);
select pg_temp.set('d', to_char((now() at time zone 'Asia/Dubai')::date - 1, 'DD/MM/YYYY'));
select pg_temp.set('salary', E'Salary Credit\nAccount XXXX9221\nAED 50000.00\n' || pg_temp.v('d') || E'\nBalance AED 53944.98');
select pg_temp.set('notice', 'Dear Customer, your funds transfer request of  AED 48,500.00 to IBAN/Account/Card XXXX9204  has been processed successfully from your account/card XXXX9221 on '
                             || pg_temp.v('d') || ' 12:30');
select pg_temp.set('out', E'Outward Remittance Debit\nAccount XXXX9221\nAED 48500.00\nDate ' || pg_temp.v('d') || E'\nBalance AED 5444.49');
select pg_temp.set('in', 'AED 48,500 sent by JOHN QUINCY PUBLIC SAMPLE and has been credited into your account number 63XXXX9204.');
select pg_temp.set('pay', 'Your local transfer of AED 50,000 to Murtaza Mazahir Gheewala from your account number 63XXXX9204 was processed.');

-- ── each alert once ─────────────────────────────────────────────────────────
select is(pg_temp.sms('FAB', pg_temp.v('salary'), pg_temp.at(0))->>'status', 'created', 'salary credit');
select pg_temp.set('notice1', pg_temp.sms('FAB', pg_temp.v('notice'), pg_temp.at(96))::text);
select is(pg_temp.v('notice1')::jsonb->>'status', 'noted', 'the transfer notice is noted');
select is(pg_temp.sms('FAB', pg_temp.v('out'), pg_temp.at(96))->>'status', 'created', 'FAB transfer out');
select pg_temp.set('in1', pg_temp.sms('WioPersonal', pg_temp.v('in'), pg_temp.at(97))::text);
select is(pg_temp.v('in1')::jsonb->>'status', 'created', 'Wio money in is a transaction');
select is(pg_temp.sms('WioPersonal', pg_temp.v('pay'), pg_temp.at(98))->>'status', 'created', 'Wio transfer out');

select results_eq(
  $$ select t.account_code, t.kind, t.amount_aed, t.description
     from public.transactions t
     join public.transaction_evidence e on e.txn_code = t.txn_code and e.is_active
     where e.sms_code = pg_temp.v('in1')::jsonb->>'sms_code' $$,
  $$ values (pg_temp.v('wio'), 'transfer_in'::text, 48500.00::numeric, 'JOHN QUINCY PUBLIC SAMPLE'::text) $$,
  'Wio money in lands on …9204 as a transfer in, described by the sender');
select results_eq(
  $$ select account_code, flow, amount_aed from public.v_cash_flow
     where profile_code = pg_temp.v('p') and amount_aed = 48500 order by flow $$,
  $$ values (pg_temp.v('wio'), 'internal_in'::text, 48500.00::numeric(14,2)),
            (pg_temp.v('fab'), 'internal_out'::text, 48500.00::numeric(14,2)) $$,
  'FAB …9221 → Wio …9204 is a move between own accounts');

-- ── the transfer notice again: it holds "Card" and "AED", so both automations sent it ─────────
select pg_temp.set('notice2', pg_temp.sms('FAB', pg_temp.v('notice'), pg_temp.at(96) + interval '3 seconds')::text);
select is(pg_temp.v('notice2')::jsonb->>'status', 'duplicate_delivery', 'the second automation''s copy is a repeat');
select is(pg_temp.v('notice2')::jsonb->>'repeat_of', pg_temp.v('notice1')::jsonb->>'sms_code', 'of the first copy');
select results_eq(
  $$ select parse_status, ignore_reason, parsed_fields->>'repeat_of', msg_kind is null
     from public.sms_messages where sms_code = pg_temp.v('notice2')::jsonb->>'sms_code' $$,
  $$ values ('ignored'::text, 'repeat'::text, pg_temp.v('notice1')::jsonb->>'sms_code', true) $$,
  'it is kept, ignored as a repeat, and never processed');

-- ── a transaction alert again: no second transaction, no second checkpoint ─────────────────────
select pg_temp.set('in2', pg_temp.sms('WioPersonal', pg_temp.v('in'), pg_temp.at(97) + interval '2 seconds')::text);
select is(pg_temp.v('in2')::jsonb->>'status', 'duplicate_delivery', 'a repeated money-in alert is a repeat');
select is(pg_temp.v('in2')::jsonb->>'txn_code', pg_temp.v('in1')::jsonb->>'txn_code', 'the phone is told the first one''s transaction');
select is((select count(*)::int from public.transaction_evidence e
           where e.sms_code = pg_temp.v('in2')::jsonb->>'sms_code'), 0, 'the repeat is no evidence at all');
select is(pg_temp.sms('FAB', pg_temp.v('out'), pg_temp.at(96) + interval '5 seconds')->>'status', 'duplicate_delivery',
          'a repeated account debit is a repeat');
select is((select count(*)::int from public.transactions where profile_code = pg_temp.v('p')), 4, 'still four transactions');
select is((select count(*)::int from public.balance_checkpoints where account_code = pg_temp.v('fab')), 2,
          'and two FAB checkpoints (salary, transfer out)');

-- ── an unparsed alert twice goes to the LLM fallback once ───────────────────────────────────
select pg_temp.set('odd', 'Reminder: Please update your new Covered Card details with the merchants you pay by card.');
select pg_temp.set('odd1', pg_temp.sms('SIB', pg_temp.v('odd'), pg_temp.at(200))::text);
select pg_temp.set('odd2', pg_temp.sms('SIB', pg_temp.v('odd'), pg_temp.at(200) + interval '3 seconds')::text);
select is(pg_temp.v('odd1')::jsonb->>'status', 'unparsed', 'the first copy is unparsed');
select is(pg_temp.v('odd2')::jsonb->>'status', 'duplicate_delivery', 'the second is a repeat');
select is((select count(*)::int from pgmq.q_sms_fallback q
           where q.message->>'sms_code' in (pg_temp.v('odd1')::jsonb->>'sms_code', pg_temp.v('odd2')::jsonb->>'sms_code')),
          1, 'one LLM fallback job, not two');

-- ── what is not a repeat ────────────────────────────────────────────────────
select is(pg_temp.sms('SIB', pg_temp.v('odd'), pg_temp.at(211))->>'status', 'unparsed',
          'the same text 11 minutes later is a new message');
select is(pg_temp.sms('WioPersonal', pg_temp.v('odd'), pg_temp.at(200) + interval '4 seconds')->>'status', 'unparsed',
          'the same text from another sender is a new message');
select is(pg_temp.sms('FAB', replace(pg_temp.v('out'), '5444.49', '444.49'), pg_temp.at(97))->>'status', 'created',
          'the same debit with another balance is another debit');

-- ── a resent client_msg_id is still idempotent ─────────────────────────────
select pg_temp.set('id', gen_random_uuid()::text);
select pg_temp.sms('SIB', 'Your SIB card statement is ready.', pg_temp.at(300), pg_temp.v('id')::uuid);
select is(pg_temp.sms('SIB', 'Your SIB card statement is ready.', pg_temp.at(300), pg_temp.v('id')::uuid)->>'status',
          'duplicate_delivery', 'the same client_msg_id answers duplicate_delivery');
select is((select count(*)::int from public.sms_messages where profile_code = pg_temp.v('p') and client_msg_id = pg_temp.v('id')::uuid),
          1, 'and stores nothing new');

select * from finish();
rollback;

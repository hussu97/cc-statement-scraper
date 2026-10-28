-- Credit-linked notes (20261028110553_credit_linked_notes): the type, its terms, the generated
-- coupon schedule (30/360, a short first period), what was received and accrued, held to
-- maturity, if called next, the verdicts, settlement, a broker call, validation and tenant
-- isolation. The evaluator is asked about fixed dates, so the file holds on any day.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
create function pg_temp.ev(p_holding text, p_as_of date) returns jsonb language sql as $$
  select private.note_evaluate(n.note_code, p_as_of) from public.structured_notes n where n.holding_code = p_holding $$;
-- The Example Airlines CLN's shape: 10.5% p.a. monthly on the 20th from a 5-day first period.
create function pg_temp.monthly(p_isin text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('name', 'CLN monthly ' || p_isin, 'institution', 'Swissquote',
    'terms', jsonb_build_object('note_type', 'credit_linked', 'product_name', 'Fixed Rate CLN', 'isin', p_isin,
      'issuer', 'Example Bank N Structured Issuance SA', 'guarantor', 'Example Bank N', 'currency', 'USD', 'denomination', '1000',
      'issue_price_pct', '100', 'issue_date', '2024-10-15', 'maturity_date', '2031-12-20',
      'credit', jsonb_build_object('reference_entity', 'Example Airlines Group Inc', 'seniority', 'Senior',
        'reference_obligation_isin', 'US0000AA0001', 'coupon_rate_pct', '10.5', 'coupon_frequency', 'monthly',
        'day_count', '30/360', 'interest_start_date', '2024-10-15', 'first_coupon_date', '2024-10-20',
        'longstop_maturity_date', '2032-12-20', 'call_dates', '[]'::jsonb) || p_extra),
    'investment', jsonb_build_object('invested_amount', '10050.00', 'nominal', '10000', 'trade_date', '2024-10-10',
                                     'purchase_price_pct', '100.5')) $$;

-- ── setup: an owner and a stranger ──────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't78-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t78-' || left(pg_temp.v('uid'), 8), 'Credit'));

-- ── validation ──────────────────────────────────────────────────────────────
select throws_ok($$ select public.create_structured_note(pg_temp.v('p'),
                      jsonb_set(pg_temp.monthly('XS0000000781'), '{terms,credit,reference_entity}', '""')) $$,
                 '22023', null, 'a CLN needs a reference entity');
select throws_ok($$ select public.create_structured_note(pg_temp.v('p'),
                      pg_temp.monthly('XS0000000781', '{"first_coupon_date": null}')) $$,
                 '22023', null, 'a coupon schedule needs its first coupon date unless paid at maturity');
select throws_ok($$ select public.create_structured_note(pg_temp.v('p'),
                      pg_temp.monthly('XS0000000781', '{"call_dates": ["2033-01-01"]}')) $$,
                 '22023', null, 'call dates fall before maturity');
select throws_ok($$ select public.create_structured_note(pg_temp.v('p'),
                      jsonb_set(pg_temp.monthly('XS0000000781'), '{terms,note_type}', '"equity"')) $$,
                 '22023', null, 'an equity note still needs its strike and final valuation');

-- ── a monthly CLN ───────────────────────────────────────────────────────────
select pg_temp.set('hm', public.create_structured_note(pg_temp.v('p'), pg_temp.monthly('XS0000000781')));
reset role;
select is((select note_type from public.structured_notes where holding_code = pg_temp.v('hm')), 'credit_linked',
          'the note is credit-linked');
select is((select kind from public.holdings where holding_code = pg_temp.v('hm')), 'structured_note',
          'its holding is a structured note');
select is((select count(*)::int from public.structured_note_underlyings u join public.structured_notes n using (note_code)
           where n.holding_code = pg_temp.v('hm')), 0, 'no underlyings');
select is((select count(*)::int from private.cln_schedule((select note_code from public.structured_notes
                                                          where holding_code = pg_temp.v('hm')))), 87,
          '87 coupons: 20 Oct 2024 to 20 Dec 2031');
select is((select rate_pct from private.cln_schedule((select note_code from public.structured_notes
                                                     where holding_code = pg_temp.v('hm'))) where seq = 1), 0.145833,
          'the first coupon covers 5 days of 30/360 (10.5% x 5/360)');
select is(private.year_fraction('30/360', '2024-01-31', '2024-03-31'), 60::numeric / 360, '30/360: the 31st counts as the 30th');
select is(private.year_fraction('act/365', '2024-01-01', '2025-01-01'), 366::numeric / 365, 'act/365 counts days');

select is(pg_temp.ev(pg_temp.v('hm'), '2026-10-28')->'received'->>'coupons', '2114.58',
          'received by 28 Oct 2026: 14.58 + 24 x 87.50');
select is(pg_temp.ev(pg_temp.v('hm'), '2026-10-28')->'credit'->'accrued'->>'amount', '23.33',
          'accrued since 20 Oct: 8 days');
select is(pg_temp.ev(pg_temp.v('hm'), '2026-10-28')->'next'->>'pay_date', '2026-11-20', 'the next coupon date');
select is(pg_temp.ev(pg_temp.v('hm'), '2026-10-28')->'next'->'coupon'->>'amount', '87.50', 'and its amount');
select is(pg_temp.ev(pg_temp.v('hm'), '2026-10-28')->'next'->'coupon'->>'barrier_pct', '0', 'unconditional (barrier 0)');
select is(pg_temp.ev(pg_temp.v('hm'), '2026-10-28')->'credit'->'to_maturity'->>'total', '17539.58',
          'held to maturity: 100% + every coupon');
select is(pg_temp.ev(pg_temp.v('hm'), '2026-10-28')->'credit'->'credit_event'->>'interest_lost', '5425.00',
          'a credit event loses the coupons to come');
select ok(pg_temp.ev(pg_temp.v('hm'), '2026-10-28')->'scenarios' = 'null'::jsonb, 'no equity scenarios');
select is(private.note_verdict(pg_temp.ev(pg_temp.v('hm'), '2026-10-28'), 'live')->>'kind', 'cln_paying',
          'the verdict: paying coupons');
select is(private.note_verdict(pg_temp.ev(pg_temp.v('hm'), '2026-10-28'), 'live')->>'amount', '87.50',
          'with the next coupon');
select is(pg_temp.ev(pg_temp.v('hm'), '2032-01-05')->>'status', 'matured', 'matured after 20 Dec 2031');
select is(pg_temp.ev(pg_temp.v('hm'), '2032-01-05')->'result'->>'total', '17539.58', 'returning 100% and every coupon');
select is((select count(*)::int from public.structured_note_events e join public.structured_notes n using (note_code)
           where n.holding_code = pg_temp.v('hm') and e.kind = 'coupon'),
          (select count(*)::int from private.cln_schedule((select note_code from public.structured_notes
                                                          where holding_code = pg_temp.v('hm')))
           where pay_date <= public.dubai_date(now())),
          'every coupon paid so far is recorded');
select ok((select bool_and(e.worst_pct is null and e.worst_symbol is null) from public.structured_note_events e
           join public.structured_notes n using (note_code) where n.holding_code = pg_temp.v('hm')),
          'without a worst share');

-- ── interest paid at maturity, callable yearly (the Example Motors shape) ─
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('ha', public.create_structured_note(pg_temp.v('p'), jsonb_build_object(
  'name', 'CLN at maturity', 'terms', jsonb_build_object('note_type', 'credit_linked', 'product_name', 'CLN',
    'isin', 'XS0000000782', 'currency', 'USD', 'denomination', '1000', 'issue_price_pct', '100',
    'issue_date', '2025-02-13', 'maturity_date', '2034-12-20',
    'credit', jsonb_build_object('reference_entity', 'Example Motors Automotive PLC', 'coupon_rate_pct', '13.25',
      'coupon_frequency', 'at_maturity', 'interest_start_date', '2025-02-13',
      'call_dates', jsonb_build_array('2025-12-20', '2026-12-20', '2027-12-20'), 'call_notice_days', 10)),
  'investment', jsonb_build_object('invested_amount', '14100.00', 'nominal', '14000', 'trade_date', '2025-01-15'))));
reset role;
select is(pg_temp.ev(pg_temp.v('ha'), '2026-10-28')->'received'->>'coupons', '0.00', 'nothing paid before maturity');
select is(pg_temp.ev(pg_temp.v('ha'), '2026-10-28')->'credit'->'accrued'->>'amount',
          round(14000 * 0.1325 * private.year_fraction('30/360', '2025-02-13', '2026-10-28'), 2)::text,
          'interest accrues from the start');
select is(pg_temp.ev(pg_temp.v('ha'), '2026-10-28')->'credit'->>'next_call_date', '2026-12-20', 'the next call date');
select is(pg_temp.ev(pg_temp.v('ha'), '2026-10-28')->'credit'->'if_called_next'->>'total',
          (14000 + round(14000 * 0.1325 * private.year_fraction('30/360', '2025-02-13', '2026-12-20'), 2))::numeric(14,2)::text,
          'if called: 100% plus the interest to the call date');
select is(pg_temp.ev(pg_temp.v('ha'), '2026-10-28')->'next'->>'kind', 'final', 'the next payment is at maturity');
select is(private.note_verdict(pg_temp.ev(pg_temp.v('ha'), '2026-10-28'), 'live')->>'kind', 'cln_accruing',
          'the verdict: interest building up');
select is(private.note_verdict(pg_temp.ev(pg_temp.v('ha'), '2026-10-28'), 'live')->>'date', '2026-12-20',
          'until the next call date');
select is(private.note_verdict(pg_temp.ev(pg_temp.v('ha'), '2026-10-28'), 'called')->>'kind', 'ended',
          'a called note has ended');

-- ── readers ─────────────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select is((select count(*)::int from jsonb_array_elements(public.structured_notes_summary(pg_temp.v('p'))) x
           where x->>'note_type' = 'credit_linked' and x->'credit'->>'reference_entity' is not null
             and x->'credit'->'schedule' is null), 2, 'the summary carries the type and headline terms');
select is(jsonb_array_length(public.structured_note_detail(pg_temp.v('p'), pg_temp.v('hm'))->'credit'->'schedule'), 87,
          'the detail carries the schedule');
select is(public.structured_note_detail(pg_temp.v('p'), pg_temp.v('hm'))->'terms'->>'note_type', 'credit_linked',
          'and the type in its terms');
select is((select count(*)::int from public.structured_note_credit_terms), 2, 'members read the credit terms');
select pg_temp.as_user('uid2');
select is((select count(*)::int from public.structured_note_credit_terms), 0, 'strangers do not');
reset role;

-- ── on a synced broker account: the broker's coupons, then its early redemption is a call ─
select pg_temp.as_user('uid');
set local role authenticated;
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.set('sync', public.import_broker_data(pg_temp.v('p'), 'swissquote', jsonb_build_object(
  'portfolio_ref', 'T78PORTFOLIO', 'currency', 'USD', 'account_number', '123456781', 'iban', 'CH2700000000000000781',
  'fetched_at', now(), 'cash', '5000.00', 'opening', jsonb_build_object('as_of', '2024-09-01T08:00:00Z', 'balance', '0'),
  'securities', jsonb_build_array(jsonb_build_object('isin', 'XS0000000783', 'name', 'CLN 783', 'symbol', 'CLN 783',
                                                     'product_type', 'WARRANT')),
  'transactions', jsonb_build_array(
    jsonb_build_object('id', '1', 'booked_at', '2024-10-01T08:00:00Z', 'action', 'G', 'label', 'Payment', 'reversal', false,
                       'net_amount', '15000.00', 'currency', 'USD', 'commission', '0', 'contract_ref', 'C1'),
    jsonb_build_object('id', '2', 'booked_at', '2024-10-10T08:00:00Z', 'action', 'B', 'label', 'Buy', 'reversal', false,
                       'isin', 'XS0000000783', 'symbol', 'CLN 783', 'name', 'CLN 783', 'quantity', '10000', 'unit_price', '1',
                       'net_amount', '-10050.00', 'currency', 'USD', 'commission', '0', 'contract_ref', 'C2'),
    jsonb_build_object('id', '3', 'booked_at', '2024-11-07T08:00:00Z', 'action', 'E', 'label', 'Coupon', 'reversal', false,
                       'isin', 'XS0000000783', 'symbol', 'CLN 783', 'name', 'CLN 783', 'quantity', '1', 'unit_price', '14.58',
                       'net_amount', '14.58', 'currency', 'USD', 'commission', '0', 'contract_ref', 'C3'),
    jsonb_build_object('id', '4', 'booked_at', '2024-11-21T08:00:00Z', 'action', 'E', 'label', 'Coupon', 'reversal', false,
                       'isin', 'XS0000000783', 'symbol', 'CLN 783', 'name', 'CLN 783', 'quantity', '1', 'unit_price', '87.50',
                       'net_amount', '87.50', 'currency', 'USD', 'commission', '0', 'contract_ref', 'C4'),
    jsonb_build_object('id', '5', 'booked_at', '2024-12-20T08:00:00Z', 'action', 'CAC', 'label', 'Redemption', 'reversal', false,
                       'isin', 'XS0000000783', 'symbol', 'CLN 783', 'name', 'CLN 783', 'quantity', '1', 'unit_price', '10000',
                       'net_amount', '10000.00', 'currency', 'USD', 'commission', '0', 'contract_ref', 'C5')),
  'positions', '[]'::jsonb, 'snapshots', '[]'::jsonb))::text);
select is((select kind from public.holdings where profile_code = pg_temp.v('p') and external_ref = 'XS0000000783'), 'broker',
          'the synced position starts as a broker holding');
select pg_temp.set('acc', pg_temp.v('sync')::jsonb->>'account_code');
select pg_temp.set('hs', public.create_structured_note(pg_temp.v('p'),
  jsonb_set(jsonb_set(pg_temp.monthly('XS0000000783'), '{investment}',
                      jsonb_build_object('funding_account_code', pg_temp.v('acc'))), '{name}', '"CLN synced"')));
select is((select kind from public.holdings where holding_code = pg_temp.v('hs')), 'structured_note',
          'the broker holding becomes the credit-linked note');
select is((select invested_amount from public.structured_notes where holding_code = pg_temp.v('hs')), 10050.00::numeric,
          'bought as the broker''s buy row says');
select is(pg_temp.ev(pg_temp.v('hs'), '2024-12-01')->'received'->>'coupons', '102.08',
          'received: what the broker paid');
select is((select status from public.structured_notes where holding_code = pg_temp.v('hs')), 'called',
          'redeemed before maturity: called');
select is((select ended_on from public.structured_notes where holding_code = pg_temp.v('hs')), '2024-12-20'::date,
          'on the redemption day');
select is((select status from public.holdings where holding_code = pg_temp.v('hs')), 'closed', 'its holding is closed');
select is(private.note_summary((select n from public.structured_notes n where n.holding_code = pg_temp.v('hs')),
                               pg_temp.ev(pg_temp.v('hs'), public.dubai_date(now())))->'result'->>'total', '10102.08',
          'the result is what the broker paid back and paid out');

select * from finish();
rollback;

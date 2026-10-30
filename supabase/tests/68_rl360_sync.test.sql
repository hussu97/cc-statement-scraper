-- RL360 sync (20261021112634_rl360_sync): import_holding_data claims the plan, stores values
-- without overriding manual ones, and reconciles premiums with linked card payments.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.txn(p_aed numeric, p_day date, p_usd numeric) returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, txn_at,
                                   description, amount_original, currency_original, amount_aed, amount_source)
  values (pg_temp.v('p'), pg_temp.v('card'), 'posted', 'purchase', 'debit', p_day,
          (p_day + time '10:00') at time zone 'Asia/Dubai', '*RL360 DOUGLAS GBR', p_usd, 'USD', p_aed, 'manual')
  returning txn_code $$;
create function pg_temp.premiums() returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('ref', 'premium:p1', 'date', pg_temp.v('today')::date - 70, 'amount', '1500.00'),
    jsonb_build_object('ref', 'premium:p2', 'date', pg_temp.v('today')::date - 40, 'amount', '1500.00'),
    jsonb_build_object('ref', 'premium:p3', 'date', pg_temp.v('today')::date - 10, 'amount', '1500.00')) $$;
create function pg_temp.sync(p_values jsonb default '[]', p_premiums jsonb default pg_temp.premiums()) returns jsonb
language sql as $$
  select public.import_holding_data(pg_temp.v('p'), 'RL360', 'RS00000001', 'USD', pg_temp.v('start')::date,
                                    p_values, p_premiums) $$;
create function pg_temp.active_total() returns numeric language sql as $$
  select coalesce(sum(amount), 0) from public.holding_flows
  where holding_code = pg_temp.v('plan') and kind = 'contribution' and private.flow_is_active(removed_at, txn_code) $$;

-- ── setup: an owner, a card, an RL360 plan linked by rule ───────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't68-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t68-' || left(pg_temp.v('uid'), 8), 'RL360'));
select pg_temp.set('today', public.dubai_date(now())::text);
select pg_temp.set('start', (date_trunc('month', pg_temp.v('today')::date) - interval '3 months')::date::text);
select pg_temp.set('plan', public.save_holding(pg_temp.v('p'), 'RL360 plan', p_kind => 'plan', p_currency => 'USD',
                                               p_institution => 'RL360', p_link_pattern => 'RL360',
                                               p_acquired_on => pg_temp.v('today')::date - 30));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code, nickname) values (pg_temp.v('p'), 'ENBD', 'ENBD card')
returning pg_temp.set('card', account_code);
-- The card payment for premium p3, linked by the plan's rule.
select pg_temp.set('rl3', pg_temp.txn(5508.75, pg_temp.v('today')::date - 9, 1500));
select is((select source from public.holding_flows where txn_code = pg_temp.v('rl3')), 'rule', 'the p3 payment is linked by rule');

-- ── callers ─────────────────────────────────────────────────────────────────
select pg_temp.as_owner();
set local role authenticated;
select throws_ok($$ select pg_temp.sync() $$, '42501', null, 'members cannot import');
reset role;
select set_config('request.jwt.claims', '', true);
select throws_ok($$ select public.import_holding_data(pg_temp.v('p'), 'RL360', 'RS 1', 'USD', null, '[]') $$,
                 '22023', null, 'a plan number is letters, digits and dashes');

-- ── first sync: claim, value, premiums ──────────────────────────────────────
select pg_temp.set('r1', pg_temp.sync(jsonb_build_array(jsonb_build_object('as_of', pg_temp.v('today'), 'value', '123456.78')))::text);
select is((pg_temp.v('r1')::jsonb)->>'holding_code', pg_temp.v('plan'), 'the one unnumbered RL360 plan is claimed');
select is((pg_temp.v('r1')::jsonb)->>'claimed', 'true', '… and reported as claimed');
select is((select external_ref from public.holdings where holding_code = pg_temp.v('plan')), 'RS00000001', 'it keeps the plan number');
select is((select acquired_on::text from public.holdings where holding_code = pg_temp.v('plan')), pg_temp.v('start'),
          'its start moves back to the plan''s start');
select is((pg_temp.v('r1')::jsonb)->>'values_added', '1', 'today''s value is stored');
select is((select source from public.holding_valuations where holding_code = pg_temp.v('plan')), 'import', '… as an import');
select is((pg_temp.v('r1')::jsonb)->'premiums', '{"imported": 2, "revived": 0, "superseded": 0, "matched_to_payments": 1}'::jsonb,
          'p3 is the linked card payment; p1 and p2 are imported');
select is(pg_temp.active_total(), 4500.00::numeric, 'three premiums of USD 1,500, none counted twice');
select is((select amount_aed from public.holding_flows where holding_code = pg_temp.v('plan') and external_ref = 'premium:p1'),
          5508.75::numeric, 'an imported premium is in AED at the peg');
select is(jsonb_array_length((pg_temp.v('r1')::jsonb)->'missing_month_ends'), 3, 'three month-ends since the start have no value');

-- ── re-runs are idempotent ──────────────────────────────────────────────────
select pg_temp.set('r2', pg_temp.sync(jsonb_build_array(jsonb_build_object('as_of', pg_temp.v('today'), 'value', '123456.78')))::text);
select is((pg_temp.v('r2')::jsonb)->>'values_added', '0', 'the same value is not stored twice');
select is((pg_temp.v('r2')::jsonb)->'premiums'->>'imported', '0', 'no premium is imported twice');
select is((select count(*)::int from public.holding_flows where holding_code = pg_temp.v('plan') and source = 'import'), 2,
          'still two imported premiums');
select is((pg_temp.sync(jsonb_build_array(jsonb_build_object('as_of', pg_temp.v('today'), 'value', '145500.00'))))->>'values_added', '1',
          'a changed value for the day is a new import');

-- ── backfill and manual values ──────────────────────────────────────────────
insert into public.holding_valuations (profile_code, holding_code, as_of, value, source)
values (pg_temp.v('p'), pg_temp.v('plan'), ((pg_temp.v('r1')::jsonb)->'missing_month_ends'->>0)::date, 100000, 'manual');
select pg_temp.set('r3', pg_temp.sync(
  (select jsonb_agg(jsonb_build_object('as_of', d, 'value', '120000')) from jsonb_array_elements_text((pg_temp.v('r1')::jsonb)->'missing_month_ends') d),
  null)::text);
select is((pg_temp.v('r3')::jsonb)->>'values_added', '2', 'the backfill skips the month-end with a manual value');
select is((select value from public.holding_valuations where holding_code = pg_temp.v('plan')
           and as_of = ((pg_temp.v('r1')::jsonb)->'missing_month_ends'->>0)::date order by created_at desc limit 1),
          100000.00::numeric, 'the manual value stands');
select is((pg_temp.v('r3')::jsonb)->'premiums', 'null'::jsonb, 'a backfill call leaves premiums alone');
select is((pg_temp.v('r3')::jsonb)->'missing_month_ends', '[]'::jsonb, 'no month-end is missing after the backfill');
select throws_ok($$ select pg_temp.sync(jsonb_build_array(jsonb_build_object('as_of', current_date + 2, 'value', '1'))) $$,
                 '22023', null, 'a value cannot be in the future');

-- ── a payment linked later stands for its premium; unlinked, the import returns ──
select pg_temp.set('rl1', pg_temp.txn(5508.75, pg_temp.v('today')::date - 69, 1500));
select pg_temp.as_owner();
set local role authenticated;
select public.link_transaction(pg_temp.v('p'), pg_temp.v('rl1'), pg_temp.v('plan'));
reset role;
select set_config('request.jwt.claims', '', true);
select is((pg_temp.sync())->'premiums', '{"imported": 0, "revived": 0, "superseded": 1, "matched_to_payments": 2}'::jsonb,
          'the p1 import gives way to the linked payment');
select is((select superseded_by from public.holding_flows where holding_code = pg_temp.v('plan') and external_ref = 'premium:p1'),
          (select flow_code from public.holding_flows where txn_code = pg_temp.v('rl1')), '… which it names');
select is(pg_temp.active_total(), 4500.00::numeric, 'still USD 4,500 in');
select pg_temp.as_owner();
set local role authenticated;
select public.link_transaction(pg_temp.v('p'), pg_temp.v('rl1'), null);
reset role;
select set_config('request.jwt.claims', '', true);
select is((pg_temp.sync())->'premiums'->>'revived', '1', 'unlinked, the payment gives p1 back to the import');
select is(pg_temp.active_total(), 4500.00::numeric, 'still USD 4,500 in');

-- ── a premium the user removed stays removed ────────────────────────────────
select pg_temp.as_owner();
set local role authenticated;
select public.remove_holding_flow(pg_temp.v('p'), (select flow_code from public.holding_flows
                                                   where holding_code = pg_temp.v('plan') and external_ref = 'premium:p2'));
reset role;
select set_config('request.jwt.claims', '', true);
select is((pg_temp.sync())->'premiums', '{"imported": 0, "revived": 0, "superseded": 0, "matched_to_payments": 1}'::jsonb,
          'the removed premium is neither imported nor revived');
select is(pg_temp.active_total(), 3000.00::numeric, 'USD 3,000 in without it');

-- ── mismatches ──────────────────────────────────────────────────────────────
select throws_ok($$ select public.import_holding_data(pg_temp.v('p'), 'RL360', 'RS00000001', 'EUR', null, '[]') $$,
                 '22023', null, 'a plan in another currency than its holding is refused');
select pg_temp.as_owner();
set local role authenticated;
select public.save_holding(pg_temp.v('p'), 'RL360 second', p_kind => 'plan', p_currency => 'USD', p_institution => 'RL360');
select public.save_holding(pg_temp.v('p'), 'RL360 third', p_kind => 'plan', p_currency => 'USD', p_institution => 'RL360');
reset role;
select set_config('request.jwt.claims', '', true);
select is((public.import_holding_data(pg_temp.v('p'), 'RL360', 'RS00000009', 'USD', null, '[]'))->>'holding_code', null,
          'with two unnumbered RL360 plans, none is claimed');

-- ── the job ─────────────────────────────────────────────────────────────────
select is((select count(*)::int from cron.job where jobname = 'ledger-rl360-sync' and schedule = '20 2 * * *'
             and command like '%invoke_edge(''rl360-sync'')%'), 1, 'a daily cron job calls the rl360-sync function');

select * from finish();
rollback;

-- Zerodha position detail (20261028062806_zerodha_position_detail): import_zerodha_data keeps
-- each position's previous price, price date, exchange, folio, asset class, category and fund
-- house; a fund's previous price is its last mark from an earlier NAV date; a holding still named
-- by its ticker takes the company name; Coin's SIPs are kept current (one no longer listed is
-- cancelled, a payload without SIPs leaves them). broker_portfolio adds day change, weight,
-- return, allocation, fund houses, highlights and SIPs; broker_position_detail shows one position
-- with its marks over time. Dates are relative to today.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.d(p_offset int) returns date language sql as $$
  select public.dubai_date(now()) + p_offset $$;
create function pg_temp.at(p_offset int) returns text language sql as $$
  select to_char(((pg_temp.d(p_offset) + time '21:30') at time zone 'Asia/Dubai') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
-- The share, the ETF (both Kite) and two funds (Coin), as zerodha-sync now sends them.
create function pg_temp.share() returns jsonb language sql as $$
  select jsonb_build_object('segment', 'kite', 'isin', 'INE000A01073', 'name', 'TESTCO LIMITED', 'symbol', 'TESTCO',
    'quantity', '10', 'price', '2500', 'cost_price', '2000', 'prev_price', '2400', 'exchange', 'NSE',
    'asset_class', 'stock') $$;
create function pg_temp.etf() returns jsonb language sql as $$
  select jsonb_build_object('segment', 'kite', 'isin', 'INF100A01011', 'name', 'TEST NIFTY ETF', 'symbol', 'TESTBEES',
    'quantity', '100', 'price', '50', 'cost_price', '40', 'prev_price', '51', 'exchange', 'BSE', 'asset_class', 'etf') $$;
create function pg_temp.fund_a(p_price text, p_nav_day int) returns jsonb language sql as $$
  select jsonb_build_object('segment', 'coin', 'isin', 'INF200A01019', 'name', 'Test Small Cap Fund - Direct Growth',
    'symbol', 'INF200A01019', 'quantity', '100', 'price', p_price, 'cost_price', '40',
    'price_date', pg_temp.d(p_nav_day), 'folio', '91064', 'asset_class', 'fund', 'category', 'Equity',
    'issuer', 'Test AMC A') $$;
create function pg_temp.fund_b() returns jsonb language sql as $$
  select jsonb_build_object('segment', 'coin', 'isin', 'INF300A01017', 'name', 'Test Liquid Fund - Direct Growth',
    'symbol', 'INF300A01017', 'quantity', '10', 'price', '100', 'cost_price', '110',
    'price_date', pg_temp.d(-3), 'folio', '77001', 'asset_class', 'fund', 'category', 'Debt', 'issuer', 'Test AMC B') $$;
create function pg_temp.sip(p_id text, p_isin text, p_status text, p_amount text, p_order jsonb) returns jsonb language sql as $$
  select jsonb_build_object('sip_id', p_id, 'isin', p_isin, 'fund', 'Fund ' || p_id, 'status', p_status,
    'frequency', 'monthly', 'amount', p_amount, 'day', 5, 'next_instalment', pg_temp.d(7),
    'last_instalment', pg_temp.at(-20), 'completed', 10, 'step_up', '{"10-02": 3}'::jsonb,
    'created', '2021-02-10T06:01:50Z', 'last_order', p_order) $$;
create function pg_temp.sync(p_day int, p_positions jsonb, p_extra jsonb) returns jsonb language sql as $$
  select public.import_zerodha_data(pg_temp.v('p'), jsonb_build_object(
    'user_id', 'ZX7501', 'fetched_at', pg_temp.at(p_day), 'cash', '1000.00',
    'segments_read', '["kite", "coin"]'::jsonb, 'positions', p_positions) || coalesce(p_extra, '{}'::jsonb)) $$;
create function pg_temp.portfolio(p_acc text) returns jsonb language sql as $$
  select public.broker_portfolio(pg_temp.v('p'), pg_temp.v(p_acc)) $$;
create function pg_temp.pos(p_acc text, p_isin text) returns jsonb language sql as $$
  select p from jsonb_array_elements(pg_temp.portfolio(p_acc)->'positions') p where p->>'isin' = p_isin $$;
create function pg_temp.sips() returns text language sql as $$
  select string_agg(external_id || ' ' || status || ' ' || coalesce(last_order_status, '-'), ', ' order by external_id)
  from public.broker_sips where profile_code = pg_temp.v('p') $$;

-- ── setup: an owner with two holdings from before, and a stranger ──────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't75-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t75-' || left(pg_temp.v('uid'), 8), 'Zerodha'));
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select pg_temp.set('p2', public.create_profile('t75b-' || left(pg_temp.v('uid2'), 8), 'Stranger'));
reset role;
select set_config('request.jwt.claims', '', true);
select public.upsert_fx_rates('{"INR": 0.044}'::jsonb, 'test', pg_temp.d(-10));
-- The share as the first sync named it (its ticker); the ETF renamed by the user.
insert into public.holdings (profile_code, name, kind, currency, institution, units, external_ref)
values (pg_temp.v('p'), 'TESTCO', 'security', 'INR', 'Zerodha Kite', 10, 'INE000A01073'),
       (pg_temp.v('p'), 'My Nifty ETF', 'security', 'INR', 'Zerodha Kite', 100, 'INF100A01011');

-- ── day 1 ───────────────────────────────────────────────────────────────────
select pg_temp.set('r1', pg_temp.sync(-2,
  jsonb_build_array(pg_temp.share(), pg_temp.etf(), pg_temp.fund_a('50', -3), pg_temp.fund_b()),
  jsonb_build_object('sips', jsonb_build_array(
    pg_temp.sip('S1', 'INF200A01019', 'active', '2000',
                jsonb_build_object('status', 'rejected', 'message', 'Payment not received.', 'at', pg_temp.at(-2))),
    pg_temp.sip('S2', 'INF300A01017', 'paused', '1000', null))))::text);
select pg_temp.set('kite', (pg_temp.v('r1')::jsonb)->'accounts'->>'kite');
select pg_temp.set('coin', (pg_temp.v('r1')::jsonb)->'accounts'->>'coin');
select is((pg_temp.v('r1')::jsonb)->>'sips', '2', 'the import reports the SIPs it read');

select is((select trim_scale(prev_price) || ' ' || exchange || ' ' || asset_class || ' ' || name from public.broker_positions
           where isin = 'INE000A01073' and as_of = pg_temp.d(-2)),
          '2400 NSE stock TESTCO LIMITED', 'a share keeps its previous close, exchange, class and company name');
select is((select folio || ' ' || asset_class || ' ' || category || ' ' || issuer || ' ' || price_date
                  || ' ' || coalesce(prev_price::text, '-') from public.broker_positions
           where isin = 'INF200A01019' and as_of = pg_temp.d(-2)),
          '91064 fund Equity Test AMC A ' || pg_temp.d(-3) || ' -',
          'a fund keeps folio, class, scheme type, fund house and NAV date; no earlier NAV yet');
select is((select name from public.holdings where profile_code = pg_temp.v('p') and external_ref = 'INE000A01073'),
          'TESTCO LIMITED', 'a holding still named by its ticker takes the company name');
select is((select name from public.holdings where profile_code = pg_temp.v('p') and external_ref = 'INF100A01011'),
          'My Nifty ETF', 'a name the user gave stays');
select is(pg_temp.sips(), 'S1 active rejected, S2 paused -', 'SIPs are kept, with the latest order''s outcome');
select is((select account_code from public.broker_sips where external_id = 'S1'), pg_temp.v('coin'),
          'on the Coin account');

-- An older payload (no new fields, no SIPs) still imports, and leaves the SIPs.
select lives_ok($$ select pg_temp.sync(-2, jsonb_build_array(
                     pg_temp.share() - 'prev_price' - 'exchange' - 'asset_class', pg_temp.etf(),
                     pg_temp.fund_a('50', -3), pg_temp.fund_b()), null) $$, 'an older payload imports');
select is(pg_temp.sips(), 'S1 active rejected, S2 paused -', 'a payload without SIPs leaves them');
select is((select coalesce(prev_price::text, '-') || ' ' || coalesce(asset_class, '-') from public.broker_positions
           where isin = 'INE000A01073' and as_of = pg_temp.d(-2)), '- -', 'and the mark says what it was told');

-- ── day 2: fund A has a new NAV; fund B's is the same as before ────────────
select pg_temp.sync(-1, jsonb_build_array(pg_temp.share(), pg_temp.etf(), pg_temp.fund_a('55', -2), pg_temp.fund_b()),
  jsonb_build_object('sips', jsonb_build_array(pg_temp.sip('S1', 'INF200A01019', 'active', '2000', null))));
select is((select prev_price::numeric from public.broker_positions where isin = 'INF200A01019' and as_of = pg_temp.d(-1)),
          50::numeric, 'a fund''s previous price: its last mark from an earlier NAV date');
select is((select prev_price from public.broker_positions where isin = 'INF300A01017' and as_of = pg_temp.d(-1)),
          null, 'none while its NAV date has not moved');
select is(pg_temp.sips(), 'S1 active rejected, S2 cancelled -',
          'a SIP no longer listed is cancelled; an order outside the window leaves the last outcome');

-- ── broker_portfolio ────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select is(pg_temp.pos('kite', 'INE000A01073')->>'day_change', '1000.00', 'a share''s day change: 10 × (2,500 − 2,400)');
select is(pg_temp.pos('kite', 'INE000A01073')->>'day_change_pct', '4.17', 'and in %');
select is(pg_temp.pos('kite', 'INE000A01073')->>'weight_pct', '83.33', 'its weight in the account''s positions');
select is(pg_temp.pos('kite', 'INE000A01073')->>'return_pct', '25.00', 'its return on cost');
select is(pg_temp.pos('kite', 'INE000A01073')->>'cost_price', '2000', 'and its average cost');
select is(pg_temp.pos('kite', 'INF100A01011')->>'day_change', '-100.00', 'the ETF fell 1 a unit');
select is(pg_temp.portfolio('kite')->>'day_change', '900.00', 'the account''s day change');
select is(pg_temp.portfolio('kite')->>'day_change_pct', '3.09', 'against the previous value (29,100)');
select is((select string_agg(a->>'key' || ' ' || (a->>'value') || ' ' || (a->>'weight_pct') || ' ' || (a->>'profit'), ', ')
           from jsonb_array_elements(pg_temp.portfolio('kite')->'allocation') a),
          'stock 25000.00 83.33 5000.00, etf 5000.00 16.67 1000.00', 'Kite''s allocation: stocks and ETFs');
select is((select string_agg(a->>'label', ', ') from jsonb_array_elements(pg_temp.portfolio('kite')->'allocation') a),
          'Stocks, ETFs', 'labelled');
select is(pg_temp.portfolio('kite')->'sips', '[]'::jsonb, 'Kite has no SIPs');

select is(pg_temp.pos('coin', 'INF200A01019')->>'day_change', '500.00', 'a fund''s day change, NAV to NAV');
select is(pg_temp.pos('coin', 'INF300A01017')->>'day_change', null, 'none without a previous NAV');
select is(pg_temp.portfolio('coin')->>'day_change_pct', '10.00', 'the account''s, over the funds with one');
select is((select string_agg(a->>'key' || ' ' || (a->>'weight_pct'), ', ')
           from jsonb_array_elements(pg_temp.portfolio('coin')->'allocation') a),
          'fund:Equity 84.62, fund:Debt 15.38', 'Coin''s allocation: by scheme type');
select is((select string_agg(a->>'issuer' || ' ' || (a->>'value'), ', ')
           from jsonb_array_elements(pg_temp.portfolio('coin')->'issuers') a),
          'Test AMC A 5500.00, Test AMC B 1000.00', 'and by fund house');
select is((select string_agg(h->>'isin', ',') from jsonb_array_elements(pg_temp.portfolio('coin')->'highlights'->'best') h),
          'INF200A01019', 'best: gains only');
select is((select string_agg(h->>'isin', ',') from jsonb_array_elements(pg_temp.portfolio('coin')->'highlights'->'worst') h),
          'INF300A01017', 'worst: losses only');
select is((select string_agg(h->>'isin', ',') from jsonb_array_elements(pg_temp.portfolio('coin')->'highlights'->'gainers_today') h),
          'INF200A01019', 'today''s gainers');
select is(pg_temp.portfolio('coin')->'highlights'->'losers_today', '[]'::jsonb, 'no loser today');
select is(pg_temp.portfolio('coin')->'highlights'->>'top5_weight_pct', null, 'no top-five share with two positions');
select is((select string_agg((s->>'status') || ' ' || (s->>'missed') || ' ' || (s->>'amount') || ' '
                             || (s->'last_order'->>'message') || ' ' || ((s->>'holding_code') is not null), ', ')
           from jsonb_array_elements(pg_temp.portfolio('coin')->'sips') s where s->>'status' = 'active'),
          'active true 2000.00 Payment not received. true', 'an active SIP whose last instalment was rejected, linked to its holding');
select is(jsonb_array_length(pg_temp.portfolio('coin')->'sips'), 2, 'cancelled ones are listed too, after');

-- ── broker_position_detail ──────────────────────────────────────────────────
select is((select string_agg((s->>'as_of') || ' ' || (s->>'price') || ' ' || (s->>'value') || ' ' || (s->>'cost'), ', ')
           from jsonb_array_elements(public.broker_position_detail(pg_temp.v('p'), pg_temp.v('coin'), 'INF200A01019')->'series') s),
          pg_temp.d(-2) || ' 50 5000.00 4000.00, ' || pg_temp.d(-1) || ' 55 5500.00 4000.00',
          'a position''s marks over time');
select is(public.broker_position_detail(pg_temp.v('p'), pg_temp.v('coin'), 'INF200A01019')->'position'->>'weight_pct',
          '84.62', 'with the position as the account shows it');
select is(jsonb_array_length(public.broker_position_detail(pg_temp.v('p'), pg_temp.v('coin'), 'INF200A01019')->'sips'), 1,
          'and its own SIPs');
select is(public.broker_position_detail(pg_temp.v('p'), pg_temp.v('coin'), 'INE000A01073'), null,
          'null for an ISIN the account never marked');
select is((select count(*)::int from public.broker_sips), 2, 'a member sees the ledger''s SIPs');
reset role;

select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select public.broker_position_detail(pg_temp.v('p'), pg_temp.v('coin'), 'INF200A01019') $$,
                 '42501', null, 'a stranger cannot read a position');
select is((select count(*)::int from public.broker_sips), 0, 'nor see the SIPs');
reset role;

select * from finish();
rollback;

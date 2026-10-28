-- Zerodha sync (20261027202923_zerodha_sync, 20261028054048_zerodha_kite_coin_accounts):
-- import_zerodha_data makes two INR broker accounts and connections, Zerodha Kite (stocks, ETFs,
-- the Funds cash) and Zerodha Coin (mutual funds, no cash), a `security` holding per ISIN, each
-- day's mark on its segment's account, the cash checkpoints and each account's value per day. Flows are inferred from day to day: the first sight at cost,
-- more units at the cost added, fewer units at the day's price, a sold position closed at its
-- last price, and a re-bought one opened again. A segment whose read failed keeps its marks.
-- broker_portfolio reports invested against value, per account; Wealth's broker_accounts_summary
-- leaves both out (they are India's). Dates are relative to today.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.d(p_offset int) returns date language sql as $$
  select pg_temp.v('today')::date + p_offset $$;
create function pg_temp.at(p_offset int) returns text language sql as $$
  select to_char(((pg_temp.d(p_offset) + time '21:30') at time zone 'Asia/Dubai') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
create function pg_temp.kite(p_qty text, p_price text, p_cost text) returns jsonb language sql as $$
  select jsonb_build_object('segment', 'kite', 'isin', 'INE000A01073', 'name', 'TESTCO', 'symbol', 'TESTCO',
                            'quantity', p_qty, 'price', p_price, 'cost_price', p_cost) $$;
create function pg_temp.coin(p_qty text, p_price text, p_cost text) returns jsonb language sql as $$
  select jsonb_build_object('segment', 'coin', 'isin', 'INF000A01073', 'name', 'Test Flexi Cap Fund - Direct Growth',
                            'symbol', 'INF000A01073', 'quantity', p_qty, 'price', p_price, 'cost_price', p_cost) $$;
create function pg_temp.sync(p_day int, p_cash text, p_read text[], p_positions jsonb) returns jsonb language sql as $$
  select public.import_zerodha_data(pg_temp.v('p'), jsonb_build_object(
    'user_id', 'zx7301', 'fetched_at', pg_temp.at(p_day), 'cash', p_cash,
    'segments_read', to_jsonb(p_read), 'positions', p_positions)) $$;
create function pg_temp.hold(p_isin text) returns text language sql as $$
  select holding_code from public.holdings where profile_code = pg_temp.v('p') and external_ref = p_isin $$;
create function pg_temp.flows(p_isin text) returns text language sql as $$
  select string_agg(kind || ' ' || amount, ', ' order by flow_date, created_at) from public.holding_flows
  where holding_code = pg_temp.hold(p_isin) and removed_at is null $$;
create function pg_temp.mark(p_isin text, p_day int) returns text language sql as $$
  select trim_scale(quantity) || ' @ ' || trim_scale(price) || ' = ' || market_value || ' (cost ' || trim_scale(cost_price)
         || ', ' || profit || ')' from public.broker_positions
  where account_code = pg_temp.v(case when p_isin like 'INF%' then 'coin' else 'acc' end)
    and isin = p_isin and as_of = pg_temp.d(p_day) $$;
create function pg_temp.snap(p_acc text, p_day int) returns text language sql as $$
  select cash || ' ' || positions_value || ' ' || total_value from public.broker_snapshots
  where account_code = pg_temp.v(p_acc) and as_of = pg_temp.d(p_day) $$;

-- ── setup: an owner, a stranger, and an INR rate ────────────────────────────
select pg_temp.set('today', public.dubai_date(now())::text);
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't73-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t73-' || left(pg_temp.v('uid'), 8), 'Zerodha'));
select throws_ok($$ select pg_temp.sync(-4, '1000', array['kite', 'coin'], '[]') $$,
                 '42501', null, 'members cannot import Zerodha data');
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select pg_temp.set('p2', public.create_profile('t73b-' || left(pg_temp.v('uid2'), 8), 'Stranger'));
reset role;
select set_config('request.jwt.claims', '', true);
select public.upsert_fx_rates('{"INR": 0.044}'::jsonb, 'test', pg_temp.d(-10));

select throws_ok($$ select public.import_zerodha_data(pg_temp.v('p'), '{"user_id": "x"}') $$, '22023', null,
                 'a Kite user id is required');
select throws_ok($$ select public.import_zerodha_data(pg_temp.v('p'),
                      '{"user_id": "ZX7301", "segments_read": ["kite", "fno"]}') $$, '22023', null,
                 'segments are kite and coin');
select throws_ok($$ select public.import_zerodha_data(pg_temp.v('p'),
                      '{"user_id": "ZX7301", "segments_read": ["kite"], "positions": [{"segment": "fno"}]}') $$, '22023', null,
                 'a position''s segment is kite or coin');

-- ── day 1: first sight ──────────────────────────────────────────────────────
select pg_temp.set('r1', pg_temp.sync(-4, '1000.00', array['kite', 'coin'],
  jsonb_build_array(pg_temp.kite('10', '2500', '2000'), pg_temp.coin('100.5', '50', '40')))::text);
select pg_temp.set('acc', (pg_temp.v('r1')::jsonb)->'accounts'->>'kite');
select pg_temp.set('coin', (pg_temp.v('r1')::jsonb)->'accounts'->>'coin');
select is((pg_temp.v('r1')::jsonb)->>'account_code', pg_temp.v('acc'), 'account_code is still Kite''s, for an older caller');
select isnt(pg_temp.v('acc'), pg_temp.v('coin'), 'Kite and Coin are two accounts');
select is((select bank_code || ' ' || kind || ' ' || currency || ' ' || product_name || ' ' || nickname from public.accounts
           where account_code = pg_temp.v('acc')),
          'KITE current INR Trading account Zerodha Kite', 'the Kite account is made: Zerodha Kite, current, INR, named');
select is((select bank_code || ' ' || kind || ' ' || currency || ' ' || product_name || ' ' || nickname from public.accounts
           where account_code = pg_temp.v('coin')),
          'COIN current INR Mutual funds Zerodha Coin', 'and the Coin account: Zerodha Coin');
select is((select string_agg(provider || ' ' || portfolio_ref || ' ' || last_status, ', ' order by portfolio_ref desc)
           from public.broker_connections where profile_code = pg_temp.v('p')),
          'zerodha ZX7301-KITE ok, zerodha ZX7301-COIN ok', 'each linked to the Kite user''s segment, upper-cased');
select is((select string_agg(bank_code || ' ' || name || ' ' || logo_path, ', ' order by bank_code) from public.banks
           where bank_code in ('KITE', 'COIN')),
          'COIN Zerodha Coin COIN.png, KITE Zerodha Kite KITE.png', 'each bank has its own name and logo');
select is((select string_agg(kind || ' ' || currency || ' ' || trim_scale(units) || ' ' || institution || ' '
                             || coalesce(symbol, '-'), ', ' order by external_ref)
           from public.holdings where profile_code = pg_temp.v('p')),
          'security INR 10 Zerodha Kite -, security INR 100.5 Zerodha Coin -',
          'a security per ISIN, units held, no symbol (the Yahoo job leaves it alone)');
select is(pg_temp.mark('INE000A01073', -4), '10 @ 2500 = 25000.00 (cost 2000, 5000.00)', 'the Kite mark: value and P&L');
select is(pg_temp.mark('INF000A01073', -4), '100.5 @ 50 = 5025.00 (cost 40, 1005.00)', 'the Coin mark');
select is((select product_type || ' ' || (account_code = pg_temp.v('coin')) from public.broker_positions
           where isin = 'INF000A01073' and as_of = pg_temp.d(-4)),
          'MUTUAL_FUND true', 'a Coin fund is a MUTUAL_FUND, marked on the Coin account');
select is((select count(*)::int from public.broker_positions where account_code = pg_temp.v('acc')), 1,
          'the Kite account holds only the share');
select is(pg_temp.flows('INE000A01073'), 'contribution 20000.00', 'first sight: a contribution at cost');
select is(pg_temp.flows('INF000A01073'), 'contribution 4020.00', 'for the fund too');
select is((select amount_aed from public.holding_flows where holding_code = pg_temp.hold('INE000A01073')),
          880.00::numeric(14,2), 'in AED at the INR rate');
select is((select balance from public.balance_checkpoints where account_code = pg_temp.v('acc')),
          1000.00::numeric(14,2), 'Funds cash is a broker checkpoint on Kite');
select is((select balance || ' ' || source from public.balance_checkpoints where account_code = pg_temp.v('coin')),
          '0.00 broker', 'Coin holds no cash: a 0 checkpoint');
select is(pg_temp.snap('acc', -4), '1000.00 25000.00 26000.00', 'Kite''s value for the day: cash + its positions');
select is(pg_temp.snap('coin', -4), '0.00 5025.00 5025.00', 'Coin''s: its funds');
select is((select unit_price::numeric from public.holding_valuations
           where holding_code = pg_temp.hold('INE000A01073') and as_of = pg_temp.d(-4)),
          2500::numeric, 'the holding''s unit price for the day');

-- Idempotent.
select pg_temp.sync(-4, '1000.00', array['kite', 'coin'],
  jsonb_build_array(pg_temp.kite('10', '2500', '2000'), pg_temp.coin('100.5', '50', '40')));
select is((select count(*)::int from public.holding_flows hf join public.holdings h using (holding_code)
           where h.profile_code = pg_temp.v('p')), 2, 'a re-run adds no flow');
select is((select count(*)::int from public.broker_positions where profile_code = pg_temp.v('p')), 2, 'nor a mark');
select is((select count(*)::int from public.balance_checkpoints where profile_code = pg_temp.v('p')), 2,
          'nor a checkpoint');
select is((select count(*)::int from public.broker_connections where profile_code = pg_temp.v('p')), 2,
          'nor a connection');

-- ── day 2: bought more of the share, redeemed some of the fund ─────────────
select pg_temp.sync(-3, '500.00', array['kite', 'coin'],
  jsonb_build_array(pg_temp.kite('15', '2600', '2100'), pg_temp.coin('80', '55', '40')));
select is(pg_temp.flows('INE000A01073'), 'contribution 20000.00, contribution 11500.00',
          'more units: the cost added (15 × 2,100 − 10 × 2,000)');
select is(pg_temp.flows('INF000A01073'), 'contribution 4020.00, withdrawal 1127.50',
          'fewer units: a withdrawal at the day''s price (20.5 × 55)');
select is((select units::numeric from public.holdings where holding_code = pg_temp.hold('INF000A01073')), 80::numeric,
          'units follow');

-- ── day 3: the share is sold; Coin could not be read ───────────────────────
select pg_temp.sync(-2, '39500.00', array['kite'], '[]');
select is((select status from public.holdings where holding_code = pg_temp.hold('INE000A01073')), 'closed',
          'a share no longer held is closed');
select is(pg_temp.flows('INE000A01073'), 'contribution 20000.00, contribution 11500.00, withdrawal 39000.00',
          'at its last price (15 × 2,600)');
select is((select status from public.holdings where holding_code = pg_temp.hold('INF000A01073')), 'active',
          'the fund stays: its segment was not read');
select is(pg_temp.mark('INF000A01073', -2), '80 @ 55 = 4400.00 (cost 40, 1200.00)', 'it keeps its last mark for the day');
select is(pg_temp.snap('coin', -2), '0.00 4400.00 4400.00', 'so Coin''s value for the day is whole');
select is(pg_temp.snap('acc', -2), '39500.00 0.00 39500.00', 'and Kite''s is its cash');

-- ── day 4: bought back ──────────────────────────────────────────────────────
select pg_temp.sync(-1, '26000.00', array['kite', 'coin'],
  jsonb_build_array(pg_temp.kite('5', '2700', '2700'), pg_temp.coin('80', '56', '40')));
select is((select status from public.holdings where holding_code = pg_temp.hold('INE000A01073')), 'active',
          'a share bought back is open again');
select is(pg_temp.flows('INE000A01073'),
          'contribution 20000.00, contribution 11500.00, withdrawal 39000.00, contribution 13500.00',
          'with a new contribution at cost, not a change from before the sale');
select is(pg_temp.flows('INF000A01073'), 'contribution 4020.00, withdrawal 1127.50', 'an unchanged fund has no flow');

-- A same-day re-run that no longer sees the buy takes its flow and mark back.
select pg_temp.sync(-1, '26000.00', array['kite', 'coin'], jsonb_build_array(pg_temp.coin('80', '56', '40')));
select is((select count(*)::int from public.broker_positions where account_code = pg_temp.v('acc') and as_of = pg_temp.d(-1)),
          0, 'today''s mark of a position no longer held goes');
select is((select count(*)::int from public.broker_positions where account_code = pg_temp.v('coin') and as_of = pg_temp.d(-1)),
          1, 'the other account''s stays');
select pg_temp.sync(-1, '26000.00', array['kite', 'coin'],
  jsonb_build_array(pg_temp.kite('5', '2700', '2700'), pg_temp.coin('80', '56', '40')));
select is(pg_temp.flows('INE000A01073'),
          'contribution 20000.00, contribution 11500.00, withdrawal 39000.00, contribution 13500.00',
          'and the buy seen again is one contribution');

-- Another ledger cannot claim the same Kite user.
select throws_ok($$ select public.import_zerodha_data(pg_temp.v('p2'), '{"user_id": "ZX7301", "segments_read": []}') $$,
                 '42501', null, 'a Kite user belongs to one ledger');
-- A user with no funds has no Coin account.
select pg_temp.set('r2', public.import_zerodha_data(pg_temp.v('p2'), jsonb_build_object(
  'user_id', 'ab1234', 'fetched_at', pg_temp.at(-1), 'cash', '10.00', 'segments_read', '["kite", "coin"]'::jsonb,
  'positions', jsonb_build_array(pg_temp.kite('1', '100', '90') || '{"isin": "INE111A01011"}')))::text);
select is((select string_agg(c.portfolio_ref || ' ' || a.bank_code, ', ') from public.broker_connections c
           join public.accounts a using (account_code) where c.profile_code = pg_temp.v('p2')),
          'AB1234-KITE KITE', 'no funds: only the Kite account');
select ok((pg_temp.v('r2')::jsonb)->'accounts'->'coin' = 'null'::jsonb, 'and no Coin account in the result');

-- ── the screens ─────────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('bp', public.broker_portfolio(pg_temp.v('p'), pg_temp.v('acc'))::text);
select pg_temp.set('bpc', public.broker_portfolio(pg_temp.v('p'), pg_temp.v('coin'))::text);
select pg_temp.set('bs', public.broker_accounts_summary(pg_temp.v('p'))::text);
reset role;
select is((pg_temp.v('bp')::jsonb)->>'basis', 'cost', 'Zerodha Kite is measured against cost');
select is((pg_temp.v('bpc')::jsonb)->>'basis', 'cost', 'so is Zerodha Coin');
select is((pg_temp.v('bp')::jsonb)->>'as_of', pg_temp.d(-1)::text, 'as of the last mark');
select is((pg_temp.v('bp')::jsonb)->>'invested', '13500.00', 'Kite invested: 5 × 2,700');
select is((pg_temp.v('bp')::jsonb)->>'net_deposits', '39500.00', 'put in: invested + cash');
select is((pg_temp.v('bp')::jsonb)->>'profit', '0.00', 'Kite''s profit is its unrealised P&L');
select is((pg_temp.v('bpc')::jsonb)->>'invested', '3200.00', 'Coin invested: 80 × 40');
select is((pg_temp.v('bpc')::jsonb)->>'positions_value', '4480.00', 'worth: 80 × 56');
select is((pg_temp.v('bpc')::jsonb)->>'cash', '0.00', 'no cash');
select is((pg_temp.v('bpc')::jsonb)->>'profit', '1280.00', 'Coin''s P&L');
select is((select string_agg(s->>'segment' || ' ' || (s->>'invested') || ' ' || (s->>'value') || ' ' || (s->>'profit')
                             || ' ' || coalesce(s->>'return_pct', '-'), ', ')
           from jsonb_array_elements((pg_temp.v('bp')::jsonb)->'segments') s),
          'kite 13500.00 13500.00 0.00 0.00', 'one segment per account: Kite');
select is((select string_agg(s->>'segment' || ' ' || (s->>'invested') || ' ' || (s->>'value') || ' ' || (s->>'profit')
                             || ' ' || coalesce(s->>'return_pct', '-'), ', ')
           from jsonb_array_elements((pg_temp.v('bpc')::jsonb)->'segments') s),
          'coin 3200.00 4480.00 1280.00 40.00', 'and Coin');
select is((select string_agg((x->>'segment') || ' ' || (x->'sell_now'->>'profit') || ' ' || (x->'sell_now'->>'return_pct'), ', ')
           from jsonb_array_elements((pg_temp.v('bpc')::jsonb)->'positions') x),
          'coin 1280.00 40.00', 'each position: its segment and its return on cost');
select is((select string_agg((d->>'as_of') || ' ' || coalesce(d->>'invested', '-') || ' ' || (d->>'total'), ', ')
           from jsonb_array_elements((pg_temp.v('bp')::jsonb)->'series') d),
          pg_temp.d(-4) || ' 20000.00 26000.00, ' || pg_temp.d(-3) || ' 31500.00 39500.00, '
            || pg_temp.d(-2) || ' - 39500.00, ' || pg_temp.d(-1) || ' 13500.00 39500.00',
          'Kite every day: invested against the total');
select is((select string_agg((d->>'as_of') || ' ' || (d->>'invested') || ' ' || (d->>'total'), ', ')
           from jsonb_array_elements((pg_temp.v('bpc')::jsonb)->'series') d),
          pg_temp.d(-4) || ' 4020.00 5025.00, ' || pg_temp.d(-3) || ' 3200.00 4400.00, '
            || pg_temp.d(-2) || ' 3200.00 4400.00, ' || pg_temp.d(-1) || ' 3200.00 4480.00',
          'Coin every day: invested against the total');
select is((pg_temp.v('bp')::jsonb)->'closed_total'->>'count', '0', 'nothing closed: the share is held again');
select is(pg_temp.v('bs')::jsonb, '[]'::jsonb,
          'Wealth''s broker summary leaves Kite and Coin out: they are India''s (75_india_mode)');

select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select public.broker_portfolio(pg_temp.v('p'), pg_temp.v('acc')) $$, '42501', null,
                 'a stranger cannot read the portfolio');
reset role;
select set_config('request.jwt.claims', '', true);

-- ── the job ─────────────────────────────────────────────────────────────────
select is((select count(*)::int from cron.job where jobname = 'ledger-zerodha-sync' and schedule = '0 18 * * 1-5'
             and command like '%invoke_edge(''zerodha-sync'')%'), 1, 'a weekday cron job calls the zerodha-sync function');
select public.record_broker_sync_error(pg_temp.v('p'), 'zerodha', 'Kite: TOTP refused');
select is((select string_agg(last_status || ' ' || last_error, ', ') from public.broker_connections
           where profile_code = pg_temp.v('p')),
          'error Kite: TOTP refused, error Kite: TOTP refused', 'a failed sync is kept for both accounts'' screens');

select * from finish();
rollback;

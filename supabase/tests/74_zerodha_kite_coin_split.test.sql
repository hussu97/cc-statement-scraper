-- Zerodha Kite and Coin as two accounts (20261028054048_zerodha_kite_coin_accounts): a Zerodha
-- account the old import made (bank ZRD, one connection for both segments) becomes the Kite
-- account, its funds' marks move to a new Coin account, and each day's value is split; a second run
-- changes nothing, and the next sync uses the two accounts. Dates are relative to today.
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
create function pg_temp.snap(p_acc text, p_day int) returns text language sql as $$
  select cash || ' ' || positions_value || ' ' || total_value from public.broker_snapshots
  where account_code = p_acc and as_of = pg_temp.d(p_day) $$;

-- ── setup: a ledger with the old single Zerodha account ─────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't74-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t74-' || left(pg_temp.v('uid'), 8), 'Zerodha'));
reset role;
select set_config('request.jwt.claims', '', true);
select public.upsert_fx_rates('{"INR": 0.044}'::jsonb, 'test', pg_temp.d(-10));

insert into public.accounts (profile_code, bank_code, kind, currency, product_name, nickname)
values (pg_temp.v('p'), 'ZRD', 'current', 'INR', 'Trading account', 'Zerodha')
returning pg_temp.set('acc', account_code);
insert into public.broker_connections (profile_code, account_code, provider, portfolio_ref)
values (pg_temp.v('p'), pg_temp.v('acc'), 'zerodha', 'ZX7302');
insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source)
values (pg_temp.v('p'), pg_temp.v('acc'), now() - interval '2 days', 1000, 'broker');
insert into public.holdings (profile_code, name, kind, currency, institution, units, external_ref)
values (pg_temp.v('p'), 'TESTCO', 'security', 'INR', 'Zerodha Kite', 10, 'INE000A01073')
returning pg_temp.set('share', holding_code);
insert into public.holdings (profile_code, name, kind, currency, institution, units, external_ref)
values (pg_temp.v('p'), 'Test Fund', 'security', 'INR', 'Zerodha Coin', 100, 'INF000A01073')
returning pg_temp.set('fund', holding_code);
insert into public.broker_positions (profile_code, account_code, holding_code, as_of, isin, name, product_type,
  quantity, price, price_in_pct, market_value, cost_price, profit, currency)
select pg_temp.v('p'), pg_temp.v('acc'), x.h, pg_temp.d(x.day), x.isin, x.name, x.pt, x.q, x.price, false,
       x.q * x.price, x.cost, x.q * (x.price - x.cost), 'INR'
from (values (pg_temp.v('share'), -2, 'INE000A01073', 'TESTCO', 'EQUITY', 10, 2500, 2000),
             (pg_temp.v('fund'), -2, 'INF000A01073', 'Test Fund', 'MUTUAL_FUND', 100, 50, 40),
             (pg_temp.v('share'), -1, 'INE000A01073', 'TESTCO', 'EQUITY', 10, 2600, 2000),
             (pg_temp.v('fund'), -1, 'INF000A01073', 'Test Fund', 'MUTUAL_FUND', 100, 51, 40))
  as x(h, day, isin, name, pt, q, price, cost);
insert into public.broker_snapshots (profile_code, account_code, as_of, currency, cash, positions_value, total_value)
values (pg_temp.v('p'), pg_temp.v('acc'), pg_temp.d(-2), 'INR', 1000, 30000, 31000),
       (pg_temp.v('p'), pg_temp.v('acc'), pg_temp.d(-1), 'INR', 1000, 31100, 32100);

-- ── the split ───────────────────────────────────────────────────────────────
select is(private.zerodha_split_single_accounts(), 1, 'one old connection is moved');
select is((select portfolio_ref from public.broker_connections where account_code = pg_temp.v('acc')), 'ZX7302-KITE',
          'it is the Kite connection now');
select is((select bank_code || ' ' || nickname from public.accounts where account_code = pg_temp.v('acc')),
          'KITE Zerodha Kite', 'its account is Zerodha Kite');
select pg_temp.set('coin', (select account_code from public.broker_connections where portfolio_ref = 'ZX7302-COIN'));
select is((select a.bank_code || ' ' || a.nickname || ' ' || a.profile_code from public.accounts a
           where a.account_code = pg_temp.v('coin')),
          'COIN Zerodha Coin ' || pg_temp.v('p'), 'the funds have a Zerodha Coin account in the same ledger');
select is((select string_agg(distinct product_type, ',') from public.broker_positions where account_code = pg_temp.v('acc')),
          'EQUITY', 'Kite keeps the share''s marks');
select is((select count(*)::int || ' ' || string_agg(distinct product_type, ',') from public.broker_positions
           where account_code = pg_temp.v('coin')),
          '2 MUTUAL_FUND', 'Coin has the fund''s marks');
select is(pg_temp.snap(pg_temp.v('acc'), -1), '1000.00 26000.00 27000.00', 'Kite''s value per day: cash + the share');
select is(pg_temp.snap(pg_temp.v('coin'), -2), '0.00 5000.00 5000.00', 'Coin''s: the fund');
select is(pg_temp.snap(pg_temp.v('coin'), -1), '0.00 5100.00 5100.00', 'every day');
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('coin')), 0.00::numeric(14,2),
          'Coin holds no cash');
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('acc')), 1000.00::numeric(14,2),
          'Kite keeps the cash');

-- Guarded: a second run moves nothing.
select is(private.zerodha_split_single_accounts(), 0, 'a second run is a no-op');
select is((select count(*)::int from public.broker_connections where profile_code = pg_temp.v('p')), 2, 'still two');

-- The next sync uses the two accounts.
select public.import_zerodha_data(pg_temp.v('p'), jsonb_build_object(
  'user_id', 'ZX7302', 'cash', '900.00', 'segments_read', '["kite", "coin"]'::jsonb,
  'positions', jsonb_build_array(
    jsonb_build_object('segment', 'kite', 'isin', 'INE000A01073', 'name', 'TESTCO', 'quantity', '10', 'price', '2700', 'cost_price', '2000'),
    jsonb_build_object('segment', 'coin', 'isin', 'INF000A01073', 'name', 'Test Fund', 'quantity', '100', 'price', '52', 'cost_price', '40'))));
select is((select count(*)::int from public.broker_connections where profile_code = pg_temp.v('p')), 2,
          'the sync makes no new connection');
select is(pg_temp.snap(pg_temp.v('acc'), 0), '900.00 27000.00 27900.00', 'today''s Kite value');
select is(pg_temp.snap(pg_temp.v('coin'), 0), '0.00 5200.00 5200.00', 'today''s Coin value');
select is((select count(*)::int from public.holding_flows where holding_code in (pg_temp.v('share'), pg_temp.v('fund'))), 0,
          'an unchanged position on its own account infers no flow');

select * from finish();
rollback;

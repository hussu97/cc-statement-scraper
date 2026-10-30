-- A share entered by hand is priced by the stock-prices job (20261030063508_manual_share_prices):
-- price_symbols lists an active security with a symbol and no broker behind it, from a week
-- before it was acquired, and its value follows the latest close. A broker-synced share, a
-- closed one and one without a symbol are not listed.
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

-- ── setup: a ledger with hand-entered shares and a broker-synced one ───────
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't79-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t79-' || left(pg_temp.v('uid'), 8), 'Shares'));
select pg_temp.set('manual', public.save_holding(pg_temp.v('p'), 'Hand-entered shares', p_kind => 'security',
  p_currency => 'USD', p_units => '12', p_symbol => 'tsta', p_acquired_on => pg_temp.d(-400)));
select pg_temp.set('nodate', public.save_holding(pg_temp.v('p'), 'Undated shares', p_kind => 'security',
  p_currency => 'USD', p_units => '5', p_symbol => 'TSTD'));
select pg_temp.set('nosym', public.save_holding(pg_temp.v('p'), 'Fund', p_kind => 'security', p_units => '10'));
select pg_temp.set('closed', public.save_holding(pg_temp.v('p'), 'Sold shares', p_kind => 'security',
  p_currency => 'USD', p_units => '1', p_symbol => 'TSTC', p_acquired_on => pg_temp.d(-30)));
reset role;
select set_config('request.jwt.claims', '', true);
update public.holdings set status = 'closed' where holding_code = pg_temp.v('closed');

insert into public.accounts (profile_code, bank_code, kind, currency, product_name, nickname)
values (pg_temp.v('p'), 'ZRD', 'current', 'USD', 'Trading account', 'Broker')
returning pg_temp.set('acc', account_code);
insert into public.holdings (profile_code, name, kind, currency, institution, units, symbol)
values (pg_temp.v('p'), 'Broker share', 'security', 'USD', 'Broker', 10, 'TSTB')
returning pg_temp.set('synced', holding_code);
insert into public.broker_positions (profile_code, account_code, holding_code, as_of, isin, name, product_type,
  quantity, price, price_in_pct, market_value, cost_price, profit, currency)
values (pg_temp.v('p'), pg_temp.v('acc'), pg_temp.v('synced'), pg_temp.d(-1), 'XS0000000018', 'Broker share', 'EQUITY',
        10, 50, false, 500, 40, 100, 'USD');

-- ── price_symbols ───────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
select is((select from_date from public.price_symbols(pg_temp.v('p')) where symbol = 'TSTA'), pg_temp.d(-407),
          'a hand-entered share is priced from a week before it was acquired');
select is((select from_date from public.price_symbols(null) where symbol = 'TSTA'), pg_temp.d(-407),
          'and by the daily run over every ledger');
select is((select from_date from public.price_symbols(pg_temp.v('p')) where symbol = 'TSTD'), pg_temp.d(-7),
          'one without an acquired date from a week before it was added');
select ok(not exists (select 1 from public.price_symbols(pg_temp.v('p')) where symbol = 'TSTB'),
          'a broker-synced share keeps its broker''s price');
select ok(not exists (select 1 from public.price_symbols(pg_temp.v('p')) where symbol = 'TSTC'),
          'a closed holding is not priced');
select is((select count(*)::int from public.price_symbols(pg_temp.v('p'))), 2, 'nothing else is listed');

-- ── its value follows the close ─────────────────────────────────────────────
select public.record_security_prices(jsonb_build_array(
  jsonb_build_object('symbol', 'TSTA', 'date', pg_temp.d(-3), 'close', '200.5'),
  jsonb_build_object('symbol', 'TSTA', 'date', pg_temp.d(-2), 'close', '210.25')));
select is((select first_date || ' ' || last_date from public.price_symbols(pg_temp.v('p')) where symbol = 'TSTA'),
          pg_temp.d(-3) || ' ' || pg_temp.d(-2), 'the stored closes are reported');
select is((select value || ' ' || value_as_of from private.holding_values(pg_temp.v('p'), now())
           where holding_code = pg_temp.v('manual')),
          '2523.00 ' || pg_temp.d(-2), 'the value is units × the latest close');

select * from finish();
rollback;

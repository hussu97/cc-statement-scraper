-- India mode (20261028061444_india_mode_and_investment_periods): a ledger with a Swissquote
-- account (Wealth) and Zerodha Kite and Coin (India). Wealth's valuation, net worth, cash,
-- returns and broker summary leave India out; the holdings marked on Kite or Coin are India's.
-- india_overview totals the India accounts: value, invested, cash, P&L, the day's move against
-- each position's previous mark, growth over a period and the value per day. holding_returns
-- takes 30d and 90d. The broker summary gains the day's move. Dates are relative to today.
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
create function pg_temp.pos(p_segment text, p_isin text, p_qty text, p_price text, p_cost text) returns jsonb language sql as $$
  select jsonb_build_object('segment', p_segment, 'isin', p_isin, 'name', 'T75 ' || p_isin, 'symbol', 'T75' || right(p_isin, 3),
                            'quantity', p_qty, 'price', p_price, 'cost_price', p_cost) $$;
create function pg_temp.zerodha(p_day int, p_cash text, p_positions jsonb) returns jsonb language sql as $$
  select public.import_zerodha_data(pg_temp.v('p'), jsonb_build_object(
    'user_id', 'zx7501', 'fetched_at', pg_temp.at(p_day), 'cash', p_cash,
    'segments_read', '["kite", "coin"]'::jsonb, 'positions', p_positions)) $$;
create function pg_temp.tx(p_id text, p_day int, p_action text, p_label text, p_net text, p_isin text default null,
                           p_symbol text default null, p_qty text default null, p_price text default null)
returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'booked_at', pg_temp.at(p_day), 'action', p_action, 'label', p_label,
    'reversal', false, 'isin', p_isin, 'symbol', p_symbol, 'name', p_symbol, 'quantity', p_qty, 'unit_price', p_price,
    'net_amount', p_net, 'currency', 'USD', 'commission', '0', 'contract_ref', 'C' || p_id) $$;
create function pg_temp.swissquote(p_day int, p_price text) returns jsonb language sql as $$
  select public.import_broker_data(pg_temp.v('p'), 'swissquote', jsonb_build_object(
    'portfolio_ref', 'T75PORTFOLIO', 'currency', 'USD', 'account_number', '123456751',
    'iban', 'CH2700000000000000751', 'fetched_at', pg_temp.at(p_day), 'cash', '9000.00',
    'opening', jsonb_build_object('as_of', pg_temp.at(-20), 'balance', '0'),
    'securities', '[]'::jsonb,
    'transactions', jsonb_build_array(pg_temp.tx('7501', -10, 'G', 'Payment', '10000.00'),
                                      pg_temp.tx('7502', -9, 'B', 'Buy', '-1000.00', 'US0000000751', 'BBB', '10', '100')),
    'positions', jsonb_build_array(jsonb_build_object('isin', 'US0000000751', 'name', 'BBB ORD', 'symbol', 'BBB',
      'product_type', 'SHARE', 'quantity', '10', 'price', p_price, 'price_in_pct', false,
      'value', (10 * p_price::numeric)::numeric(14,2)::text, 'cost_price', '100', 'currency', 'USD')),
    'snapshots', '[]'::jsonb)) $$;

-- ── setup: an owner with Swissquote, Kite and Coin; a stranger ──────────────
select pg_temp.set('today', public.dubai_date(now())::text);
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't75-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t75-' || left(pg_temp.v('uid'), 8), 'India'));
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select pg_temp.set('p2', public.create_profile('t75b-' || left(pg_temp.v('uid2'), 8), 'Stranger'));
reset role;
select set_config('request.jwt.claims', '', true);
select public.upsert_fx_rates('{"INR": 0.044}'::jsonb, 'test', pg_temp.d(-60));

select pg_temp.set('sq', (pg_temp.swissquote(-1, '100'))->>'account_code');
select pg_temp.swissquote(0, '110');

-- Day −40 (before 30 days): share A and fund F. Day −2: A up, share B bought (500 put in), F up.
-- Day −1: A up again, B down, F up.
select pg_temp.set('z', pg_temp.zerodha(-40, '1000.00', jsonb_build_array(
  pg_temp.pos('kite', 'INE000A01751', '10', '100', '90'), pg_temp.pos('coin', 'INF000A01751', '100', '10', '9')))::text);
select pg_temp.set('kite', (pg_temp.v('z')::jsonb)->'accounts'->>'kite');
select pg_temp.set('coin', (pg_temp.v('z')::jsonb)->'accounts'->>'coin');
select pg_temp.zerodha(-2, '500.00', jsonb_build_array(
  pg_temp.pos('kite', 'INE000A01751', '10', '110', '90'), pg_temp.pos('kite', 'INE000B01752', '5', '200', '200'),
  pg_temp.pos('coin', 'INF000A01751', '100', '11', '9')));
select pg_temp.zerodha(-1, '500.00', jsonb_build_array(
  pg_temp.pos('kite', 'INE000A01751', '10', '120', '90'), pg_temp.pos('kite', 'INE000B01752', '5', '190', '200'),
  pg_temp.pos('coin', 'INF000A01751', '100', '11.5', '9')));

-- ── the India scope ─────────────────────────────────────────────────────────
select ok(private.is_india_bank('KITE') and private.is_india_bank('COIN') and private.is_india_bank('ZRD')
          and not private.is_india_bank('SQB') and not private.is_india_bank(null), 'India banks: KITE, COIN, ZRD');
select is((select string_agg(external_ref || ' ' || portfolio, ', ' order by external_ref) from public.holdings
           where profile_code = pg_temp.v('p')),
          'INE000A01751 india, INE000B01752 india, INF000A01751 india, US0000000751 wealth',
          'a holding marked on Kite or Coin is India''s; the Swissquote share stays Wealth''s');

-- ── Wealth leaves India out ─────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('hv', public.holdings_valuation(pg_temp.v('p'))::text);
select pg_temp.set('nw', public.net_worth(pg_temp.v('p'))::text);
select pg_temp.set('cp', public.cash_position(pg_temp.v('p'))::text);
select pg_temp.set('bs', public.broker_accounts_summary(pg_temp.v('p'))::text);
select pg_temp.set('hs', public.holdings_value_series(pg_temp.v('p'), pg_temp.d(-3), pg_temp.d(0))::text);
select pg_temp.set('r30', public.holding_returns(pg_temp.v('p'), '30d')::text);
select pg_temp.set('r90', public.holding_returns(pg_temp.v('p'), '90d')::text);
select pg_temp.set('io', public.india_overview(pg_temp.v('p'), '30d')::text);
select pg_temp.set('io90', public.india_overview(pg_temp.v('p'), '90d')::text);
select pg_temp.set('iod', public.india_overview(pg_temp.v('p'))::text);
reset role;

select is((pg_temp.v('hv')::jsonb)->>'holdings_count', '1', 'Investments: only the Swissquote share');
select is((pg_temp.v('hv')::jsonb)->>'value_aed', '4039.75', '… worth 10 × 110 USD');
select is((select count(*)::int from private.holding_values(pg_temp.v('p'), now()) v
           join public.holdings h using (holding_code) where h.portfolio = 'india'), 0, 'no India holding is priced for Wealth');
select is((pg_temp.v('nw')::jsonb)->>'holdings_count', '1', 'net worth counts the share only');
select is((pg_temp.v('nw')::jsonb)->>'cash_aed', '33052.50', 'and Swissquote''s cash, not Kite''s');
select is((select string_agg(x->>'class', ',' order by x->>'class') from jsonb_array_elements((pg_temp.v('nw')::jsonb)->'allocation') x),
          'cash,security', 'allocation: Wealth''s classes');
select is((select string_agg(x->>'account_code', ',') from jsonb_array_elements((pg_temp.v('cp')::jsonb)->'accounts') x),
          pg_temp.v('sq'), 'cash and the Accounts list: Swissquote only');
select is((pg_temp.v('cp')::jsonb)->>'total_aed', '33052.50', 'the cash total leaves Kite out');
select is((select string_agg(x->>'value_aed', ',' order by x->>'date') from jsonb_array_elements(pg_temp.v('hs')::jsonb) x
           where (x->>'date')::date >= pg_temp.d(-1)),
          '3672.50,4039.75', 'the value per day is the share''s alone');
select is((select string_agg(x->>'name', ',') from jsonb_array_elements((pg_temp.v('r30')::jsonb)->'holdings') x),
          'BBB ORD', 'returns: Wealth''s holdings only');

-- ── holding_returns: 30 and 90 days ─────────────────────────────────────────
select is((pg_temp.v('r30')::jsonb)->>'from', pg_temp.d(-30)::text, '30d starts 30 days ago');
select is((pg_temp.v('r90')::jsonb)->>'from', pg_temp.d(-90)::text, '90d starts 90 days ago');
select is((pg_temp.v('r30')::jsonb)->>'period', '30d', 'and says which period');
select throws_ok($$ select public.holding_returns(pg_temp.v('p'), 'week') $$, '22023',
                 'period must be all, ytd, 12m, 30d or 90d', 'any other period is refused');

-- ── broker summary: India out, the day's move in ────────────────────────────
select is(jsonb_array_length(pg_temp.v('bs')::jsonb), 1, 'the broker summary is Swissquote''s line alone');
select is((pg_temp.v('bs')::jsonb)->0->>'change_24h', '100.00', 'the day''s move: 10 × (110 − 100)');
select is((pg_temp.v('bs')::jsonb)->0->>'change_24h_aed', '367.25', '… in AED');
select is((pg_temp.v('bs')::jsonb)->0->>'change_24h_pct', '10.00', '… against yesterday''s value');
select is((pg_temp.v('bs')::jsonb)->0->>'profit_aed',
          private.to_aed(((pg_temp.v('bs')::jsonb)->0->>'profit')::numeric, 'USD')::text, 'the profit in AED');

-- ── india_overview ──────────────────────────────────────────────────────────
select is((pg_temp.v('io')::jsonb)->>'available', 'true', 'India is available: the ledger has an India account');
select is((pg_temp.v('io')::jsonb)->>'currency', 'INR', 'in rupees');
select is((pg_temp.v('iod')::jsonb)->>'period', '90d', 'the default period is 90 days');
select is((pg_temp.v('io')::jsonb)->>'from', pg_temp.d(-30)::text, 'from as in holding_returns');
select is((pg_temp.v('io')::jsonb)->>'to', pg_temp.d(0)::text, 'to today');
select is((select string_agg(x.key || '=' || x.value, ' ' order by x.key)
           from jsonb_each_text((pg_temp.v('io')::jsonb)->'total') x
           where x.key in ('value', 'value_aed', 'invested', 'cash', 'pnl', 'pnl_pct', 'change_24h', 'change_24h_aed',
                           'change_24h_pct', 'positions')),
          'cash=500.00 change_24h=100.00 change_24h_aed=4.40 change_24h_pct=3.13 invested=2800.00 pnl=500.00 '
          || 'pnl_pct=17.86 positions=3 value=3800.00 value_aed=167.20',
          'the total: cash + positions, cost, P&L and the day''s move (A +100, B −50, F +50 over 3,200)');
select ok((pg_temp.v('io')::jsonb)->'total'->>'last_synced_at' is not null, 'with the last sync');
select is((select string_agg(x->>'bank_code' || ' ' || (x->>'segment') || ' ' || (x->>'name') || ' ' || (x->>'value') || ' '
                             || (x->>'invested') || ' ' || (x->>'cash') || ' ' || (x->>'pnl') || ' ' || (x->>'pnl_pct') || ' '
                             || (x->>'change_24h') || ' ' || (x->>'change_24h_pct') || ' ' || (x->>'positions') || ' '
                             || (x->>'sync_status') || ' ' || (x->>'value_aed'), ', ' order by ord)
           from jsonb_array_elements((pg_temp.v('io')::jsonb)->'accounts') with ordinality a(x, ord)),
          'KITE kite Zerodha Kite 2650.00 1900.00 500.00 250.00 13.16 50.00 2.38 2 ok 116.60, '
          || 'COIN coin Zerodha Coin 1150.00 900.00 0.00 250.00 27.78 50.00 4.55 1 ok 50.60',
          'per account, Kite first, then Coin');
select is((select string_agg(x.key || '=' || coalesce(x.value, '-'), ' ' order by x.key)
           from jsonb_each_text((pg_temp.v('io')::jsonb)->'total') x where x.key like 'period%'),
          'period_added=500.00 period_end_value=3800.00 period_growth=300.00 period_growth_pct=8.57 period_start_value=3000.00',
          '30 days: from 3,000 to 3,800, 500 put in (B at cost less the cash it took), 300 of growth (A +200, B −50, F +150)');
select is((select string_agg((x->>'date') || ' ' || (x->>'value') || ' ' || (x->>'invested'), ', ' order by x->>'date')
           from jsonb_array_elements((pg_temp.v('io')::jsonb)->'series') x),
          pg_temp.d(-2) || ' 3700.00 2800.00, ' || pg_temp.d(-1) || ' 3800.00 2800.00', 'the value per day in the period');
select is((select string_agg(x.key || '=' || coalesce(x.value, '-'), ' ' order by x.key)
           from jsonb_each_text((pg_temp.v('io90')::jsonb)->'total') x where x.key like 'period%'),
          'period_added=- period_end_value=3800.00 period_growth=- period_growth_pct=- period_start_value=-',
          '90 days: the first sync is inside it, so the start (and growth) is unknown, not 0');
select is((select string_agg((x->>'date') || ' ' || (x->>'value') || ' ' || (x->>'invested'), ', ' order by x->>'date')
           from jsonb_array_elements((pg_temp.v('io90')::jsonb)->'series') x),
          pg_temp.d(-40) || ' 3000.00 1800.00, ' || pg_temp.d(-2) || ' 3700.00 2800.00, ' || pg_temp.d(-1) || ' 3800.00 2800.00',
          'each day with a snapshot');

-- An account opened inside the period after the data began starts at 0, its opening added: the
-- legacy combined account (ZRD, segment kite) with 100 of cash from day −5.
insert into public.accounts (profile_code, bank_code, kind, currency, product_name, nickname)
values (pg_temp.v('p'), 'ZRD', 'current', 'INR', 'Trading account', 'Zerodha')
returning pg_temp.set('zrd', account_code);
insert into public.broker_snapshots (profile_code, account_code, as_of, currency, cash, positions_value, total_value)
values (pg_temp.v('p'), pg_temp.v('zrd'), pg_temp.d(-5), 'INR', 100, 0, 100);
select pg_temp.set('io3', public.india_overview(pg_temp.v('p'), '30d')::text);
select is((select string_agg(x->>'bank_code' || ' ' || (x->>'segment'), ', ' order by ord)
           from jsonb_array_elements((pg_temp.v('io3')::jsonb)->'accounts') with ordinality a(x, ord)),
          'KITE kite, COIN coin, ZRD kite', 'the legacy account comes last, as Kite (it holds the cash)');
select is((select string_agg(x.key || '=' || coalesce(x.value, '-'), ' ' order by x.key)
           from jsonb_each_text((pg_temp.v('io3')::jsonb)->'total') x where x.key like 'period%'),
          'period_added=600.00 period_end_value=3900.00 period_growth=300.00 period_growth_pct=8.33 period_start_value=3000.00',
          'it starts at 0 and its 100 is added, not growth');
delete from public.broker_snapshots where account_code = pg_temp.v('zrd');
update public.accounts set status = 'closed' where account_code = pg_temp.v('zrd');

-- No INR rate: the AED figures are unknown, never 0.
delete from public.fx_rates where currency = 'INR';
select pg_temp.set('io4', public.india_overview(pg_temp.v('p'), '30d')::text);
select is((pg_temp.v('io4')::jsonb)->'total'->>'value_aed', null, 'no INR rate: the total in AED is unknown');
select is((pg_temp.v('io4')::jsonb)->'total'->>'change_24h_aed', null, 'and so is the day''s move in AED');
select is((select count(*)::int from jsonb_array_elements((pg_temp.v('io4')::jsonb)->'accounts') x
           where x->>'value_aed' is not null), 0, 'and each account''s');
select is((pg_temp.v('io4')::jsonb)->'total'->>'value', '3800.00', 'the INR total stands');
select public.upsert_fx_rates('{"INR": 0.044}'::jsonb, 'test', pg_temp.d(-60));

-- Coin on a day only Kite synced: Coin's last snapshot is carried.
delete from public.broker_snapshots where account_code = pg_temp.v('coin') and as_of = pg_temp.d(-1);
select is((select x->>'value' from jsonb_array_elements(public.india_overview(pg_temp.v('p'), '30d')->'series') x
           where x->>'date' = pg_temp.d(-1)::text), '3750.00', 'an account''s last snapshot is carried forward');

select throws_ok($$ select public.india_overview(pg_temp.v('p'), 'all') $$, '22023',
                 'period must be 30d, 90d, ytd or 12m', 'India''s periods are 30d, 90d, ytd and 12m');

-- No India account: not available, nothing to show.
select pg_temp.as_user('uid2');
set local role authenticated;
select pg_temp.set('io2', public.india_overview(pg_temp.v('p2'), '30d')::text);
select throws_ok($$ select public.india_overview(pg_temp.v('p'), '30d') $$, '42501', null,
                 'a stranger cannot read India');
reset role;
select set_config('request.jwt.claims', '', true);
select is((pg_temp.v('io2')::jsonb)->>'available', 'false', 'a ledger without an India account: not available');
select is((pg_temp.v('io2')::jsonb)->'accounts', '[]'::jsonb, 'no accounts');
select is((pg_temp.v('io2')::jsonb)->'series', '[]'::jsonb, 'no series');
select is((pg_temp.v('io2')::jsonb)->'total'->>'value', '0.00', 'a zero total');
select is((pg_temp.v('io2')::jsonb)->'total'->>'pnl_pct', null, 'and no percentage');
select is((pg_temp.v('io2')::jsonb)->'total'->>'period_start_value', null, 'no start value');
select is((pg_temp.v('io2')::jsonb)->'total'->>'period_end_value', null, 'nor an end');
select is((pg_temp.v('io2')::jsonb)->'total'->>'period_growth', null, 'nor growth');

-- Backfill and trigger: a position moved onto an India account makes its holding India's.
insert into public.holdings (profile_code, name, kind, currency, units, external_ref)
values (pg_temp.v('p'), 'Moved', 'security', 'INR', 1, 'INE000C01753') returning pg_temp.set('moved', holding_code);
insert into public.broker_positions (profile_code, account_code, holding_code, as_of, isin, name, product_type,
  quantity, price, price_in_pct, market_value, cost_price, profit, currency)
values (pg_temp.v('p'), pg_temp.v('sq'), pg_temp.v('moved'), pg_temp.d(-5), 'INE000C01753', 'Moved', 'EQUITY',
        1, 10, false, 10, 10, 0, 'INR');
select is((select portfolio from public.holdings where holding_code = pg_temp.v('moved')), 'wealth',
          'marked on a Wealth account: Wealth''s');
update public.broker_positions set account_code = pg_temp.v('kite') where holding_code = pg_temp.v('moved');
select is((select portfolio from public.holdings where holding_code = pg_temp.v('moved')), 'india',
          'moved onto Kite: India''s');

select * from finish();
rollback;

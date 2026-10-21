-- Gold and silver (20261021070429_metal_prices_and_holdings): record_metal_prices, holdings
-- and their RPCs, holdings_valuation (value, gain, 24-hour change), the series, and net worth
-- with metals.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;

-- ── setup: an owner, a viewer, a stranger ───────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('viewer', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't66-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('viewer'), pg_temp.v('uid2')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t66-' || left(pg_temp.v('uid'), 8), 'Metals'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.profile_members (profile_code, user_id, role) values (pg_temp.v('p'), pg_temp.v('viewer')::uuid, 'viewer');

-- The local stack may hold real prices; start from none.
delete from public.metal_prices;

select is((select count(*)::int from cron.job where jobname = 'ledger-metal-prices' and schedule = '7 */6 * * *'
             and command like '%invoke_edge(''metal-prices'')%'), 1, 'a 6-hourly cron job calls the metal-prices function');

-- ── record_metal_prices ─────────────────────────────────────────────────────
-- Yesterday-ish (60 hours ago) and now.
select pg_temp.set('old', (now() - interval '60 hours')::text);
select is(public.record_metal_prices(jsonb_build_array(
  jsonb_build_object('quote', 'gold_24k', 'aed_per_gram', '496.00', 'source', 'dubaicityofgold.com', 'as_of', pg_temp.v('old')),
  jsonb_build_object('quote', 'gold_22k', 'aed_per_gram', '459.25', 'source', 'dubaicityofgold.com', 'as_of', pg_temp.v('old')),
  jsonb_build_object('quote', 'silver_spot', 'usd_per_oz', '57.34', 'source', 'gold-api.com', 'as_of', pg_temp.v('old')),
  jsonb_build_object('quote', 'silver_retail', 'aed_per_kg', '7,960'::text, 'source', 'khaleejtimes.com', 'as_of', pg_temp.v('old'))
))->'stored', '["gold_24k", "gold_22k", "silver_spot"]'::jsonb, 'three quotes stored; a per-kilo price with a comma is refused');
select is(public.record_metal_prices(jsonb_build_array(
  jsonb_build_object('quote', 'silver_retail', 'aed_per_kg', '7960', 'source', 'khaleejtimes.com', 'as_of', pg_temp.v('old'))
))->'stored', '["silver_retail"]'::jsonb, 'a per-kilo price');
select is((select aed_per_gram from public.metal_prices where quote = 'silver_retail'), 7.96::numeric, 'kilo ÷ 1000');
select is((select aed_per_gram from public.metal_prices where quote = 'silver_spot'),
          round(57.34 * 3.6725 / 31.1034768, 6), 'spot USD/oz becomes AED/g at the peg and the troy ounce');
select results_eq(
  $$ select r->>'quote', r->>'reason' like 'more than 50%%' from jsonb_array_elements(public.record_metal_prices(jsonb_build_array(
       jsonb_build_object('quote', 'gold_24k', 'aed_per_gram', '500.00', 'source', 'dubaicityofgold.com'),
       jsonb_build_object('quote', 'silver_retail', 'aed_per_kg', '8200', 'source', 'khaleejtimes.com'),
       jsonb_build_object('quote', 'gold_22k', 'aed_per_gram', '4592.50', 'source', 'dubaicityofgold.com'),
       jsonb_build_object('quote', 'platinum', 'aed_per_gram', '100', 'source', 'x')))->'rejected') r $$,
  $$ values ('gold_22k'::text, true), ('platinum', false) $$,
  'a tenfold misread and an unknown quote are refused; the rest are stored');
select pg_temp.as_user('uid');
set local role authenticated;
select throws_ok($$ select public.record_metal_prices('[]'::jsonb) $$, '42501', null, 'only the service role records prices');
select is((select count(*)::int from public.metal_prices), 6, 'signed-in users read prices');
select is((select x->>'aed_per_gram' from jsonb_array_elements(public.metal_price_series('gold_24k',
             public.dubai_date(now()), public.dubai_date(now()))) x), '500.000000', 'metal_price_series: today''s last price');
select is((select x->>'aed_per_gram' from jsonb_array_elements(public.metal_price_series('gold_24k',
             public.dubai_date(now()) - 4, public.dubai_date(now()) - 4)) x), null, 'null before the first price');

-- ── holdings ────────────────────────────────────────────────────────────────
select pg_temp.set('bar', public.save_holding(pg_temp.v('p'), '1 kg bar', 'gold', '1000', p_cost_aed => '400000.00'));
select pg_temp.set('coins', public.save_holding(pg_temp.v('p'), 'Coins', 'gold', '200', p_karat => 22));
select pg_temp.set('silver', public.save_holding(pg_temp.v('p'), 'Silver bars', 'silver', '8000', p_cost_aed => '40000'));
select pg_temp.set('tt', public.save_holding(pg_temp.v('p'), 'TT bar', 'gold', '116.64', p_fineness => 9950));
select results_eq(
  $$ select name, karat, fineness, purity from public.holdings where profile_code = pg_temp.v('p') order by name $$,
  $$ values ('1 kg bar'::text, 24, 9999, null::numeric), ('Coins', 22, null, null), ('Silver bars', null, null, 0.9990),
            ('TT bar', 24, 9950, null) $$,
  'gold defaults to 24K 999.9, silver to 999');
select throws_ok($$ select public.save_holding(pg_temp.v('p'), 'Bad', 'gold', '1', p_karat => 22, p_fineness => 9950) $$,
                 '22023', null, 'fineness is for 24K only');
select results_eq(
  $$ select name, form from public.holdings where profile_code = pg_temp.v('p') order by name $$,
  $$ values ('1 kg bar'::text, 'bar'::text), ('Coins', 'jewellery'), ('Silver bars', 'bar'), ('TT bar', 'bar') $$,
  'form defaults: a 24K or silver holding is a bar, gold below 24K is jewellery');
select throws_ok($$ select public.save_holding(pg_temp.v('p'), 'Bad', 'silver', '1', p_form => 'jewellery') $$,
                 '22023', null, 'no silver jewellery');
select public.save_holding(pg_temp.v('p'), 'Coins', 'gold', '200', p_karat => 22, p_form => 'coin',
                           p_holding_code => pg_temp.v('coins'));
select throws_ok($$ select public.save_holding(pg_temp.v('p'), 'Bad', 'gold', '0') $$, '22023', null, 'grams must be above 0');
select throws_ok($$ select public.save_holding(pg_temp.v('p'), 'Bad', 'platinum', '1') $$, '22023', null, 'gold or silver only');
reset role;

select pg_temp.as_user('viewer');
set local role authenticated;
select throws_ok($$ select public.save_holding(pg_temp.v('p'), 'Viewer', 'gold', '1') $$, '42501', null, 'a viewer cannot add');
select is((select count(*)::int from public.holdings where profile_code = pg_temp.v('p')), 4, 'a viewer reads the holdings');
reset role;

-- ── valuation ───────────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
-- Silver at the Dubai retail rate (8.20/g now, 7.96/g 60 hours ago); a 995 bar at 99.51% of 24K.
select pg_temp.set('silver_value', '65600.00');
select pg_temp.set('silver_prev', '63680.00');
select pg_temp.set('tt_value', round(116.64 * 0.9951 * 500, 2)::text);
select results_eq(
  $$ select h->>'name', h->>'value_aed', h->>'gain_aed', h->>'gain_pct', h->>'change_24h_aed', h->>'quote'
     from jsonb_array_elements(public.holdings_valuation(pg_temp.v('p'))->'holdings') h order by h->>'name' $$,
  $$ values ('1 kg bar'::text, '500000.00'::text, '100000.00'::text, '25.00'::text, '4000.00'::text, 'gold_24k'::text),
            ('Coins', '91850.00', null, null, '0.00', 'gold_22k'),
            ('Silver bars', pg_temp.v('silver_value'), (pg_temp.v('silver_value')::numeric - 40000)::numeric(14,2)::text,
             round((pg_temp.v('silver_value')::numeric - 40000) / 40000 * 100, 2)::text,
             (pg_temp.v('silver_value')::numeric - pg_temp.v('silver_prev')::numeric)::numeric(14,2)::text, 'silver_retail'),
            ('TT bar', pg_temp.v('tt_value'), null, null, round(116.64 * 0.9951 * 4, 2)::text, 'gold_24k') $$,
  'each holding: value at its rate, gain vs cost, 24-hour change');
select results_eq(
  $$ select h->>'name', h->>'form', h->>'image_path'
     from jsonb_array_elements(public.holdings_valuation(pg_temp.v('p'))->'holdings') h order by h->>'name' $$,
  $$ values ('1 kg bar'::text, 'bar'::text, 'gold-bar.jpg'::text), ('Coins', 'coin', 'gold-coin.jpg'),
            ('Silver bars', 'bar', 'silver-bar.jpg'), ('TT bar', 'bar', 'gold-bar.jpg') $$,
  'each holding names its image in the investment-images bucket');
select results_eq(
  $$ select v->>'value_aed', v->>'cost_aed', (v->>'complete')::boolean, (v->>'costs_complete')::boolean,
            (v->'prices'->'gold_24k'->>'change_24h_pct')
     from (select public.holdings_valuation(pg_temp.v('p')) v) x $$,
  $$ values ((591850.00 + pg_temp.v('silver_value')::numeric + pg_temp.v('tt_value')::numeric)::numeric(14,2)::text, '440000.00'::text, true, false, '0.81'::text) $$,
  'totals; cost counts the holdings that have one; 24K moved 0.81% in 24 hours');

select is((public.net_worth(pg_temp.v('p'))->>'holdings_aed'),
          (591850.00 + pg_temp.v('silver_value')::numeric + pg_temp.v('tt_value')::numeric)::numeric(14,2)::text, 'net worth counts the metals');
select is((public.net_worth(pg_temp.v('p'))->>'net_aed'),
          (591850.00 + pg_temp.v('silver_value')::numeric + pg_temp.v('tt_value')::numeric)::numeric(14,2)::text, 'net = cash 0 + metals − owed 0');
select results_eq(
  $$ select x->>'date', x->>'value_aed' from jsonb_array_elements(public.holdings_value_series(pg_temp.v('p'),
       public.dubai_date(now()) - 4, public.dubai_date(now()))) x where x->>'date' in
       ((public.dubai_date(now()) - 4)::text, public.dubai_date(now())::text) order by 1 $$,
  $$ values ((public.dubai_date(now()) - 4)::text, null::text),
            (public.dubai_date(now())::text, (591850.00 + pg_temp.v('silver_value')::numeric + pg_temp.v('tt_value')::numeric)::numeric(14,2)::text) $$,
  'value series: unknown before the first price, today''s value at the end');
select public.close_holding(pg_temp.v('p'), pg_temp.v('coins'));
select is((public.holdings_valuation(pg_temp.v('p'))->>'holdings_count')::int, 3, 'a closed holding stops counting');
select throws_ok($$ select public.close_holding(pg_temp.v('p'), pg_temp.v('coins')) $$, 'P0002', null, 'and cannot be closed twice');
reset role;
select set_config('request.jwt.claims', '', true);

select private.snapshot_net_worth(pg_temp.v('p'));
select is((select holdings_aed from public.net_worth_snapshots where profile_code = pg_temp.v('p')),
          (500000.00 + pg_temp.v('silver_value')::numeric + pg_temp.v('tt_value')::numeric)::numeric(14,2), 'the nightly snapshot records the metals');

select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select public.holdings_valuation(pg_temp.v('p')) $$, '42501', null, 'a stranger cannot value the holdings');
select is((select count(*)::int from public.holdings where profile_code = pg_temp.v('p')), 0, 'nor read them');
reset role;

select is((select public from storage.buckets where id = 'investment-images'), true, 'the image bucket is public');

select * from finish();
rollback;

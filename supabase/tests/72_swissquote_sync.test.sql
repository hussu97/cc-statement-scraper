-- Swissquote sync (20261027165732_swissquote_sync): import_broker_data makes the cash account
-- and its transactions from the broker's rows (deposits, buys, coupons, interest and its
-- reversal, fees, dividends, a redemption), the holdings and their flows, the marks, the cash
-- checkpoint and the daily values; it is idempotent. broker_portfolio serves the screen. A note
-- entered for a synced position adopts its holding, settles against the broker's rows, ignores
-- a coupon paid before it was bought, and cancelling it leaves the position. Dates are relative
-- to today.
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
  select to_char(((pg_temp.d(p_offset) + time '12:00') at time zone 'Asia/Dubai') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
create function pg_temp.tx(p_id text, p_day int, p_action text, p_label text, p_net text, p_isin text default null,
                           p_symbol text default null, p_qty text default null, p_price text default null,
                           p_reversal boolean default false)
returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'booked_at', pg_temp.at(p_day), 'action', p_action, 'label', p_label,
    'reversal', p_reversal, 'isin', p_isin, 'symbol', p_symbol, 'name', p_symbol, 'quantity', p_qty, 'unit_price', p_price,
    'net_amount', p_net, 'currency', 'USD', 'commission', '0', 'contract_ref', 'C' || p_id) $$;
create function pg_temp.txs() returns jsonb language sql as $$
  select jsonb_build_array(
    pg_temp.tx('1001', -180, 'G', 'Payment', '10000.00'),
    pg_temp.tx('1002', -170, 'B', 'Buy', '-9550.00', 'XS0000000072', 'TEST NOTE 72', '10000', '0.95'),
    pg_temp.tx('1003', -160, 'B', 'Buy', '-1005.00', 'US0000000072', 'AAA', '10', '100'),
    pg_temp.tx('1004', -100, 'E', 'Coupon', '100.00', 'XS0000000072', 'TEST NOTE 72', '1', '100'),
    pg_temp.tx('1005', -90, 'K', 'Interest on deposits', '5.00'),
    pg_temp.tx('1005-R', -89, 'b', 'Reversal', '-5.00', null, null, null, null, true),
    pg_temp.tx('1006', -80, 'J', 'Custody Fees', '-10.00'),
    pg_temp.tx('1007', -70, 'D', 'Dividend', '7.00', 'US0000000072', 'AAA', '1', '7'),
    pg_temp.tx('1008', -30, 'CAS', 'Redemption', '0', 'XS0000000072', 'TEST NOTE 72', '-10000', '1'),
    pg_temp.tx('1009', -30, 'CAC', 'Redemption', '10000.00', 'XS0000000072', 'TEST NOTE 72', '1', '10000')) $$;
create function pg_temp.payload(p_cash text, p_txs jsonb, p_positions jsonb) returns jsonb language sql as $$
  select jsonb_build_object('portfolio_ref', 'T72PORTFOLIO', 'currency', 'USD', 'account_number', '123456701',
    'iban', 'CH2700000000000000001', 'fetched_at', now(), 'cash', p_cash,
    'opening', jsonb_build_object('as_of', pg_temp.at(-200), 'balance', '0'),
    'securities', jsonb_build_array(jsonb_build_object('isin', 'XS0000000072', 'name', 'Test Phoenix 72',
                                                       'symbol', 'TEST NOTE 72', 'product_type', 'WARRANT')),
    'transactions', p_txs, 'positions', p_positions,
    'snapshots', jsonb_build_array(jsonb_build_object('as_of', pg_temp.d(-5), 'total_value', '10500.00', 'estimated', true),
                                   jsonb_build_object('as_of', pg_temp.d(0), 'total_value', '1.00', 'estimated', true))) $$;
create function pg_temp.share() returns jsonb language sql as $$
  select jsonb_build_object('isin', 'US0000000072', 'name', 'AAA ORD', 'symbol', 'AAA', 'product_type', 'SHARE',
    'quantity', '10', 'price', '110', 'price_in_pct', false, 'value', '1100.00', 'cost_price', '100', 'currency', 'USD') $$;
create function pg_temp.sync(p jsonb) returns jsonb language sql as $$
  select public.import_broker_data(pg_temp.v('p'), 'swissquote', p) $$;
create function pg_temp.txn_of(p_id text) returns text language sql as $$
  select txn_code from public.broker_transactions where account_code = pg_temp.v('acc') and external_id = p_id $$;
create function pg_temp.cat_of(p_id text) returns text language sql as $$
  select c.name from public.transactions t join public.categories c on c.category_code = t.effective_category_code
  where t.txn_code = pg_temp.txn_of(p_id) $$;
create function pg_temp.hold(p_isin text) returns text language sql as $$
  select holding_code from public.holdings where profile_code = pg_temp.v('p') and external_ref = p_isin $$;
create function pg_temp.flows(p_isin text) returns text language sql as $$
  select string_agg(kind || ' ' || amount, ', ' order by flow_date, kind) from public.holding_flows
  where holding_code = pg_temp.hold(p_isin) and removed_at is null $$;

-- ── setup: an owner and a stranger ──────────────────────────────────────────
select pg_temp.set('today', public.dubai_date(now())::text);
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't72-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t72-' || left(pg_temp.v('uid'), 8), 'Broker'));
select throws_ok($$ select pg_temp.sync(pg_temp.payload('9542.00', pg_temp.txs(), jsonb_build_array(pg_temp.share()))) $$,
                 '42501', null, 'members cannot import broker data');
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select pg_temp.set('p2', public.create_profile('t72b-' || left(pg_temp.v('uid2'), 8), 'Stranger'));
reset role;
select set_config('request.jwt.claims', '', true);

select throws_ok($$ select public.import_broker_data(pg_temp.v('p'), 'ibkr', '{}') $$, '22023', null, 'an unknown provider is refused');
select throws_ok($$ select public.import_broker_data(pg_temp.v('p'), 'swissquote', '{"portfolio_ref":"x"}') $$, '22023', null,
                 'a portfolio reference is required');

-- ── first sync ──────────────────────────────────────────────────────────────
-- Cash: 10,000 − 9,550 − 1,005 + 100 + 5 − 5 − 10 + 7 + 10,000 = 9,542.
select pg_temp.set('r1', pg_temp.sync(pg_temp.payload('9542.00', pg_temp.txs(), jsonb_build_array(pg_temp.share())))::text);
select pg_temp.set('acc', (pg_temp.v('r1')::jsonb)->>'account_code');
select is((select bank_code || ' ' || kind || ' ' || currency || ' ' || account_ref || ' ' || account_number
           from public.accounts where account_code = pg_temp.v('acc')),
          'SWQ current USD 6701 123456701', 'the cash account is made: Swissquote, current, USD, its number');
select is((select portfolio_ref from public.broker_connections where account_code = pg_temp.v('acc')), 'T72PORTFOLIO',
          'and linked to the portfolio');
select is((pg_temp.v('r1')::jsonb)->>'transactions_added', '10', 'every broker row is kept');
select is((select count(*)::int from public.broker_transactions where account_code = pg_temp.v('acc') and txn_code is not null), 9,
          'each cash row has a transaction (the security leg of the redemption has none)');
select is((select string_agg(kind || '/' || direction || '/' || amount_original || '/' || description, ' | ' order by txn_at)
           from public.transactions where account_code = pg_temp.v('acc')),
          'transfer_in/credit/10000.00/INCOMING TRANSFER | transfer_out/debit/9550.00/BUY TEST NOTE 72 | '
          || 'transfer_out/debit/1005.00/BUY AAA | transfer_in/credit/100.00/NOTE COUPON XS0000000072 | '
          || 'transfer_in/credit/5.00/DEPOSIT INTEREST | transfer_out/debit/5.00/REVERSAL DEPOSIT INTEREST | '
          || 'fee/debit/10.00/SWISSQUOTE CUSTODY FEE | transfer_in/credit/7.00/DIVIDEND AAA | '
          || 'transfer_in/credit/10000.00/NOTE REDEMPTION XS0000000072',
          'transactions read like a bank account''s: deposits, buys, income, fees, a reversal');
select is((select count(*)::int from public.transactions where account_code = pg_temp.v('acc')
           and (status <> 'posted' or amount_source <> 'broker' or txn_at is null)), 0,
          'all posted, from the broker, with their booking time');
select private.refresh_transaction(pg_temp.txn_of('1001'));
select is((select status from public.transactions where txn_code = pg_temp.txn_of('1001')), 'posted',
          'a broker row is typed evidence: refreshing keeps it posted');
select is(pg_temp.cat_of('1004'), 'Investment income', 'a coupon is investment income');
select is(pg_temp.cat_of('1007'), 'Dividends', 'a dividend files under Dividends');
select is(pg_temp.cat_of('1005'), 'Investment income', 'deposit interest is investment income');
select is(pg_temp.cat_of('1006'), 'Bank Fees & Interest', 'the custody fee is a bank fee');
select is((select count(*)::int from public.v_spend s join public.broker_transactions b on b.txn_code = s.txn_code
           where b.account_code = pg_temp.v('acc')), 1, 'only the custody fee is spend (buys and redemptions are saving)');

-- Balance: the opening and today's broker checkpoints, and the ledger agrees.
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('acc')), 9542.00::numeric,
          'the balance is the broker''s cash');
select is((select anchor_source from public.v_bank_balances where account_code = pg_temp.v('acc')), 'broker',
          'anchored on a broker checkpoint');
select is((select count(*)::int from public.balance_checkpoints where account_code = pg_temp.v('acc')), 2,
          'two checkpoints: the opening and today');

-- Holdings and flows.
select is((select kind || ' ' || status from public.holdings where holding_code = pg_temp.hold('XS0000000072')), 'broker closed',
          'the note without terms is a broker holding, closed once redeemed');
select is((select kind || ' ' || status || ' ' || units || ' ' || symbol from public.holdings
           where holding_code = pg_temp.hold('US0000000072')), 'security active 10.000000 AAA',
          'the share is a security with its units and ticker');
select is(pg_temp.flows('XS0000000072'), 'contribution 9550.00, income 100.00, withdrawal 10000.00',
          'the note''s flows: the buy, the coupon, the redemption');
select is(pg_temp.flows('US0000000072'), 'contribution 1005.00, income 7.00', 'the share''s flows: the buy, the dividend');
select is((select v.value from private.holding_values(pg_temp.v('p'), now()) v
           where v.holding_code = pg_temp.hold('US0000000072')), 1100.00::numeric, 'the share is worth today''s mark');

-- Daily values.
select is((select total_value || ' ' || estimated from public.broker_snapshots
           where account_code = pg_temp.v('acc') and as_of = pg_temp.d(0)), '10642.00 false',
          'today''s value is cash + marks, a real mark (the rebuilt one for today is ignored)');
select is((select total_value || ' ' || estimated from public.broker_snapshots
           where account_code = pg_temp.v('acc') and as_of = pg_temp.d(-5)), '10500.00 true', 'an earlier rebuilt value is kept');

-- ── the same data again: nothing new ────────────────────────────────────────
select pg_temp.set('r2', pg_temp.sync(pg_temp.payload('9542.00', pg_temp.txs(), jsonb_build_array(pg_temp.share())))::text);
select is((pg_temp.v('r2')::jsonb)->>'transactions_added', '0', 'a second sync adds nothing');
select is((select count(*)::int from public.transactions where account_code = pg_temp.v('acc')), 9, 'no transaction twice');
select is((select count(*)::int from public.holding_flows where holding_code in (pg_temp.hold('XS0000000072'), pg_temp.hold('US0000000072'))),
          5, 'no flow twice');
select is((select count(*)::int from public.balance_checkpoints where account_code = pg_temp.v('acc')), 2,
          'no new checkpoint while the cash agrees and the last one is recent');

-- ── the screen ──────────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('bp', public.broker_portfolio(pg_temp.v('p'), pg_temp.v('acc'))::text);
reset role;
select is((pg_temp.v('bp')::jsonb)->>'total', '10642.00', 'the portfolio total');
select is((pg_temp.v('bp')::jsonb)->>'net_deposits', '10000.00', 'net deposits');
select is((pg_temp.v('bp')::jsonb)->>'profit', '642.00', 'profit = total − net deposits');
select is(((pg_temp.v('bp')::jsonb)->'positions'->0)->>'isin', 'US0000000072', 'one open position');
select is(((pg_temp.v('bp')::jsonb)->'positions'->0->'sell_now')->>'total', '1107.00', 'sold today: the mark plus the dividend');
select is(((pg_temp.v('bp')::jsonb)->'closed'->0)->>'profit', '550.00', 'the redeemed note: 10,000 + 100 − 9,550');
select is(jsonb_array_length((pg_temp.v('bp')::jsonb)->'series'), 2, 'the daily values');
select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select public.broker_portfolio(pg_temp.v('p'), pg_temp.v('acc')) $$, '42501', null,
                 'a stranger cannot read the portfolio');
select is((select count(*)::int from public.broker_transactions), 0, 'a stranger sees no broker rows');
select is((select count(*)::int from public.broker_positions), 0, '… no marks');
select is((select count(*)::int from public.broker_connections), 0, '… no connection');
reset role;
select set_config('request.jwt.claims', '', true);

-- ── a note bought on the account, its terms entered after the buy ──────────
-- Phoenix on CCC (initial 50): monthly 1% coupons with a 70% barrier, autocall 100% from the
-- third observation. Struck 60 days ago, bought 20 days ago at 80% (20,000 nominal, 16,050 with
-- commission). The coupon paid 33 days ago was the seller's.
insert into public.security_prices (symbol, price_date, close, source) values
  ('CCC', pg_temp.d(-60), 50, 'manual'), ('CCC', pg_temp.d(-40), 45, 'manual'), ('CCC', pg_temp.d(-10), 40, 'manual'),
  ('CCC', pg_temp.d(-1), 41, 'manual')
on conflict (symbol, price_date) do update set close = excluded.close;
select pg_temp.set('txs2', (pg_temp.txs() || jsonb_build_array(
  pg_temp.tx('1010', -20, 'G', 'Payment', '20000.00'),
  pg_temp.tx('1011', -20, 'B', 'Buy', '-16050.00', 'XS0000000073', 'TEST NOTE 73', '20000', '0.8')))::text);
select pg_temp.set('note', jsonb_build_object('isin', 'XS0000000073', 'name', 'TEST NOTE 73', 'symbol', 'TEST NOTE 73',
  'product_type', 'STRUCTURED_PRODUCTS', 'quantity', '20000', 'price', '85', 'price_in_pct', true, 'value', '17000.00',
  'cost_price', '80', 'currency', 'USD')::text);
select pg_temp.sync(pg_temp.payload('13492.00', pg_temp.v('txs2')::jsonb,
                                    jsonb_build_array(pg_temp.share(), pg_temp.v('note')::jsonb)));
select is((select kind from public.holdings where holding_code = pg_temp.hold('XS0000000073')), 'broker',
          'a new position without terms is a broker holding');
select is((pg_temp.sync(pg_temp.payload('13492.00', pg_temp.v('txs2')::jsonb,
                                        jsonb_build_array(pg_temp.share(), pg_temp.v('note')::jsonb)))->'isins_without_terms'),
          '["XS0000000072", "XS0000000073"]'::jsonb, 'positions held without terms are reported, the redeemed one too (its history)');

select pg_temp.set('draft', jsonb_build_object(
  'name', 'Phoenix CCC', 'institution', 'Swissquote',
  'terms', jsonb_build_object(
    'product_name', 'Phoenix on CCC', 'isin', 'XS0000000073', 'issuer', 'Test Bank', 'currency', 'USD',
    'denomination', '1000', 'issue_price_pct', '100', 'strike_date', pg_temp.d(-60), 'issue_date', pg_temp.d(-55),
    'final_valuation_date', pg_temp.d(90), 'maturity_date', pg_temp.d(97),
    'underlyings', jsonb_build_array(jsonb_build_object('name', 'Ccc Inc', 'symbol', 'CCC', 'initial_level', '50')),
    'observations', jsonb_build_array(
      jsonb_build_object('obs_date', pg_temp.d(-40), 'pay_date', pg_temp.d(-33), 'coupon_rate_pct', '1', 'coupon_barrier_pct', '70'),
      jsonb_build_object('obs_date', pg_temp.d(-10), 'pay_date', pg_temp.d(-3), 'coupon_rate_pct', '1', 'coupon_barrier_pct', '70'),
      jsonb_build_object('obs_date', pg_temp.d(30), 'pay_date', pg_temp.d(37), 'coupon_rate_pct', '1', 'coupon_barrier_pct', '70',
                         'autocall_trigger_pct', '100', 'autocall_amount_pct', '100'),
      jsonb_build_object('obs_date', pg_temp.d(90), 'pay_date', pg_temp.d(97), 'coupon_rate_pct', '1', 'coupon_barrier_pct', '70',
                         'autocall_trigger_pct', '100', 'autocall_amount_pct', '100')),
    'payout', jsonb_build_array(
      jsonb_build_object('min_worst_pct', '60', 'intercept_pct', '100', 'slope', '0', 'settlement', 'cash'),
      jsonb_build_object('min_worst_pct', '0', 'intercept_pct', '0', 'slope', '1', 'settlement', 'cash'))),
  'investment', jsonb_build_object('funding_account_code', pg_temp.v('acc')))::text);
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('nh', public.create_structured_note(pg_temp.v('p'), pg_temp.v('draft')::jsonb));
reset role;
select is(pg_temp.v('nh'), pg_temp.hold('XS0000000073'), 'the note adopts the position''s holding');
select is((select kind from public.holdings where holding_code = pg_temp.v('nh')), 'structured_note', 'which becomes a note');
select is((select invested_amount || ' ' || nominal || ' ' || purchase_price_pct || ' ' || trade_date
           from public.structured_notes where holding_code = pg_temp.v('nh')),
          '16050.00 20000.00 80.00000 ' || pg_temp.d(-20), 'what was bought comes from the broker''s buy');
select is((select purchase_txn_code from public.structured_notes where holding_code = pg_temp.v('nh')), pg_temp.txn_of('1011'),
          'the purchase is the broker''s buy');
select is((select count(*)::int from public.transactions where account_code = pg_temp.v('acc') and description like 'NOTE PURCHASE%'),
          0, 'no purchase of its own is posted');
select is(pg_temp.flows('XS0000000073'), 'contribution 16050.00', 'one contribution: the broker''s');
select is((select v.value from private.holding_values(pg_temp.v('p'), now()) v where v.holding_code = pg_temp.v('nh')),
          17000.00::numeric, 'a live note is worth its market value');
select is((select count(*)::int from public.structured_note_events e join public.structured_notes n using (note_code)
           where n.holding_code = pg_temp.v('nh') and e.pay_date = pg_temp.d(-33)), 0,
          'the coupon paid before the purchase is not the buyer''s');
select is((select e.amount || ' ' || (e.settled_at is null) from public.structured_note_events e join public.structured_notes n using (note_code)
           where n.holding_code = pg_temp.v('nh') and e.kind = 'coupon'), '200.00 true',
          'the coupon since waits for the broker''s row');

select pg_temp.set('txs3', (pg_temp.v('txs2')::jsonb || jsonb_build_array(
  pg_temp.tx('1012', -3, 'E', 'Coupon', '200.00', 'XS0000000073', 'TEST NOTE 73', '1', '200')))::text);
select pg_temp.sync(pg_temp.payload('13692.00', pg_temp.v('txs3')::jsonb,
                                    jsonb_build_array(pg_temp.share(), pg_temp.v('note')::jsonb)));
select is((select e.txn_code from public.structured_note_events e join public.structured_notes n using (note_code)
           where n.holding_code = pg_temp.v('nh') and e.kind = 'coupon'), pg_temp.txn_of('1012'),
          'once it arrives the coupon settles against it');
select is((select count(*)::int from public.transactions where account_code = pg_temp.v('acc') and description like 'NOTE COUPON XS0000000073%'),
          1, 'one coupon transaction: the broker''s');

select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('sum', (select x::text from jsonb_array_elements(public.structured_notes_summary(pg_temp.v('p'))) x
                           where x->>'holding_code' = pg_temp.v('nh')));
reset role;
select is((pg_temp.v('sum')::jsonb)->'market'->>'value', '17000.00', 'the summary has what it fetches sold today');
select is((pg_temp.v('sum')::jsonb)->'market'->>'profit', '1150.00', '… with the coupon received: 17,000 + 200 − 16,050');
select is((pg_temp.v('sum')::jsonb)->'if_called_next'->>'pay_date', pg_temp.d(37)::text, 'and what it pays if called next');
select is((pg_temp.v('sum')::jsonb)->'if_called_next'->>'total', '20400.00', '… 20,000 + both coupons');

-- Cancelled: the position stays, the broker's rows stand.
select pg_temp.as_user('uid');
set local role authenticated;
select public.cancel_structured_note(pg_temp.v('p'), pg_temp.v('nh'));
reset role;
select is((select kind || ' ' || status from public.holdings where holding_code = pg_temp.v('nh')), 'broker active',
          'cancelling the terms leaves the position a broker holding');
select is((select count(*)::int from public.transactions where account_code = pg_temp.v('acc') and status = 'void'), 0,
          'and voids none of the broker''s rows');
select is((select n.status from public.structured_notes n join public.holdings h using (holding_code)
           where n.isin = 'XS0000000073' and h.status = 'closed'), 'cancelled', 'the cancelled terms keep a closed holding');
select pg_temp.as_user('uid');
set local role authenticated;
select is(public.create_structured_note(pg_temp.v('p'), pg_temp.v('draft')::jsonb), pg_temp.v('nh'),
          'entering the terms again adopts the position again');
reset role;
select set_config('request.jwt.claims', '', true);

-- ── terms for the redeemed position, entered after it ended (no closes stored) ──
select pg_temp.set('draft72', jsonb_set(jsonb_set(jsonb_set(pg_temp.v('draft')::jsonb, '{terms,isin}', '"XS0000000072"'),
  '{terms,underlyings}', '[{"name": "Ddd Inc", "symbol": "DDD", "initial_level": "10"}]'), '{name}', '"Redeemed note"')::text);
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('rh', public.create_structured_note(pg_temp.v('p'), pg_temp.v('draft72')::jsonb));
select pg_temp.set('rsum', (select x::text from jsonb_array_elements(public.structured_notes_summary(pg_temp.v('p'))) x
                            where x->>'holding_code' = pg_temp.v('rh')));
reset role;
select is((select status || ' ' || ended_on from public.structured_notes where holding_code = pg_temp.v('rh')),
          'autocalled ' || pg_temp.d(-30), 'the broker''s redemption ends the note');
select is((pg_temp.v('rsum')::jsonb)->>'status', 'autocalled', 'its summary says so, though no close was stored');
select is((pg_temp.v('rsum')::jsonb)->'result'->>'profit', '550.00', 'with the result the broker paid: 10,000 + 100 − 9,550');
select is((pg_temp.v('rsum')::jsonb)->'if_called_next', 'null'::jsonb, 'and no live figures');
select set_config('request.jwt.claims', '', true);

-- ── a failed sync is shown ──────────────────────────────────────────────────
select public.record_broker_sync_error(pg_temp.v('p'), 'swissquote', 'Swissquote: card code refused');
select is((select last_status || ' ' || last_error from public.broker_connections where account_code = pg_temp.v('acc')),
          'error Swissquote: card code refused', 'the last error is kept for the screen');

select * from finish();
rollback;

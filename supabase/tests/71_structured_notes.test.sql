-- Structured notes (20261027124257_structured_notes): Swissquote USD cash, typed account
-- entries, note terms, the evaluator (memory coupons, autocall, final payout branches, physical
-- delivery), settlement onto the funding account, values and tenant isolation. Every date is
-- relative to today, so the file holds on any day.
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
create function pg_temp.price(p_symbol text, p_offset int, p_close numeric) returns void language sql as $$
  insert into public.security_prices (symbol, price_date, close, source) values (p_symbol, pg_temp.d(p_offset), p_close, 'manual')
  on conflict (symbol, price_date) do update set close = excluded.close $$;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
create function pg_temp.obs(p_obs int, p_rate text, p_barrier text, p_memory boolean, p_trigger text, p_amount text)
returns jsonb language sql as $$
  select jsonb_build_object('obs_date', pg_temp.d(p_obs), 'pay_date', pg_temp.d(p_obs + 7), 'coupon_rate_pct', p_rate,
    'coupon_barrier_pct', p_barrier, 'coupon_memory', p_memory, 'autocall_trigger_pct', p_trigger, 'autocall_amount_pct', p_amount) $$;

-- ── setup: an owner, a stranger, a USD Swissquote account with an opening balance ──
select pg_temp.set('today', public.dubai_date(now())::text);
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't71-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t71-' || left(pg_temp.v('uid'), 8), 'Notes'));
select pg_temp.set('sq', public.create_bank_account(pg_temp.v('p'), 'SWQ', 'current', null, 'Swissquote', 'USD'));
select public.record_balance(pg_temp.v('p'), pg_temp.v('sq'), '20000.00',
                             (pg_temp.d(-200) + time '09:00') at time zone 'Asia/Dubai');
reset role;
select set_config('request.jwt.claims', '', true);

select is((select balance_aed from public.v_bank_balances where account_code = pg_temp.v('sq')), 73450.00::numeric,
          'a USD account has an AED balance (at the peg)');
select is((public.net_worth(pg_temp.v('p'))->>'cash_aed')::numeric, 73450.00, 'USD cash counts in net worth')
from (select pg_temp.as_user('uid')) x;

-- ── account entries ─────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('dep', public.add_account_entry(pg_temp.v('p'), pg_temp.v('sq'), 'credit', '1000.00', pg_temp.d(-150)));
reset role;
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('sq')), 21000.00::numeric,
          'a deposit adds to the balance');
select is((select status from public.transactions t join public.account_entries e on e.txn_code = t.txn_code
           where e.entry_code = pg_temp.v('dep')), 'posted', 'its transaction is posted');
select private.refresh_transaction(txn_code) from public.account_entries where entry_code = pg_temp.v('dep');
select is((select status from public.transactions t join public.account_entries e on e.txn_code = t.txn_code
           where e.entry_code = pg_temp.v('dep')), 'posted', 'and stays posted when refreshed (typed evidence)');
set local role authenticated;
select public.remove_account_entry(pg_temp.v('p'), pg_temp.v('dep'));
reset role;
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('sq')), 20000.00::numeric,
          'removing it voids its transaction');

-- ── note A: a Phoenix with memory and a leveraged put (the Example Bank M shape) ─────
-- Two shares (AAA 100, BBB 200). Coupons 0.667% with a 98% barrier and memory; autocall 105%
-- at 100% from the second observation; at maturity WP >= 100 → 100%, else shares worth
-- WP − 24.5%. Bought 10,000 nominal at 74.5% = 7,450.
select pg_temp.price('AAA', -120, 100), pg_temp.price('BBB', -120, 200);
select pg_temp.price('AAA', -90, 97), pg_temp.price('BBB', -90, 210);     -- worst 97: coupon missed, remembered
select pg_temp.price('AAA', -60, 99), pg_temp.price('BBB', -60, 230);     -- worst 99: two coupons, no autocall
select pg_temp.price('AAA', -31, 104), pg_temp.price('BBB', -31, 220);    -- the day before obs 3 (a holiday)
select pg_temp.price('AAA', -1, 90), pg_temp.price('BBB', -1, 210);       -- today: worst 90
select pg_temp.set('draft_a', jsonb_build_object(
  'name', 'Phoenix AAA/BBB', 'institution', 'Swissquote',
  'terms', jsonb_build_object(
    'product_name', 'Worst of Memory Phoenix Autocall', 'isin', 'XS0000000011', 'issuer', 'Example Bank M Financial',
    'currency', 'USD', 'denomination', '1000', 'issue_price_pct', '74.5',
    'strike_date', pg_temp.d(-120), 'issue_date', pg_temp.d(-100), 'final_valuation_date', pg_temp.d(60),
    'maturity_date', pg_temp.d(67),
    'underlyings', jsonb_build_array(
      jsonb_build_object('name', 'Aaa Inc', 'symbol', 'aaa', 'bloomberg_code', 'AAA UW Equity', 'initial_level', '100'),
      jsonb_build_object('name', 'Bbb Corp', 'symbol', 'BBB', 'initial_level', '200')),
    'observations', jsonb_build_array(
      pg_temp.obs(-90, '0.667', '98', true, null, null),
      pg_temp.obs(-60, '0.667', '98', true, '105', '100'),
      pg_temp.obs(-30, '0.667', '98', true, '105', '100'),
      pg_temp.obs(30, '0.667', '98', true, '105', '100'),
      pg_temp.obs(60, '0.667', '98', true, '105', '100')),
    'payout', jsonb_build_array(
      jsonb_build_object('min_worst_pct', '100', 'intercept_pct', '100', 'slope', '0', 'settlement', 'cash'),
      jsonb_build_object('min_worst_pct', '0', 'intercept_pct', '-24.5', 'slope', '1', 'settlement', 'physical'))),
  'investment', jsonb_build_object('invested_amount', '7450.00', 'funding_account_code', pg_temp.v('sq'),
                                   'trade_date', pg_temp.d(-110)))::text);

select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select public.create_structured_note(pg_temp.v('p'), pg_temp.v('draft_a')::jsonb) $$,
                 '42501', null, 'a stranger cannot add a note to the ledger');
reset role;

select pg_temp.as_user('uid');
set local role authenticated;
select throws_ok($$ select public.create_structured_note(pg_temp.v('p'),
                      jsonb_set(pg_temp.v('draft_a')::jsonb, '{terms,payout}',
                                '[{"min_worst_pct":"100","intercept_pct":"100","slope":"0","settlement":"cash"}]')) $$,
                 '22023', null, 'the payout must cover a fall to 0%');
select pg_temp.set('ha', public.create_structured_note(pg_temp.v('p'), pg_temp.v('draft_a')::jsonb));
reset role;
select pg_temp.set('na', (select note_code from public.structured_notes where holding_code = pg_temp.v('ha')));

select is((select nominal from public.structured_notes where note_code = pg_temp.v('na')), 10000.00::numeric,
          'nominal = invested / price');
select is((select array_agg(symbol order by ordinal) from public.structured_note_underlyings where note_code = pg_temp.v('na')),
          array['AAA', 'BBB'], 'symbols are upper-cased, in order');
select is((select count(*)::int from public.structured_note_observations where note_code = pg_temp.v('na')), 5, 'five observations');

select pg_temp.set('ea', private.note_evaluate(pg_temp.v('na'), pg_temp.d(0))::text);
select is((select array_agg(x->>'kind' order by ord) from jsonb_array_elements(pg_temp.v('ea')::jsonb->'events') with ordinality e(x, ord)),
          array['coupon_missed', 'coupon', 'autocall_missed', 'coupon', 'autocall_missed'],
          'past outcomes: missed, paid with memory, no autocall, paid (from the close the day before)');
select is((select (x->>'rate_pct')::numeric from jsonb_array_elements(pg_temp.v('ea')::jsonb->'events') x where x->>'kind' = 'coupon' limit 1),
          1.334, 'the memory coupon pays both rates');
select is(pg_temp.v('ea')::jsonb->'received'->>'coupons', '200.10', 'coupons received: 133.40 + 66.70');
select is(pg_temp.v('ea')::jsonb->>'status', 'live', 'still live');
select is(pg_temp.v('ea')::jsonb->'worst_now'->>'symbol', 'AAA', 'AAA is the worst share now');
select is(pg_temp.v('ea')::jsonb->'if_ended_today'->>'amount', '6550.00', 'ended today: 90% − 24.5% = 65.5% of 10,000');
select is(pg_temp.v('ea')::jsonb->'if_ended_today'->>'settlement', 'physical', 'in shares');
select is(pg_temp.v('ea')::jsonb->>'break_even_pct', '99.0000', 'break-even at 99% (99 − 24.5 = 74.5, the price paid)');
select is((pg_temp.v('ea')::jsonb->'next'->>'obs_date')::date, pg_temp.d(30), 'the next observation');
select is(pg_temp.v('ea')::jsonb->'next'->'coupon'->>'would_pay', 'false', 'its coupon would not pay at 90%');
select is(pg_temp.v('ea')::jsonb->'next'->'autocall'->>'amount', '10000.00', 'an autocall would repay 100%');
select is((select x->>'distance_pct' from jsonb_array_elements(pg_temp.v('ea')::jsonb->'levels') x where x->>'kind' = 'autocall'),
          '16.67', 'AAA needs +16.67% to reach the 105% autocall');
select is((select x->>'to_coupon_pct' from jsonb_array_elements(pg_temp.v('ea')::jsonb->'underlyings') x where x->>'symbol' = 'BBB'),
          '-6.67', 'BBB can fall 6.67% before the coupon barrier');
select is(jsonb_array_length(pg_temp.v('ea')::jsonb->'scenarios'->'autocall'), 2, 'two autocall dates ahead');
select is((pg_temp.v('ea')::jsonb->'scenarios'->'autocall'->0->>'total'), '10266.80',
          'called next time: 200.10 received + that coupon (66.70) + 10,000');
select is(jsonb_array_length(pg_temp.v('ea')::jsonb->'scenarios'->'maturity'), 31, 'the payoff curve from 0% to 150%');
select is(pg_temp.v('ea')::jsonb->'scenarios'->'worst'->>'total', '200.10', 'the worst case keeps the coupons received');

-- Settled on creation: the purchase and both paid coupons are on the Swissquote ledger.
select is((select balance from public.v_bank_balances where account_code = pg_temp.v('sq')),
          (20000 - 7450 + 133.40 + 66.70)::numeric(14,2), 'cash: opening − purchase + coupons');
select is((select count(*)::int from public.structured_note_events where note_code = pg_temp.v('na') and settled_at is not null),
          2, 'two coupons settled');
select is((select c.kind from public.structured_note_events e join public.transactions t on t.txn_code = e.txn_code
           join public.categories c on c.category_code = t.effective_category_code
           where e.note_code = pg_temp.v('na') limit 1), 'income', 'a coupon is filed as income');
select is((select flow from public.v_cash_flow where txn_code = (select purchase_txn_code from public.structured_notes
                                                                where note_code = pg_temp.v('na'))),
          'saving', 'the purchase is saving');
select is((select sum(amount) from public.holding_flows where holding_code = pg_temp.v('ha') and kind = 'income'),
          200.10::numeric, 'the coupons are the holding''s income');
select private.settle_structured_note(pg_temp.v('na'));
select is((select count(*)::int from public.transactions where account_code = pg_temp.v('sq') and status = 'posted'), 3,
          'settling again posts nothing new');
select is((select value from private.holding_values(pg_temp.v('p'), now()) where holding_code = pg_temp.v('ha')),
          7450.00::numeric, 'a live note is worth what was invested');

-- ── note B: the leveraged put at maturity, delivered in shares (the Example Bank A Phoenix shape) ──
-- WP >= 60 → 100%; else shares worth WP / 0.6. Final at −10 days: CCC at 45% → 75%:
-- per 1,000 note 750 / 90 = 8.33 shares → 8, cash 0.33 × 90 = 30; five notes.
select pg_temp.price('CCC', -400, 200), pg_temp.price('DDD', -400, 50);
select pg_temp.price('CCC', -10, 90), pg_temp.price('DDD', -10, 55);
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('hb', public.create_structured_note(pg_temp.v('p'), jsonb_build_object(
  'name', 'Put CCC/DDD',
  'terms', jsonb_build_object('currency', 'USD', 'denomination', '1000', 'issue_price_pct', '100',
    'strike_date', pg_temp.d(-400), 'final_valuation_date', pg_temp.d(-10), 'maturity_date', pg_temp.d(-3),
    'underlyings', jsonb_build_array(jsonb_build_object('name', 'Ccc', 'symbol', 'CCC', 'initial_level', '200'),
                                     jsonb_build_object('name', 'Ddd', 'symbol', 'DDD', 'initial_level', '50')),
    'observations', '[]'::jsonb,
    'payout', jsonb_build_array(
      jsonb_build_object('min_worst_pct', '60', 'intercept_pct', '100', 'slope', '0', 'settlement', 'cash'),
      jsonb_build_object('min_worst_pct', '0', 'intercept_pct', '0', 'slope', '1.66666667', 'settlement', 'physical'))),
  'investment', jsonb_build_object('invested_amount', '5000.00', 'funding_account_code', pg_temp.v('sq'),
                                   'trade_date', pg_temp.d(-399)))));
reset role;
select pg_temp.set('nb', (select note_code from public.structured_notes where holding_code = pg_temp.v('hb')));
select is((select payout_pct from private.note_payout(pg_temp.v('nb'), 30)), 50.0000001::numeric, 'WP 30% → 50%');
select is((select payout_pct from private.note_payout(pg_temp.v('nb'), 60)), 100.00000::numeric, 'WP 60% → 100%');
select is((select (kind, shares, amount, worst_symbol)::text from public.structured_note_events where note_code = pg_temp.v('nb')),
          '(maturity,40.000000,150.00,CCC)', 'redeemed in 40 CCC shares and 150 in cash');
select is((select status from public.structured_notes where note_code = pg_temp.v('nb')), 'matured', 'the note matured');
select is((select status from public.holdings where holding_code = pg_temp.v('hb')), 'closed', 'its holding closed');
select is((select (h.kind, h.units, h.symbol)::text from public.structured_note_events e
           join public.holdings h on h.holding_code = e.delivered_holding_code where e.note_code = pg_temp.v('nb')),
          '(security,40.000000,CCC)', 'the shares are a security holding');
select is((select value from private.holding_values(pg_temp.v('p'), now()) v
           join public.structured_note_events e on e.delivered_holding_code = v.holding_code where e.note_code = pg_temp.v('nb')),
          3600.00::numeric, 'valued at the latest CCC close (40 × 90)');

-- ── payout shapes of the other sheets ───────────────────────────────────────
create function pg_temp.shape(p_branches jsonb) returns text language plpgsql as $$
declare
  v text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
  v := public.create_structured_note(pg_temp.v('p'), jsonb_build_object('name', 'Shape',
    'terms', jsonb_build_object('currency', 'USD', 'denomination', '1000', 'issue_price_pct', '100',
      'strike_date', pg_temp.d(-5), 'final_valuation_date', pg_temp.d(700), 'maturity_date', pg_temp.d(707),
      'underlyings', jsonb_build_array(jsonb_build_object('name', 'Aaa', 'symbol', 'AAA', 'initial_level', '100')),
      'payout', p_branches),
    'investment', jsonb_build_object('invested_amount', '1000.00')));
  return (select note_code from public.structured_notes where holding_code = v);
end $$;
-- Example Bank B Athena: >= 100 → 100%; >= 45 → WP − 45%; else 0.
select pg_temp.set('athena', pg_temp.shape('[{"min_worst_pct":"100","intercept_pct":"100","slope":"0","settlement":"cash"},
  {"min_worst_pct":"45","intercept_pct":"-45","slope":"1","settlement":"cash"},
  {"min_worst_pct":"0","intercept_pct":"0","slope":"0","settlement":"cash"}]'));
select is((select array_agg(round(p.payout_pct, 2) order by w desc) from unnest(array[120, 80, 45, 40]) w
           cross join lateral private.note_payout(pg_temp.v('athena'), w) p),
          array[100.00, 35.00, 0.00, 0.00], 'Athena: 120 → 100, 80 → 35, 45 → 0, 40 → 0');
-- Example Bank A autocallable: >= 100 → 181%; >= 63.5 → 100%; else WP.
select pg_temp.set('kib', pg_temp.shape('[{"min_worst_pct":"100","intercept_pct":"181","slope":"0","settlement":"cash"},
  {"min_worst_pct":"63.5","intercept_pct":"100","slope":"0","settlement":"cash"},
  {"min_worst_pct":"0","intercept_pct":"0","slope":"1","settlement":"cash"}]'));
select is((select array_agg(round(p.payout_pct, 2) order by w desc) from unnest(array[100, 70, 63.4]) w
           cross join lateral private.note_payout(pg_temp.v('kib'), w) p),
          array[181.00, 100.00, 63.40], 'knock-in: 100 → 181, 70 → 100, 63.4 → 63.4');
select is(private.note_break_even(pg_temp.v('kib'), 100), 63.5000::numeric, 'break-even at the knock-in level');
select is(private.note_break_even(pg_temp.v('athena'), 54), 99.0000::numeric, 'Athena bought at 54%: break-even at 99%');

-- ── note C: autocalled (the Example Bank B step-up shape: 105% trigger, 63% + n·1%) ────
select pg_temp.price('EEE', -100, 100), pg_temp.price('EEE', -50, 101), pg_temp.price('EEE', -20, 106);
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('hc', public.create_structured_note(pg_temp.v('p'), jsonb_build_object(
  'name', 'Athena EEE',
  'terms', jsonb_build_object('currency', 'USD', 'denomination', '1', 'issue_price_pct', '54',
    'strike_date', pg_temp.d(-100), 'final_valuation_date', pg_temp.d(400), 'maturity_date', pg_temp.d(408),
    'underlyings', jsonb_build_array(jsonb_build_object('name', 'Eee', 'symbol', 'EEE', 'initial_level', '100')),
    'observations', jsonb_build_array(pg_temp.obs(-50, null, null, false, '105', '64'),
                                      pg_temp.obs(-20, null, null, false, '105', '65'),
                                      pg_temp.obs(10, null, null, false, '105', '66')),
    'payout', '[{"min_worst_pct":"100","intercept_pct":"100","slope":"0","settlement":"cash"},
                {"min_worst_pct":"45","intercept_pct":"-45","slope":"1","settlement":"cash"},
                {"min_worst_pct":"0","intercept_pct":"0","slope":"0","settlement":"cash"}]'::jsonb),
  'investment', jsonb_build_object('invested_amount', '5400.00', 'funding_account_code', pg_temp.v('sq'),
                                   'trade_date', pg_temp.d(-95)))));
select pg_temp.set('dc', public.structured_note_detail(pg_temp.v('p'), pg_temp.v('hc'))::text);
reset role;
select is(pg_temp.v('dc')::jsonb->>'status', 'autocalled', 'called at 106% on the second date');
select is(pg_temp.v('dc')::jsonb->'result'->>'total', '6500.00', '65% of 10,000 nominal');
select is(pg_temp.v('dc')::jsonb->'result'->>'profit', '1100.00', 'a 1,100 profit on 5,400');
select is((select status from public.holdings where holding_code = pg_temp.v('hc')), 'closed', 'its holding closed');
select is((select flow from public.v_cash_flow v join public.structured_note_events e on e.txn_code = v.txn_code
           where e.note_code = (select note_code from public.structured_notes where holding_code = pg_temp.v('hc'))),
          'saving', 'the redemption is money back out of the holding');
select is((select amount_aed from public.v_cash_flow v join public.structured_note_events e on e.txn_code = v.txn_code
           where e.note_code = (select note_code from public.structured_notes where holding_code = pg_temp.v('hc'))),
          -23871.25::numeric, '(negative saving)');
select ok(pg_temp.v('dc')::jsonb ? 'series' and jsonb_array_length(pg_temp.v('dc')::jsonb->'series'->'EEE') = 3,
          'the detail carries each share''s closes since strike');

-- ── summary, isolation, cancel ──────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select is((select count(*)::int from jsonb_array_elements(public.structured_notes_summary(pg_temp.v('p')))), 5,
          'the summary lists every note');
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select public.structured_note_detail(pg_temp.v('p'), pg_temp.v('ha')) $$, '42501', null,
                 'a stranger cannot read a note');
select is((select count(*)::int from public.structured_notes), 0, 'nor see its rows');
reset role;

select pg_temp.as_user('uid');
set local role authenticated;
select public.cancel_structured_note(pg_temp.v('p'), pg_temp.v('ha'));
reset role;
select is((select count(*)::int from public.transactions t where t.txn_code in (
             select purchase_txn_code from public.structured_notes where note_code = pg_temp.v('na')
             union all select txn_code from public.structured_note_events where note_code = pg_temp.v('na'))
           and t.status = 'void'), 3, 'cancelling voids the purchase and the coupons');
select is((select status from public.structured_notes where note_code = pg_temp.v('na')), 'cancelled', 'the note is cancelled');

-- ── service RPCs ────────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select throws_ok($$ select public.settle_structured_notes() $$, '42501', null, 'settling is service-only');
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
select is(public.record_security_prices('[{"symbol":"aaa","date":"2020-01-02","close":"10.5"}]'), 1, 'closes are stored');
select is((select close from public.security_prices where symbol = 'AAA' and price_date = '2020-01-02'), 10.500000::numeric,
          'under the upper-case symbol');
select ok(exists (select 1 from public.price_symbols(pg_temp.v('p')) where symbol = 'CCC'), 'delivered shares keep being priced');

select * from finish();
rollback;

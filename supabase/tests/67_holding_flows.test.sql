-- Investments (20261021093154_holdings_flows_and_returns): holding kinds, valuations, flows,
-- rule and manual links (a linked payment is saving, not spend), returns and allocation.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.cat(p_name text) returns text language sql as $$
  select category_code from public.categories where profile_code = pg_temp.v('p') and name = p_name $$;
create function pg_temp.txn(p_acc text, p_kind text, p_dir text, p_aed numeric, p_day date, p_desc text,
                            p_orig numeric default null, p_ccy text default 'AED', p_cat text default null)
returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, txn_at,
                                   description, amount_original, currency_original, amount_aed, amount_source,
                                   manual_category_code)
  values (pg_temp.v('p'), pg_temp.v(p_acc), 'posted', p_kind, p_dir, p_day,
          (p_day + time '10:00') at time zone 'Asia/Dubai', p_desc, coalesce(p_orig, p_aed), p_ccy, p_aed, 'manual',
          pg_temp.cat(p_cat))
  returning txn_code $$;

-- ── setup: an owner and a stranger; a card and a current account ────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't67-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t67-' || left(pg_temp.v('uid'), 8), 'Investments'));
select pg_temp.set('bank', public.create_bank_account(pg_temp.v('p'), 'ADCB', 'current', '810001'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code, nickname) values (pg_temp.v('p'), 'ENBD', 'ENBD card')
returning pg_temp.set('card', account_code);
delete from public.metal_prices;
insert into public.metal_prices (quote, aed_per_gram, source, as_of) values ('gold_24k', 500, 'test', now() - interval '1 hour');
select pg_temp.set('today', public.dubai_date(now())::text);

-- Two RL360 payments already in the ledger (filed under Investment, a spend category).
select pg_temp.set('rl1', pg_temp.txn('card', 'purchase', 'debit', 7575.70, pg_temp.v('today')::date - 40,
                                      '*RL360 DOUGLAS GBR', 2000, 'USD', 'Investment'));
select pg_temp.set('rl2', pg_temp.txn('card', 'purchase', 'debit', 7575.90, pg_temp.v('today')::date - 10,
                                      '*RL360 DOUGLAS GBR', 2000, 'USD', 'Investment'));
select is((select count(*)::int from public.v_spend where txn_code in (pg_temp.v('rl1'), pg_temp.v('rl2'))), 2,
          'before any holding, RL360 counts as spend');

-- ── holding kinds ───────────────────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('rl360', public.save_holding(pg_temp.v('p'), 'RL360 plan', p_kind => 'plan', p_currency => 'usd',
                                                p_institution => 'RL360', p_link_pattern => 'RL360',
                                                p_acquired_on => pg_temp.v('today')::date - 60));
select pg_temp.set('fund', public.save_holding(pg_temp.v('p'), 'World fund', p_kind => 'security', p_units => '10',
                                               p_symbol => 'vwrl', p_currency => 'USD'));
select pg_temp.set('fd', public.save_holding(pg_temp.v('p'), 'ADCB deposit', p_kind => 'deposit', p_principal => '100000',
                                             p_rate_pct => '4', p_acquired_on => pg_temp.v('today')::date - 73,
                                             p_maturity_on => pg_temp.v('today')::date + 292));
select pg_temp.set('bar', public.save_holding(pg_temp.v('p'), '100 g bar', 'gold', '100', p_cost_aed => '40000',
                                              p_acquired_on => pg_temp.v('today')::date - 400));
select results_eq(
  $$ select name, kind, currency, symbol, form from public.holdings where profile_code = pg_temp.v('p') order by name $$,
  $$ values ('100 g bar'::text, 'metal'::text, 'AED'::text, null::text, 'bar'::text),
            ('ADCB deposit', 'deposit', 'AED', null, null), ('RL360 plan', 'plan', 'USD', null, null),
            ('World fund', 'security', 'USD', 'VWRL', null) $$,
  'four kinds, currencies upper-cased, a symbol for the fund, a form only for the metal');
select throws_ok($$ select public.save_holding(pg_temp.v('p'), 'Bad', p_kind => 'security') $$, '22023', null,
                 'a share or fund needs units');
select throws_ok($$ select public.save_holding(pg_temp.v('p'), 'Bad', p_kind => 'deposit', p_principal => '1') $$, '22023', null,
                 'a deposit needs rate, start and maturity');
select throws_ok($$ select public.save_holding(pg_temp.v('p'), 'Bad', p_kind => 'plan', p_currency => 'XYZ') $$, '22023', null,
                 'an unknown currency is refused');

-- ── links: the rule ─────────────────────────────────────────────────────────
reset role;
select results_eq(
  $$ select txn_code, kind, amount, amount_aed, source from public.holding_flows
     where holding_code = pg_temp.v('rl360') order by flow_date $$,
  $$ values (pg_temp.v('rl1'), 'contribution'::text, 2000.00::numeric, 7575.70::numeric, 'rule'::text),
            (pg_temp.v('rl2'), 'contribution', 2000.00, 7575.90, 'rule') $$,
  'saving the rule links the existing RL360 payments, in USD and AED');
select pg_temp.set('rl3', pg_temp.txn('card', 'purchase', 'debit', 7576.10, pg_temp.v('today')::date - 1,
                                      '*RL360 DOUGLAS GBR', 2000, 'USD', 'Investment'));
select is((select holding_code from public.holding_flows where txn_code = pg_temp.v('rl3')), pg_temp.v('rl360'),
          'a new payment is linked as it arrives');
update public.transactions set amount_aed = 7577.00 where txn_code = pg_temp.v('rl3');
select is((select amount_aed from public.holding_flows where txn_code = pg_temp.v('rl3')), 7577.00::numeric,
          'a linked flow follows its transaction''s amount');
select is((select count(*)::int from public.v_spend where txn_code in (pg_temp.v('rl1'), pg_temp.v('rl2'), pg_temp.v('rl3'))), 0,
          'linked payments leave spend');
select results_eq(
  $$ select flow, holding_code, amount_aed from public.v_cash_flow where txn_code = pg_temp.v('rl2') $$,
  $$ values ('saving'::text, pg_temp.v('rl360'), 7575.90::numeric) $$,
  'and are saving in cash flow, with their holding');
select is((select holding_name from public.v_transactions where txn_code = pg_temp.v('rl1')), 'RL360 plan',
          'v_transactions names the holding');
-- An exact rule: Wio prints RL360 as just "RI".
select pg_temp.set('ri', pg_temp.txn('card', 'purchase', 'debit', 7400.00, pg_temp.v('today')::date - 3, 'RI', 2000, 'USD'));
select pg_temp.set('pride', pg_temp.txn('card', 'purchase', 'debit', 50.00, pg_temp.v('today')::date - 3, 'PRIDE CAFE'));
select pg_temp.as_user('uid');
set local role authenticated;
select throws_ok($$ select public.save_holding(pg_temp.v('p'), 'Bad', p_kind => 'plan', p_link_pattern => 'RI') $$, '23514', null,
                 'a two-letter rule must match the whole description');
select pg_temp.set('rl360w', public.save_holding(pg_temp.v('p'), 'RL360 (Wio)', p_kind => 'plan', p_currency => 'USD',
                                                 p_link_pattern => 'ri', p_link_exact => true));
reset role;
select results_eq(
  $$ select txn_code from public.holding_flows where holding_code = pg_temp.v('rl360w') $$,
  $$ values (pg_temp.v('ri')) $$,
  'the exact rule links "RI" and not "PRIDE CAFE"');
delete from public.holdings where holding_code = pg_temp.v('rl360w');  -- keeps the totals below to the four holdings

-- ── links: by hand ──────────────────────────────────────────────────────────
select pg_temp.set('xfer', pg_temp.txn('bank', 'transfer_out', 'debit', 5000.00, pg_temp.v('today')::date - 5, 'TO SARWA'));
select pg_temp.as_user('uid');
set local role authenticated;
select public.link_transaction(pg_temp.v('p'), pg_temp.v('rl3'), null);
select public.link_transaction(pg_temp.v('p'), pg_temp.v('xfer'), pg_temp.v('fund'));
reset role;
select is((select count(*)::int from public.v_spend where txn_code = pg_temp.v('rl3')), 1,
          'an unlinked payment is spend again');
update public.transactions set amount_aed = 7578.00 where txn_code = pg_temp.v('rl3');
select is((select removed_at is not null from public.holding_flows where txn_code = pg_temp.v('rl3')), true,
          'and the rule does not link it again');
select results_eq(
  $$ select r->>'flow', r->>'holding_name' from jsonb_array_elements(public.account_ledger(pg_temp.v('p'), pg_temp.v('bank'),
       pg_temp.v('today')::date - 30, pg_temp.v('today')::date)->'rows') r $$,
  $$ values ('saving'::text, 'World fund'::text) $$,
  'a bank transfer linked by hand is saving, named in the account ledger');

-- ── values, flows and valuation ─────────────────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
select throws_ok($$ select public.record_holding_value(pg_temp.v('p'), pg_temp.v('fund'), p_value => '100') $$, '22023', null,
                 'a fund takes a unit price, not a value');
select throws_ok($$ select public.record_holding_value(pg_temp.v('p'), pg_temp.v('bar'), p_value => '100') $$, '22023', null,
                 'a metal is priced by the feed');
select public.record_holding_value(pg_temp.v('p'), pg_temp.v('rl360'), p_value => '6500.00');
select public.record_holding_value(pg_temp.v('p'), pg_temp.v('fund'), p_unit_price => '130.50');
select public.add_holding_flow(pg_temp.v('p'), pg_temp.v('fund'), 'income', pg_temp.v('today')::date - 2, '20', p_notes => 'dividend');
select results_eq(
  $$ select h->>'name', h->>'value', h->>'value_aed', h->>'cost_aed', h->>'income_aed', h->>'gain_aed', (h->>'is_estimate')::boolean
     from jsonb_array_elements(public.holdings_valuation(pg_temp.v('p'))->'holdings') h order by h->>'name' $$,
  $$ values ('100 g bar'::text, '50000.00'::text, '50000.00'::text, '40000.00'::text, '0.00'::text, '10000.00'::text, false),
            ('ADCB deposit', '100800.00', '100800.00', '100000.00', '0.00', '800.00', true),
            ('RL360 plan', '6500.00', '23871.25', '15151.60', '0.00', '8719.65', false),
            ('World fund', '1305.00', '4792.61', '5000.00', '73.45', '-133.94', false) $$,
  'value in each currency and AED; cost = contributions − withdrawals; gain adds income; a deposit accrues');
select is((select count(*)::int from jsonb_array_elements(public.holding_detail(pg_temp.v('p'), pg_temp.v('rl360'))->'flows')), 2,
          'holding_detail lists the active flows');

-- ── returns ─────────────────────────────────────────────────────────────────
select results_eq(
  $$ select h->>'added_aed', h->>'growth_aed', h->>'simple_pct',
            abs((h->>'annual_pct')::numeric - round(((power(1.25::numeric, 365.0 / 400) - 1) * 100), 2)) <= 0.01
     from jsonb_array_elements(public.holding_returns(pg_temp.v('p'), 'all')->'holdings') h where h->>'name' = '100 g bar' $$,
  $$ values ('40000.00'::text, '10000.00'::text, '25.00'::text, true) $$,
  'all time: added 40,000, grew 10,000 (25%), about 22.6% a year');
select is((select (h->>'complete')::boolean from jsonb_array_elements(public.holding_returns(pg_temp.v('p'), 'ytd')->'holdings') h
           where h->>'name' = '100 g bar'), false,
          'this year: no gold price on 1 January, so the start value is unknown');
select is((select h->>'annual_pct' from jsonb_array_elements(public.holding_returns(pg_temp.v('p'), 'all')->'holdings') h
           where h->>'name' = 'World fund'), null, 'under 90 days of history: no yearly rate');
select is((select (h->>'complete')::boolean from jsonb_array_elements(public.holding_returns(pg_temp.v('p'), 'all')->'holdings') h
           where h->>'name' = 'RL360 plan'), true, 'a plan with linked payments is complete');
select throws_ok($$ select public.holding_returns(pg_temp.v('p'), 'week') $$, '22023', null, 'periods are all, ytd and 12m');

-- ── cash flow by holding, allocation ────────────────────────────────────────
select results_eq(
  $$ select x->>'holding_name', sum((x->>'amount_aed')::numeric)
     from jsonb_array_elements(public.cash_flow_savings(pg_temp.v('p'), pg_temp.v('today')::date - 60, pg_temp.v('today')::date)) x
     group by 1 order by 1 $$,
  $$ values ('RL360 plan'::text, 15151.60::numeric), ('World fund', 5000.00) $$,
  'saving by holding');
select results_eq(
  $$ select x->>'class', x->>'value_aed' from jsonb_array_elements(public.net_worth(pg_temp.v('p'))->'allocation') x $$,
  $$ values ('deposit'::text, '100800.00'::text), ('gold', '50000.00'), ('plan', '23871.25'), ('security', '4792.61') $$,
  'allocation by class, largest first');
reset role;

-- ── a metal's cost is its first contribution ────────────────────────────────
select is((select flow_date::text || ' ' || amount_aed from public.holding_flows where holding_code = pg_temp.v('bar')),
          (pg_temp.v('today')::date - 400)::text || ' 40000.00', 'the bar''s cost and date are a contribution');
select pg_temp.as_user('uid');
set local role authenticated;
select public.save_holding(pg_temp.v('p'), '100 g bar', 'gold', '100', p_holding_code => pg_temp.v('bar'));
reset role;
select is((select removed_at is not null from public.holding_flows where holding_code = pg_temp.v('bar')), true,
          'clearing the cost removes that contribution');

select pg_temp.as_user('uid2');
set local role authenticated;
select throws_ok($$ select public.holding_returns(pg_temp.v('p')) $$, '42501', null, 'a stranger cannot read returns');
select throws_ok($$ select public.link_transaction(pg_temp.v('p'), pg_temp.v('xfer'), null) $$, '42501', null, 'nor link');
select is((select count(*)::int from public.holding_flows where profile_code = pg_temp.v('p')), 0, 'nor read flows');
reset role;

select * from finish();
rollback;

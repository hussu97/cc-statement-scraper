-- A savings account shown as an investment (20261028082732, tasks/todo.md §13).
-- Mashreq NEO statements create a saver and a current account; tracking the saver makes a
-- savings_account holding valued at the account's balance, whose transfers and interest are its
-- flows. Net worth counts the saver once (holdings, not cash) and is unchanged by tracking;
-- Accounts lists it but leaves it out of the cash total; returns count the interest once; a later
-- statement's lines become flows on their own; closing the holding puts the saver back in cash.
begin;
create extension if not exists pgtap with schema extensions;
set local client_min_messages = warning;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.new_doc() returns text language sql as $$
  insert into public.documents (profile_code, storage_path, original_filename, sha256, size_bytes, source)
  values (pg_temp.v('p'), 'x/' || gen_random_uuid(), 'consolidated.pdf',
          encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 100, 'outlook')
  returning doc_code $$;
create function pg_temp.line(p_no int, p_date date, p_desc text, p_merchant text, p_amount text,
                             p_direction text, p_kind text)
returns jsonb language sql as $$
  select jsonb_build_object('line_no', p_no, 'txn_date', p_date, 'txn_time', null, 'posting_date', p_date,
    'description_raw', p_desc, 'merchant_normalized', p_merchant, 'amount_original', p_amount,
    'currency_original', 'AED', 'amount_aed', p_amount, 'fx_rate', '1', 'direction', p_direction,
    'kind', p_kind, 'country_code', null, 'card_last4', null, 'card_holder', null,
    'legacy_fingerprint', repeat('0', 64))
$$;
create function pg_temp.stmt(p_number text, p_kind text, p_product text, p_end date, p_open text, p_close text,
                             p_lines jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('kind', 'statement', 'bank_code', 'MASHREQ',
    'statement_reference', p_number || '-' || to_char(p_end, 'YYYYMMDD'), 'reference_source', 'fallback',
    'statement_date', p_end, 'period_start', date_trunc('month', p_end)::date, 'period_end', p_end,
    'due_date', null, 'primary_card_last4', null, 'card_holder', 'JANE Q SAMPLE', 'card_type', null,
    'account', jsonb_build_object('kind', p_kind, 'number', p_number, 'ref', right(p_number, 4),
                                  'iban', 'AE000330000' || p_number, 'product', p_product, 'currency', 'AED'),
    'totals', jsonb_build_object('opening_balance', p_open, 'closing_balance', p_close, 'total_debits', null,
                                 'total_credits', null, 'min_due', null, 'credit_limit', null),
    'warnings', '[]'::jsonb, 'metadata', '{}'::jsonb, 'lines', p_lines)
$$;
create function pg_temp.payload(p_statements jsonb) returns jsonb language sql as $$
  select jsonb_build_object('contract_version', 1, 'parser_version', 'test', 'bank_code', 'MASHREQ',
    'document_kind', 'account_statement_pdf', 'statements', p_statements)
$$;
create function pg_temp.acc(p_ref text) returns text language sql as $$
  select account_code from public.accounts where profile_code = pg_temp.v('p') and account_ref = p_ref $$;
create function pg_temp.nw() returns jsonb language sql as $$ select private.net_worth(pg_temp.v('p')) $$;

-- ── setup: a ledger, and May's statement (10,000 in, 41.66 interest) ───────
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't76-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't76-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t76-' || left(pg_temp.v('uid'), 8), 'Saver'));
reset role;

select public.ingest_parsed_document(pg_temp.new_doc(), pg_temp.payload(jsonb_build_array(
  pg_temp.stmt('099990002222', 'savings', 'Neo Plus Saver - Balance', '2026-05-31', '0.00', '10041.66', jsonb_build_array(
    pg_temp.line(1, '2026-05-08', 'Inward Remittance J SAMPLE SAMPLE BANK', 'INWARD REMITTANCE', '10000.00',
                 'credit', 'transfer_in'),
    pg_temp.line(2, '2026-05-31', 'Interest 099990002222', 'INTEREST', '41.66', 'credit', 'interest'))),
  pg_temp.stmt('099990001111', 'current', 'Neo Current Account', '2026-05-31', '0.00', '0.00', '[]'::jsonb))));
select pg_temp.set('saver', pg_temp.acc('2222'));
select pg_temp.set('nw_before', pg_temp.nw()->>'net_aed');
select is(pg_temp.nw()->>'cash_aed', '10041.66', 'before tracking, the saver is cash');

-- ── tracking: owner only, bank accounts only ────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('h', public.track_account_as_investment(pg_temp.v('p'), pg_temp.v('saver'), '5'));
select is(public.track_account_as_investment(pg_temp.v('p'), pg_temp.v('saver')), pg_temp.v('h'),
          'tracking again is a no-op that returns the same holding');
reset role;
insert into public.accounts (profile_code, bank_code, nickname) values (pg_temp.v('p'), 'MASHREQ', 'Card')
returning pg_temp.set('card', account_code);
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok($$ select public.track_account_as_investment(pg_temp.v('p'), pg_temp.v('card')) $$,
                 '22023', 'not a bank account of this ledger', 'a card account cannot be tracked');
reset role;

select results_eq(
  $$ select kind, name, currency, institution, rate_pct, account_code, status, portfolio
     from public.holdings where holding_code = pg_temp.v('h') $$,
  $$ values ('savings_account'::text, 'Neo Plus Saver - Balance'::text, 'AED'::text, 'MASHREQ'::text, 5::numeric,
             pg_temp.v('saver'), 'active'::text, 'wealth'::text) $$,
  'the holding is the saver, in its currency, at its stated rate');
select results_eq(
  $$ select flow_date, kind, amount_aed, source from public.holding_flows
     where holding_code = pg_temp.v('h') and removed_at is null order by flow_date $$,
  $$ values ('2026-05-08'::date, 'contribution'::text, 10000.00::numeric, 'account'::text),
            ('2026-05-31', 'income', 41.66, 'account') $$,
  'the account''s transfer in and interest so far are its flows');

-- ── counted once ────────────────────────────────────────────────────────────
select results_eq(
  $$ select pg_temp.nw()->>'cash_aed', pg_temp.nw()->>'holdings_aed', pg_temp.nw()->>'net_aed' $$,
  $$ values ('0.00'::text, '10041.66'::text, pg_temp.v('nw_before')) $$,
  'net worth moves the saver from cash to holdings and stays the same');
select ok(pg_temp.nw()->'allocation' @> '[{"class": "savings_account", "value_aed": "10041.66"}]'::jsonb,
          'allocation shows it as a savings account');
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select results_eq(
  $$ select (c->>'total_aed'), (select a->>'investment_holding_code' from jsonb_array_elements(c->'accounts') a
                                where a->>'account_code' = pg_temp.v('saver')),
            jsonb_array_length(c->'accounts')
     from public.cash_position(pg_temp.v('p')) c $$,
  $$ values ('0.00'::text, pg_temp.v('h'), 2) $$,
  'Accounts lists the saver, marked as an investment, outside the cash total');
reset role;

-- ── June: the sweep to the current account and June's interest become flows ─
select public.ingest_parsed_document(pg_temp.new_doc(), pg_temp.payload(jsonb_build_array(
  pg_temp.stmt('099990002222', 'savings', 'Neo Plus Saver - Balance', '2026-06-30', '10041.66', '10041.84', jsonb_build_array(
    pg_temp.line(1, '2026-06-01', 'Account to Account Transfer FROM ACCOUNT No:099990002222 TO ACCOUNT No: 099990001111',
                 'ACCOUNT TO ACCOUNT TRANSFER', '41.66', 'debit', 'transfer_out'),
    pg_temp.line(2, '2026-06-30', 'Interest 099990002222', 'INTEREST', '41.84', 'credit', 'interest'))),
  pg_temp.stmt('099990001111', 'current', 'Neo Current Account', '2026-06-30', '0.00', '41.66', jsonb_build_array(
    pg_temp.line(1, '2026-06-01', 'Account to Account Transfer FROM ACCOUNT No:099990002222 TO ACCOUNT No: 099990001111',
                 'ACCOUNT TO ACCOUNT TRANSFER', '41.66', 'credit', 'transfer_in'))))));
select results_eq(
  $$ select flow_date, kind, amount_aed from public.holding_flows
     where holding_code = pg_temp.v('h') and removed_at is null order by flow_date $$,
  $$ values ('2026-05-08'::date, 'contribution'::text, 10000.00::numeric), ('2026-05-31', 'income', 41.66),
            ('2026-06-01', 'withdrawal', 41.66), ('2026-06-30', 'income', 41.84) $$,
  'a later statement''s transfer out and interest become flows on their own; the current account makes none');

-- ── value: the account's balance, on any day ────────────────────────────────
select results_eq(
  $$ select (select value_aed from private.holding_values(pg_temp.v('p'), '2026-05-31 23:59:59+04') where holding_code = pg_temp.v('h')),
            (select value_aed from private.holding_values(pg_temp.v('p'), now()) where holding_code = pg_temp.v('h')),
            (select balance from public.v_bank_balances where account_code = pg_temp.v('saver')) $$,
  $$ values (10041.66::numeric, 10041.84::numeric, 10041.84::numeric) $$,
  'the holding is worth the saver''s balance at the end of May and now');
select results_eq(
  $$ select pg_temp.nw()->>'cash_aed', pg_temp.nw()->>'holdings_aed', pg_temp.nw()->>'net_aed' $$,
  $$ values ('41.66'::text, '10041.84'::text, '10083.50'::text) $$,
  'net worth: the current account is cash, the saver a holding, nothing counted twice');

-- ── returns: the interest once ──────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select results_eq(
  $$ select r->>'added_aed', r->>'income_aed', r->>'growth_aed', (r->>'complete')::boolean, (r->>'annual_pct') is not null
     from jsonb_array_elements(public.holding_returns(pg_temp.v('p'), 'all')->'holdings') r
     where r->>'holding_code' = pg_temp.v('h') $$,
  $$ values ('9958.34'::text, '83.50'::text, '83.50'::text, true, true) $$,
  'all time: 10,000 in less the sweep, growth is the interest, counted once');
select results_eq(
  $$ select r->>'cost_aed', r->>'income_aed', r->>'gain_aed', r->>'account_code', r->>'rate_pct'
     from jsonb_array_elements(public.holdings_valuation(pg_temp.v('p'))->'holdings') r
     where r->>'holding_code' = pg_temp.v('h') $$,
  $$ values ('9958.34'::text, '83.50'::text, '83.50'::text, pg_temp.v('saver'), '5.000'::text) $$,
  'the valuation''s gain is the interest once, and names the account');
select is(public.holdings_valuation(pg_temp.v('p'))->>'gain_aed', '83.50', 'and so is the total gain');
reset role;
select is((select count(*)::int from public.v_spend s where s.account_code in (pg_temp.v('saver'), pg_temp.acc('1111'))),
          0, 'none of it is spend');

-- ── closing the holding puts the saver back in cash ─────────────────────────
update public.holdings set status = 'closed' where holding_code = pg_temp.v('h');
select results_eq(
  $$ select pg_temp.nw()->>'cash_aed', pg_temp.nw()->>'holdings_aed', pg_temp.nw()->>'net_aed' $$,
  $$ values ('10083.50'::text, '0.00'::text, '10083.50'::text) $$,
  'a closed holding leaves the saver to cash');
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select is(public.track_account_as_investment(pg_temp.v('p'), pg_temp.v('saver')), pg_temp.v('h'),
          'tracking again reopens the same holding');
reset role;
select results_eq($$ select status, rate_pct from public.holdings where holding_code = pg_temp.v('h') $$,
                  $$ values ('active'::text, 5::numeric) $$, 'and it is active, its rate kept');
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select public.track_account_as_investment(pg_temp.v('p'), pg_temp.v('saver'), '');
reset role;
select is((select rate_pct from public.holdings where holding_code = pg_temp.v('h')), null, 'an empty rate clears it');

-- ── the schema keeps the link honest ────────────────────────────────────────
select throws_ok(
  $$ insert into public.holdings (profile_code, kind, name) values (pg_temp.v('p'), 'savings_account', 'No account') $$,
  '23514', null, 'a savings_account holding needs its account');
select throws_ok(
  $$ insert into public.holdings (profile_code, kind, name, account_code)
     values (pg_temp.v('p'), 'savings_account', 'Twice', pg_temp.v('saver')) $$,
  '23505', null, 'one active holding per account');

select * from finish();
rollback;

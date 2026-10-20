-- The cash_advance insight (20261020131850_cash_advance_insight.sql).
-- Runs on a non-empty DB: every assertion is scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
set local client_min_messages = warning;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.txn(p_desc text, p_aed numeric, p_kind text, p_days_ago int,
                            p_currency text default 'AED', p_original numeric default null) returns text
language sql as $$
  insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description, merchant_code,
                                   amount_original, currency_original, amount_aed, amount_source, status)
  values (pg_temp.v('p'), pg_temp.v('acc'), p_kind, 'debit', public.dubai_date(now()) - p_days_ago, p_desc,
          private.resolve_merchant(p_desc), coalesce(p_original, p_aed), p_currency, p_aed, 'statement_line', 'posted')
  returning txn_code $$;
create function pg_temp.insight(p_txn text) returns public.insights language sql as $$
  select * from public.insights where profile_code = pg_temp.v('p') and kind = 'cash_advance' and dedupe_key = p_txn $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't57-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now());
select pg_temp.set('uid', (select id::text from auth.users where email like 't57-%' order by created_at desc limit 1));
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t57-' || left(pg_temp.v('uid'), 8), 'Cash advance insight'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'FAB');
select pg_temp.set('acc', (select account_code from public.accounts where profile_code = pg_temp.v('p')));

-- The FAB Nairobi withdrawal: KES 5,000, then the bank's fee and its VAT the same day.
select pg_temp.set('atm', pg_temp.txn('DTBKEN NAIROBI KEN', 147.45, 'cash_advance', 3, 'KES', 5000));
select pg_temp.txn('CASH ADVANCE FEE', 150.00, 'fee', 3);
select pg_temp.txn('VAT ON CASH ADVANCE FEE', 7.50, 'fee', 3);
select pg_temp.txn('VAT ON SERVICE CHARGES', 0.27, 'fee', 3);
-- One with no fee line, one too old, and a purchase.
select pg_temp.set('atm2', pg_temp.txn('ATM WDL MALL OF EMIRATES', 500, 'cash_advance', 10));
select pg_temp.set('old', pg_temp.txn('BANGKOK BANK PHUKET', 148.42, 'cash_advance', 45));
select pg_temp.set('buy', pg_temp.txn('JAVA HOUSE NAIROBI KEN', 20, 'purchase', 3));

select lives_ok($$ select private.generate_insights(pg_temp.v('p')) $$, 'generate_insights runs');
select is((pg_temp.insight(pg_temp.v('atm'))).severity, 'warn', 'a cash advance makes a heads-up');
select is((pg_temp.insight(pg_temp.v('atm'))).title, 'Cash advance: ' || (select display_name from public.merchants
          where merchant_code = private.resolve_merchant('DTBKEN NAIROBI KEN')), 'titled with the merchant');
select matches((pg_temp.insight(pg_temp.v('atm'))).body,
               '^AED 147 \(KES 5,000\.00\) withdrawn on .*, plus AED 158 in fees\. Cash advances accrue interest',
               'the body gives the amount, the original currency and the fee with its VAT (not the other VAT line)');
select is((pg_temp.insight(pg_temp.v('atm'))).data->>'txn_code', pg_temp.v('atm'), 'it links to the transaction');
select is((pg_temp.insight(pg_temp.v('atm'))).data->>'fee', '157.50', 'its data carries the exact fee (150 + 7.50 VAT)');
select is((pg_temp.insight(pg_temp.v('atm'))).valid_until, public.dubai_date(now()) - 3 + 30,
          'it is kept 30 days from the withdrawal');
select matches((pg_temp.insight(pg_temp.v('atm2'))).body, '^AED 500 withdrawn on [^,]*\. Cash',
               'a cash advance without a fee line says no fee');
select is((pg_temp.insight(pg_temp.v('old'))).insight_code, null, 'a cash advance older than 30 days makes none');
select is((select count(*)::int from public.insights where profile_code = pg_temp.v('p') and kind = 'cash_advance'),
          2, 'and a purchase makes none');

-- Dismissed stays dismissed on the next nightly run.
update public.insights set dismissed_at = now() where profile_code = pg_temp.v('p') and dedupe_key = pg_temp.v('atm');
select private.generate_insights(pg_temp.v('p'));
select isnt((pg_temp.insight(pg_temp.v('atm'))).dismissed_at, null, 'a dismissed cash advance insight stays dismissed');

select * from finish();
rollback;

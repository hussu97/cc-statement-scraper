-- Category taxonomy v2 (20261010001100_category_taxonomy_v2.sql): a new profile gets the new
-- categories, and the seed rules land merchants in them; the over-broad UBER / EMIRATES rules
-- are fixed and the length tie-break keeps specific brand rules ahead of generic ones.
-- (The existing-profile path was replayed against production descriptions before release.)
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
-- plpgsql: the insert's after-statement categorisation trigger must run before the read.
create function pg_temp.cat_for(p_desc text, p_direction text default 'debit') returns text language plpgsql as $$
declare v_txn text;
begin
  insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description, merchant_code,
                                   amount_original, currency_original, amount_aed, amount_source, status)
  values (pg_temp.v('p'), pg_temp.v('acc'), case when p_direction = 'credit' then 'refund' else 'purchase' end,
          p_direction, current_date, p_desc, private.resolve_merchant(p_desc), 10, 'AED', 10, 'statement_line', 'posted')
  returning txn_code into v_txn;
  return (select c.name from public.transactions x join public.categories c on c.category_code = x.rule_category_code
          where x.txn_code = v_txn);
end $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't25-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t25-' || left(pg_temp.v('uid'), 8), 'Taxonomy'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'FAB');
select pg_temp.set('acc', (select account_code from public.accounts where profile_code = pg_temp.v('p')));

-- ═══ categories ═══════════════════════════════════════════════════════════
select is((select count(*)::int from public.categories where profile_code = pg_temp.v('p')), 32,
          'a new profile gets the 18 original, 10 taxonomy-v2 and 4 cash-flow categories');
select set_eq($$ select name from public.categories where profile_code = pg_temp.v('p') $$,
              $$ select name from private.seed_categories $$, 'every seed category, by name');
select is((select kind from public.categories where profile_code = pg_temp.v('p') and name = 'Bank Fees & Interest'),
          'fee', 'Bank Fees & Interest is a fee category (counts as spend)');
select ok(not exists (select 1 from public.categories c where c.profile_code = pg_temp.v('p') and c.color_token is null),
          'every category has a colour token');

-- ═══ seed rules ═══════════════════════════════════════════════════════════
-- Each case inserts a transaction and reads the category its rule gave it.
create temp table cases (description text, direction text, want text);
insert into cases values
  ('NOON FOOD FOOD DELIVERYDUBAI', 'debit', 'Food Delivery'),
  ('UBERJP_EATSAMSTERDAM', 'debit', 'Food Delivery'),
  ('UBER *TRIP HELP.UBER.COM', 'debit', 'Transport'),
  ('CAREEM HALA RIDEDUBAI', 'debit', 'Transport'),
  ('LIME*RIDE NAH2 LONDON LND', 'debit', 'Transport'),
  ('NOON.COMDUBAI', 'debit', 'Online Marketplaces'),
  ('NOON MINUTESDUBAI', 'debit', 'Grocery'),
  ('AMAZON RETAIL DUBAI DXB', 'debit', 'Online Marketplaces'),
  ('AMAZON NOWDUBAI', 'debit', 'Grocery'),
  ('AMAZON PRIME SUBSCRIPTDUBAI', 'debit', 'Subscription'),
  ('AMAZON CATERINGNA', 'debit', 'Dining'),
  ('NAMSHI DUBAI ARE', 'debit', 'Fashion'),
  ('SEPHORADUBAI', 'debit', 'Beauty & Personal Care'),
  ('PERFECT GENTS SALONSHARJAH', 'debit', 'Beauty & Personal Care'),
  ('TABBY FZ LLCDUBAI', 'debit', 'BNPL Instalments'),
  ('TABBY 800 82229DUBAI', 'debit', 'BNPL Instalments'),
  ('ADNOC AL SAFA 2 521DUBAI', 'debit', 'Car & Fuel'),
  ('TESLA MOTORS NETHERLANDS', 'debit', 'Car & Fuel'),
  ('NATIONAL PARKING COMPA DUBAI', 'debit', 'Car & Fuel'),
  ('KFC ADNOC MUHAISNAHDUBAI', 'debit', 'Dining'),
  ('MCDONALDS ADNOC 4244ABUDHABI', 'debit', 'Dining'),
  ('EMIRATESDUBAI', 'debit', 'Flights'),
  ('EMIRATES1762206730198DUBAI', 'debit', 'Flights'),
  ('AIR ARABIA PJSC 3DSHARJAH', 'debit', 'Flights'),
  ('EMIRATES HOSPITALSDUBAI', 'debit', 'Medicine'),
  ('BOOKING.COM HOTEL AMSTERDAM', 'debit', 'Travel'),
  ('FAB - ETISALAT ABU DHABI UAE', 'debit', 'Telecom & Internet'),
  ('CAREEM PAY DUABU DHABI', 'debit', 'Telecom & Internet'),
  ('DUBAI ELECTRICITYDUBAI', 'debit', 'Utilities'),
  ('CASH ADVANCE FEE', 'debit', 'Bank Fees & Interest'),
  ('VAT ON CASH ADVANCE FEE', 'debit', 'Bank Fees & Interest'),
  ('MEMBERSHIP FEE ASSESSED', 'debit', 'Bank Fees & Interest'),
  ('MURABAHA PROFIT', 'debit', 'Bank Fees & Interest'),
  ('MURABAHA PROFIT', 'credit', 'Cashback'),
  ('FOREIGN TRANSACTION FEE', 'debit', 'Forex Charge'),
  ('INVOLUNTARY LOSS OF EDUBAI', 'debit', 'Insurance'),
  ('AL JAMEA TUS SAIFIYAH NAIROBI KNE', 'debit', 'Education'),
  ('UDEMY: ONLINE COURSES SAN FR', 'debit', 'Education');
select is(pg_temp.cat_for(description, direction), want, description || ' → ' || want) from cases;
select is(pg_temp.cat_for('EMIRATES LEISURE RETDUBAI'), null,
          'EMIRATES no longer catches non-airline Emirates businesses (left to the LLM)');

select * from finish();
rollback;

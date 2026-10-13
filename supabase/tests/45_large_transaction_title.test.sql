-- The nightly large_transaction insight names the merchant (20261013042809, audit WEB-16r):
-- the title uses public.anomalies' merchant_name, and falls back to the cleaned description
-- when the charge has no merchant.
-- Runs on a non-empty DB: every key is unique to this run and every assertion is scoped to this
-- run's profile. Dates are relative to today, so generate_insights' 3-day window sees the charges.
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
-- A posted AED purchase; p_merchant false → no merchant. Returns its txn_code.
create function pg_temp.txn(p_days_ago int, p_desc text, p_aed numeric, p_cat text, p_merchant boolean default true)
returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source, merchant_code,
                                   manual_category_code)
  values (pg_temp.v('p'), pg_temp.v('acc'), 'posted', 'purchase', 'debit', current_date - p_days_ago, p_desc,
          p_aed, 'AED', p_aed, 'manual', case when p_merchant then private.resolve_merchant(p_desc) end,
          pg_temp.cat(p_cat))
  returning txn_code $$;
create function pg_temp.title(p_key text) returns text language sql as $$
  select title from public.insights where profile_code = pg_temp.v('p') and kind = 'large_transaction'
    and dedupe_key = pg_temp.v(p_key) $$;

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't45-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now())
returning pg_temp.set('uid', id::text);
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t45-' || left(pg_temp.v('uid'), 8), 'Insights'));
reset role;
select set_config('request.jwt.claims', '', true);
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ADCB') returning account_code)
select pg_temp.set('acc', account_code) from a;

-- History: six AED 100 meals at one restaurant; twelve AED ~300 purchases, each at its own shop.
select pg_temp.txn(d, 'T45 BAYLEAF RESTAURANT', 100, 'Dining') from unnest(array[30, 60, 90, 120, 150, 180]) d;
select pg_temp.txn(20 + 10 * i::int, 'T45 SHOP ' || w, case when i % 2 = 0 then 290 else 310 end, 'Shopping')
from unnest(array['ALPHA', 'BRAVO', 'CHARLIE', 'DELTA', 'ECHO', 'FOXTROT', 'GOLF', 'HOTEL', 'INDIA', 'JULIET',
                  'KILO', 'LIMA']) with ordinality x(w, i);

-- Yesterday: a large meal under a different spelling of the restaurant, and a large Shopping
-- charge with no merchant at all.
select pg_temp.set('bayleaf', pg_temp.txn(1, 'T45 BAYLEAF RESTAURANT,DUBAI', 500, 'Dining'));
select pg_temp.set('nomerchant', pg_temp.txn(1, 'T45 SOME UNKNOWN STORE', 3000, 'Shopping', false));

select private.generate_insights(pg_temp.v('p'));

select is(pg_temp.title('bayleaf'),
          'Unusually large: ' || (select m.display_name from public.merchants m join public.transactions t
                                  on t.merchant_code = m.merchant_code where t.txn_code = pg_temp.v('bayleaf')),
          'the insight is titled with the merchant''s display name');
select isnt(pg_temp.title('bayleaf'), 'Unusually large: T45 Bayleaf Restaurant,dubai',
            'not with the statement description');
select is(pg_temp.title('nomerchant'), 'Unusually large: T45 Some Unknown Store',
          'without a merchant, the cleaned description is the fallback');
select is((select body from public.insights where profile_code = pg_temp.v('p') and kind = 'large_transaction'
           and dedupe_key = pg_temp.v('bayleaf')), 'AED 500, usually about AED 100.',
          'the body is unchanged');

select * from finish();
rollback;

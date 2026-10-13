-- Anomalies in plain words and "This is fine" (20261012234036_anomalies_plain_and_dismissals.sql,
-- audit WEB-16): merchant and category names, the first-purchase rule (first AND above the
-- threshold), baseline_scope / times_usual, dismiss_anomaly (owner only, durable, idempotent,
-- dismisses the insight) and tenant isolation of anomaly_dismissals.
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
create function pg_temp.new_user(p_key text) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          email_confirmed_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't42-' || p_key || '-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now(), now())
  returning pg_temp.set(p_key, id::text) $$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.cat(p_name text) returns text language sql as $$
  select category_code from public.categories where profile_code = pg_temp.v('p') and name = p_name $$;
-- A posted AED purchase; p_desc null → no merchant. Returns its txn_code.
create function pg_temp.txn(p_days_ago int, p_desc text, p_aed numeric, p_cat text, p_merchant boolean default true)
returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source, merchant_code,
                                   manual_category_code)
  values (pg_temp.v('p'), pg_temp.v('acc'), 'posted', 'purchase', 'debit', current_date - p_days_ago, p_desc,
          p_aed, 'AED', p_aed, 'manual', case when p_merchant then private.resolve_merchant(p_desc) end,
          pg_temp.cat(p_cat))
  returning txn_code $$;
-- 'reason:scope:baseline_mean:times_usual' for one charge of the last week, or null when not flagged.
create function pg_temp.anom(p_key text) returns text language sql as $$
  select a.reason || ':' || coalesce(a.baseline_scope, '-') || ':' || coalesce(a.baseline_mean::text, '-') || ':'
         || coalesce(a.times_usual::text, '-')
  from public.anomalies(pg_temp.v('p'), current_date - 7, current_date) a where a.txn_code = pg_temp.v(p_key) $$;
-- ── setup: owner, viewer, outsider (with a profile of their own) ────────────
select pg_temp.new_user('owner');
select pg_temp.new_user('viewer');
select pg_temp.new_user('other');
select pg_temp.as_user('owner');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t42-' || left(pg_temp.v('owner'), 8), 'Anomalies'));
reset role;
insert into public.profile_members (profile_code, user_id, role) values (pg_temp.v('p'), pg_temp.v('viewer')::uuid, 'viewer');
select pg_temp.as_user('other');
set local role authenticated;
select pg_temp.set('q', public.create_profile('t42o-' || left(pg_temp.v('other'), 8), 'Other'));
reset role;
select set_config('request.jwt.claims', '', true);
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ADCB') returning account_code)
select pg_temp.set('acc', account_code) from a;

-- ── history (all before the last week) ─────────────────────────────────────
-- Dining: six AED 100 meals at one merchant.
select pg_temp.txn(d, 'T42 BAYLEAF RESTAURANT', 100, 'Dining') from unnest(array[30, 60, 90, 120, 150, 180]) d;
-- Shopping: twelve purchases of about AED 300, each at its own merchant.
select pg_temp.txn(20 + 10 * i::int, 'T42 SHOP ' || w, case when i % 2 = 0 then 290 else 310 end, 'Shopping')
from unnest(array['ALPHA', 'BRAVO', 'CHARLIE', 'DELTA', 'ECHO', 'FOXTROT', 'GOLF', 'HOTEL', 'INDIA', 'JULIET',
                  'KILO', 'LIMA']) with ordinality x(w, i);
-- Travel: five AED 3,000 stays, each at its own hotel.
select pg_temp.txn(40 * i::int, 'T42 STAY ' || w, 3000, 'Travel')
from unnest(array['MARINA', 'DESERT', 'OASIS', 'HARBOUR', 'GARDEN']) with ordinality x(w, i);
-- Uncategorised: ten AED 100 charges, each at its own merchant.
select pg_temp.txn(20 + 10 * i::int, 'T42 MISC ' || w, 100, null)
from unnest(array['ONE', 'TWO', 'THREE', 'FOUR', 'FIVE', 'SIX', 'SEVEN', 'EIGHT', 'NINE', 'TEN']) with ordinality x(w, i);

-- ── the last week ───────────────────────────────────────────────────────────
select pg_temp.set('bayleaf', pg_temp.txn(1, 'T42 BAYLEAF RESTAURANT,DUBAI', 500, 'Dining'));
select pg_temp.set('shop', pg_temp.txn(2, 'T42 SHOP ALPHA', 3000, 'Shopping'));
select pg_temp.set('grandview', pg_temp.txn(1, 'T42 GRANDVIEW HOTEL', 2500, 'Travel'));
select pg_temp.set('palace', pg_temp.txn(1, 'T42 PALACE HOTEL', 7000, 'Travel'));
select pg_temp.set('academy', pg_temp.txn(1, 'T42 ACADEMY', 800, 'Education'));
select pg_temp.set('tailor', pg_temp.txn(1, 'T42 TAILOR', 400, 'Fashion'));
select pg_temp.set('nomerchant', pg_temp.txn(1, 'T42 CASH THING', 5000, 'Entertainment', false));
select pg_temp.set('misc', pg_temp.txn(1, 'T42 MISC ONE', 2000, null));

-- ═══ names ═════════════════════════════════════════════════════════════════
select pg_temp.as_user('viewer');
set local role authenticated;
select is((select merchant_name from public.anomalies(pg_temp.v('p'), current_date - 7, current_date)
           where txn_code = pg_temp.v('bayleaf')),
          (select m.display_name from public.merchants m join public.transactions t on t.merchant_code = m.merchant_code
           where t.txn_code = pg_temp.v('bayleaf')),
          'a member gets the merchant''s display name');
select isnt((select merchant_name from public.anomalies(pg_temp.v('p'), current_date - 7, current_date)
             where txn_code = pg_temp.v('bayleaf')), 'T42 BAYLEAF RESTAURANT,DUBAI',
            'the name is not the raw statement description');
select is((select merchant_code from public.anomalies(pg_temp.v('p'), current_date - 7, current_date)
           where txn_code = pg_temp.v('bayleaf')),
          (select merchant_code from public.transactions where profile_code = pg_temp.v('p')
           and description = 'T42 BAYLEAF RESTAURANT' limit 1),
          'both Bayleaf spellings carry one merchant_code, so they read as one merchant');
select is((select category_name from public.anomalies(pg_temp.v('p'), current_date - 7, current_date)
           where txn_code = pg_temp.v('shop')), 'Shopping', 'anomalies returns the category name');
select ok((select baseline_sd is not null and description = 'T42 SHOP ALPHA'
           from public.anomalies(pg_temp.v('p'), current_date - 7, current_date) where txn_code = pg_temp.v('shop')),
          'the earlier columns (description, baseline_sd) are still returned');

-- ═══ rules ═════════════════════════════════════════════════════════════════
select is(pg_temp.anom('bayleaf'), 'merchant_outlier:merchant:100.00:5',
          'a merchant outlier compares with the merchant: 5× the usual AED 100');
select is(pg_temp.anom('shop'), 'category_outlier:category:300.00:10',
          'a category outlier compares with the category, even at a merchant with history');
select is(pg_temp.anom('palace'), 'new_merchant_large:category:3000.00:2.3',
          'a first purchase at least 2× the category usual is flagged, with one decimal below 3×');
select is(pg_temp.anom('grandview'), null,
          'a first purchase below the category usual is not flagged (was "Large first purchase")');
select is(pg_temp.anom('academy'), 'new_merchant_large:-:-:-',
          'a large first purchase in a category with no usual is flagged without a comparison');
select is(pg_temp.anom('tailor'), null, 'a first purchase under AED 500 is not flagged');
select is(pg_temp.anom('nomerchant'), null, 'a charge with no merchant is never a first purchase');
select is(pg_temp.anom('misc'), null, 'uncategorised spend has no category usual to be an outlier of');
reset role;

-- ═══ dismiss_anomaly ═══════════════════════════════════════════════════════
select set_config('request.jwt.claims', '', true);
select private.generate_insights(pg_temp.v('p'));
select is((select count(*)::int from public.insights where profile_code = pg_temp.v('p') and kind = 'large_transaction'
           and dedupe_key = pg_temp.v('palace') and dismissed_at is null), 1,
          'the nightly feed makes a large_transaction insight from the anomaly');

with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('q'), 'FAB') returning account_code),
     t as (insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                            amount_original, currency_original, amount_aed, amount_source)
           select pg_temp.v('q'), a.account_code, 'posted', 'purchase', 'debit', current_date - 1, 'T42 OTHER', 900,
                  'AED', 900, 'manual' from a
           returning txn_code)
select pg_temp.set('qtxn', txn_code) from t;

select pg_temp.as_user('viewer');
set local role authenticated;
select throws_ok($$ select public.dismiss_anomaly(pg_temp.v('p'), pg_temp.v('palace')) $$, '42501', null,
                 'a viewer cannot dismiss an anomaly');
select throws_ok($$ insert into public.anomaly_dismissals (profile_code, txn_code) values (pg_temp.v('p'), pg_temp.v('palace')) $$,
                 '42501', null, 'clients cannot write anomaly_dismissals directly');
reset role;
select pg_temp.as_user('other');
set local role authenticated;
select throws_ok($$ select public.dismiss_anomaly(pg_temp.v('p'), pg_temp.v('palace')) $$, '42501', null,
                 'a non-member cannot dismiss an anomaly');
select throws_ok($$ select * from public.anomalies(pg_temp.v('p'), current_date - 7, current_date) $$, '42501', null,
                 'a non-member cannot read another profile''s anomalies');
reset role;

select pg_temp.as_user('owner');
set local role authenticated;
select throws_ok($$ select public.dismiss_anomaly(pg_temp.v('p'), pg_temp.v('qtxn')) $$, 'P0002', null,
                 'an owner cannot dismiss another profile''s transaction through their own');
select throws_ok($$ select public.dismiss_anomaly(pg_temp.v('q'), pg_temp.v('qtxn')) $$, '42501', null,
                 'an owner of one profile is not an owner of another');
select lives_ok($$ select public.dismiss_anomaly(pg_temp.v('p'), pg_temp.v('palace')) $$, 'the owner says "This is fine"');
select lives_ok($$ select public.dismiss_anomaly(pg_temp.v('p'), pg_temp.v('palace')) $$, 'saying it twice is harmless');
select is(pg_temp.anom('palace'), null, 'a dismissed charge leaves the anomalies list');
select is(pg_temp.anom('bayleaf'), 'merchant_outlier:merchant:100.00:5', 'other anomalies stay');
reset role;
select is((select count(*)::int || ':' || bool_and(dismissed_by = pg_temp.v('owner')::uuid)::text
           from public.anomaly_dismissals where profile_code = pg_temp.v('p')), '1:true',
          'one dismissal, recorded with who made it');
select isnt((select dismissed_at from public.insights where profile_code = pg_temp.v('p') and kind = 'large_transaction'
             and dedupe_key = pg_temp.v('palace')), null, 'the matching insight is dismissed too');

-- The feed doesn't bring it back once its insight row is gone (insights expire after 14 days).
delete from public.insights where profile_code = pg_temp.v('p') and kind = 'large_transaction';
select set_config('request.jwt.claims', '', true);
select private.generate_insights(pg_temp.v('p'));
select is((select count(*)::int from public.insights where profile_code = pg_temp.v('p') and kind = 'large_transaction'
           and dedupe_key = pg_temp.v('palace')), 0, 'the nightly feed skips a dismissed charge');
select is((select count(*)::int from public.insights where profile_code = pg_temp.v('p') and kind = 'large_transaction'
           and dedupe_key = pg_temp.v('bayleaf')), 1, 'and still reports the others');

-- ═══ tenant isolation of anomaly_dismissals ════════════════════════════════
select pg_temp.as_user('viewer');
set local role authenticated;
select is((select count(*)::int from public.anomaly_dismissals where profile_code = pg_temp.v('p')), 1,
          'a member reads the profile''s dismissals');
reset role;
select pg_temp.as_user('other');
set local role authenticated;
select is((select count(*)::int from public.anomaly_dismissals), 0, 'a non-member reads none of them');
reset role;

-- A dismissal goes with its transaction.
delete from public.transactions where txn_code = pg_temp.v('palace');
select is((select count(*)::int from public.anomaly_dismissals where txn_code = pg_temp.v('palace')), 0,
          'deleting the transaction deletes its dismissal');

select * from finish();
rollback;

-- Categorisation and batch jobs (20261009000200_db_categorisation_and_jobs.sql):
-- DB-24, DP-09, DB-25, DB-29r, DB-31, DB-37 / WEB-14.
-- Runs on a non-empty DB: every key is unique to this run and every assertion is
-- scoped to this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.txn(p_desc text, p_amount numeric default 50, p_kind text default 'purchase',
                            p_direction text default 'debit', p_date date default current_date) returns text
language sql as $$
  insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description, merchant_code,
                                   amount_original, currency_original, amount_aed, amount_source, status)
  values (pg_temp.v('p'), pg_temp.v('acc'), p_kind, p_direction, p_date, p_desc, private.resolve_merchant(p_desc),
          p_amount, 'AED', p_amount, 'statement_line', 'posted')
  returning txn_code $$;
create function pg_temp.cat_of(p_txn text) returns text language sql as $$
  select c.name from public.transactions t left join public.categories c on c.category_code = t.effective_category_code
  where t.txn_code = p_txn $$;
create function pg_temp.cat(p_name text) returns text language sql as $$
  select category_code from public.categories where profile_code = pg_temp.v('p') and name = p_name $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't14-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now(), now());
create function pg_temp.as_owner() returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_owner();
set local role authenticated;
select pg_temp.set('p', public.create_profile('t14-' || left(pg_temp.v('uid'), 8), 'Categorisation'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'FAB');
select pg_temp.set('acc', (select account_code from public.accounts where profile_code = pg_temp.v('p')));

-- ═══ DB-24 / DP-09: seed rules ════════════════════════════════════════════
select is((select count(*)::int from public.category_rules where profile_code = pg_temp.v('p')), 247,
          'a new profile gets 247 seed rules (198 + taxonomy v2, + SIB BONUS 20261020110137, + Salary, + Dividends)');
select is((select match_type || ' ' || pattern from private.seed_rules where category_name = 'Dining' and match_type = 'regex'),
          'regex \mREST(AURANT[A-Z]*|O)?\M', 'the REST seed is a whole-word regex');
select is((select name from public.category_rules where profile_code = pg_temp.v('p') and pattern = '\mNOON\M'),
          'seed: NOON', 'converted seed rules keep their readable name');
select is(pg_temp.cat_of(pg_temp.txn('INTEREST CHARGES', 120, 'interest')), 'Bank Fees & Interest',
          'INTEREST CHARGES is not Dining (DB-24); it is a bank fee (taxonomy v2)');
select is(pg_temp.cat_of(pg_temp.txn('THE RESTAURANT AT THE PARK')), 'Dining', 'RESTAURANT is Dining');
select is(pg_temp.cat_of(pg_temp.txn('AFTERNOON TEA LOUNGE')), null, 'AFTERNOON is not Shopping');
select is(pg_temp.cat_of(pg_temp.txn('NOON.COM ORDER')), 'Online Marketplaces', 'NOON.COM is an online marketplace (taxonomy v2)');
select is(pg_temp.cat_of(pg_temp.txn('SUBLIME SPA')), null, 'SUBLIME is not Entertainment');
select is(pg_temp.cat_of(pg_temp.txn('LIME RIDE DUBAI')), 'Transport', 'LIME is Transport (taxonomy v2)');
select is(pg_temp.cat_of(pg_temp.txn('MURABAHA PROFIT', 744, 'interest')), 'Bank Fees & Interest',
          'a MURABAHA PROFIT charge (debit) is not Cashback but a bank fee, so it counts as spend (DP-09, taxonomy v2)');
select is(pg_temp.cat_of(pg_temp.txn('MURABAHA PROFIT', 10, 'refund', 'credit')), 'Cashback',
          'a MURABAHA PROFIT credit is still Cashback');
select is(pg_temp.cat_of(pg_temp.txn('BONUS POINTS SHOP')), null, 'a BONUS purchase is not Cashback');

-- ═══ DB-31: preview_rule mirrors recategorize ═════════════════════════════
select pg_temp.set('tie', pg_temp.txn('T14 TIE SHOP'));
insert into public.category_rules (profile_code, category_code, match_type, pattern, priority)
values (pg_temp.v('p'), pg_temp.cat('Travel'), 'contains', 'T14 TIE', 100);
select pg_temp.set('rule_a', (select rule_code from public.category_rules where profile_code = pg_temp.v('p') and pattern = 'T14 TIE'));
select is(pg_temp.cat_of(pg_temp.v('tie')), 'Travel', 'the existing rule categorises the transaction');
select pg_temp.as_owner();
set local role authenticated;
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'T14 TIE', pg_temp.cat('Grocery'))->>'would_change')::int, 0,
          'a new rule that ties on priority, length and type loses the tie: nothing would change (DB-31)');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'T14 TIE S', pg_temp.cat('Grocery'))->>'would_change')::int, 1,
          'a longer pattern at the same priority wins');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'T14 TIE', pg_temp.cat('Grocery'), '{}', 100,
                               pg_temp.v('rule_a'))->>'would_change')::int, 1,
          'editing the rule itself: it is not counted against itself');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'T14 TIE', pg_temp.cat('Grocery'), '{}', 50)->>'would_change')::int, 1,
          'a higher priority wins');
reset role;
select set_config('request.jwt.claims', '', true);

-- ═══ DB-37 / WEB-14: declined and rejected merchants are not re-asked ═════
select pg_temp.set('t1', pg_temp.txn('T14 ZQX MERCHANT ONE'));
select pg_temp.set('t2', pg_temp.txn('T14 ZQX MERCHANT TWO'));
select pg_temp.set('t3', pg_temp.txn('T14 ZQX MERCHANT THREE'));
select pg_temp.set('m1', (select merchant_code from public.transactions where txn_code = pg_temp.v('t1')));
select pg_temp.set('m2', (select merchant_code from public.transactions where txn_code = pg_temp.v('t2')));
select pg_temp.set('m3', (select merchant_code from public.transactions where txn_code = pg_temp.v('t3')));
select pg_temp.set('hash', private.category_set_hash(pg_temp.v('p')));
select is(public.apply_llm_suggestions(pg_temp.v('p'),
            jsonb_build_array(jsonb_build_object('merchant_code', pg_temp.v('m1'), 'category_code', pg_temp.cat('Shopping'), 'confidence', 0.9),
                              jsonb_build_object('merchant_code', pg_temp.v('m2'), 'category_code', pg_temp.cat('Shopping'), 'confidence', 0.2)),
            'test-model', pg_temp.v('hash'), array[pg_temp.v('m1'), pg_temp.v('m2'), pg_temp.v('m3')]),
          1, 'one confident suggestion applied');
select is((select array_agg(merchant_code || ':' || reason order by merchant_code) from public.merchant_category_skips
           where profile_code = pg_temp.v('p')),
          (select array_agg(x order by x) from unnest(array[pg_temp.v('m2') || ':declined', pg_temp.v('m3') || ':declined']) x),
          'the low-confidence and the unanswered merchant are recorded as declined (DB-37)');
select is(pg_temp.cat_of(pg_temp.v('t1')), 'Shopping', 'the applied suggestion categorises its transaction');
select lives_ok($$ select public.apply_llm_suggestions(pg_temp.v('p'), '[]'::jsonb, 'm', pg_temp.v('hash')) $$,
                'the old 4-argument call still works');

delete from pgmq.q_llm_categorize where message->>'profile_code' = pg_temp.v('p');
select private.enqueue_llm_categorize();
create function pg_temp.queued() returns text[] language sql as $$
  select coalesce(array_agg(m order by m), '{}') from pgmq.q_llm_categorize q,
         jsonb_array_elements_text(q.message->'merchant_codes') m
  where q.message->>'profile_code' = pg_temp.v('p') and m in (pg_temp.v('m1'), pg_temp.v('m2'), pg_temp.v('m3')) $$;
select is(pg_temp.queued(), '{}'::text[], 'declined merchants are not re-queued while the category set is unchanged');
update public.merchant_category_skips set category_set_hash = 'stale' where profile_code = pg_temp.v('p');
delete from pgmq.q_llm_categorize where message->>'profile_code' = pg_temp.v('p');
select private.enqueue_llm_categorize();
select is(pg_temp.queued(), (select array_agg(x order by x) from unnest(array[pg_temp.v('m2'), pg_temp.v('m3')]) x),
          'they are asked again once the category set changes');

select pg_temp.as_owner();
set local role authenticated;
select lives_ok($$ select public.reject_merchant_suggestion(pg_temp.v('p'), pg_temp.v('m1')) $$,
                'an owner rejects a suggestion (WEB-14)');
reset role;
select set_config('request.jwt.claims', '', true);
select is((select count(*)::int from public.merchant_profile_category where profile_code = pg_temp.v('p')
           and merchant_code = pg_temp.v('m1')), 0, 'the suggestion is gone');
select is(pg_temp.cat_of(pg_temp.v('t1')), null, 'and no longer categorises the transaction');
select is((select reason from public.merchant_category_skips where profile_code = pg_temp.v('p') and merchant_code = pg_temp.v('m1')),
          'rejected', 'the merchant is marked rejected');
update public.merchant_category_skips set category_set_hash = 'stale' where profile_code = pg_temp.v('p');
delete from pgmq.q_llm_categorize where message->>'profile_code' = pg_temp.v('p');
select private.enqueue_llm_categorize();
select ok(not (pg_temp.v('m1') = any (pg_temp.queued())), 'a rejected merchant is never re-queued, even for a new category set');
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid2')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't14b-' || pg_temp.v('uid2') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid2'), 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok($$ select public.reject_merchant_suggestion(pg_temp.v('p'), pg_temp.v('m2')) $$, '42501', null,
                 'reject_merchant_suggestion needs an owner of the profile');
reset role;
select set_config('request.jwt.claims', '', true);

-- ═══ DB-25: one profile's failure does not stop a batch job ═══════════════
alter table public.category_rules disable trigger user;
insert into public.category_rules (profile_code, category_code, match_type, pattern, priority)
values (pg_temp.v('p'), pg_temp.cat('Dining'), 'regex', '(', 1);
alter table public.category_rules enable trigger user;
update public.profile_state set rules_version = rules_version + 1 where profile_code = pg_temp.v('p');
select lives_ok($$ select private.recategorize_stale() $$, 'recategorize_stale survives a profile whose rules raise');
select ok(exists (select 1 from private.job_errors where job = 'recategorize_stale' and profile_code = pg_temp.v('p')),
          'and records the failure in private.job_errors');
select lives_ok($$ select private.nightly(pg_temp.v('p')) $$, 'nightly runs per profile');
delete from public.category_rules where profile_code = pg_temp.v('p') and pattern = '(';

-- ═══ DB-29r: the remaining insight kinds ══════════════════════════════════
-- large_transaction: a large first purchase at a new merchant today
select pg_temp.set('big', pg_temp.txn('T14 FIRST TIME JEWELLER', 2500));
-- review_backlog: ten open reviews
insert into public.match_reviews (profile_code, subject_type, subject_code, reason)
select pg_temp.v('p'), 'transaction', pg_temp.txn('T14 REVIEW ' || i), 'orphaned' from generate_series(1, 10) i;
-- new_recurring: a series detected today
insert into public.recurring_series (profile_code, merchant_code, cadence, expected_amount, last_amount, occurrences,
                                     first_date, last_date, next_expected)
values (pg_temp.v('p'), pg_temp.v('m3'), 'monthly', 45, 45, 3, current_date - 60, current_date, current_date + 30);
-- spend_pace: this month far above the last three months
select pg_temp.txn('T14 PACE PRIOR ' || i, 50, 'purchase', 'debit', (date_trunc('month', current_date) - (i || ' month')::interval)::date)
from generate_series(1, 3) i;
select private.generate_insights(pg_temp.v('p'));
select is((select data->>'txn_code' from public.insights where profile_code = pg_temp.v('p') and kind = 'large_transaction'
           and dedupe_key = pg_temp.v('big')), pg_temp.v('big'), 'a large first purchase raises large_transaction');
select is((select (data->>'count')::int >= 10 from public.insights where profile_code = pg_temp.v('p') and kind = 'review_backlog'),
          true, 'ten open reviews raise review_backlog');
select is((select count(*)::int from public.insights where profile_code = pg_temp.v('p') and kind = 'new_recurring'), 1,
          'a newly detected series raises new_recurring');
select ok(extract(day from current_date) < 5
          or exists (select 1 from public.insights where profile_code = pg_temp.v('p') and kind = 'spend_pace'),
          'spending far above the usual pace raises spend_pace (from day 5)');

select * from finish();
rollback;

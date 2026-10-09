-- LLM categorisation tuning (20261010001000_llm_categorize_tuning.sql): batches of 100,
-- a stale-hash suggestion is re-asked only when it can change, distinct example descriptions.
-- Runs on a non-empty DB: every key is unique to this run and every assertion is scoped to
-- this run's profile.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated, service_role;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.txn(p_desc text) returns text language sql as $$
  insert into public.transactions (profile_code, account_code, kind, direction, txn_date, description, merchant_code,
                                   amount_original, currency_original, amount_aed, amount_source, status)
  values (pg_temp.v('p'), pg_temp.v('acc'), 'purchase', 'debit', current_date, p_desc, private.resolve_merchant(p_desc),
          10, 'AED', 10, 'statement_line', 'posted')
  returning txn_code $$;
create function pg_temp.mer(p_txn text) returns text language sql as $$
  select merchant_code from public.transactions where txn_code = p_txn $$;
create function pg_temp.cat(p_name text) returns text language sql as $$
  select category_code from public.categories where profile_code = pg_temp.v('p') and name = p_name $$;
create function pg_temp.enqueue() returns void language sql as $$
  delete from pgmq.q_llm_categorize where message->>'profile_code' = pg_temp.v('p');
  select private.enqueue_llm_categorize();
$$;
create function pg_temp.queued() returns text[] language sql as $$
  select coalesce(array_agg(m order by m), '{}') from pgmq.q_llm_categorize q,
         jsonb_array_elements_text(q.message->'merchant_codes') m
  where q.message->>'profile_code' = pg_temp.v('p') $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't24-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t24-' || left(pg_temp.v('uid'), 8), 'LLM tuning'));
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'FAB');
select pg_temp.set('acc', (select account_code from public.accounts where profile_code = pg_temp.v('p')));
select pg_temp.set('run', upper(translate(left(replace(pg_temp.v('uid'), '-', ''), 8), '0123456789', 'GHIJKLMNOP')));

-- ═══ batches of 100 ═══════════════════════════════════════════════════════
-- Letters-only, distinct words: survives any merchant_key normalisation of codes and suffixes.
select pg_temp.txn('T24 QZV ' || translate(left(md5(pg_temp.v('run') || i), 12), '0123456789', 'GHIJKLMNOP') || ' STORE')
from generate_series(0, 104) i;
select pg_temp.enqueue();
select is((select array_agg(jsonb_array_length(message->'merchant_codes') order by jsonb_array_length(message->'merchant_codes') desc)
           from pgmq.q_llm_categorize where message->>'profile_code' = pg_temp.v('p')),
          array[100, 5], '105 uncategorised merchants are queued as one batch of 100 and one of 5');

-- ═══ re-ask only what can change ══════════════════════════════════════════
select pg_temp.set('hash', private.category_set_hash(pg_temp.v('p')));
create temp table m24 as
  select merchant_code, row_number() over (order by merchant_code) n from (select unnest(pg_temp.queued()) merchant_code) x;
select pg_temp.set('confident', (select merchant_code from m24 where n = 1));
select pg_temp.set('unsure', (select merchant_code from m24 where n = 2));
select pg_temp.set('edited', (select merchant_code from m24 where n = 3));
select public.apply_llm_suggestions(pg_temp.v('p'),
  (select jsonb_agg(jsonb_build_object('merchant_code', merchant_code,
     'category_code', case when n = 3 then pg_temp.cat('Travel') else pg_temp.cat('Shopping') end,
     'confidence', case when n = 2 then 0.6 else 0.9 end)) from m24),
  'test-model', pg_temp.v('hash'), (select array_agg(merchant_code) from m24));
select pg_temp.enqueue();
select is(pg_temp.queued(), '{}'::text[], 'nothing is re-queued while the category set is unchanged');

-- A new category changes the set: only the low-confidence suggestion is re-asked.
insert into public.categories (profile_code, name, kind) values (pg_temp.v('p'), 'T24 New Category', 'spend');
select isnt(private.category_set_hash(pg_temp.v('p')), pg_temp.v('hash'), 'the category set changed');
select pg_temp.enqueue();
select is(pg_temp.queued(), array[pg_temp.v('unsure')], 'a new category re-asks only suggestions below 0.8 confidence');

-- Editing a category re-asks the merchants suggested into it. now() is fixed inside this
-- transaction, so date that suggestion back (bypassing the touch trigger) to order the edit after it.
alter table public.merchant_profile_category disable trigger merchant_profile_category_touch;
update public.merchant_profile_category set updated_at = now() - interval '1 day'
  where profile_code = pg_temp.v('p') and merchant_code = pg_temp.v('edited');
alter table public.merchant_profile_category enable trigger merchant_profile_category_touch;
update public.categories set name = 'Travel & Holidays' where category_code = pg_temp.cat('Travel');
select pg_temp.enqueue();
select is(pg_temp.queued(), (select array_agg(x order by x) from unnest(array[pg_temp.v('unsure'), pg_temp.v('edited')]) x),
          'renaming a category re-asks the merchants in it');

-- Archiving one re-asks its merchants too.
update public.categories set archived_at = now() where category_code = pg_temp.cat('Shopping');
select pg_temp.enqueue();
select ok(pg_temp.v('confident') = any (pg_temp.queued()), 'archiving a category re-asks its merchants');

-- ═══ distinct examples ════════════════════════════════════════════════════
select pg_temp.set('ex', pg_temp.txn('T24 ' || pg_temp.v('run') || ' EXAMPLE CAFE 1001'));
select pg_temp.txn('T24 ' || pg_temp.v('run') || ' EXAMPLE CAFE 1001');
select pg_temp.txn('T24 ' || pg_temp.v('run') || ' EXAMPLE CAFE 1001');
select pg_temp.txn('T24 ' || pg_temp.v('run') || ' EXAMPLE CAFE 2002');
set local role service_role;
select is((select jsonb_array_length(m->'examples') from jsonb_array_elements(
             public.worker_llm_context(pg_temp.v('p'), array[pg_temp.mer(pg_temp.v('ex'))])->'merchants') m),
          2, 'examples are distinct descriptions (three identical rows count once)');
reset role;

select * from finish();
rollback;

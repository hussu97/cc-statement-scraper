-- Activity bulk actions (20261013042808_activity_bulk_actions.sql, audit WEB-24):
-- activity_selection_summary (count, net AED, excluded count for ticked codes or "all matching"),
-- bulk_update_transactions (Exclude / Include from spend, Categorise; owner only) and
-- activity_export (the rows for an Export CSV, money as decimal strings).
-- Runs on a non-empty DB: every key is unique to this run and every assertion is scoped to this
-- run's profile.
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
          't44-' || p_key || '-' || gen_random_uuid() || '@test.dev', '{}', '{}', now(), now(), now())
  returning pg_temp.set(p_key, id::text) $$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.cat(p_name text) returns text language sql as $$
  select category_code from public.categories where profile_code = pg_temp.v('p') and name = p_name $$;
-- One transaction of this run's profile. Returns its txn_code.
create function pg_temp.txn(p_date date, p_desc text, p_aed numeric, p_dir text default 'debit',
                            p_status text default 'posted', p_cat text default null, p_estimate boolean default false,
                            p_at timestamptz default null)
returns text language sql as $$
  insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, txn_at, description,
                                   amount_original, currency_original, amount_aed, amount_aed_is_estimate,
                                   amount_source, manual_category_code, voided_at)
  values (pg_temp.v('p'), pg_temp.v('acc'), p_status, case when p_dir = 'credit' then 'refund' else 'purchase' end,
          p_dir, p_date, p_at, p_desc, coalesce(p_aed, 10), case when p_aed is null then 'USD' else 'AED' end, p_aed,
          p_estimate, 'manual', pg_temp.cat(p_cat), case when p_status = 'void' then now() end)
  returning txn_code $$;
create function pg_temp.sum_codes(p_keys text[]) returns jsonb language sql as $$
  select public.activity_selection_summary(pg_temp.v('p'), (select array_agg(pg_temp.v(x)) from unnest(p_keys) x)) $$;

-- ── setup: owner, viewer, outsider (with a profile of their own) ────────────
select pg_temp.new_user('owner');
select pg_temp.new_user('viewer');
select pg_temp.new_user('other');
select pg_temp.as_user('owner');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t44-' || left(pg_temp.v('owner'), 8), 'Bulk'));
reset role;
insert into public.profile_members (profile_code, user_id, role) values (pg_temp.v('p'), pg_temp.v('viewer')::uuid, 'viewer');
select pg_temp.as_user('other');
set local role authenticated;
select pg_temp.set('q', public.create_profile('t44o-' || left(pg_temp.v('other'), 8), 'Other'));
reset role;
select set_config('request.jwt.claims', '', true);
with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('p'), 'ADCB') returning account_code)
select pg_temp.set('acc', account_code) from a;

select pg_temp.set('cafe', pg_temp.txn('2026-08-01', 'T44 CAFE', 25.50, p_cat => 'Dining',
                                       p_at => '2026-08-01 20:30:00+00'));
select pg_temp.set('shop', pg_temp.txn('2026-08-02', '=HYPERLINK("x") SHOP', 100, p_cat => 'Shopping'));
select pg_temp.set('refund', pg_temp.txn('2026-08-03', 'T44 REFUND', 40, 'credit', p_cat => 'Shopping'));
select pg_temp.set('void', pg_temp.txn('2026-08-04', 'T44 VOIDED', 999, p_status => 'void'));
select pg_temp.set('usd', pg_temp.txn('2026-08-05', 'T44 USD PENDING', null, p_status => 'pending'));
select pg_temp.set('fx', pg_temp.txn('2026-08-06', 'T44 FX ESTIMATE', 10.01, p_estimate => true));

with a as (insert into public.accounts (profile_code, bank_code) values (pg_temp.v('q'), 'FAB') returning account_code),
     t as (insert into public.transactions (profile_code, account_code, status, kind, direction, txn_date, description,
                                            amount_original, currency_original, amount_aed, amount_source)
           select pg_temp.v('q'), a.account_code, 'posted', 'purchase', 'debit', '2026-08-01', 'T44 OTHER', 900,
                  'AED', 900, 'manual' from a
           returning txn_code)
select pg_temp.set('qtxn', txn_code) from t;
select pg_temp.set('qcat', (select category_code from public.categories where profile_code = pg_temp.v('q') and name = 'Dining'));

-- ═══ activity_selection_summary ════════════════════════════════════════════
select pg_temp.as_user('viewer');
set local role authenticated;
select is(pg_temp.sum_codes(array['cafe', 'shop', 'refund']),
          '{"txn_count": 3, "net_aed": "85.50", "unpriced_count": 0, "has_estimate": false, "excluded_count": 0}'::jsonb,
          'ticked codes: count and net AED (debits minus credits) as a decimal string');
select is(pg_temp.sum_codes(array['cafe', 'void'])->>'net_aed', '25.50', 'a void row counts but adds nothing');
select is(pg_temp.sum_codes(array['cafe', 'void'])->>'txn_count', '2', 'and is still in the count, like the list');
select is(pg_temp.sum_codes(array['usd', 'fx'])->>'unpriced_count', '1', 'a row without an AED amount is unpriced');
select is((pg_temp.sum_codes(array['usd', 'fx'])->>'has_estimate')::boolean, true, 'an estimated FX amount is flagged');
select is(pg_temp.sum_codes(array['cafe', 'qtxn'])->>'txn_count', '1', 'another profile''s code matches nothing');
select is(public.activity_selection_summary(pg_temp.v('p'), array[]::text[])->>'net_aed', '0.00',
          'an empty selection is zero, not null');
select is(public.activity_selection_summary(pg_temp.v('p'), p_filter => '{}')->>'txn_count',
          public.activity_summary(pg_temp.v('p'))->>'txn_count', '"all matching" with no filter is the whole list');
select is(public.activity_selection_summary(pg_temp.v('p'), p_filter => '{}')->>'net_aed',
          public.activity_summary(pg_temp.v('p'))->>'net_aed', 'and its net equals the Activity header''s');
select is(public.activity_selection_summary(pg_temp.v('p'), p_filter => '{"from":"2026-08-02","to":"2026-08-03"}')->>'net_aed',
          '60.00', 'date range filter');
select is(public.activity_selection_summary(pg_temp.v('p'), p_filter => jsonb_build_object('category', pg_temp.cat('Shopping')))->>'txn_count',
          '2', 'category filter');
select is(public.activity_selection_summary(pg_temp.v('p'), p_filter => '{"category":"none"}')->>'txn_count',
          (select count(*)::text from public.v_transactions where profile_code = pg_temp.v('p') and category_code is null),
          'category "none" is uncategorised, as in the web URL');
select is(public.activity_selection_summary(pg_temp.v('p'), p_filter => '{"q":"t44 caf"}')->>'txn_count', '1',
          'search is case-insensitive over the description');
select is(public.activity_selection_summary(pg_temp.v('p'), p_filter => '{"status":"void"}')->>'net_aed', '0.00',
          'status filter');
select is(public.activity_selection_summary(pg_temp.v('p'), p_filter => '{"source":"sms"}')->>'txn_count', '0',
          'source filter (these rows have no evidence)');
select throws_ok($$ select public.activity_selection_summary(pg_temp.v('p')) $$, '22023', null,
                 'neither codes nor a filter is refused (never "everything" by accident)');
select throws_ok($$ select public.activity_selection_summary(pg_temp.v('p'), array[pg_temp.v('cafe')], '{}') $$, '22023', null,
                 'both codes and a filter is refused');
select throws_ok($$ select public.activity_selection_summary(pg_temp.v('p'), p_filter => '{"page":2}') $$, '22023', null,
                 'an unknown filter key is refused');
select throws_ok($$ select public.activity_selection_summary(pg_temp.v('p'), p_filter => '{"status":"bogus"}') $$, '22023', null,
                 'an unknown status is refused');
select throws_ok($$ select public.activity_selection_summary(pg_temp.v('p'), p_filter => '[]') $$, '22023', null,
                 'a filter that is not an object is refused');
reset role;

-- ═══ bulk_update_transactions ══════════════════════════════════════════════
select pg_temp.as_user('viewer');
set local role authenticated;
select throws_ok($$ select public.bulk_update_transactions(pg_temp.v('p'), '{"exclude_from_spend":true}', array[pg_temp.v('cafe')]) $$,
                 '42501', null, 'a viewer cannot exclude');
reset role;

select pg_temp.as_user('owner');
set local role authenticated;
select pg_temp.set('spend_before', (select coalesce(sum(spend_aed), 0)::text from public.v_spend where profile_code = pg_temp.v('p')));
select is(public.bulk_update_transactions(pg_temp.v('p'), '{"exclude_from_spend":true}',
                                          array[pg_temp.v('cafe'), pg_temp.v('shop'), pg_temp.v('qtxn')]), 2,
          'the owner excludes two of their own; another profile''s code is ignored');
select is(public.bulk_update_transactions(pg_temp.v('p'), '{"exclude_from_spend":true}',
                                          array[pg_temp.v('cafe'), pg_temp.v('shop')]), 0,
          'excluding again changes nothing');
select is(pg_temp.sum_codes(array['cafe', 'shop'])->>'excluded_count', '2', 'the summary counts them as excluded');
select is((select coalesce(sum(spend_aed), 0) from public.v_spend where profile_code = pg_temp.v('p')),
          pg_temp.v('spend_before')::numeric - 125.50, 'v_spend no longer counts them');
select is(public.bulk_update_transactions(pg_temp.v('p'), '{"exclude_from_spend":false}', p_filter => '{"q":"t44 caf"}'), 1,
          '"all matching" includes by filter');
select is((select exclude_from_spend from public.transactions where txn_code = pg_temp.v('cafe')), false,
          'the matching row is included again');
select is((select exclude_from_spend from public.transactions where txn_code = pg_temp.v('shop')), true,
          'a row outside the filter is untouched');

select is(public.bulk_update_transactions(pg_temp.v('p'), jsonb_build_object('manual_category_code', pg_temp.cat('Travel')),
                                          array[pg_temp.v('cafe'), pg_temp.v('refund')]), 2, 'Categorise sets the manual category');
select is((select string_agg(distinct category_name, ',') from public.v_transactions
           where txn_code in (pg_temp.v('cafe'), pg_temp.v('refund'))), 'Travel', 'both now read Travel');
select is(public.bulk_update_transactions(pg_temp.v('p'), '{"manual_category_code":null}', array[pg_temp.v('cafe')]), 1,
          'null clears the manual choice');
select is((select manual_category_code from public.transactions where txn_code = pg_temp.v('cafe')), null,
          'the manual category is cleared');
select throws_ok(format($$ select public.bulk_update_transactions(%L, jsonb_build_object('manual_category_code', %L), array[%L]) $$,
                        pg_temp.v('p'), pg_temp.v('qcat'), pg_temp.v('cafe')), 'P0002', null,
                 'another profile''s category is refused');
select throws_ok($$ select public.bulk_update_transactions(pg_temp.v('p'), '{"notes":"x"}', array[pg_temp.v('cafe')]) $$,
                 '22023', null, 'only exclude_from_spend and manual_category_code can be bulk-updated');
select throws_ok($$ select public.bulk_update_transactions(pg_temp.v('p'), '{"exclude_from_spend":"yes"}', array[pg_temp.v('cafe')]) $$,
                 '22023', null, 'exclude_from_spend must be a boolean');
select throws_ok($$ select public.bulk_update_transactions(pg_temp.v('p'), '{}', array[pg_temp.v('cafe')]) $$,
                 '22023', null, 'an empty patch is refused');
select throws_ok($$ select public.bulk_update_transactions(pg_temp.v('p'), '{"exclude_from_spend":true}') $$,
                 '22023', null, 'a patch with neither codes nor a filter is refused');
reset role;
select is((select exclude_from_spend from public.transactions where txn_code = pg_temp.v('qtxn')), false,
          'the other profile''s transaction was not touched');
select ok((select count(*) > 0 from public.audit_events where profile_code = pg_temp.v('p') and entity = 'transactions'
           and actor = pg_temp.v('owner')::uuid), 'bulk changes are audited as the owner''s');

-- ═══ activity_export ═══════════════════════════════════════════════════════
select pg_temp.as_user('viewer');
set local role authenticated;
select pg_temp.set('export', public.activity_export(pg_temp.v('p'), p_filter => '{}')::text);
select is(jsonb_array_length(pg_temp.v('export')::jsonb), 6, 'a member exports every matching row');
select is((select string_agg(e->>'txn_date', ',' order by o) from jsonb_array_elements(pg_temp.v('export')::jsonb) with ordinality x(e, o)),
          '2026-08-06,2026-08-05,2026-08-04,2026-08-03,2026-08-02,2026-08-01', 'newest first, as the list');
select is((select e from jsonb_array_elements(pg_temp.v('export')::jsonb) e where e->>'txn_code' = pg_temp.v('refund')) ->> 'net_aed',
          '-40.00', 'a credit''s net is negative, as a decimal string');
select is((select e from jsonb_array_elements(pg_temp.v('export')::jsonb) e where e->>'txn_code' = pg_temp.v('refund')) ->> 'amount_aed',
          '40.00', 'amount_aed is the stored amount, as a decimal string');
select is((select e->>'txn_time' from jsonb_array_elements(pg_temp.v('export')::jsonb) e where e->>'txn_code' = pg_temp.v('cafe')),
          '00:30', 'the time is Dubai time');
select is((select e->>'amount_aed' from jsonb_array_elements(pg_temp.v('export')::jsonb) e where e->>'txn_code' = pg_temp.v('usd')),
          null, 'an unpriced row has no AED amount');
select is((select jsonb_typeof(e->'exclude_from_spend') from jsonb_array_elements(pg_temp.v('export')::jsonb) e
           where e->>'txn_code' = pg_temp.v('shop')), 'boolean', 'flags stay booleans');
select is(jsonb_array_length(public.activity_export(pg_temp.v('p'), array[pg_temp.v('cafe'), pg_temp.v('qtxn')])), 1,
          'ticked codes export only this profile''s rows');
select is(public.activity_export(pg_temp.v('p'), p_filter => '{"q":"nothing like this"}'), '[]'::jsonb, 'no rows: an empty array');
reset role;

-- ═══ non-members ═══════════════════════════════════════════════════════════
select pg_temp.as_user('other');
set local role authenticated;
select throws_ok($$ select public.activity_selection_summary(pg_temp.v('p'), p_filter => '{}') $$, '42501', null,
                 'a non-member cannot total another profile''s selection');
select throws_ok($$ select public.bulk_update_transactions(pg_temp.v('p'), '{"exclude_from_spend":true}', p_filter => '{}') $$,
                 '42501', null, 'nor bulk-update it');
select throws_ok($$ select public.activity_export(pg_temp.v('p'), p_filter => '{}') $$, '42501', null, 'nor export it');
reset role;

select * from finish();
rollback;

-- Web follow-ups: member management RPCs, preview_rule conditions and counts,
-- overview utilisation / change fractions, spend_series top-N folding.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ── helpers ─────────────────────────────────────────────────────────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.new_user(p_key text, p_email text) returns text language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_email,
          '{}', '{}', now(), now());
  select pg_temp.set(p_key, (select id::text from auth.users where email = p_email));
$$;
create function pg_temp.as_user(p_key text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p_key), 'role', 'authenticated')::text, true) $$;
create function pg_temp.txn(p_card text, p_date date, p_desc text, p_aed numeric, p_cur text default 'AED',
                            p_orig numeric default null) returns void language sql as $$
  insert into public.transactions (profile_code, account_code, card_code, status, kind, direction, txn_date, description,
                                   amount_original, currency_original, amount_aed, amount_source)
  select pg_temp.v('p'), c.account_code, c.card_code, 'posted', 'purchase', 'debit', p_date, p_desc,
         coalesce(p_orig, p_aed), p_cur, p_aed, 'manual'
  from public.cards c where c.card_code = pg_temp.v(p_card)
$$;

-- ── setup: owner A, viewer B, outsider C, one pending invite ───────────────
select pg_temp.new_user('ua', 'owner-a@test.dev');
select pg_temp.new_user('ub', 'viewer-b@test.dev');
select pg_temp.new_user('uc', 'outsider-c@test.dev');

select pg_temp.as_user('ua');
set local role authenticated;
select pg_temp.set('p', public.create_profile('followups', 'Follow-ups'));
select is(public.add_profile_member(pg_temp.v('p'), 'viewer-b@test.dev', 'viewer'), 'added', 'B is added as a viewer');
select is(public.add_profile_member(pg_temp.v('p'), 'Pending@Test.dev', 'viewer'), 'invited', 'an unknown email is saved as an invite');

-- ── 1. list_profile_members ────────────────────────────────────────────────
select is((select count(*)::int from public.list_profile_members(pg_temp.v('p'))), 3, 'two members plus one pending invite');
select is((select string_agg(email || ':' || role || ':' || pending, ',' order by email)
           from public.list_profile_members(pg_temp.v('p'))),
          'owner-a@test.dev:owner:false,pending@test.dev:viewer:true,viewer-b@test.dev:viewer:false',
          'members carry their auth email and role; the invite is flagged pending');
select ok((select user_id is null from public.list_profile_members(pg_temp.v('p')) where pending),
          'a pending invite has no user_id');
select is((select pending from public.list_profile_members(pg_temp.v('p')) order by 1 limit 1), false,
          'members are listed before pending invites');

select pg_temp.as_user('ub');
select is((select count(*)::int from public.list_profile_members(pg_temp.v('p'))), 3, 'a viewer can list members');
select throws_ok(format('select public.remove_profile_member(%L, %L)', pg_temp.v('p'), pg_temp.v('ua')),
                 '42501', null, 'a viewer cannot remove members');
select throws_ok(format('select public.cancel_profile_invite(%L, %L)', pg_temp.v('p'), 'pending@test.dev'),
                 '42501', null, 'a viewer cannot cancel invites');

select pg_temp.as_user('uc');
select throws_ok(format('select * from public.list_profile_members(%L)', pg_temp.v('p')),
                 '42501', null, 'a non-member cannot list members');
select throws_ok(format('select public.remove_profile_member(%L, %L)', pg_temp.v('p'), pg_temp.v('ub')),
                 '42501', null, 'a non-member cannot remove members');
select throws_ok(format('select public.cancel_profile_invite(%L, %L)', pg_temp.v('p'), 'pending@test.dev'),
                 '42501', null, 'a non-member cannot cancel invites');

-- ── 2. last-owner protection and removal ───────────────────────────────────
select pg_temp.as_user('ua');
select throws_ok(format('select public.remove_profile_member(%L, %L)', pg_temp.v('p'), pg_temp.v('ua')),
                 '22023', null, 'the last owner cannot remove themselves');
select throws_ok(format('select public.remove_profile_member(%L, %L)', pg_temp.v('p'), pg_temp.v('uc')),
                 'P0002', null, 'removing a non-member is reported as not found');
select is(public.add_profile_member(pg_temp.v('p'), 'outsider-c@test.dev', 'owner'), 'added', 'C becomes a second owner');
select lives_ok(format('select public.remove_profile_member(%L, %L)', pg_temp.v('p'), pg_temp.v('ub')), 'an owner removes the viewer');

select pg_temp.as_user('uc');
select lives_ok(format('select public.remove_profile_member(%L, %L)', pg_temp.v('p'), pg_temp.v('ua')),
                'with two owners, one may remove the other');
select throws_ok(format('select public.remove_profile_member(%L, %L)', pg_temp.v('p'), pg_temp.v('uc')),
                 '22023', null, 'the remaining owner is now the last one');

-- ── 3. cancel invite ───────────────────────────────────────────────────────
select lives_ok(format('select public.cancel_profile_invite(%L, %L)', pg_temp.v('p'), ' PENDING@test.dev '),
                'an owner cancels an invite (case-insensitive)');
select is((select string_agg(email || ':' || role || ':' || pending, ',' order by email)
           from public.list_profile_members(pg_temp.v('p'))),
          'outsider-c@test.dev:owner:false', 'only C is left, with no pending invites');
select throws_ok(format('select public.cancel_profile_invite(%L, %L)', pg_temp.v('p'), 'pending@test.dev'),
                 'P0002', null, 'cancelling a missing invite is reported as not found');
reset role;

-- ── data: one ADCB account with three cards ────────────────────────────────
with a as (
  insert into public.accounts (profile_code, bank_code, product_name, credit_limit)
  values (pg_temp.v('p'), 'ADCB', 'Test card', 30000) returning account_code
)
select pg_temp.set('acc', account_code) from a;
insert into public.cards (profile_code, account_code, bank_code, last4)
values (pg_temp.v('p'), pg_temp.v('acc'), 'ADCB', '1111'), (pg_temp.v('p'), pg_temp.v('acc'), 'ADCB', '2222'),
       (pg_temp.v('p'), pg_temp.v('acc'), 'ADCB', '3333');
select pg_temp.set('c1', (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '1111'));
select pg_temp.set('c2', (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '2222'));
select pg_temp.set('c3', (select card_code from public.cards where profile_code = pg_temp.v('p') and last4 = '3333'));
select pg_temp.set('cat', (select category_code from public.categories where profile_code = pg_temp.v('p') and name = 'Travel'));

-- ── 4. preview_rule honours currency / card_code and counts every match ────
select pg_temp.txn('c1', '2024-01-05', 'ZQX RIDE HAILING', 20);
select pg_temp.txn('c2', '2024-01-06', 'ZQX RIDE HAILING', 36.73, 'USD', 10);
select pg_temp.txn('c1', d::date, 'ZQB BULK STORE', 1)
from generate_series('2023-01-01'::date, '2023-01-01'::date + 1099, interval '1 day') d;

select pg_temp.as_user('uc');
set local role authenticated;
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'ZQX', pg_temp.v('cat')))->>'matched', '2',
          'without conditions both rides match');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'ZQX', pg_temp.v('cat'), '{"currency":"USD"}'))->>'matched', '1',
          'the currency condition narrows the preview');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'ZQX', pg_temp.v('cat'), '{"currency":"USD"}'))->'sample'->0->>'amount_aed',
          '36.73', 'and the sample is the USD ride');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'ZQX', pg_temp.v('cat'),
           jsonb_build_object('card_code', pg_temp.v('c1'))))->>'matched', '1', 'the card_code condition narrows the preview');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'ZQX', pg_temp.v('cat'), '{"currency":"EUR"}'))->>'matched', '0',
          'an unmatched currency previews nothing');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'ZQB BULK', pg_temp.v('cat')))->>'matched', '1100',
          'counts cover every match, not just the first 1000');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'ZQB BULK', pg_temp.v('cat')))->>'would_change', '1100',
          'would_change also counts every match');
select is(jsonb_array_length((public.preview_rule(pg_temp.v('p'), 'contains', 'ZQB BULK', pg_temp.v('cat')))->'sample'), 20,
          'the sample keeps 20 rows');
select is((public.preview_rule(pg_temp.v('p'), 'contains', 'ZQB BULK', pg_temp.v('cat')))->'sample'->0->>'txn_date',
          ('2023-01-01'::date + 1099)::text, 'the sample is newest first');
-- the saved rule categorises exactly what the preview promised
insert into public.category_rules (profile_code, category_code, match_type, pattern, priority, conditions)
values (pg_temp.v('p'), pg_temp.v('cat'), 'contains', 'ZQX', 1, '{"currency":"USD"}');
select is((select string_agg(currency_original, ',') from public.transactions
           where profile_code = pg_temp.v('p') and description like 'ZQX%' and rule_category_code = pg_temp.v('cat')),
          'USD', 'recategorize applies the same currency condition');
reset role;
delete from public.transactions where profile_code = pg_temp.v('p') and description like 'ZQB%';

-- ── 5. overview: utilisation and change fractions ──────────────────────────
-- Dec 2024: 300, Jan 2025: 0, Feb 2025: 200, Mar 2025: 300
select pg_temp.txn('c1', '2024-12-10', 'ZQS SHOP', 300);
select pg_temp.txn('c1', '2025-02-10', 'ZQS SHOP', 200);
select pg_temp.txn('c1', '2025-03-10', 'ZQS SHOP', 300);
insert into public.statements (profile_code, account_code, kind, statement_date, closing_balance, credit_limit)
values (pg_temp.v('p'), pg_temp.v('acc'), 'statement', '2025-02-28', 4000, null),
       (pg_temp.v('p'), pg_temp.v('acc'), 'statement', '2025-03-31', 5000, 20000);

select pg_temp.as_user('uc');
set local role authenticated;
select pg_temp.set('ov', public.overview(pg_temp.v('p'), '2025-03-01')::text);
select ok(pg_temp.v('ov')::jsonb ?& array['month', 'spend', 'spend_prev_month', 'spend_prev_month_to_date', 'spend_avg_3m',
          'payments', 'pending_count', 'pending_amount', 'uncategorized_count', 'open_reviews', 'last_sms_at',
          'top_categories', 'accounts', 'recent'], 'every existing overview key is still there');
select is(pg_temp.v('ov')::jsonb->>'spend', '300.00', 'March spend');
select is(pg_temp.v('ov')::jsonb->>'spend_avg_3m', '166.67', '3-month average (Dec–Feb)');
select is(pg_temp.v('ov')::jsonb->>'change_vs_prev_month_to_date', '0.5000',
          'a past month compares with the whole previous month (300 vs 200)');
select is(pg_temp.v('ov')::jsonb->>'change_vs_avg_3m', '0.8000', 'and with the 3-month average (300 vs 166.67)');
select is(pg_temp.v('ov')::jsonb->'accounts'->0->>'utilisation', '0.2500',
          'utilisation uses the latest statement and its own credit limit (5000 / 20000)');
select is(public.overview(pg_temp.v('p'), '2025-01-01')->>'change_vs_prev_month_to_date', '-1.0000',
          'no spend after a 300 month is −100%');
select is(jsonb_typeof(public.overview(pg_temp.v('p'), '2024-12-01')->'change_vs_prev_month_to_date'), 'null',
          'change is null when the previous month is 0');
select is(jsonb_typeof(public.overview(pg_temp.v('p'), '2024-12-01')->'change_vs_avg_3m'), 'null',
          'change vs average is null when the average is 0');
reset role;
update public.statements set status = 'superseded' where profile_code = pg_temp.v('p') and statement_date = '2025-03-31';
select pg_temp.as_user('uc');
set local role authenticated;
select is(public.overview(pg_temp.v('p'), '2025-03-01')->'accounts'->0->>'utilisation', '0.1333',
          'falls back to the account credit limit (4000 / 30000) on the latest active statement');
reset role;
update public.accounts set credit_limit = null where account_code = pg_temp.v('acc');
select pg_temp.as_user('uc');
set local role authenticated;
select is(jsonb_typeof(public.overview(pg_temp.v('p'), '2025-03-01')->'accounts'->0->'utilisation'), 'null',
          'utilisation is null without any credit limit');
reset role;

-- ── 6. spend_series p_top folding ──────────────────────────────────────────
-- card 1: May 300; card 2: Jun 200; card 3: May 50 + Jun 50
select pg_temp.txn('c1', '2024-05-10', 'ZQT ONE', 300);
select pg_temp.txn('c2', '2024-06-10', 'ZQT TWO', 200);
select pg_temp.txn('c3', '2024-05-12', 'ZQT THREE', 50);
select pg_temp.txn('c3', '2024-06-12', 'ZQT THREE', 50);

select pg_temp.as_user('uc');
set local role authenticated;
select is((select count(distinct group_key)::int from public.spend_series(pg_temp.v('p'), '2024-05-01', '2024-06-30', 'month', 'card')),
          3, 'without p_top every card is its own group');
select is((select string_agg(bucket || '|' || coalesce(group_key, '-') || '|' || group_label || '|' || amount || '|' || txn_count, ','
                             order by bucket, amount desc)
           from public.spend_series(pg_temp.v('p'), '2024-05-01', '2024-06-30', 'month', 'card', 2)),
          '2024-05-01|' || pg_temp.v('c1') || '|ADCB •1111|300.00|1,2024-05-01|-|Other|50.00|1,'
          || '2024-06-01|' || pg_temp.v('c2') || '|ADCB •2222|200.00|1,2024-06-01|-|Other|50.00|1',
          'p_top = 2 keeps the two largest cards over the whole range and folds the third into Other');
select is((select sum(amount) from public.spend_series(pg_temp.v('p'), '2024-05-01', '2024-06-30', 'month', 'card', 2)),
          (select sum(amount) from public.spend_series(pg_temp.v('p'), '2024-05-01', '2024-06-30', 'month', 'card')),
          'folding preserves the total');
select is((select count(*)::int from public.spend_series(pg_temp.v('p'), '2024-05-01', '2024-06-30', 'month', 'card', 5)
           where group_label = 'Other'), 0, 'no Other group when everything fits in the top N');
select is((select string_agg(group_label, ',') from public.spend_series(pg_temp.v('p'), '2024-05-01', '2024-06-30', 'month', 'none', 1)),
          'Total,Total', 'p_top is ignored when not grouping');
reset role;

select * from finish();
rollback;

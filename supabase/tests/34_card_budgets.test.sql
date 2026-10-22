-- Card budgets (20261012163000): a budget may name a card (account) and then counts only that
-- card's spend, all of it or one category's; budgets without a card still count every card;
-- one budget per card × category × start month; another profile's card is refused; budget
-- insights name the card; merging accounts moves the budget.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.account(p_profile text, p_bank text, p_last4 text, p_nick text default null) returns text
language plpgsql as $$
declare v_acc text;
begin
  insert into public.accounts (profile_code, bank_code, nickname, product_name)
  values (p_profile, p_bank, p_nick, 'Platinum') returning account_code into v_acc;
  insert into public.cards (profile_code, account_code, bank_code, last4) values (p_profile, v_acc, p_bank, p_last4);
  return v_acc;
end $$;
create function pg_temp.spend(p_acc text, p_cat text, p_amount numeric) returns text language sql as $$
  insert into public.transactions (profile_code, account_code, card_code, status, kind, direction, txn_date,
                                   description, amount_original, currency_original, amount_aed, amount_source,
                                   manual_category_code)
  values (pg_temp.v('p'), p_acc, (select card_code from public.cards where account_code = p_acc), 'posted', 'purchase',
          'debit', date_trunc('month', public.dubai_date(now()))::date, 'SHOP', p_amount, 'AED', p_amount,
          'statement_line', p_cat)
  returning txn_code $$;

-- ── setup ───────────────────────────────────────────────────────────────────
select pg_temp.set('uid', gen_random_uuid()::text);
select pg_temp.set('uid2', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       't34-' || u || '@test.dev', '{}', '{}', now(), now()
from unnest(array[pg_temp.v('uid'), pg_temp.v('uid2')]) u;
create function pg_temp.as_user(p text) returns text language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v(p), 'role', 'authenticated')::text, true) $$;
select pg_temp.as_user('uid');
set local role authenticated;
select pg_temp.set('p', public.create_profile('t34-' || left(pg_temp.v('uid'), 8), 'Budgets'));
reset role;
select pg_temp.as_user('uid2');
set local role authenticated;
select pg_temp.set('p2', public.create_profile('t34b-' || left(pg_temp.v('uid2'), 8), 'Other'));
reset role;
select set_config('request.jwt.claims', '', true);

select pg_temp.set('fab', pg_temp.account(pg_temp.v('p'), 'FAB', '1111', 'Daily card'));
select pg_temp.set('enbd', pg_temp.account(pg_temp.v('p'), 'ENBD', '2222'));
select pg_temp.set('fab_old', pg_temp.account(pg_temp.v('p'), 'FAB', '3333'));
select pg_temp.set('other', pg_temp.account(pg_temp.v('p2'), 'FAB', '4444'));
select pg_temp.set('dining', (select category_code from public.categories
                              where profile_code = pg_temp.v('p') and kind = 'spend' order by category_code limit 1));
select pg_temp.set('month', date_trunc('month', public.dubai_date(now()))::date::text);

select pg_temp.spend(pg_temp.v('fab'), pg_temp.v('dining'), 100);
select pg_temp.spend(pg_temp.v('fab'), null, 40);
select pg_temp.spend(pg_temp.v('enbd'), pg_temp.v('dining'), 500);

-- ── the owner creates budgets through RLS ───────────────────────────────────
select pg_temp.as_user('uid');
set local role authenticated;
-- The FAB card budget (100) is below what the card has already spent (140), so it is over pace
-- on every day of the month: a budget above 140 stops projecting over it late in the month
-- (200 failed from the 22nd: 140 × 31 / 22 < 200).
insert into public.budgets (profile_code, account_code, category_code, amount_aed, effective_from) values
  (pg_temp.v('p'), null, null, 1000, pg_temp.v('month')::date),
  (pg_temp.v('p'), pg_temp.v('fab'), null, 100, pg_temp.v('month')::date),
  (pg_temp.v('p'), pg_temp.v('fab'), pg_temp.v('dining'), 50, pg_temp.v('month')::date),
  (pg_temp.v('p'), null, pg_temp.v('dining'), 800, pg_temp.v('month')::date);

select results_eq(
  $$ select account_code, category_code, spent_aed, account_name, bank_code
     from public.budget_status(pg_temp.v('p'), pg_temp.v('month')::date)
     order by account_code nulls first, category_code nulls first $$,
  $$ values (null::text, null::text, 640.00::numeric, null::text, null::text),
            (null, pg_temp.v('dining'), 600.00, null, null),
            (pg_temp.v('fab'), null, 140.00, 'Daily card', 'FAB'),
            (pg_temp.v('fab'), pg_temp.v('dining'), 100.00, 'Daily card', 'FAB') $$,
  'card budgets count only that card; budgets without a card count every card');

select throws_ok(
  $$ insert into public.budgets (profile_code, account_code, category_code, amount_aed, effective_from)
     values (pg_temp.v('p'), pg_temp.v('fab'), null, 300, pg_temp.v('month')::date) $$,
  '23505', null, 'one budget per card, category and start month');
select lives_ok(
  $$ insert into public.budgets (profile_code, account_code, category_code, amount_aed, effective_from)
     values (pg_temp.v('p'), pg_temp.v('fab_old'), null, 300, pg_temp.v('month')::date) $$,
  'another card may have its own budget for the same scope');
select throws_ok(
  $$ insert into public.budgets (profile_code, account_code, category_code, amount_aed, effective_from)
     values (pg_temp.v('p'), pg_temp.v('other'), null, 300, pg_temp.v('month')::date) $$,
  '23503', null, 'another profile''s card is refused');
reset role;
select set_config('request.jwt.claims', '', true);

-- An unnamed card is labelled "BANK · product".
select is((select account_name from public.budget_status(pg_temp.v('p'), pg_temp.v('month')::date)
           where account_code = pg_temp.v('fab_old')), 'FAB · Platinum', 'a card without a nickname is BANK · product');

-- ── insights name the card and don't collide ───────────────────────────────
select lives_ok($$ select private.generate_insights(pg_temp.v('p')) $$, 'insights generate with card budgets');
select is((select count(*)::int from public.insights where profile_code = pg_temp.v('p') and kind = 'budget_risk'
             and title like 'Daily card budget%'),
          case when extract(day from public.dubai_date(now())) >= 5 then 1 else 0 end,
          'a card''s over-pace budget gets its own insight, titled with the card');

-- ── merging accounts moves the budget ──────────────────────────────────────
select pg_temp.set('merge', private.merge_accounts(pg_temp.v('p'), pg_temp.v('fab_old'), pg_temp.v('fab'))::text);
select is((pg_temp.v('merge')::jsonb ->> 'budgets')::int, 0, 'a colliding budget stays on the closed card');
delete from public.budgets where account_code = pg_temp.v('fab') and category_code is null;
update public.accounts set status = 'active' where account_code = pg_temp.v('fab_old');
select pg_temp.set('merge', private.merge_accounts(pg_temp.v('p'), pg_temp.v('fab_old'), pg_temp.v('fab'))::text);
select is((pg_temp.v('merge')::jsonb ->> 'budgets')::int, 1, 'a budget without a collision follows its card');

select * from finish();
rollback;

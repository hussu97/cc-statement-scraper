-- Category colours on the 16-hue palette (20261012220834_category_palette_16.sql, audit WEB-17r):
-- new ledgers get the new seed colours; replaying the guarded recolour moves a row still on its
-- seeded colour and leaves a row the user recoloured. Every assertion is scoped to this run's
-- profile; the seed table is restored by the rollback.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
create function pg_temp.colour(p_name text) returns text language sql as $$
  select color_token from public.categories where profile_code = pg_temp.v('p') and name = p_name $$;

select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        email_confirmed_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 't41-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t41-' || left(pg_temp.v('uid'), 8), 'Palette'));
reset role;
select set_config('request.jwt.claims', '', true);

-- ═══ new ledgers: the seed source carries the new colours ═════════════════
select results_eq(
  $$ select name, color_token from public.categories where profile_code = pg_temp.v('p')
     and name in ('Fashion', 'Beauty & Personal Care', 'Car & Fuel', 'Flights', 'Telecom & Internet', 'Insurance',
                  'Apple in-app purchase', 'Donation', 'BNPL Instalments', 'Forex Charge')
     order by name collate "C" $$,
  $$ values ('Apple in-app purchase'::text, 'cat-15'::text), ('BNPL Instalments', 'cat-13'),
            ('Beauty & Personal Care', 'cat-14'), ('Car & Fuel', 'cat-13'), ('Donation', 'cat-5'),
            ('Fashion', 'cat-16'), ('Flights', 'cat-15'), ('Forex Charge', 'cat-8'), ('Insurance', 'cat-14'),
            ('Telecom & Internet', 'cat-11') $$,
  'a new ledger gets the 16-hue seed colours');
select is((select count(*)::int from private.seed_categories
           where color_token !~ '^cat-([1-9]|1[0-6])$'), 0, 'every seed colour is one of cat-1 … cat-16');
select is((select count(*)::int from public.categories c join private.seed_categories s using (name)
           where c.profile_code = pg_temp.v('p') and c.color_token is distinct from s.color_token), 0,
          'a new ledger''s categories match the seed source');

-- ═══ replay: the guard moves seeded colours and keeps the user's ══════════
-- As a ledger from before the migration: Fashion and Forex Charge still on their seeded colours,
-- Flights recoloured by the user (cat-4), Insurance renamed by the user.
update public.categories set color_token = 'cat-7' where profile_code = pg_temp.v('p') and name = 'Fashion';
update public.categories set color_token = 'cat-11' where profile_code = pg_temp.v('p') and name = 'Forex Charge';
update public.categories set color_token = 'cat-4' where profile_code = pg_temp.v('p') and name = 'Flights';
update public.categories set color_token = 'cat-9', name = 'Health cover' where profile_code = pg_temp.v('p')
  and name = 'Insurance';
-- Medicine is cat-9 too, but not in the mapping.
select is(pg_temp.colour('Medicine'), 'cat-9', 'Medicine starts on cat-9');

select ok(private.recolour_palette_16() >= 2, 'the recolour reports the rows it moved');
select is(pg_temp.colour('Fashion'), 'cat-16', 'a seeded colour moves: Fashion cat-7 → cat-16');
select is(pg_temp.colour('Forex Charge'), 'cat-8', 'a seeded colour moves: Forex Charge cat-11 → cat-8');
select is(pg_temp.colour('Flights'), 'cat-4', 'a colour the user chose stays');
select is(pg_temp.colour('Health cover'), 'cat-9', 'a category the user renamed keeps its colour');
select is(pg_temp.colour('Medicine'), 'cat-9', 'a category outside the mapping is untouched');

-- Idempotent: nothing left on an old colour it maps, in this profile.
select is((select count(*)::int from public.categories c
           where c.profile_code = pg_temp.v('p')
             and (c.name, c.color_token) in (('Fashion', 'cat-7'), ('Forex Charge', 'cat-11'), ('Car & Fuel', 'cat-3'))),
          0, 'a second run has nothing of this ledger to move');

select * from finish();
rollback;

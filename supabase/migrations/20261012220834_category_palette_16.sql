-- Category colours use the 16-hue palette (audit WEB-17r).
--
-- The design tokens now define cat-1 … cat-16. The 28 seeded categories shared twelve hues, so
-- several read as the same colour on one chart. Ten seeded categories move to a hue of their own.
--
-- Guarded content migration (CLAUDE.md §1.9): a row moves only while it still holds the colour it
-- was seeded with, so a category the user recoloured (or renamed) keeps what they chose. The same
-- mapping applies to private.seed_categories, which create_profile copies for new ledgers.
-- color_token has no CHECK constraint (any 'cat-N' resolves through the tokens): nothing to widen.
--
-- private.recolour_palette_16() holds the mapping so pgTAP can replay it; it runs once below and
-- is idempotent (a second run finds no row still on an old colour it maps).

create or replace function private.recolour_palette_16()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  with m(name, old_token, new_token) as (values
         ('Fashion', 'cat-7', 'cat-16'),
         ('Beauty & Personal Care', 'cat-2', 'cat-14'),
         ('Car & Fuel', 'cat-3', 'cat-13'),
         ('Flights', 'cat-8', 'cat-15'),
         ('Telecom & Internet', 'cat-1', 'cat-11'),
         ('Insurance', 'cat-9', 'cat-14'),
         ('Apple in-app purchase', 'cat-3', 'cat-15'),
         ('Donation', 'cat-6', 'cat-5'),
         ('BNPL Instalments', 'cat-11', 'cat-13'),
         ('Forex Charge', 'cat-11', 'cat-8')),
       seed as (
         update private.seed_categories s set color_token = m.new_token
         from m where s.name = m.name and s.color_token = m.old_token
         returning 1)
  update public.categories c set color_token = m.new_token
  from m where c.name = m.name and c.color_token = m.old_token;
  -- the profiles' rows moved (the seed CTE always runs: data-modifying CTEs execute in full)
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

select private.recolour_palette_16();

-- SIB profit credits net off the Murabaha profit charge (financial audit 2026-10-20).
--
-- SIB posts its monthly profit charge as a MURABAHA PROFIT debit (Bank Fees & Interest, spend)
-- and, the same day, a WAKALA PROFIT credit plus a small BONUS credit that pay most of it back
-- (2026-05-14: 348.90 debit = 341.57 + 7.33 credits). The seed rules put both credits in
-- Cashback (kind 'income'), which public.v_spend leaves out, so the full charge counted as
-- spend: AED 1,669.03 too much on the alice profile for Apr–Jul 2026.
--
--   WAKALA PROFIT   Cashback → Bank Fees & Interest, credits only. It is SIB-only wording.
--   BONUS (SIB)     a new SIB-scoped credit rule in Bank Fees & Interest at priority 90, so it
--                   outranks the generic '\mBONUS\M' Cashback rule (priority 100), which other
--                   banks' bonus credits keep.
--
-- A credit (kind 'refund') in a 'fee' category is negative spend in v_spend, so the category's
-- total becomes the net charge. MURABAHA PROFIT credits (none seen) stay Cashback.
--
-- Content migration, guarded (CLAUDE.md §1.9): a profile's WAKALA rule moves only while it is
-- still the seed rule exactly as seeded, in Cashback; the BONUS rule is added only when the
-- profile has no rule with that pattern and those conditions. The category_rules triggers
-- recategorise each profile.

-- ── seed rules (new profiles) ───────────────────────────────────────────────
alter table private.seed_rules add column priority integer not null default 100;

update private.seed_rules set category_name = 'Bank Fees & Interest', conditions = '{"direction":"credit"}'::jsonb
where category_name = 'Cashback' and pattern = 'WAKALA PROFIT' and match_type = 'contains'
  and conditions = '{}'::jsonb;

insert into private.seed_rules (category_name, pattern, match_type, conditions, priority)
values ('Bank Fees & Interest', '\mBONUS\M', 'regex', '{"direction":"credit","bank_code":"SIB"}'::jsonb, 90)
on conflict (category_name, pattern) do nothing;

create or replace function private.seed_profile_defaults(p_profile_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.categories where profile_code = p_profile_code) then
    return;
  end if;
  insert into public.categories (profile_code, name, kind, sort_order, color_token)
  select p_profile_code, name, kind, sort_order, color_token from private.seed_categories;
  insert into public.category_rules (profile_code, category_code, name, match_type, pattern, conditions, priority,
                                     source)
  select p_profile_code, c.category_code,
         'seed: ' || regexp_replace(r.pattern, '\\[mM]|\(.*\)\?', '', 'g')
           || case when r.conditions ? 'bank_code' then ' (' || (r.conditions->>'bank_code') || ')' else '' end,
         r.match_type, r.pattern, r.conditions, r.priority, 'seed'
  from private.seed_rules r
  join public.categories c on c.profile_code = p_profile_code and c.name = r.category_name;
end;
$$;

-- ── existing profiles ───────────────────────────────────────────────────────
update public.category_rules r
set category_code = nc.category_code, conditions = '{"direction":"credit"}'::jsonb
from public.categories oc, public.categories nc
where r.source = 'seed' and r.pattern = 'WAKALA PROFIT' and r.match_type = 'contains'
  and r.conditions = '{}'::jsonb
  and oc.profile_code = r.profile_code and oc.category_code = r.category_code and oc.name = 'Cashback'
  and nc.profile_code = r.profile_code and nc.name = 'Bank Fees & Interest' and nc.archived_at is null;

insert into public.category_rules (profile_code, category_code, name, match_type, pattern, conditions, priority, source)
select c.profile_code, c.category_code, 'seed: BONUS (SIB)', 'regex', '\mBONUS\M',
       '{"direction":"credit","bank_code":"SIB"}'::jsonb, 90, 'seed'
from public.categories c
where c.name = 'Bank Fees & Interest' and c.archived_at is null
  and not exists (select 1 from public.category_rules r
                  where r.profile_code = c.profile_code and upper(btrim(r.pattern)) = '\MBONUS\M'
                    and r.conditions = '{"direction":"credit","bank_code":"SIB"}'::jsonb);

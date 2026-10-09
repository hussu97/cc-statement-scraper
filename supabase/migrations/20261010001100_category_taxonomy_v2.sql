-- Category taxonomy v2: a finer middle ground, so a couple of categories no longer take
-- ~45% of spend (prod audit 2026-10-09: Shopping 27% + Dining 18%; Transport 26% + Dining 17%).
--
--   New categories (every profile, inserted only when absent by name):
--     Food Delivery, Online Marketplaces, Fashion, Beauty & Personal Care, BNPL Instalments,
--     Car & Fuel, Flights, Telecom & Internet, Bank Fees & Interest, Education.
--   Existing categories keep their codes and names; they just lose the merchants that moved.
--
--   Seed rules: moved to the new categories, and the over-broad ones fixed:
--     UBER        Travel → Transport (rides); Uber Eats → Food Delivery
--     EMIRATES    'contains' caught Emirates Hospital, Emirates Leisure Retail and Emirates Fast
--                 Food; it is now an airline-only regex (Flights)
--     fees        cash-advance fee, card membership/annual fee → Bank Fees & Interest
--     LIME        Entertainment → Transport; salons/spa/massage → Beauty & Personal Care
--
-- Content migration, guarded (CLAUDE.md §1.9): a profile's rule is re-pointed or rewritten only
-- while it is still a 'seed' rule holding exactly the seeded pattern, match type and conditions
-- and still in the seeded category; a new seed rule is added only when the profile has no rule
-- with that pattern. Rule changes recategorise each profile through the category_rules triggers.
-- Tie-break reminder (private.recategorize): same priority → LONGER pattern wins, so a generic
-- brand rule is a plain 'contains' ('AMAZON', 6) that every specific one ('AMAZON NOW') outranks;
-- a '\m…\M' regex counts its escapes and would outrank them.
-- Merchant-level LLM suggestions are not touched here (re-asked or backfilled separately).

-- ── categories ─────────────────────────────────────────────────────────────
insert into private.seed_categories (name, kind, sort_order, color_token) values
  ('Food Delivery', 'spend', 15, 'cat-12'),
  ('Online Marketplaces', 'spend', 42, 'cat-10'),
  ('Fashion', 'spend', 44, 'cat-7'),
  ('Beauty & Personal Care', 'spend', 46, 'cat-2'),
  ('BNPL Instalments', 'spend', 48, 'cat-11'),
  ('Car & Fuel', 'spend', 65, 'cat-3'),
  ('Flights', 'spend', 72, 'cat-8'),
  ('Telecom & Internet', 'spend', 82, 'cat-1'),
  ('Bank Fees & Interest', 'fee', 135, 'cat-6'),
  ('Education', 'spend', 145, 'cat-4')
on conflict (name) do nothing;

insert into public.categories (profile_code, name, kind, sort_order, color_token)
select p.profile_code, s.name, s.kind, s.sort_order, s.color_token
from public.profiles p
cross join private.seed_categories s
where s.name in ('Food Delivery', 'Online Marketplaces', 'Fashion', 'Beauty & Personal Care', 'BNPL Instalments',
                 'Car & Fuel', 'Flights', 'Telecom & Internet', 'Bank Fees & Interest', 'Education')
  and exists (select 1 from public.categories c where c.profile_code = p.profile_code)
  and not exists (select 1 from public.categories c where c.profile_code = p.profile_code and lower(c.name) = lower(s.name));

-- ── moved seed rules: same pattern, new category ───────────────────────────
create temp table _move (old_category text, pattern text, new_category text) on commit drop;
insert into _move values
  ('Dining', 'NOON FOOD', 'Food Delivery'),
  ('Dining', 'KEETA DB', 'Food Delivery'),
  ('Dining', 'KEETA', 'Food Delivery'),
  ('Dining', 'ZOMATO', 'Food Delivery'),
  ('Dining', 'DELIVEROO', 'Food Delivery'),
  ('Dining', 'TALABAT.COM', 'Food Delivery'),
  ('Dining', 'KITOPIDUBAI', 'Food Delivery'),
  ('Shopping', '\mNOON\M', 'Online Marketplaces'),
  ('Shopping', 'AMAZON.AE', 'Online Marketplaces'),
  ('Shopping', 'TEMU.COM', 'Online Marketplaces'),
  ('Shopping', 'NAMSHI', 'Fashion'),
  ('Shopping', 'UNIQLO', 'Fashion'),
  ('Shopping', 'BERSHKA', 'Fashion'),
  ('Shopping', 'AMERICAN EAGLE', 'Fashion'),
  ('Shopping', 'HENNES &MA', 'Fashion'),
  ('Shopping', 'SKECHERS', 'Fashion'),
  ('Shopping', 'SEPHORA', 'Beauty & Personal Care'),
  ('Shopping', 'TABBY FZ', 'BNPL Instalments'),
  ('Shopping', 'GETYOURGUIDE', 'Travel'),
  ('Entertainment', 'RIVER SPA', 'Beauty & Personal Care'),
  ('Entertainment', 'GENTS SALON', 'Beauty & Personal Care'),
  ('Entertainment', 'MASSAGE', 'Beauty & Personal Care'),
  ('Entertainment', 'SPA 1DUBAI', 'Beauty & Personal Care'),
  ('Entertainment', '\mLIME\M', 'Transport'),
  ('Transport', 'TESLA', 'Car & Fuel'),
  ('Transport', 'ADNOC', 'Car & Fuel'),
  ('Transport', 'ENOC', 'Car & Fuel'),
  ('Transport', 'EMARAT', 'Car & Fuel'),
  ('Transport', 'EPPCO', 'Car & Fuel'),
  ('Travel', 'UBER', 'Transport'),
  ('Travel', 'AIRASIA', 'Flights'),
  ('Travel', 'AIR ARABIA', 'Flights'),
  ('Travel', 'AIR INDIA', 'Flights'),
  ('Travel', 'FLIGHTNETWRK', 'Flights'),
  ('Travel', 'INDIGO AIRLINES', 'Flights'),
  ('Travel', 'TRAVELWINGS.COM', 'Flights'),
  ('Utilities', 'ETISALAT', 'Telecom & Internet'),
  ('Utilities', 'E& DIGITAL', 'Telecom & Internet'),
  ('Utilities', 'DU APPLE PAY', 'Telecom & Internet'),
  ('Utilities', 'CAREEM PAY', 'Telecom & Internet'),
  ('Fines/Govt Services', 'PARKONIC', 'Car & Fuel'),
  ('Fines/Govt Services', 'CASH ADVANCE FEE', 'Bank Fees & Interest'),
  ('Fines/Govt Services', 'INVOLUNTARY LOSS OF', 'Insurance'),
  ('Subscription', 'MEMBERSHIP FEE', 'Bank Fees & Interest'),
  ('Forex Charge', 'ANNUAL FEE', 'Bank Fees & Interest'),
  ('Investment', 'AL JAMEA TUS', 'Education');

update private.seed_rules r set category_name = m.new_category
from _move m
where r.category_name = m.old_category and r.pattern = m.pattern;

update public.category_rules r set category_code = nc.category_code
from _move m, private.seed_rules s, public.categories oc, public.categories nc
where s.category_name = m.new_category and s.pattern = m.pattern
  and r.source = 'seed' and r.pattern = s.pattern and r.match_type = s.match_type and r.conditions = s.conditions
  and oc.profile_code = r.profile_code and oc.category_code = r.category_code and oc.name = m.old_category
  and nc.profile_code = r.profile_code and nc.name = m.new_category and nc.archived_at is null;

-- ── EMIRATES: airline only ─────────────────────────────────────────────────
-- 'EMIRATESDUBAI', 'EMIRATES1762206730198DUBAI', 'EMIRATES AIRLINE'; not EMIRATES HOSPITAL,
-- EMIRATES LEISURE RETAIL, EMIRATES FAST FOOD, EMIRATES LITERATURE FOUNDATION.
update private.seed_rules set category_name = 'Flights', match_type = 'regex',
  pattern = '^EMIRATES(\s*[0-9]|\s*DUBAI|\s+AIRLINE|$)'
where category_name = 'Travel' and pattern = 'EMIRATES' and match_type = 'contains' and conditions = '{}'::jsonb;

update public.category_rules r set category_code = nc.category_code, match_type = 'regex',
  pattern = '^EMIRATES(\s*[0-9]|\s*DUBAI|\s+AIRLINE|$)',
  name = 'seed: EMIRATES (airline)'
from public.categories oc, public.categories nc
where r.source = 'seed' and r.pattern = 'EMIRATES' and r.match_type = 'contains' and r.conditions = '{}'::jsonb
  and oc.profile_code = r.profile_code and oc.category_code = r.category_code and oc.name = 'Travel'
  and nc.profile_code = r.profile_code and nc.name = 'Flights' and nc.archived_at is null;

-- ── new seed rules ─────────────────────────────────────────────────────────
create temp table _new (category_name text, match_type text, pattern text, conditions jsonb) on commit drop;
insert into _new values
  ('Food Delivery', 'contains', 'CAREEM FOOD', '{}'),
  ('Food Delivery', 'regex', '\mUBER[^A-Z]*(JP)?[^A-Z]*EATS', '{}'),
  ('Dining', 'contains', 'KFC ADNOC', '{}'),
  ('Food Delivery', 'contains', 'TALABAT', '{}'),
  ('Food Delivery', 'contains', 'INSTASHOP', '{}'),
  ('Online Marketplaces', 'contains', 'AMAZON', '{}'),
  ('Online Marketplaces', 'contains', 'DUBIZZLE', '{}'),
  ('Online Marketplaces', 'regex', '\mSHEIN\M', '{}'),
  ('Online Marketplaces', 'contains', 'ALIEXPRESS', '{}'),
  ('Subscription', 'contains', 'AMAZON PRIME', '{}'),
  ('Grocery', 'contains', 'AMAZON GROCERY', '{}'),
  ('Grocery', 'contains', 'ABELA FRESH', '{}'),
  ('Fashion', 'contains', 'PARFOIS', '{}'),
  ('Fashion', 'regex', '\mZARA\M', '{}'),
  ('Fashion', 'contains', 'MAX FASHION', '{}'),
  ('Fashion', 'contains', 'CENTREPOINT', '{}'),
  ('Fashion', 'contains', '6THSTREET', '{}'),
  ('Fashion', 'contains', 'OUNASS', '{}'),
  ('Beauty & Personal Care', 'regex', '\mSALON\M', '{}'),
  ('Beauty & Personal Care', 'regex', '\mBEAUTY\M', '{}'),
  ('Beauty & Personal Care', 'regex', '\mBARBER', '{}'),
  ('BNPL Instalments', 'regex', '\mTABBY\M', '{}'),
  ('BNPL Instalments', 'regex', '\mTAMARA\M', '{}'),
  ('BNPL Instalments', 'regex', '\mPOSTPAY\M', '{}'),
  ('Car & Fuel', 'regex', '\mPARKING\M', '{}'),
  ('Car & Fuel', 'regex', '\mSALIK\M', '{}'),
  ('Car & Fuel', 'regex', '\mCAR\s?WASH', '{}'),
  ('Car & Fuel', 'contains', 'SUPERCHARGER', '{}'),
  ('Flights', 'regex', '\mFLYDUBAI\M', '{}'),
  ('Flights', 'contains', 'ETIHAD AIRWAYS', '{}'),
  ('Flights', 'contains', 'QATAR AIRWAYS', '{}'),
  ('Flights', 'regex', '\mAIRLINES?\M', '{}'),
  ('Medicine', 'contains', 'EMIRATES HOSPITAL', '{}'),
  ('Telecom & Internet', 'contains', 'CAREEM PAY DU', '{}'),
  ('Telecom & Internet', 'contains', 'VIRGIN MOBILE', '{}'),
  ('Utilities', 'regex', '\mLAUNDRY\M', '{}'),
  ('Bank Fees & Interest', 'contains', 'VAT ON CASH ADVANCE', '{}'),
  ('Bank Fees & Interest', 'contains', 'LATE PAYMENT FEE', '{}'),
  ('Bank Fees & Interest', 'contains', 'OVERLIMIT FEE', '{}'),
  ('Bank Fees & Interest', 'contains', 'FINANCE CHARGE', '{}'),
  ('Bank Fees & Interest', 'contains', 'INTEREST CHARGE', '{}'),
  ('Bank Fees & Interest', 'contains', 'MURABAHA PROFIT', '{"direction":"debit"}'),
  ('Education', 'contains', 'UDEMY', '{}'),
  ('Education', 'contains', 'COURSERA', '{}'),
  ('Education', 'regex', '\mUNIVERSITY\M', '{}'),
  ('Education', 'regex', '\mSCHOOL\M', '{}');

-- seed_rules is keyed by (category_name, pattern): MURABAHA PROFIT already exists under
-- Cashback (credits), and the debit one lives under Bank Fees & Interest, so no clash.
insert into private.seed_rules (category_name, pattern, match_type, conditions)
select category_name, pattern, match_type, conditions from _new
on conflict (category_name, pattern) do nothing;

insert into public.category_rules (profile_code, category_code, name, match_type, pattern, conditions, source)
select c.profile_code, c.category_code,
       'seed: ' || regexp_replace(n.pattern, '\\[mMs]|[\\?*()^$|]|\[.*\]', '', 'g'), n.match_type, n.pattern, n.conditions, 'seed'
from _new n
join public.categories c on c.name = n.category_name and c.archived_at is null
where not exists (select 1 from public.category_rules r
                  where r.profile_code = c.profile_code and upper(btrim(r.pattern)) = upper(btrim(n.pattern))
                    and r.conditions = n.conditions);

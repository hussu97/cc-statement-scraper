-- Default categories and keyword rules, generated once from the legacy
-- backend/config/category_rules.yaml. They are copied into each profile by
-- private.seed_profile_defaults() and are then the profile's own (editable) rows.

create table private.seed_categories (
  name text primary key,
  kind text not null,
  sort_order integer not null,
  color_token text not null
);

create table private.seed_rules (
  category_name text not null references private.seed_categories(name),
  pattern text not null,
  primary key (category_name, pattern)
);

insert into private.seed_categories (name, kind, sort_order, color_token) values
  ('Dining', 'spend', 10, 'cat-1'),
  ('Grocery', 'spend', 20, 'cat-2'),
  ('Subscription', 'spend', 30, 'cat-3'),
  ('Shopping', 'spend', 40, 'cat-4'),
  ('Entertainment', 'spend', 50, 'cat-5'),
  ('Transport', 'spend', 60, 'cat-6'),
  ('Travel', 'spend', 70, 'cat-7'),
  ('Utilities', 'spend', 80, 'cat-8'),
  ('Insurance', 'spend', 90, 'cat-9'),
  ('Investment', 'spend', 100, 'cat-10'),
  ('Fines/Govt Services', 'spend', 110, 'cat-11'),
  ('Fraud', 'spend', 120, 'cat-12'),
  ('Forex Charge', 'fee', 130, 'cat-1'),
  ('Medicine', 'spend', 140, 'cat-2'),
  ('Cashback', 'income', 150, 'cat-3'),
  ('Card Repayment', 'transfer', 160, 'cat-4'),
  ('Apple in-app purchase', 'spend', 170, 'cat-5'),
  ('Donation', 'spend', 180, 'cat-6');

insert into private.seed_rules (category_name, pattern) values
  ('Dining', 'NOON FOOD'),
  ('Dining', 'BALCONA'),
  ('Dining', 'KEETA DB'),
  ('Dining', 'KEETA'),
  ('Dining', 'NAJM ALSHAMAL COFFEE'),
  ('Dining', 'ZOMATO'),
  ('Dining', 'DUSIT THANI'),
  ('Dining', 'DELIVEROO'),
  ('Dining', 'SEVA WELLBEING'),
  ('Dining', 'QLUB'),
  ('Dining', 'MALL MART'),
  ('Dining', 'PANDA EXPRESS'),
  ('Dining', 'TALABAT.COM'),
  ('Dining', 'KFC'),
  ('Dining', 'KITOPIDUBAI'),
  ('Dining', 'MCDONALD'),
  ('Dining', 'SUBWAY'),
  ('Dining', 'ALL DAY GOURMENT'),
  ('Dining', 'ALL DAY GOURMET'),
  ('Dining', 'COFFEE'),
  ('Dining', 'ABSOLUTE BARBECUE'),
  ('Dining', 'CAFE'),
  ('Dining', 'REST'),
  ('Dining', 'RESTAUR'),
  ('Dining', 'FOOD'),
  ('Dining', 'BRASSERIE'),
  ('Dining', 'RAMEN'),
  ('Dining', 'JAYS ONE SWEET AND FLOWER'),
  ('Dining', 'ADNH CATERING'),
  ('Dining', 'ADNH COMPASS'),
  ('Dining', 'AMAZON CATERINGNA'),
  ('Dining', 'THE BLUE BOX'),
  ('Dining', 'CAREEM DINEOUT'),
  ('Dining', 'QUICK MART'),
  ('Dining', 'AMARAVATHIDUBAI'),
  ('Dining', 'STARBUCKS'),
  ('Dining', 'DUNKIN'),
  ('Dining', 'BESH CAIRO'),
  ('Dining', 'AVATARA'),
  ('Dining', 'REVELRY'),
  ('Grocery', 'NOON MINUTES'),
  ('Grocery', 'AMAZON NOW'),
  ('Grocery', 'MARKET'),
  ('Grocery', 'GROCERY'),
  ('Grocery', '7 11'),
  ('Grocery', 'LULU'),
  ('Grocery', 'GRAB.COM'),
  ('Grocery', 'CARREFOUR'),
  ('Grocery', 'CHOITHRAM'),
  ('Grocery', 'DAY TO DAY'),
  ('Grocery', 'GMG CONSUMER'),
  ('Grocery', 'NOWNOW'),
  ('Subscription', 'WHOOPDUBLIN'),
  ('Subscription', 'OSNDUBAI'),
  ('Subscription', 'NOON ONE'),
  ('Subscription', 'DUOLINGO'),
  ('Subscription', 'EXCELLENCY BENEFIT'),
  ('Subscription', 'MEMBERSHIP FEE'),
  ('Subscription', 'OPENAI *CHATGPT'),
  ('Subscription', 'SHOPIFY'),
  ('Subscription', 'GOOGLE'),
  ('Subscription', 'APPLE.COM/BILL'),
  ('Subscription', 'WIX.COM'),
  ('Subscription', 'ICONSCOUT.COM'),
  ('Subscription', 'NAME-CHEAP.COM'),
  ('Subscription', 'NOVORESUME'),
  ('Subscription', 'GODADDY'),
  ('Subscription', 'CAREEM PLUSDUBAI'),
  ('Subscription', 'OPENAI.COM'),
  ('Subscription', 'CANVA'),
  ('Subscription', 'CURSOR.COM'),
  ('Subscription', 'SPOTIFY'),
  ('Shopping', 'NOON'),
  ('Shopping', 'ZIINA'),
  ('Shopping', 'NAMSHI'),
  ('Shopping', 'ALSAYYEDA'),
  ('Shopping', 'AMAZON.AE'),
  ('Shopping', 'HOME CENTRE'),
  ('Shopping', 'DECATHLON'),
  ('Shopping', 'VAPE'),
  ('Shopping', 'DODO FLOWERS'),
  ('Shopping', 'UNIQLO'),
  ('Shopping', 'AL TAQDEER'),
  ('Shopping', 'BERSHKA'),
  ('Shopping', 'JASHANMAL'),
  ('Shopping', 'MINISO'),
  ('Shopping', 'DANUBE HOME'),
  ('Shopping', 'AMERICAN EAGLE'),
  ('Shopping', 'SEPHORA'),
  ('Shopping', 'TABBY FZ'),
  ('Shopping', 'AL SHAMSI HOLDINGS'),
  ('Shopping', 'TEMU.COM'),
  ('Shopping', 'LANDMARK'),
  ('Shopping', 'AL BASHA SMOKING'),
  ('Shopping', 'TRADING LLC'),
  ('Shopping', 'HENNES &MA'),
  ('Shopping', 'MARKS AND SPENCER'),
  ('Shopping', 'SKECHERS'),
  ('Shopping', 'DANUBE'),
  ('Shopping', 'KOTHARI TRADING'),
  ('Shopping', 'MADINAT JUMEIRAH'),
  ('Shopping', 'GETYOURGUIDE'),
  ('Shopping', 'EDIT BY AHMEDSEDDIQIDUBAI'),
  ('Entertainment', 'SKYDIVE'),
  ('Entertainment', 'PRISON ISLAND'),
  ('Entertainment', 'RIVER SPA'),
  ('Entertainment', 'OMISE*PHUKET'),
  ('Entertainment', 'PYGMY ANIMAL PARK'),
  ('Entertainment', 'VOX CINEMAS'),
  ('Entertainment', 'LIME'),
  ('Entertainment', 'GENTS SALON'),
  ('Entertainment', 'MASSAGE'),
  ('Entertainment', 'SPA 1DUBAI'),
  ('Entertainment', 'SENSAS'),
  ('Entertainment', 'THE PALACE DOWNTOWN'),
  ('Entertainment', 'WILD PAINT HOUSE'),
  ('Entertainment', 'CINEMA'),
  ('Transport', 'ZED MOBILITY'),
  ('Transport', 'CAREEM RIDE'),
  ('Transport', 'BOLT'),
  ('Transport', 'CAREEM HALA'),
  ('Transport', 'TAXI'),
  ('Transport', 'TESLA'),
  ('Transport', 'GRAB RIDES'),
  ('Transport', 'GRAB-EC'),
  ('Transport', 'ADNOC'),
  ('Transport', 'ENOC'),
  ('Transport', 'EMARAT'),
  ('Transport', 'CAREEMDUBAI'),
  ('Transport', 'EPPCO'),
  ('Travel', 'TRANS SINGAPORE'),
  ('Travel', 'BOOKING.COM'),
  ('Travel', 'AIRPORT'),
  ('Travel', 'AIRALO'),
  ('Travel', 'AIRASIA'),
  ('Travel', 'COZMO TRAVEL'),
  ('Travel', 'KOMUTER'),
  ('Travel', 'UBER'),
  ('Travel', 'IMMIGRATION'),
  ('Travel', 'AIR ARABIA'),
  ('Travel', 'EMIRATES'),
  ('Travel', 'AIR INDIA'),
  ('Travel', 'RESORT'),
  ('Travel', 'FLIGHTNETWRK'),
  ('Travel', 'HOTEL'),
  ('Travel', 'MAKEMYTRIP'),
  ('Travel', 'TRAVELWINGS.COM'),
  ('Travel', 'JABAL AL DHANNA'),
  ('Travel', 'INDIGO AIRLINES'),
  ('Utilities', 'DUBAI ELECTRICITY'),
  ('Utilities', 'NOOR ALJIDAF'),
  ('Utilities', 'CAREEM PAY'),
  ('Utilities', 'GAS SERVICE'),
  ('Utilities', 'DEWA'),
  ('Utilities', 'ETISALAT'),
  ('Utilities', 'DESCO'),
  ('Utilities', 'URBAN COMPANY'),
  ('Utilities', 'DU APPLE PAY'),
  ('Utilities', 'CAREEM HOMESRVICES'),
  ('Utilities', 'CAREEM LAUNDRY'),
  ('Utilities', 'E& DIGITAL'),
  ('Insurance', 'ZURICH INTL'),
  ('Insurance', 'VAT ON INSURANCE'),
  ('Insurance', 'UNION INSURANCE'),
  ('Insurance', 'SUKOON INSURANCEDUBAI'),
  ('Investment', 'RL360'),
  ('Investment', 'AL JAMEA TUS'),
  ('Fines/Govt Services', 'SMART DUBAI GOVERNMENT DUBAI'),
  ('Fines/Govt Services', 'SMART DUBAIGOVERNMENTDUBAI'),
  ('Fines/Govt Services', 'AL ETIHAD CREDIT BUREA'),
  ('Fines/Govt Services', 'SHARJAH FINANCE DEPART'),
  ('Fines/Govt Services', 'PARKONIC'),
  ('Fines/Govt Services', 'CASH ADVANCE FEE'),
  ('Fines/Govt Services', 'INVOLUNTARY LOSS OF'),
  ('Fraud', 'UPFRONTCR DISP'),
  ('Forex Charge', 'VAT ON SERVICE CHARGES'),
  ('Forex Charge', 'VAT ON'),
  ('Forex Charge', 'FOREIGN TRANSACTION FEE'),
  ('Forex Charge', 'ANNUAL FEE'),
  ('Medicine', 'HEALTH'),
  ('Medicine', 'PHARMACY'),
  ('Medicine', 'CITY LIFE PHY'),
  ('Medicine', 'LIFE PHY'),
  ('Medicine', 'HALA PHY'),
  ('Medicine', 'PHYSIOCARE'),
  ('Medicine', 'MEDCARE'),
  ('Cashback', 'FAB REWARDS REDEMPTION - CASHBACK'),
  ('Cashback', 'JOINING_BONUS_CASHBACK'),
  ('Cashback', 'CASHBACK'),
  ('Cashback', 'WAKALA PROFIT'),
  ('Cashback', 'BONUS'),
  ('Cashback', 'MURABAHA PROFIT'),
  ('Card Repayment', 'INWARD IPP CC'),
  ('Card Repayment', 'PAYMENT RECEIVED'),
  ('Card Repayment', 'PAYMENTS RECEIVED'),
  ('Card Repayment', 'CREDIT CARD PAYMENT'),
  ('Apple in-app purchase', 'APPLE.COM/BILL CORK'),
  ('Donation', 'SHARETHEMEAL');

revoke all on private.seed_categories, private.seed_rules from public, anon, authenticated;

-- Copy the defaults into a profile, once. A profile that already has categories
-- is left alone, so this can never fight the user's own edits.
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
  insert into public.category_rules (profile_code, category_code, name, match_type, pattern, source)
  select p_profile_code, c.category_code, 'seed: ' || r.pattern, 'contains', r.pattern, 'seed'
  from private.seed_rules r
  join public.categories c on c.profile_code = p_profile_code and c.name = r.category_name;
end;
$$;

-- A signed-in user creates a profile (their ledger) and becomes its owner.
create or replace function public.create_profile(p_key text, p_name text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'sign in required' using errcode = '42501';
  end if;
  insert into public.profiles (key, name) values (p_key, p_name) returning profile_code into v_code;
  insert into public.profile_members (profile_code, user_id, role) values (v_code, auth.uid(), 'owner');
  insert into public.profile_state (profile_code) values (v_code);
  perform private.seed_profile_defaults(v_code);
  return v_code;
end;
$$;

-- Owners add another signed-in user (by email) as owner or viewer.
create or replace function public.add_profile_member(p_profile_code text, p_email text, p_role text default 'viewer')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  perform private.assert_member(p_profile_code, true);
  select id into v_user from auth.users where lower(email) = lower(p_email);
  if v_user is null then
    raise exception 'no user with that email has signed up yet' using errcode = 'P0002';
  end if;
  insert into public.profile_members (profile_code, user_id, role) values (p_profile_code, v_user, p_role)
  on conflict (profile_code, user_id) do update set role = excluded.role;
end;
$$;

grant execute on function public.create_profile(text, text) to authenticated;
grant execute on function public.add_profile_member(text, text, text) to authenticated;

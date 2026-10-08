-- ═════════════════════════════════════════════════════════════════════════════
-- Ledger v2 — local demo data (`supabase db reset` runs this after migrations).
--
-- Everything here is SYNTHETIC: merchants, card numbers, people and amounts are
-- invented. Nothing resembles a real customer.
--
-- What you get:
--   • demo@ledger.local / ledger-demo-pass   (owner of "Demo ledger" + "Household")
--   • viewer@ledger.local / ledger-demo-pass (viewer of "Demo ledger")
--   • Two credit cards (ADCB •4821, FAB •7310), 18 statements Jan–Sep 2026 that go
--     through the real ingest path (public.ingest_parsed_document, contract v1),
--     SMS alerts through public.ingest_sms, October still unbilled (pending SMS).
--   • Review inbox with unknown_card / unparsed_sms / low_score / ambiguous items,
--     one mis-totalled statement (recon 'fail'), budgets, LLM category
--     suggestions, a Gmail mailbox + route, recurring series and insights.
--
-- Profile codes are generated (prf_…). Find them with:
--   select key, profile_code from public.profiles;
--
-- Runs as `postgres`: private.caller_role() is 'none', so service-role-guarded
-- RPCs (ingest_parsed_document, apply_llm_suggestions, propose_sms_template) and
-- owner-guarded ones (ingest_sms, create_service_token) pass. No JWT claims are
-- set, so auth.uid() is null and the audit trail stays empty (seeding is a
-- system write, not a user action).
--
-- Determinism: amounts, days and times come from hashtext() of fixed keys, so a
-- reset always produces the same ledger (only the generated codes differ).
-- ═════════════════════════════════════════════════════════════════════════════


-- The ingest functions create their scratch tables with IF NOT EXISTS once per
-- call; hide those NOTICEs.
set client_min_messages = warning;

-- ── 0. helpers ───────────────────────────────────────────────────────────────
-- Deterministic pseudo-random number in [0, 1) from a text key.
create function pg_temp.rnd(p text) returns numeric
language sql immutable as $$
  select ((hashtext(p)::bigint + 2147483648) / 4294967296.0)::numeric
$$;

create function pg_temp.prof() returns text
language sql stable as $$ select profile_code from public.profiles where key = 'demo' $$;

create function pg_temp.cat(p_name text) returns text
language sql stable as $$
  select category_code from public.categories where profile_code = pg_temp.prof() and name = p_name
$$;

create function pg_temp.money(p numeric) returns text
language sql immutable as $$ select to_char(p, 'FM999,999,990.00') $$;


-- ── 1. auth users (password sign-in through local GoTrue) ────────────────────
-- GoTrue scans the *_token / *_change columns as strings, so they must be ''
-- rather than NULL or sign-in fails with a 500.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, last_sign_in_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  email_change_token_current, phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
       extensions.crypt('ledger-demo-pass', extensions.gen_salt('bf')), now(), null,
       '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
       '', '', '', '', '', '', '', ''
from (values
  ('d0d0d0d0-0000-4000-8000-000000000001'::uuid, 'demo@ledger.local'),
  ('d0d0d0d0-0000-4000-8000-000000000002'::uuid, 'viewer@ledger.local')
) as u(id, email);

insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, 'email',
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       now(), now(), now()
from auth.users u
where u.id in ('d0d0d0d0-0000-4000-8000-000000000001', 'd0d0d0d0-0000-4000-8000-000000000002');


-- ── 2. profiles (same steps as public.create_profile, without a JWT) ─────────
insert into public.profiles (key, name) values
  ('demo', 'Demo ledger'),
  ('household', 'Household');

insert into public.profile_members (profile_code, user_id, role)
select p.profile_code, m.user_id, m.role
from public.profiles p
join (values
  ('demo', 'd0d0d0d0-0000-4000-8000-000000000001'::uuid, 'owner'),
  ('demo', 'd0d0d0d0-0000-4000-8000-000000000002'::uuid, 'viewer'),
  ('household', 'd0d0d0d0-0000-4000-8000-000000000001'::uuid, 'owner')
) as m(key, user_id, role) on m.key = p.key;

insert into public.profile_state (profile_code)
select profile_code from public.profiles where key in ('demo', 'household');

select private.seed_profile_defaults(profile_code) from public.profiles where key in ('demo', 'household');


-- ── 3. accounts and cards ────────────────────────────────────────────────────
-- Registered up front (as the app's "add card" flow would), so SMS alerts that
-- arrive before the first statement already resolve to a card.
do $$
begin
insert into public.accounts (profile_code, bank_code, product_name, nickname, credit_limit, cycle_close_day)
values
  (pg_temp.prof(), 'ADCB', 'Platinum Rewards', 'Everyday', 30000.00, 25),
  (pg_temp.prof(), 'FAB', 'Cashback Signature', 'Bills & travel', 45000.00, 5);

insert into public.cards (profile_code, account_code, bank_code, last4, holder_name)
select a.profile_code, a.account_code, a.bank_code, case a.bank_code when 'ADCB' then '4821' else '7310' end, 'DEMO USER'
from public.accounts a where a.profile_code = pg_temp.prof();
end $$;


-- ── 4. SMS templates (global, synthetic formats) ─────────────────────────────
-- private.validate_sms_template() proves every example parses to its `expect`.
insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples, source)
values
 ('ADCB', 'ADCB credit card purchase', '^ADCB',
  'Credit Card XXX([0-9]{4}) was used for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) at (.*?) on ([0-9]{2}/[0-9]{2}/[0-9]{4}) ([0-9]{2}:[0-9]{2})\. Available limit:? ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})',
  '{"last4":1,"currency":2,"amount":3,"merchant":4,"date":5,"time":6,"available":8}', 'DD/MM/YYYY', 'purchase', 100,
  '[{"sender":"ADCBAlert","body":"Your ADCB Credit Card XXX4821 was used for AED 52.25 at SAFFRON KITCHEN,DUBAI on 03/10/2026 14:22. Available limit: AED 21,345.10.","expect":{"amount":"52.25","currency":"AED","last4":"4821","merchant":"SAFFRON KITCHEN,DUBAI","date":"2026-10-03","time":"14:22","available":"21345.10"}},
    {"sender":"ADCBAlert","body":"Your ADCB Credit Card XXX4821 was used for EUR 86.40 at RESTAURANTE MIRADOURO on 13/09/2026 20:40. Available limit: AED 18,002.00.","expect":{"amount":"86.40","currency":"EUR","merchant":"RESTAURANTE MIRADOURO"}}]', 'seed'),
 ('ADCB', 'ADCB credit card reversal', '^ADCB',
  'Reversal of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on ADCB Credit Card XXX([0-9]{4}) at (.*?) on ([0-9]{2}/[0-9]{2}/[0-9]{4})',
  '{"currency":1,"amount":2,"last4":3,"merchant":4,"date":5}', 'DD/MM/YYYY', 'reversal', 100,
  '[{"sender":"ADCBAlert","body":"Reversal of AED 850.00 on ADCB Credit Card XXX4821 at GRANDVIEW HOTEL on 05/10/2026.","expect":{"amount":"850.00","currency":"AED","last4":"4821","merchant":"GRANDVIEW HOTEL","date":"2026-10-05"}}]', 'seed'),
 ('ADCB', 'ADCB debit card (ignored)', '^ADCB',
  'Debit Card XXX([0-9]{4}) was used for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) at (.*?) on ([0-9]{2}/[0-9]{2}/[0-9]{4})',
  '{"last4":1,"currency":2,"amount":3,"merchant":4,"date":5}', 'DD/MM/YYYY', 'debit_card', 100,
  '[{"sender":"ADCBAlert","body":"Your ADCB Debit Card XXX5530 was used for AED 120.00 at ATM DEIRA on 04/10/2026 18:40.","expect":{"amount":"120.00","last4":"5530"}}]', 'seed'),
 ('FAB', 'FAB credit card purchase', '^FAB',
  'Purchase of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) at (.*?) with Credit Card ending ([0-9]{4}) on ([0-9]{2}/[0-9]{2}/[0-9]{4}) ([0-9]{2}:[0-9]{2})\. Available limit ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})',
  '{"currency":1,"amount":2,"merchant":3,"last4":4,"date":5,"time":6,"available":8}', 'DD/MM/YYYY', 'purchase', 100,
  '[{"sender":"FAB","body":"Purchase of AED 52.25 at OASIS FRESH MART,DUBAI with Credit Card ending 7310 on 03/10/2026 14:22. Available limit AED 38,120.55","expect":{"amount":"52.25","currency":"AED","last4":"7310","merchant":"OASIS FRESH MART,DUBAI","date":"2026-10-03","time":"14:22","available":"38120.55"}},
    {"sender":"FAB","body":"Purchase of USD 20.00 at CODEFORGE.IO with Credit Card ending 7310 on 09/09/2026 04:00. Available limit AED 40,010.00","expect":{"amount":"20.00","currency":"USD","merchant":"CODEFORGE.IO"}}]', 'seed'),
 ('FAB', 'FAB credit card refund', '^FAB',
  'Refund of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) from (.*?) credited to Credit Card ending ([0-9]{4}) on ([0-9]{2}/[0-9]{2}/[0-9]{4})',
  '{"currency":1,"amount":2,"merchant":3,"last4":4,"date":5}', 'DD/MM/YYYY', 'refund', 100,
  '[{"sender":"FAB","body":"Refund of AED 145.00 from ATLAS HOME STORE,DUBAI credited to Credit Card ending 7310 on 21/07/2026.","expect":{"amount":"145.00","currency":"AED","last4":"7310","merchant":"ATLAS HOME STORE,DUBAI","date":"2026-07-21"}}]', 'seed');


-- ── 5. the demo user's own category rules ────────────────────────────────────
-- The seeded keyword rules don't know these synthetic merchants; a user would
-- have added rules like these. Several merchants are deliberately left without
-- any rule so the "uncategorised" flow and LLM suggestions have data.
do $$
begin
insert into public.category_rules (profile_code, category_code, name, match_type, pattern, priority, source)
select pg_temp.prof(), pg_temp.cat(r.category), r.name, 'contains', r.pattern, 90, 'user'
from (values
  ('Dining', 'Saffron Kitchen', 'SAFFRON KITCHEN'),
  ('Transport', 'Desertline fuel', 'DESERTLINE'),
  ('Utilities', 'Metro Utilities bill', 'METRO UTILITIES'),
  ('Utilities', 'Skylink telecom', 'SKYLINK'),
  ('Subscription', 'Streamflix', 'STREAMFLIX'),
  ('Subscription', 'Tunewave', 'TUNEWAVE'),
  ('Subscription', 'Cloudbox', 'CLOUDBOX'),
  ('Subscription', 'Codeforge', 'CODEFORGE'),
  ('Insurance', 'Roadshield motor insurance', 'ROADSHIELD')
) as r(category, name, pattern);
end $$;


-- ── 6. the event plan: every card transaction the demo person makes ─────────
-- One row per real-world card event. Statements (section 7/9) take the rows in
-- their period; SMS alerts (sections 8/10) are generated from the same rows, so
-- statement lines and SMS always agree on amount, date and merchant.
do $$
begin
create temp table ev (
  ev_id int generated always as identity primary key,
  bank text not null,
  last4 text not null,
  txn_date date not null,
  txn_time time not null,
  merchant text not null,                    -- parser's merchant_normalized; rules match on it
  raw_suffix text not null default ' DUBAI AE',
  sms_merchant text,                         -- how the SMS prints it (null → derived)
  currency text not null default 'AED',
  amount numeric(14,2) not null,             -- in `currency`
  fx_rate numeric(18,8),
  amount_aed numeric(14,2) not null,
  direction text not null default 'debit',
  kind text not null default 'purchase',
  country text not null default 'AE',
  sms text not null default 'auto',          -- auto | yes | no
  sms_kind text                              -- 'reversal' for the ADCB reversal alert
);

-- 6a. everyday habits: probability per day, amount range, hour range, weekday bias
insert into ev (bank, last4, txn_date, txn_time, merchant, amount, amount_aed)
select h.bank, case h.bank when 'ADCB' then '4821' else '7310' end, d.day,
       make_time(h.h_lo + floor((h.h_hi - h.h_lo + 1) * pg_temp.rnd(h.merchant || '|h|' || d.key))::int,
                 floor(60 * pg_temp.rnd(h.merchant || '|m|' || d.key))::int, 0),
       h.merchant, a.amt, a.amt
from (values
  -- merchant                 bank    p/day  lo     hi     h_lo h_hi bias
  ('DUNE COFFEE ROASTERS',   'ADCB', 0.33,  16.00,  34.00,  7, 10, 'weekday'),
  ('CAFE MARINA',            'FAB',  0.10,  28.00,  85.00, 10, 17, 'weekend'),
  ('SAFFRON KITCHEN',        'ADCB', 0.08,  85.00, 260.00, 19, 22, 'weekend'),
  ('BAYLEAF RESTAURANT',     'FAB',  0.05, 120.00, 380.00, 19, 22, 'weekend'),
  ('NOMAD FOOD HALL',        'ADCB', 0.07,  38.00,  95.00, 12, 14, 'weekday'),
  ('GREENLEAF MARKET',       'ADCB', 0.12,  60.00, 340.00, 10, 21, 'none'),
  ('OASIS FRESH MART',       'FAB',  0.10,  25.00, 180.00,  9, 22, 'none'),
  ('PALM GROCERY JLT',       'ADCB', 0.07,  12.00,  70.00,  7, 23, 'none'),
  ('CITYRIDE TAXI',          'ADCB', 0.15,  18.00,  75.00,  8, 23, 'none'),
  ('DESERTLINE FUEL',        'FAB',  0.07,  95.00, 160.00,  7, 20, 'none'),
  ('ATLAS HOME STORE',       'FAB',  0.02,  80.00, 650.00, 11, 21, 'weekend'),
  ('NORTHWIND APPAREL',      'ADCB', 0.025,120.00, 520.00, 12, 22, 'weekend'),
  ('KITE LAUNDRY',           'FAB',  0.04,  35.00,  90.00,  9, 19, 'none'),
  ('BLUEFIN PET SUPPLIES',   'ADCB', 0.02,  60.00, 240.00, 10, 20, 'none'),
  ('GOLDLEAF PHARMACY',      'FAB',  0.03,  25.00, 140.00,  9, 22, 'none'),
  ('STARLIGHT CINEMA',       'ADCB', 0.02,  45.00, 120.00, 18, 23, 'weekend')
) as h(merchant, bank, p, lo, hi, h_lo, h_hi, bias)
cross join lateral (
  select g::date as day, to_char(g::date, 'YYYY-MM-DD') as key, extract(isodow from g::date)::int as dow
  from generate_series(date '2025-12-06', date '2026-10-08', interval '1 day') g
) d
cross join lateral (select round(h.lo + (h.hi - h.lo) * pg_temp.rnd(h.merchant || '|a|' || d.key), 2) as amt) a
where pg_temp.rnd(h.merchant || '|p|' || d.key) < h.p * case h.bias
        when 'weekday' then case when d.dow <= 5 then 1.3 else 0.5 end
        when 'weekend' then case when d.dow >= 5 then 1.7 else 0.7 end
        else 1 end
  -- each card's first statement period starts here
  and d.day >= case h.bank when 'ADCB' then date '2025-12-26' else date '2025-12-06' end
  -- keep this week clear for the hand-made "ambiguous" coffee pair (section 11)
  and not (h.merchant = 'DUNE COFFEE ROASTERS' and d.day between date '2026-09-15' and date '2026-09-21');

-- 6b. monthly bills and subscriptions: steady amount, steady day
insert into ev (bank, last4, txn_date, txn_time, merchant, raw_suffix, currency, amount, fx_rate, amount_aed, country)
select s.bank, case s.bank when 'ADCB' then '4821' else '7310' end,
       make_date(extract(year from m)::int, extract(month from m)::int, s.dom), s.at, s.merchant, s.suffix, s.cur,
       x.amt, s.fx, round(x.amt * coalesce(s.fx, 1), 2), s.country
from (values
  ('STREAMFLIX.COM',          'FAB',   3, time '03:10', ' INTERNET',   'AED', null::numeric, 39.00,  'AE'),
  ('CLOUDBOX STORAGE',        'FAB',   2, time '02:45', ' INTERNET',   'AED', null,          11.00,  'AE'),
  ('CODEFORGE.IO',            'FAB',   9, time '04:00', ' SAN FRANCISCO US', 'USD', 3.6725, 20.00, 'US'),
  ('TUNEWAVE MUSIC',          'ADCB', 14, time '06:00', ' INTERNET',   'AED', null,          21.99,  'AE'),
  ('SKYLINK TELECOM',         'ADCB', 12, time '09:00', ' DUBAI AE',   'AED', null,         299.00,  'AE'),
  ('METRO UTILITIES BILLPAY', 'ADCB',  8, time '20:15', ' DUBAI AE',   'AED', null,           0.00,  'AE')
) as s(merchant, bank, dom, at, suffix, cur, fx, base, country)
cross join generate_series(date '2025-12-01', date '2026-10-01', interval '1 month') m
cross join lateral (
  select case
           -- utilities vary with the season
           when s.merchant = 'METRO UTILITIES BILLPAY' then round(380 + 240 * pg_temp.rnd('util|' || to_char(m, 'YYYY-MM')), 2)
           -- Cloudbox raised its price in October
           when s.merchant = 'CLOUDBOX STORAGE' and m >= date '2026-10-01' then 14.50
           else s.base end as amt
) x
where make_date(extract(year from m)::int, extract(month from m)::int, s.dom)
      >= case s.bank when 'ADCB' then date '2025-12-26' else date '2025-12-06' end;

-- 6c. one-offs, travel, FX, refunds, fees
insert into ev (bank, last4, txn_date, txn_time, merchant, raw_suffix, currency, amount, fx_rate, amount_aed,
                direction, kind, country, sms, sms_kind)
select e.bank, case e.bank when 'ADCB' then '4821' else '7310' end, e.d, e.t, e.merchant, e.suffix, e.cur, e.amt, e.fx,
       round(e.amt * coalesce(e.fx, 1), 2), e.dir, e.kind, e.country, e.sms, e.sms_kind
from (values
  -- yearly motor insurance (a single charge in this window)
  ('ADCB', date '2026-03-18', time '11:40', 'ROADSHIELD MOTOR INSURANCE', ' DUBAI AE', 'AED', 2150.00, null::numeric, 'debit', 'purchase', 'AE', 'yes', null),
  -- large one-off: a new laptop
  ('ADCB', date '2026-07-09', time '18:25', 'VOLTA ELECTRONICS', ' DUBAI AE', 'AED', 4800.00, null, 'debit', 'purchase', 'AE', 'yes', null),
  -- flights for the September trip
  ('ADCB', date '2026-08-20', time '22:05', 'SKYWARD AIRWAYS', ' DUBAI AE', 'AED', 3240.00, null, 'debit', 'purchase', 'AE', 'yes', null),
  -- September trip to Lisbon (EUR)
  ('ADCB', date '2026-09-12', time '13:05', 'TAXI LISBOA', ' LISBOA PT', 'EUR', 18.60, 4.3125, 'debit', 'purchase', 'PT', 'yes', null),
  ('ADCB', date '2026-09-12', time '15:20', 'CASA ALFAMA HOTEL', ' LISBOA PT', 'EUR', 640.00, 4.3125, 'debit', 'purchase', 'PT', 'yes', null),
  ('ADCB', date '2026-09-13', time '10:15', 'LISBOA CITY TRANSIT', ' LISBOA PT', 'EUR', 12.00, 4.3098, 'debit', 'purchase', 'PT', 'yes', null),
  ('ADCB', date '2026-09-13', time '20:40', 'RESTAURANTE MIRADOURO', ' LISBOA PT', 'EUR', 86.40, 4.3098, 'debit', 'purchase', 'PT', 'yes', null),
  ('ADCB', date '2026-09-14', time '09:30', 'PASTELARIA BELEM', ' LISBOA PT', 'EUR', 9.80, 4.3150, 'debit', 'purchase', 'PT', 'yes', null),
  ('ADCB', date '2026-09-15', time '21:10', 'TASCA DO BAIRRO', ' LISBOA PT', 'EUR', 54.20, 4.3150, 'debit', 'purchase', 'PT', 'yes', null),
  ('ADCB', date '2026-09-16', time '19:55', 'RESTAURANTE MIRADOURO', ' LISBOA PT', 'EUR', 61.00, 4.3150, 'debit', 'purchase', 'PT', 'yes', null),
  ('ADCB', date '2026-09-17', time '11:00', 'AZULEJO CORNER', ' LISBOA PT', 'EUR', 145.00, 4.3172, 'debit', 'purchase', 'PT', 'yes', null),
  -- USD / GBP online purchases on FAB (the bank's own rate includes a markup)
  ('FAB',  date '2026-02-11', time '23:10', 'PIXEL PRINT STUDIO', ' NEW YORK US', 'USD', 24.00, 3.7095, 'debit', 'purchase', 'US', 'auto', null),
  ('FAB',  date '2026-04-23', time '22:30', 'PIXEL PRINT STUDIO', ' NEW YORK US', 'USD', 89.00, 3.7095, 'debit', 'purchase', 'US', 'auto', null),
  ('FAB',  date '2026-07-30', time '21:45', 'PIXEL PRINT STUDIO', ' NEW YORK US', 'USD', 46.50, 3.7095, 'debit', 'purchase', 'US', 'auto', null),
  ('FAB',  date '2026-06-14', time '16:20', 'THAMES BOOKSELLERS', ' LONDON GB', 'GBP', 32.00, 4.9610, 'debit', 'purchase', 'GB', 'yes', null),
  -- refunds
  ('ADCB', date '2026-05-12', time '12:00', 'NORTHWIND APPAREL', ' DUBAI AE', 'AED', 189.00, null, 'credit', 'refund', 'AE', 'no', null),
  ('FAB',  date '2026-07-21', time '15:35', 'ATLAS HOME STORE', ' DUBAI AE', 'AED', 145.00, null, 'credit', 'refund', 'AE', 'yes', null),
  -- annual fee + VAT (FAB April statement)
  ('FAB',  date '2026-04-01', time '00:00', 'ANNUAL FEE', '', 'AED', 300.00, null, 'debit', 'fee', 'AE', 'no', null),
  ('FAB',  date '2026-04-01', time '00:00', 'VAT ON ANNUAL FEE', '', 'AED', 15.00, null, 'debit', 'fee', 'AE', 'no', null),
  -- statement-only lines the late SMS in section 11 will fail to match cleanly
  ('ADCB', date '2026-09-22', time '21:47', 'HARBOUR LIGHTS BISTRO', ' DUBAI AE', 'AED', 146.00, null, 'debit', 'purchase', 'AE', 'no', null),
  ('ADCB', date '2026-09-17', time '08:05', 'DUNE COFFEE ROASTERS', ' DUBAI AE', 'AED', 24.50, null, 'debit', 'purchase', 'AE', 'no', null),
  ('ADCB', date '2026-09-18', time '08:12', 'DUNE COFFEE ROASTERS', ' DUBAI AE', 'AED', 24.50, null, 'debit', 'purchase', 'AE', 'no', null),
  -- October (unbilled): a birthday dinner, a hotel hold and its reversal, a double-fired alert
  ('ADCB', date '2026-10-02', time '20:45', 'SAFFRON KITCHEN', ' DUBAI AE', 'AED', 268.00, null, 'debit', 'purchase', 'AE', 'auto', null),
  ('ADCB', date '2026-10-04', time '19:30', 'GRANDVIEW HOTEL', ' DUBAI AE', 'AED', 850.00, null, 'debit', 'purchase', 'AE', 'auto', null),
  ('ADCB', date '2026-10-05', time '11:02', 'GRANDVIEW HOTEL', ' DUBAI AE', 'AED', 850.00, null, 'credit', 'refund', 'AE', 'auto', 'reversal'),
  ('FAB',  date '2026-10-06', time '13:20', 'CAFE MARINA', ' DUBAI AE', 'AED', 47.50, null, 'debit', 'purchase', 'AE', 'auto', null)
) as e(bank, d, t, merchant, suffix, cur, amt, fx, dir, kind, country, sms, sms_kind);

update ev set sms_merchant = 'GRANDVIEW HOTEL' where merchant = 'GRANDVIEW HOTEL';

-- ADCB's foreign transaction fee on the Lisbon spend (2.09%), on the September statement
insert into ev (bank, last4, txn_date, txn_time, merchant, raw_suffix, amount, amount_aed, kind, sms)
select 'ADCB', '4821', date '2026-09-24', time '00:00', 'FOREIGN TRANSACTION FEE', '',
       round(sum(amount_aed) * 0.0209, 2), round(sum(amount_aed) * 0.0209, 2), 'fee', 'no'
from ev where bank = 'ADCB' and currency = 'EUR';

-- "Now" for the demo is 2026-10-08 ~11:00 Dubai: nothing after that has happened yet.
delete from ev where txn_date + txn_time > timestamp '2026-10-08 11:00';
end $$;


-- ── 7. statement plan: 9 monthly statements per card, totals computed here ──
-- ADCB closes on the 25th (due +18 days), FAB on the 5th (due +20 days).
-- Each statement carries the payment of the previous one (paid the day before it
-- was due), so opening = previous closing and closing = opening + debits − credits.
-- FAB's June payment is partial, so July carries a finance charge.
-- FAB April is deliberately mis-totalled (the "parser" read the summary box
-- wrong) so reconciliation fails for exactly one statement.
do $$
begin
create temp table stm (
  bank text, last4 text, seq int, stmt_date date, period_start date, due_date date,
  opening numeric(14,2), debits numeric(14,2), credits numeric(14,2), closing numeric(14,2),
  reported_debits numeric(14,2), min_due numeric(14,2), credit_limit numeric(14,2), card_type text,
  warnings jsonb
);
end $$;

do $$
declare
  b record;
  i int;
  v_prev date;
  v_date date;
  v_open numeric(14,2);
  v_pay numeric(14,2);
  v_carry numeric(14,2);
  v_deb numeric(14,2);
  v_cred numeric(14,2);
  v_close numeric(14,2);
  v_reported numeric(14,2);
begin
  for b in
    select * from (values
      ('ADCB', '4821', 25, 18, 2940.15::numeric(14,2), 30000.00::numeric(14,2), 'VISA PLATINUM',
       'PAYMENT RECEIVED - THANK YOU'),
      ('FAB', '7310', 5, 20, 1615.80::numeric(14,2), 45000.00::numeric(14,2), 'MASTERCARD WORLD',
       'CREDIT CARD PAYMENT VIA MOBILE BANKING')
    ) as x(bank, last4, close_day, due_days, opening, credit_limit, card_type, payment_desc)
  loop
    v_prev := make_date(2025, 12, b.close_day);
    v_open := b.opening;
    v_carry := 0;
    for i in 1..9 loop
      v_date := make_date(2026, i, b.close_day);

      -- payment of the previous statement, the day before it was due
      v_pay := case when b.bank = 'FAB' and i = 6 then round(v_open * 0.6, 2) else v_open end;
      insert into ev (bank, last4, txn_date, txn_time, merchant, raw_suffix, amount, amount_aed, direction, kind, sms)
      values (b.bank, b.last4, v_prev + b.due_days - 1, time '10:00', b.payment_desc, '', v_pay, v_pay,
              'credit', 'payment', 'no');

      -- interest on last month's unpaid balance
      if v_carry > 0 then
        insert into ev (bank, last4, txn_date, txn_time, merchant, raw_suffix, amount, amount_aed, kind, sms)
        values (b.bank, b.last4, v_date, time '00:00', 'FINANCE CHARGES', '', round(v_carry * 0.0325, 2),
                round(v_carry * 0.0325, 2), 'interest', 'no');
        v_carry := 0;
      end if;
      if b.bank = 'FAB' and i = 6 then
        v_carry := v_open - v_pay;
      end if;

      select coalesce(sum(amount_aed) filter (where direction = 'debit'), 0),
             coalesce(sum(amount_aed) filter (where direction = 'credit'), 0)
      into v_deb, v_cred
      from ev where bank = b.bank and txn_date between v_prev + 1 and v_date;

      v_close := v_open + v_deb - v_cred;
      v_reported := case when b.bank = 'FAB' and i = 4 then v_deb + 112.40 else v_deb end;

      insert into stm values (
        b.bank, b.last4, i, v_date, v_prev + 1, v_date + b.due_days,
        v_open, v_deb, v_cred, v_close, v_reported,
        greatest(round(v_close * 0.05, 2), least(v_close, 100.00)), b.credit_limit, b.card_type,
        case when v_reported <> v_deb
             then jsonb_build_array('Summary total debits differ from the sum of transaction lines')
             else '[]'::jsonb end
      );
      v_prev := v_date;
      v_open := v_close;
    end loop;
  end loop;
end $$;


-- ── 8. SMS alerts ────────────────────────────────────────────────────────────
-- Phase 2 = alerts for billed periods (sent before the statements are ingested,
-- as in real life: ~40% of purchases, plus everything on ADCB in the last ten
-- days of its September cycle). Phase 4 = every alert after each card's last
-- statement (ADCB > 25 Sep, FAB > 5 Sep): these stay pending.
do $$
begin
create temp table sms_out as
select e.ev_id,
       case when e.txn_date > case e.bank when 'ADCB' then date '2026-09-25' else date '2026-09-05' end
            then 4 else 2 end as phase,
       (e.txn_date + e.txn_time) at time zone 'Asia/Dubai'
         + make_interval(secs => 4 + floor(40 * pg_temp.rnd('rcv|' || e.ev_id))::int) as received_at,
       md5('ledger-demo-sms|' || e.bank || '|' || to_char(e.txn_date, 'YYYY-MM-DD') || '|' || e.txn_time
           || '|' || e.merchant || '|' || e.amount || '|' || e.direction)::uuid as client_msg_id,
       case e.bank when 'ADCB' then 'ADCBAlert' else 'FAB' end as sender,
       case
         when e.bank = 'ADCB' and e.sms_kind = 'reversal' then
           format('Reversal of %s %s on ADCB Credit Card XXX%s at %s on %s.', e.currency, f.amt, e.last4, f.m, f.d)
         when e.bank = 'ADCB' then
           format('Your ADCB Credit Card XXX%s was used for %s %s at %s on %s %s. Available limit: AED %s.',
                  e.last4, e.currency, f.amt, f.m, f.d, f.t, f.avail)
         when e.kind = 'refund' then
           format('Refund of %s %s from %s credited to Credit Card ending %s on %s.', e.currency, f.amt, f.m, e.last4, f.d)
         else
           format('Purchase of %s %s at %s with Credit Card ending %s on %s %s. Available limit AED %s',
                  e.currency, f.amt, f.m, e.last4, f.d, f.t, f.avail)
       end as body
from ev e
cross join lateral (
  select pg_temp.money(e.amount) as amt,
         coalesce(e.sms_merchant, case when e.raw_suffix = ' DUBAI AE' then e.merchant || ',DUBAI' else e.merchant end) as m,
         to_char(e.txn_date, 'DD/MM/YYYY') as d,
         to_char(e.txn_time, 'HH24:MI') as t,
         pg_temp.money(case e.bank when 'ADCB' then 30000 else 45000 end - 1800
                       - round(9000 * pg_temp.rnd('avail|' || e.ev_id), 2)) as avail
) f
where e.sms <> 'no'
  and (e.kind = 'purchase' or (e.kind = 'refund' and (e.bank = 'FAB' or e.sms_kind = 'reversal')))
  and (e.sms = 'yes'
       or e.txn_date > case e.bank when 'ADCB' then date '2026-09-25' else date '2026-09-05' end
       or (e.bank = 'ADCB' and e.txn_date between date '2026-09-15' and date '2026-09-25')
       or pg_temp.rnd('sms|' || e.merchant || '|' || to_char(e.txn_date, 'YYYY-MM-DD') || '|' || e.amount) < 0.4);
end $$;

do $$
declare
  r record;
begin
  for r in select * from sms_out where phase = 2 order by received_at, ev_id loop
    perform public.ingest_sms(pg_temp.prof(), jsonb_build_array(jsonb_build_object(
      'client_msg_id', r.client_msg_id, 'received_at', r.received_at, 'sender', r.sender, 'body', r.body)));
  end loop;
end $$;


-- ── 9. statements through the real ingest path ───────────────────────────────
-- One documents row per PDF (storage_path = <profile_code>/<doc_code>.pdf), then
-- public.ingest_parsed_document(doc_code, contract-v1 payload).
do $$
declare
  s record;
  v_prof text := pg_temp.prof();
  v_doc text;
  v_file text;
  v_lines jsonb;
  v_source text;
begin
  for s in select * from stm order by stmt_date, bank loop
    v_doc := public.gen_code('doc');
    v_file := s.bank || '_' || to_char(s.stmt_date, 'YYYY-MM') || '.pdf';
    -- ADCB: scraper, then the Gmail route from August; FAB: manual uploads
    v_source := case when s.bank = 'FAB' then 'upload' when s.seq >= 8 then 'gmail' else 'scraper' end;

    insert into public.documents (doc_code, profile_code, bank_code, storage_path, original_filename, sha256,
                                  size_bytes, source, source_ref, parse_attempts, created_at)
    values (v_doc, v_prof, s.bank, v_prof || '/' || v_doc || '.pdf', v_file,
            encode(sha256(convert_to('ledger-demo|' || v_file, 'UTF8')), 'hex'),
            140000 + floor(90000 * pg_temp.rnd('size|' || v_file))::int,
            v_source,
            case when v_source = 'gmail' then 'demo-msg-' || to_char(s.stmt_date, 'YYYYMM') || '/att-1' end,
            1, (s.stmt_date + 1 + time '07:30') at time zone 'Asia/Dubai');

    select jsonb_agg(jsonb_build_object(
             'line_no', l.rn,
             'txn_date', l.txn_date,
             'txn_time', null,
             'posting_date', case when l.kind in ('payment', 'fee', 'interest') then l.txn_date
                                  else least(l.txn_date + 1, s.stmt_date) end,
             'description_raw', l.merchant || l.raw_suffix,
             'merchant_normalized', l.merchant,
             'amount_original', l.amount::text,
             'currency_original', l.currency,
             'amount_aed', l.amount_aed::text,
             'fx_rate', l.fx_rate::text,
             'direction', l.direction,
             'kind', l.kind,
             'country_code', l.country,
             'card_last4', l.last4,
             'card_holder', null,
             'legacy_fingerprint', null) order by l.rn)
    into v_lines
    from (select e.*, row_number() over (order by e.txn_date, e.txn_time, e.ev_id) as rn
          from ev e where e.bank = s.bank and e.txn_date between s.period_start and s.stmt_date) l;

    perform public.ingest_parsed_document(v_doc, jsonb_build_object(
      'contract_version', 1,
      'parser_version', '2026.10.0-demo',
      'bank_code', s.bank,
      'document_kind', 'statement_pdf',
      'statements', jsonb_build_array(jsonb_build_object(
        'kind', 'statement',
        'bank_code', s.bank,
        'statement_reference', s.bank || '-' || s.last4 || '-' || to_char(s.stmt_date, 'YYYYMM'),
        'reference_source', 'explicit',
        'statement_date', s.stmt_date,
        'period_start', s.period_start,
        'period_end', s.stmt_date,
        'due_date', s.due_date,
        'primary_card_last4', s.last4,
        'card_holder', 'DEMO USER',
        'card_type', s.card_type,
        'totals', jsonb_build_object(
          'opening_balance', s.opening::text,
          'closing_balance', s.closing::text,
          'total_debits', s.reported_debits::text,
          'total_credits', s.credits::text,
          'min_due', s.min_due::text,
          'credit_limit', s.credit_limit::text),
        'warnings', s.warnings,
        'metadata', '{}'::jsonb,
        'lines', v_lines))));
  end loop;
end $$;


-- ── 10. unbilled alerts (October + FAB since 5 Sep) → pending transactions ───
do $$
declare
  r record;
begin
  for r in select * from sms_out where phase = 4 order by received_at, ev_id loop
    perform public.ingest_sms(pg_temp.prof(), jsonb_build_array(jsonb_build_object(
      'client_msg_id', r.client_msg_id, 'received_at', r.received_at, 'sender', r.sender, 'body', r.body)));
  end loop;
end $$;


-- ── 11. alerts that need a human (review inbox) ──────────────────────────────
do $$
declare
  v_prof text := pg_temp.prof();
  v_dup record;
  v_unparsed text;
begin
  -- low_score: a late alert for a posted dinner, printed under the operator's
  -- legal name and dated three days before the statement line.
  perform public.ingest_sms(v_prof, jsonb_build_array(jsonb_build_object(
    'client_msg_id', md5('ledger-demo-special|low-score')::uuid,
    'received_at', timestamptz '2026-09-19 21:48:10+04', 'sender', 'ADCBAlert',
    'body', 'Your ADCB Credit Card XXX4821 was used for AED 146.00 at HLB F AND B LLC,DUBAI on 19/09/2026 21:47. Available limit: AED 19,870.35.')));

  -- ambiguous: one coffee alert, two identical posted coffees on consecutive days.
  perform public.ingest_sms(v_prof, jsonb_build_array(jsonb_build_object(
    'client_msg_id', md5('ledger-demo-special|ambiguous')::uuid,
    'received_at', timestamptz '2026-09-18 08:12:40+04', 'sender', 'ADCBAlert',
    'body', 'Your ADCB Credit Card XXX4821 was used for AED 24.50 at DUNE COFFEE ROASTERS,DUBAI on 18/09/2026 08:12. Available limit: AED 20,114.80.')));

  -- unknown_card: a card the profile has never seen (a new replacement card).
  perform public.ingest_sms(v_prof, jsonb_build_array(jsonb_build_object(
    'client_msg_id', md5('ledger-demo-special|unknown-card')::uuid,
    'received_at', timestamptz '2026-10-06 09:31:05+04', 'sender', 'ADCBAlert',
    'body', 'Your ADCB Credit Card XXX9902 was used for AED 75.00 at DUNE COFFEE ROASTERS,DUBAI on 06/10/2026 09:31. Available limit: AED 29,925.00.')));

  -- debit card alert: parsed by the debit_card template and ignored.
  perform public.ingest_sms(v_prof, jsonb_build_array(jsonb_build_object(
    'client_msg_id', md5('ledger-demo-special|debit-card')::uuid,
    'received_at', timestamptz '2026-10-04 18:40:20+04', 'sender', 'ADCBAlert',
    'body', 'Your ADCB Debit Card XXX5530 was used for AED 120.00 at ATM DEIRA on 04/10/2026 18:40.')));

  -- the same alert delivered twice: once with the same client id (idempotent
  -- re-delivery), once double-fired by the automation with a new id (linked as
  -- duplicate evidence, no second transaction).
  select client_msg_id, received_at, sender, body into v_dup
  from public.sms_messages
  where profile_code = v_prof and body like 'Purchase of AED 47.50 at CAFE MARINA,DUBAI%06/10/2026%';
  perform public.ingest_sms(v_prof, jsonb_build_array(
    jsonb_build_object('client_msg_id', v_dup.client_msg_id, 'received_at', v_dup.received_at,
                       'sender', v_dup.sender, 'body', v_dup.body),
    jsonb_build_object('client_msg_id', md5('ledger-demo-special|double-fire')::uuid,
                       'received_at', v_dup.received_at + interval '41 seconds',
                       'sender', v_dup.sender, 'body', v_dup.body)));

  -- unparsed: a FAB format no template knows. The LLM fallback "proposes" a
  -- template (stored inactive) and an unparsed_sms review awaits the owner.
  perform public.ingest_sms(v_prof, jsonb_build_array(jsonb_build_object(
    'client_msg_id', md5('ledger-demo-special|unparsed')::uuid,
    'received_at', timestamptz '2026-10-06 09:15:30+04', 'sender', 'FAB',
    'body', 'FAB Alert: Credit Card ending 7310 charged AED 64.00 by PARKVIEW PARKING on 06-10-2026 at 09:15. Call 600 000000 if not you.')));
  select sms_code into v_unparsed from public.sms_messages
  where profile_code = v_prof and client_msg_id = md5('ledger-demo-special|unparsed')::uuid;
  perform public.propose_sms_template(v_unparsed, jsonb_build_object(
    'bank_code', 'FAB',
    'name', 'FAB credit card charge (proposed)',
    'sender_pattern', '^FAB',
    'body_pattern', 'Credit Card ending ([0-9]{4}) charged ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) by (.*?) on ([0-9]{2}-[0-9]{2}-[0-9]{4}) at ([0-9]{2}:[0-9]{2})',
    'field_groups', jsonb_build_object('last4', 1, 'currency', 2, 'amount', 3, 'merchant', 4, 'date', 5, 'time', 6),
    'date_format', 'DD-MM-YYYY',
    'msg_kind', 'purchase',
    'expect', jsonb_build_object('amount', '64.00', 'currency', 'AED', 'last4', '7310',
                                 'merchant', 'PARKVIEW PARKING', 'date', '2026-10-06', 'time', '09:15')));
end $$;


-- ── 12. budgets (from January; Dining and Subscription run hot in October) ──
do $$
begin
insert into public.budgets (profile_code, category_code, amount_aed, effective_from)
select pg_temp.prof(), case when b.category is null then null else pg_temp.cat(b.category) end, b.amount, date '2026-01-01'
from (values
  (null::text, 6500.00),
  ('Dining', 1200.00),
  ('Grocery', 1400.00),
  ('Shopping', 1000.00),
  ('Subscription', 250.00)
) as b(category, amount);
end $$;


-- ── 13. categorisation extras ────────────────────────────────────────────────
-- LLM suggestions (lowest precedence) for merchants no rule covers. OASIS FRESH
-- MART (the most frequent one), ATLAS HOME STORE, BLUEFIN PET SUPPLIES, PIXEL
-- PRINT STUDIO, THAMES BOOKSELLERS, HARBOUR LIGHTS BISTRO and a few Lisbon
-- merchants stay uncategorised on purpose (~11% of transactions). The real category-set hash is used so the nightly
-- LLM enqueue does not immediately re-ask for these merchants.
do $$
begin
perform public.apply_llm_suggestions(
  pg_temp.prof(),
  (select jsonb_agg(jsonb_build_object(
            'merchant_code', (select merchant_code from public.merchants where merchant_key = public.merchant_key(s.merchant)),
            'category_code', pg_temp.cat(s.category),
            'confidence', s.confidence))
   from (values
     ('KITE LAUNDRY', 'Utilities', 0.71),
     ('NORTHWIND APPAREL', 'Shopping', 0.79),
     ('VOLTA ELECTRONICS', 'Shopping', 0.83),
     ('SKYWARD AIRWAYS', 'Travel', 0.90),
     ('PASTELARIA BELEM', 'Dining', 0.72)
   ) as s(merchant, category, confidence)),
  'claude-haiku',
  private.category_set_hash(pg_temp.prof()));

-- One manual choice, so the Activity screen shows every category source.
perform public.set_transaction_category(t.txn_code, pg_temp.cat('Dining'))
from public.transactions t
where t.profile_code = pg_temp.prof() and t.description = 'TASCA DO BAIRRO';
end $$;


-- ── 14. email ingestion, service token, documents not parsed (yet) ──────────
do $$
begin
insert into public.email_mailboxes (profile_code, provider, mailbox_email, sync_state, watch_expires_at, last_synced_at)
values (pg_temp.prof(), 'gmail', 'demo.statements@example.com', '{"history_id": "482913"}'::jsonb,
        now() + interval '6 days', now() - interval '3 hours');

insert into public.email_routes (profile_code, mailbox_code, bank_code, sender_allowlist, subject_keywords,
                                 attachment_filename_regex)
select m.profile_code, m.mailbox_code, 'ADCB', array['estatements@bank.example'], array['Credit Card Statement'],
       'statement.*\.pdf$'
from public.email_mailboxes m where m.profile_code = pg_temp.prof();

insert into public.email_events (profile_code, route_code, provider_message_id, provider_attachment_id,
                                 attachment_filename, attachment_sha256, status, doc_code, detail, created_at)
select r.profile_code, r.route_code, x.msg, x.att, x.fname, d.sha256, x.status, d.doc_code, x.detail, x.at
from public.email_routes r
cross join (values
  ('demo-msg-202608', 'att-1', 'ADCB_2026-08.pdf', 'ingested', null::text, timestamptz '2026-08-26 07:30+04'),
  ('demo-msg-202609', 'att-1', 'ADCB_2026-09.pdf', 'ingested', null, timestamptz '2026-09-26 07:30+04'),
  ('demo-msg-202609-fwd', 'att-1', 'ADCB_2026-09.pdf', 'duplicate', 'same PDF already ingested', timestamptz '2026-09-27 12:04+04'),
  ('demo-msg-202609-promo', 'att-2', 'rewards_offer.png', 'ignored', 'attachment is not a PDF', timestamptz '2026-09-29 16:40+04')
) as x(msg, att, fname, status, detail, at)
left join public.documents d on d.profile_code = r.profile_code and d.original_filename = x.fname and x.fname like '%.pdf'
where r.profile_code = pg_temp.prof();
end $$;

-- A scraper token (the plaintext is returned once and discarded here).
do $$
begin
  perform public.create_service_token(pg_temp.prof(), 'Local scraper (demo)', array['statements:upload', 'sms:ingest']);
  update public.service_tokens set last_used_at = timestamptz '2026-09-26 07:28+04'
  where profile_code = pg_temp.prof();
end $$;

-- A password-protected PDF that failed, and FAB's October statement still queued.
do $$
begin
insert into public.documents (doc_code, profile_code, bank_code, storage_path, original_filename, sha256, size_bytes, source,
                              parse_status, parse_attempts, parse_error_code, parse_error, created_at)
select x.code, pg_temp.prof(), x.bank, pg_temp.prof() || '/' || x.code || '.pdf', x.fname,
       encode(sha256(convert_to('ledger-demo|' || x.fname, 'UTF8')), 'hex'), x.size, x.source,
       x.status, x.attempts, x.err_code, x.err, x.at
from (values
  (public.gen_code('doc'), 'ADCB', 'ADCB_2025-12.pdf', 188412, 'upload', 'failed', 1::smallint,
   'PDF_DECRYPT_FAILED', 'Password required', timestamptz '2026-10-07 21:12+04'),
  (public.gen_code('doc'), 'FAB', 'FAB_2026-10.pdf', 151230, 'scraper', 'queued', 0::smallint,
   null, null, timestamptz '2026-10-08 07:45+04')
) as x(code, bank, fname, size, source, status, attempts, err_code, err, at);
end $$;

-- Inserting documents enqueued parse jobs. Keep only the one for the queued PDF
-- so a locally running worker doesn't try to re-parse seeded statements, and
-- drop the SMS fallback job that section 11 already "handled".
do $$
begin
perform pgmq.delete('parse_document', q.msg_id)
from pgmq.q_parse_document q
join public.documents d on d.doc_code = q.message->>'doc_code'
where d.parse_status <> 'queued';

perform pgmq.delete('sms_fallback', q.msg_id)
from pgmq.q_sms_fallback q
where exists (select 1 from public.match_reviews r
              where r.subject_code = q.message->>'sms_code' and r.reason = 'unparsed_sms');
end $$;


-- ── 15. nightly housekeeping: recurring series + insights ───────────────────
select private.nightly();

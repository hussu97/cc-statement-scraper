-- App Review demo ledger (Guideline 2.1(a)): Apple's Beta App Review signs in with
-- a username and password and needs a ledger that shows every screen with data.
--
-- private.create_review_demo(user_id) creates the "app-review" profile, makes that
-- user its owner, and fills it with SYNTHETIC cards, statements and SMS alerts
-- dated relative to today, through the real ingest paths (ingest_parsed_document,
-- ingest_sms) so every derived table is what production would derive.
--
-- Run by an admin as `postgres` (scripts/cutover/create-review-demo.sh): private
-- is unreachable for client roles, and the guard also refuses any other role.
-- Nothing global is written except merchants (shared reference data, as for any
-- ingest): no SMS templates, no rules outside the profile. The alerts use the
-- formats the real ADCB / FAB templates already parse, so nothing reaches the LLM
-- fallback. The parse jobs the documents trigger enqueues are deleted (the PDFs
-- don't exist; the statements are ingested directly).

create or replace function private.review_demo_rnd(p text)
returns numeric
language sql
immutable
set search_path = ''
as $$ select ((hashtext(p)::bigint + 2147483648) / 4294967296.0)::numeric $$;

create or replace function private.seed_review_demo(p_profile_code text, p_today date)
returns void
language plpgsql
set search_path = ''
as $$
declare
  b record;
  s record;
  r record;
  i int;
  v_last date;
  v_prev date;
  v_date date;
  v_open numeric(14,2);
  v_deb numeric(14,2);
  v_cred numeric(14,2);
  v_close numeric(14,2);
  v_doc text;
  v_lines jsonb;
  v_start date;
begin
  perform private.assert_service_role();

  -- ── cards ──────────────────────────────────────────────────────────────────
  insert into public.accounts (profile_code, bank_code, product_name, nickname, credit_limit, cycle_close_day)
  values (p_profile_code, 'ADCB', 'Platinum Rewards', 'Everyday', 30000.00, 25),
         (p_profile_code, 'FAB', 'Cashback Signature', 'Bills & travel', 45000.00, 5);
  insert into public.cards (profile_code, account_code, bank_code, last4, holder_name)
  select a.profile_code, a.account_code, a.bank_code, case a.bank_code when 'ADCB' then '4821' else '7310' end, 'DEMO USER'
  from public.accounts a where a.profile_code = p_profile_code;

  -- ── the profile's own category rules (one merchant is left for the LLM) ─────
  insert into public.category_rules (profile_code, category_code, name, match_type, pattern, priority, source)
  select p_profile_code, c.category_code, x.pattern, 'contains', x.pattern, 90, 'user'
  from (values
    ('Dining', 'DUNE COFFEE ROASTERS'), ('Dining', 'SAFFRON KITCHEN'), ('Dining', 'CAFE MARINA'),
    ('Dining', 'NOMAD FOOD HALL'), ('Dining', 'RESTAURANTE MIRADOURO'), ('Dining', 'TASCA DO BAIRRO'),
    ('Grocery', 'GREENLEAF MARKET'), ('Grocery', 'OASIS FRESH MART'),
    ('Transport', 'CITYRIDE TAXI'), ('Transport', 'TAXI LISBOA'), ('Car & Fuel', 'DESERTLINE FUEL'),
    ('Shopping', 'NORTHWIND APPAREL'), ('Shopping', 'ATLAS HOME STORE'), ('Shopping', 'VOLTA ELECTRONICS'),
    ('Entertainment', 'STARLIGHT CINEMA'), ('Medicine', 'GOLDLEAF PHARMACY'),
    ('Subscription', 'STREAMFLIX'), ('Subscription', 'TUNEWAVE'), ('Subscription', 'CLOUDBOX'),
    ('Telecom & Internet', 'SKYLINK TELECOM'), ('Utilities', 'METRO UTILITIES'),
    ('Travel', 'SKYWARD AIRWAYS'), ('Travel', 'CASA ALFAMA HOTEL')
  ) as x(category, pattern)
  join public.categories c on c.profile_code = p_profile_code and c.name = x.category;

  -- ── the event plan: every card transaction, statements and alerts agree ────
  drop table if exists pg_temp.review_demo_ev;
  create temp table review_demo_ev (
    ev_id int generated always as identity primary key,
    bank text not null,
    last4 text not null,
    txn_date date not null,
    txn_time time not null,
    merchant text not null,
    city text not null default 'DUBAI',
    country text not null default 'AE',
    currency text not null default 'AED',
    amount numeric(14,2) not null,
    fx_rate numeric(18,8),
    amount_aed numeric(14,2) not null,
    direction text not null default 'debit',
    kind text not null default 'purchase'
  ) on commit drop;

  -- Six closed cycles per card before today: ADCB closes on the 25th, FAB on the 5th.
  drop table if exists pg_temp.review_demo_bank;
  create temp table review_demo_bank on commit drop as
  select x.bank, x.last4, x.close_day, x.due_days, x.opening, x.payment_desc, x.card_type, x.credit_limit,
         l.last_stmt, (l.last_stmt - interval '6 months')::date as first_prev
  from (values
    ('ADCB', '4821', 25, 18, 2940.15::numeric(14,2), 'PAYMENT RECEIVED - THANK YOU', 'VISA PLATINUM', 30000.00::numeric(14,2)),
    ('FAB', '7310', 5, 20, 1615.80::numeric(14,2), 'CREDIT CARD PAYMENT VIA MOBILE BANKING', 'MASTERCARD WORLD', 45000.00::numeric(14,2))
  ) as x(bank, last4, close_day, due_days, opening, payment_desc, card_type, credit_limit)
  cross join lateral (
    select case when extract(day from p_today)::int > x.close_day
                then make_date(extract(year from p_today)::int, extract(month from p_today)::int, x.close_day)
                else (make_date(extract(year from p_today)::int, extract(month from p_today)::int, x.close_day)
                      - interval '1 month')::date end as last_stmt
  ) l;

  -- everyday habits: probability per day, amount range, hour range
  insert into review_demo_ev (bank, last4, txn_date, txn_time, merchant, amount, amount_aed)
  select h.bank, bk.last4, d.day,
         make_time(h.h_lo + floor((h.h_hi - h.h_lo + 1) * private.review_demo_rnd(h.merchant || '|h|' || d.key))::int,
                   floor(60 * private.review_demo_rnd(h.merchant || '|m|' || d.key))::int, 0),
         h.merchant, a.amt, a.amt
  from (values
    ('DUNE COFFEE ROASTERS', 'ADCB', 0.33, 16.00, 34.00, 7, 10),
    ('CAFE MARINA',          'FAB',  0.10, 28.00, 85.00, 10, 17),
    ('SAFFRON KITCHEN',      'ADCB', 0.08, 85.00, 260.00, 19, 22),
    ('NOMAD FOOD HALL',      'ADCB', 0.07, 38.00, 95.00, 12, 14),
    ('GREENLEAF MARKET',     'ADCB', 0.12, 60.00, 340.00, 10, 21),
    ('OASIS FRESH MART',     'FAB',  0.10, 25.00, 180.00, 9, 22),
    ('CITYRIDE TAXI',        'ADCB', 0.15, 18.00, 75.00, 8, 22),
    ('DESERTLINE FUEL',      'FAB',  0.07, 95.00, 160.00, 7, 20),
    ('ATLAS HOME STORE',     'FAB',  0.02, 80.00, 650.00, 11, 21),
    ('NORTHWIND APPAREL',    'ADCB', 0.025, 120.00, 520.00, 12, 22),
    ('KITE LAUNDRY',         'FAB',  0.04, 35.00, 90.00, 9, 19),
    ('GOLDLEAF PHARMACY',    'FAB',  0.03, 25.00, 140.00, 9, 21),
    ('STARLIGHT CINEMA',     'ADCB', 0.02, 45.00, 120.00, 18, 22)
  ) as h(merchant, bank, p, lo, hi, h_lo, h_hi)
  join review_demo_bank bk on bk.bank = h.bank
  cross join lateral (
    select g::date as day, to_char(g::date, 'YYYY-MM-DD') as key
    from generate_series(bk.first_prev + 1, p_today - 1, interval '1 day') g
  ) d
  cross join lateral (select round(h.lo + (h.hi - h.lo) * private.review_demo_rnd(h.merchant || '|a|' || d.key), 2) as amt) a
  where private.review_demo_rnd(h.merchant || '|p|' || d.key) < h.p;

  -- monthly bills and subscriptions: steady day, steady amount (utilities vary)
  insert into review_demo_ev (bank, last4, txn_date, txn_time, merchant, city, country, currency, amount, fx_rate, amount_aed)
  select sub.bank, bk.last4, x.day, sub.at, sub.merchant, sub.city, sub.country, sub.cur, x.amt, sub.fx, round(x.amt * coalesce(sub.fx, 1), 2)
  from (values
    ('STREAMFLIX.COM',          'FAB',   3, time '03:10', 'INTERNET', 'AE', 'AED', null::numeric, 39.00),
    ('CLOUDBOX STORAGE',        'FAB',   2, time '02:45', 'INTERNET', 'AE', 'AED', null, 11.00),
    ('TUNEWAVE MUSIC',          'ADCB', 14, time '06:00', 'INTERNET', 'AE', 'AED', null, 21.99),
    ('SKYLINK TELECOM',         'ADCB', 12, time '09:00', 'DUBAI', 'AE', 'AED', null, 299.00),
    ('METRO UTILITIES BILLPAY', 'ADCB',  8, time '20:15', 'DUBAI', 'AE', 'AED', null, 0.00)
  ) as sub(merchant, bank, dom, at, city, country, cur, fx, base)
  join review_demo_bank bk on bk.bank = sub.bank
  cross join generate_series(date_trunc('month', bk.first_prev)::date, p_today, interval '1 month') m
  cross join lateral (
    select make_date(extract(year from m)::int, extract(month from m)::int, sub.dom) as day,
           case when sub.merchant = 'METRO UTILITIES BILLPAY'
                then round(380 + 240 * private.review_demo_rnd('util|' || to_char(m, 'YYYY-MM')), 2)
                else sub.base end as amt
  ) x
  where x.day > bk.first_prev and x.day < p_today;

  -- one-offs: a laptop, a trip abroad (EUR, with ADCB's FX), a refund
  insert into review_demo_ev (bank, last4, txn_date, txn_time, merchant, city, country, currency, amount, fx_rate,
                              amount_aed, direction, kind)
  select e.bank, bk.last4, p_today - e.ago, e.t, e.merchant, e.city, e.country, e.cur, e.amt, e.fx,
         round(e.amt * coalesce(e.fx, 1), 2), e.dir, e.kind
  from (values
    ('ADCB', 75, time '18:25', 'VOLTA ELECTRONICS', 'DUBAI', 'AE', 'AED', 4800.00, null::numeric, 'debit', 'purchase'),
    ('ADCB', 50, time '22:05', 'SKYWARD AIRWAYS', 'DUBAI', 'AE', 'AED', 3240.00, null, 'debit', 'purchase'),
    ('ADCB', 40, time '13:05', 'TAXI LISBOA', 'LISBOA', 'PT', 'EUR', 18.60, 4.3125, 'debit', 'purchase'),
    ('ADCB', 40, time '15:20', 'CASA ALFAMA HOTEL', 'LISBOA', 'PT', 'EUR', 640.00, 4.3125, 'debit', 'purchase'),
    ('ADCB', 39, time '20:40', 'RESTAURANTE MIRADOURO', 'LISBOA', 'PT', 'EUR', 86.40, 4.3098, 'debit', 'purchase'),
    ('ADCB', 38, time '21:10', 'TASCA DO BAIRRO', 'LISBOA', 'PT', 'EUR', 54.20, 4.3150, 'debit', 'purchase'),
    ('FAB',  60, time '15:35', 'ATLAS HOME STORE', 'DUBAI', 'AE', 'AED', 145.00, null, 'credit', 'refund')
  ) as e(bank, ago, t, merchant, city, country, cur, amt, fx, dir, kind)
  join review_demo_bank bk on bk.bank = e.bank
  where p_today - e.ago > bk.first_prev;

  -- ── statements: six per card, each paying the previous one before its due date ──
  drop table if exists pg_temp.review_demo_stm;
  create temp table review_demo_stm (
    bank text, last4 text, stmt_date date, period_start date, due_date date, opening numeric(14,2),
    debits numeric(14,2), credits numeric(14,2), closing numeric(14,2), min_due numeric(14,2),
    credit_limit numeric(14,2), card_type text
  ) on commit drop;

  for b in select * from review_demo_bank loop
    v_prev := b.first_prev;
    v_open := b.opening;
    for i in 1..6 loop
      v_date := (b.first_prev + make_interval(months => i))::date;
      insert into review_demo_ev (bank, last4, txn_date, txn_time, merchant, city, amount, amount_aed, direction, kind)
      values (b.bank, b.last4, v_prev + b.due_days - 1, time '10:00', b.payment_desc, '', v_open, v_open, 'credit', 'payment');

      select coalesce(sum(amount_aed) filter (where direction = 'debit'), 0),
             coalesce(sum(amount_aed) filter (where direction = 'credit'), 0)
      into v_deb, v_cred
      from review_demo_ev where bank = b.bank and txn_date between v_prev + 1 and v_date;
      v_close := v_open + v_deb - v_cred;

      insert into review_demo_stm values (
        b.bank, b.last4, v_date, v_prev + 1, v_date + b.due_days, v_open, v_deb, v_cred, v_close,
        greatest(round(v_close * 0.05, 2), least(v_close, 100.00)), b.credit_limit, b.card_type);
      v_prev := v_date;
      v_open := v_close;
    end loop;
  end loop;

  -- ── SMS alerts in the formats the production ADCB / FAB templates parse ────
  -- Billed periods get ~40% of purchases (sent before the statements, so they
  -- match); everything after each card's last statement stays pending.
  drop table if exists pg_temp.review_demo_sms;
  create temp table review_demo_sms on commit drop as
  select e.ev_id,
         e.txn_date > bk.last_stmt as pending,
         (e.txn_date + e.txn_time) at time zone 'Asia/Dubai'
           + make_interval(secs => 4 + floor(40 * private.review_demo_rnd('rcv|' || e.ev_id))::int) as received_at,
         md5(p_profile_code || '|review-demo-sms|' || e.ev_id)::uuid as client_msg_id,
         case e.bank when 'ADCB' then 'ADCBAlert' else 'FAB' end as sender,
         case e.bank
           when 'ADCB' then format('Your Cr.Card XXX%s was used for %s%s on %s %s at %s,%s-%s. Avl. Cr.limit is AED%s',
                                   e.last4, e.currency, e.amount, to_char(e.txn_date, 'DD/MM/YYYY'),
                                   to_char(e.txn_time, 'HH24:MI:SS'), e.merchant, e.city, e.country, f.avail)
           else format(E'Credit Card Purchase\nCard No XXXX%s\n%s %s\n%s %s %s\n%s %s\nAvl Bal AED %s',
                       e.last4, e.currency, e.amount, e.merchant, e.city, e.country,
                       to_char(e.txn_date, 'DD/MM/YY'), to_char(e.txn_time, 'HH24:MI'), f.avail)
         end as body
  from review_demo_ev e
  join review_demo_bank bk on bk.bank = e.bank
  cross join lateral (
    select (bk.credit_limit - 1800 - round(9000 * private.review_demo_rnd('avail|' || e.ev_id), 2))::text as avail
  ) f
  where e.kind = 'purchase'
    and (e.txn_date > bk.last_stmt
         or private.review_demo_rnd('sms|' || e.ev_id) < 0.4);

  for r in select * from review_demo_sms where not pending order by received_at, ev_id loop
    perform public.ingest_sms(p_profile_code, jsonb_build_array(jsonb_build_object(
      'client_msg_id', r.client_msg_id, 'received_at', r.received_at, 'sender', r.sender, 'body', r.body)));
  end loop;

  -- ── statements through the real ingest path ────────────────────────────────
  for s in select * from review_demo_stm order by stmt_date, bank loop
    v_doc := public.gen_code('doc');
    insert into public.documents (doc_code, profile_code, bank_code, storage_path, original_filename, sha256,
                                  size_bytes, source, parse_attempts, created_at)
    values (v_doc, p_profile_code, s.bank, p_profile_code || '/' || v_doc || '.pdf',
            s.bank || '_' || to_char(s.stmt_date, 'YYYY-MM') || '.pdf',
            encode(sha256(convert_to(p_profile_code || '|review-demo|' || s.bank || s.stmt_date, 'UTF8')), 'hex'),
            140000 + floor(90000 * private.review_demo_rnd('size|' || s.bank || s.stmt_date))::int,
            'upload', 1, (s.stmt_date + 1 + time '07:30') at time zone 'Asia/Dubai');
    perform pgmq.delete('parse_document', q.msg_id)
    from pgmq.q_parse_document q where q.message->>'doc_code' = v_doc;

    select jsonb_agg(jsonb_build_object(
             'line_no', l.rn,
             'txn_date', l.txn_date,
             'txn_time', null,
             'posting_date', case when l.kind in ('payment', 'fee', 'interest') then l.txn_date
                                  else least(l.txn_date + 1, s.stmt_date) end,
             'description_raw', trim(l.merchant || ' ' || l.city || case when l.city = '' then '' else ' ' || l.country end),
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
          from review_demo_ev e where e.bank = s.bank and e.txn_date between s.period_start and s.stmt_date) l;

    perform public.ingest_parsed_document(v_doc, jsonb_build_object(
      'contract_version', 1,
      'parser_version', 'review-demo',
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
          'total_debits', s.debits::text,
          'total_credits', s.credits::text,
          'min_due', s.min_due::text,
          'credit_limit', s.credit_limit::text),
        'warnings', '[]'::jsonb,
        'metadata', '{}'::jsonb,
        'lines', coalesce(v_lines, '[]'::jsonb)))));
  end loop;

  for r in select * from review_demo_sms where pending order by received_at, ev_id loop
    perform public.ingest_sms(p_profile_code, jsonb_build_array(jsonb_build_object(
      'client_msg_id', r.client_msg_id, 'received_at', r.received_at, 'sender', r.sender, 'body', r.body)));
  end loop;

  -- ── budgets, recurring series, insights ───────────────────────────────────
  v_start := date_trunc('month', (select min(first_prev) from review_demo_bank))::date;
  insert into public.budgets (profile_code, category_code, amount_aed, effective_from)
  select p_profile_code, c.category_code, x.amount, v_start
  from (values (null::text, 6500.00), ('Dining', 1200.00), ('Grocery', 1400.00), ('Shopping', 1000.00)) as x(category, amount)
  left join public.categories c on c.profile_code = p_profile_code and c.name = x.category
  where x.category is null or c.category_code is not null;

  perform private.detect_recurring(p_profile_code);
  perform private.generate_insights(p_profile_code);
end;
$$;

-- Creates the App Review ledger for an existing auth user (made with a password
-- through the Auth admin API). Refuses to run twice: the reviewer's own edits are
-- part of what they review.
create or replace function private.create_review_demo(p_user_id uuid, p_today date default null)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_code text;
begin
  perform private.assert_service_role();
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'no auth user %', p_user_id using errcode = '22023';
  end if;
  if exists (select 1 from public.profile_members m where m.user_id = p_user_id) then
    raise exception 'user % already belongs to a ledger; the review account must see only the demo', p_user_id
      using errcode = '22023';
  end if;
  if exists (select 1 from public.profiles p where p.key = 'app-review') then
    raise exception 'the app-review ledger already exists' using errcode = '23505';
  end if;

  insert into public.profiles (key, name) values ('app-review', 'Demo ledger') returning profile_code into v_code;
  insert into public.profile_members (profile_code, user_id, role) values (v_code, p_user_id, 'owner');
  insert into public.profile_state (profile_code) values (v_code);
  perform private.seed_profile_defaults(v_code);
  perform private.seed_review_demo(v_code, coalesce(p_today, public.dubai_date(now())));
  return v_code;
end;
$$;

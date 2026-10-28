-- Credit-linked notes (tasks/todo.md §15): a second kind of structured note. A CLN pays a fixed
-- coupon (monthly … yearly, or all of it at maturity) and returns 100% at maturity unless its
-- reference entity has a credit event; there are no underlying shares, barriers or autocalls.
--
-- • structured_notes.note_type: 'equity' (every note so far) or 'credit_linked'. A CLN has no
--   strike or final valuation date; statuses add 'called' (the issuer's call) and 'credit_event'.
-- • structured_note_credit_terms: the reference entity, coupon rate p.a., frequency, day count,
--   interest start, first coupon date, longstop maturity and the issuer's call dates. The coupon
--   schedule is generated from them (private.cln_schedule), never stored.
-- • private.cln_evaluate answers what private.note_evaluate answers for an equity note (received,
--   next, events for the settlement) plus `credit`: the schedule, interest accrued, remaining
--   coupons, held to maturity, if called next, and what a credit event would cost.
--   private.note_evaluate dispatches on the type; the equity evaluator is unchanged (renamed).
-- • note_verdict: cln_paying (coupons on a schedule) and cln_accruing (interest paid at maturity).
-- • create_structured_note takes terms.note_type = 'credit_linked' with a `credit` block
--   (docs/contracts/termsheet-v1.md); equity drafts are unchanged.

-- ── 1. schema ──────────────────────────────────────────────────────────────
alter table public.structured_notes
  add column note_type text not null default 'equity' check (note_type in ('equity', 'credit_linked')),
  alter column strike_date drop not null,
  alter column final_valuation_date drop not null,
  drop constraint structured_notes_dates_check,
  drop constraint structured_notes_status_check;
alter table public.structured_notes
  add constraint structured_notes_status_check
    check (status in ('live', 'autocalled', 'called', 'matured', 'credit_event', 'cancelled')),
  add constraint structured_notes_dates_check check (
    (note_type = 'credit_linked' or (strike_date is not null and final_valuation_date is not null))
    and (strike_date is null or final_valuation_date is null or strike_date <= final_valuation_date)
    and (final_valuation_date is null or final_valuation_date <= maturity_date)
    and (issue_date is null or strike_date is null or issue_date >= strike_date)
    and (issue_date is null or issue_date <= maturity_date));
comment on column public.structured_notes.note_type is
  'equity: a worst-of note on shares (underlyings, observations, payout branches). credit_linked: a fixed coupon on a reference entity''s credit (structured_note_credit_terms).';

alter table public.structured_note_events
  alter column worst_pct drop not null,
  alter column worst_symbol drop not null,
  drop constraint structured_note_events_kind_check;
alter table public.structured_note_events
  add constraint structured_note_events_kind_check
    check (kind in ('coupon', 'autocall', 'call', 'maturity', 'credit_event'));

create table public.structured_note_credit_terms (
  credit_terms_code text primary key default public.gen_code('snc')
    check (credit_terms_code ~ '^snc_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  note_code text not null unique,
  reference_entity text not null check (length(btrim(reference_entity)) between 1 and 160),
  seniority text check (length(seniority) <= 60),
  transaction_type text check (length(transaction_type) <= 80),
  reference_obligation_isin text check (reference_obligation_isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'),
  coupon_rate_pct numeric(9,5) not null check (coupon_rate_pct > 0 and coupon_rate_pct < 100),   -- per annum
  coupon_frequency text not null
    check (coupon_frequency in ('monthly', 'quarterly', 'semiannual', 'annual', 'at_maturity')),
  day_count text not null default '30/360' check (day_count in ('30/360', 'act/360', 'act/365')),
  interest_start_date date not null,          -- interest commencement (usually the issue date)
  first_coupon_date date,                     -- null when every coupon is paid at maturity
  longstop_maturity_date date,                -- the latest maturity if a credit event is pending
  call_dates date[] not null default '{}',    -- the issuer may redeem at 100% + accrued on these
  call_notice_days int check (call_notice_days between 0 and 365),
  constraint structured_note_credit_terms_note_fkey foreign key (profile_code, note_code)
    references public.structured_notes(profile_code, note_code) on delete cascade,
  constraint structured_note_credit_terms_shape_check check (
    (coupon_frequency = 'at_maturity') = (first_coupon_date is null)
    and (first_coupon_date is null or first_coupon_date > interest_start_date))
);
comment on table public.structured_note_credit_terms is
  'A credit-linked note''s terms: the reference entity, a fixed coupon p.a. on a schedule (or paid at maturity), the day count and the issuer''s call dates. One per note of type credit_linked.';
alter table public.structured_note_credit_terms enable row level security;
create policy structured_note_credit_terms_member_read on public.structured_note_credit_terms for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.structured_note_credit_terms to authenticated;
grant all on public.structured_note_credit_terms to service_role;
create index structured_note_credit_terms_profile_code_idx on public.structured_note_credit_terms(profile_code);

-- ── 2. the coupon schedule ─────────────────────────────────────────────────
-- The year fraction between two dates: 30/360 (ISDA bond basis), act/360 or act/365.
create function private.year_fraction(p_day_count text, p_from date, p_to date)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case p_day_count
    when 'act/360' then (p_to - p_from)::numeric / 360
    when 'act/365' then (p_to - p_from)::numeric / 365
    else (360 * (extract(year from p_to) - extract(year from p_from))
          + 30 * (extract(month from p_to) - extract(month from p_from))
          + (case when extract(day from p_to) = 31 and extract(day from p_from) >= 30 then 30 else extract(day from p_to) end)
          - least(extract(day from p_from), 30))::numeric / 360
  end
$$;

-- Every coupon of a credit-linked note: its period and what it pays (% of nominal). Coupons fall
-- on the first coupon date and every 1/3/6/12 months after it, the last on the maturity date; a
-- note paid at maturity has one coupon from the interest start to maturity.
create function private.cln_schedule(p_note_code text)
returns table (seq int, period_start date, pay_date date, rate_pct numeric, is_final boolean)
language sql
stable
set search_path = ''
as $$
  with t as (
    select n.maturity_date, c.interest_start_date, c.first_coupon_date, c.coupon_rate_pct, c.day_count,
           case c.coupon_frequency when 'monthly' then 1 when 'quarterly' then 3 when 'semiannual' then 6
                                   when 'annual' then 12 end as step
    from public.structured_notes n
    join public.structured_note_credit_terms c on c.note_code = n.note_code
    where n.note_code = p_note_code
  ), d as (
    select (t.first_coupon_date + make_interval(months => k * t.step))::date as pay_date
    from t cross join generate_series(0, 1200) k
    where t.step is not null and (t.first_coupon_date + make_interval(months => k * t.step))::date < t.maturity_date
    union
    select t.maturity_date from t
  )
  select row_number() over (order by d.pay_date)::int,
         lag(d.pay_date, 1, t.interest_start_date) over (order by d.pay_date),
         d.pay_date,
         round(t.coupon_rate_pct * private.year_fraction(t.day_count,
               lag(d.pay_date, 1, t.interest_start_date) over (order by d.pay_date), d.pay_date), 6),
         d.pay_date = t.maturity_date
  from d cross join t
  order by d.pay_date
$$;

-- ── 3. evaluating a credit-linked note ─────────────────────────────────────
-- Same top-level keys as the equity evaluator where they apply (status, received, due, result,
-- next, events), no shares or scenarios, plus `credit`. On an account a broker sync keeps, what
-- was received is what the broker paid (its coupon and redemption flows).
create function private.cln_evaluate(p_note_code text, p_as_of date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  n public.structured_notes;
  c public.structured_note_credit_terms;
  v_synced boolean;
  v_status text := 'live';
  v_ended date;
  v_schedule jsonb;
  v_events jsonb;
  v_paid numeric;
  v_remaining numeric;
  v_received numeric;
  v_redeemed numeric := 0;
  v_last date;
  v_accrued numeric := 0;
  v_next record;
  v_call date;
  v_call_total numeric;
  v_mat_total numeric;
  v_end date;
begin
  select * into n from public.structured_notes where note_code = p_note_code;
  select * into c from public.structured_note_credit_terms where note_code = p_note_code;
  if n.note_code is null or c.note_code is null then
    return null;
  end if;
  v_synced := n.funding_account_code is not null and n.isin is not null
              and private.is_broker_account(n.profile_code, n.funding_account_code);
  if n.status in ('called', 'matured', 'credit_event') then
    v_status := n.status;
    v_ended := n.ended_on;
  elsif p_as_of >= n.maturity_date then
    v_status := 'matured';
    v_ended := n.maturity_date;
  end if;
  v_end := coalesce(v_ended, 'infinity'::date);

  -- Each coupon: paid (on or before today, after the purchase), to come, before the purchase
  -- (the seller's), or not paid (after the note ended early).
  select jsonb_agg(jsonb_build_object(
           'seq', s.seq, 'period_start', s.period_start, 'pay_date', s.pay_date, 'rate_pct', s.rate_pct,
           'amount', round(n.nominal * s.rate_pct / 100, 2), 'is_final', s.is_final,
           'is_call_date', s.pay_date = any (c.call_dates),
           'status', case when s.pay_date <= n.trade_date then 'before_purchase'
                          when s.pay_date > v_end then 'not_paid'
                          when s.pay_date <= p_as_of then 'paid'
                          else 'to_come' end) order by s.pay_date),
         coalesce(sum(round(n.nominal * s.rate_pct / 100, 2))
                    filter (where s.pay_date > n.trade_date and s.pay_date <= least(p_as_of, v_end)), 0),
         coalesce(sum(round(n.nominal * s.rate_pct / 100, 2))
                    filter (where s.pay_date > p_as_of and s.pay_date <= v_end), 0),
         max(s.pay_date) filter (where s.pay_date <= p_as_of)
    into v_schedule, v_paid, v_remaining, v_last
  from private.cln_schedule(n.note_code) s;

  if v_synced then
    select coalesce(sum(hf.amount) filter (where hf.kind = 'income'), 0),
           coalesce(sum(hf.amount) filter (where hf.kind = 'withdrawal'), 0)
      into v_received, v_redeemed
    from public.holding_flows hf where hf.holding_code = n.holding_code and hf.removed_at is null;
  else
    v_received := v_paid;
    if v_status = 'matured' then
      v_redeemed := n.nominal;
    end if;
  end if;

  -- Interest accrued and not yet paid: since the last coupon (or the interest start).
  if v_status = 'live' and p_as_of > c.interest_start_date then
    v_accrued := round(n.nominal * c.coupon_rate_pct / 100
                       * private.year_fraction(c.day_count, greatest(coalesce(v_last, c.interest_start_date),
                                                                     c.interest_start_date), p_as_of), 2);
  end if;

  select (x->>'seq')::int as seq, (x->>'pay_date')::date as pay_date, (x->>'rate_pct')::numeric as rate_pct,
         (x->>'amount')::numeric as amount, (x->>'is_final')::boolean as is_final
    into v_next
  from jsonb_array_elements(coalesce(v_schedule, '[]'::jsonb)) x
  where x->>'status' = 'to_come' order by (x->>'pay_date')::date limit 1;

  -- If called at the next call date: 100% plus the coupons up to it and the interest accrued since.
  select min(d) into v_call from unnest(c.call_dates) d where d > p_as_of and d < n.maturity_date;
  if v_status = 'live' and v_call is not null then
    select v_received + coalesce(sum((x->>'amount')::numeric) filter (where (x->>'pay_date')::date <= v_call
                                                                       and x->>'status' = 'to_come'), 0)
           + round(n.nominal * c.coupon_rate_pct / 100 * private.year_fraction(c.day_count,
               coalesce(max((x->>'pay_date')::date) filter (where (x->>'pay_date')::date <= v_call),
                        c.interest_start_date), v_call), 2)
           + n.nominal
      into v_call_total
    from jsonb_array_elements(coalesce(v_schedule, '[]'::jsonb)) x;
  end if;
  v_mat_total := v_received + v_remaining + n.nominal;

  -- What the settlement records: each coupon paid since the purchase, then the redemption.
  select coalesce(jsonb_agg(jsonb_build_object('kind', 'coupon', 'seq', (x->>'seq')::int, 'obs_date', x->>'pay_date',
                    'pay_date', x->>'pay_date', 'rate_pct', x->>'rate_pct', 'amount', x->>'amount', 'settlement', 'cash')
                  order by (x->>'pay_date')::date), '[]'::jsonb)
    into v_events
  from jsonb_array_elements(coalesce(v_schedule, '[]'::jsonb)) x
  where x->>'status' = 'paid';
  if v_status = 'matured' and v_ended <= p_as_of then
    v_events := v_events || jsonb_build_object('kind', 'maturity', 'obs_date', v_ended, 'pay_date', v_ended,
                                               'rate_pct', 100, 'amount', n.nominal, 'settlement', 'cash');
  end if;

  return private.jsonb_decimal_strings(jsonb_build_object(
    'as_of', p_as_of,
    'status', v_status,
    'awaiting_prices', false,
    'ended_on', v_ended,
    'currency', n.currency,
    'nominal', n.nominal::text,
    'invested', n.invested_amount::text,
    'received', jsonb_build_object('coupons', v_received::numeric(14,2)::text, 'redemption', v_redeemed::numeric(14,2)::text,
                                   'total', (v_received + v_redeemed)::numeric(14,2)::text),
    'due', jsonb_build_object('coupons', '0.00', 'redemption', '0.00', 'total', '0.00'),
    'result', case when v_status <> 'live' then jsonb_build_object(
      'total', (v_received + v_redeemed)::numeric(14,2)::text,
      'profit', (v_received + v_redeemed - n.invested_amount)::numeric(14,2)::text,
      'return_pct', round(((v_received + v_redeemed) / n.invested_amount - 1) * 100, 2)::text) end,
    'memory_unpaid_pct', '0',
    'break_even_pct', null,
    'worst_now', null,
    'underlyings', '[]'::jsonb,
    'levels', null,
    -- The next coupon (unconditional: barrier 0), or for a note paid at maturity, the payment then.
    'next', case when v_status = 'live' and v_next.pay_date is not null then jsonb_build_object(
      'kind', case when v_next.is_final then 'final' else 'coupon' end, 'seq', v_next.seq,
      'obs_date', v_next.pay_date, 'pay_date', v_next.pay_date, 'days', v_next.pay_date - p_as_of,
      'is_final', v_next.is_final,
      'coupon', jsonb_build_object('rate_pct', v_next.rate_pct::text, 'barrier_pct', '0',
                                   'amount', v_next.amount::text, 'would_pay', true)) end,
    'if_ended_today', null,
    'scenarios', null,
    'events', v_events,
    'credit', jsonb_build_object(
      'reference_entity', c.reference_entity, 'seniority', c.seniority, 'transaction_type', c.transaction_type,
      'reference_obligation_isin', c.reference_obligation_isin,
      'coupon_rate_pct', c.coupon_rate_pct::text, 'coupon_frequency', c.coupon_frequency, 'day_count', c.day_count,
      'interest_at_maturity', c.coupon_frequency = 'at_maturity',
      'interest_start_date', c.interest_start_date, 'first_coupon_date', c.first_coupon_date,
      'maturity_date', n.maturity_date, 'longstop_maturity_date', c.longstop_maturity_date,
      'call_dates', to_jsonb(c.call_dates), 'call_notice_days', c.call_notice_days,
      'next_call_date', case when v_status = 'live' then v_call end,
      'accrued', jsonb_build_object('amount', v_accrued::numeric(14,2)::text,
                                    'since', greatest(coalesce(v_last, c.interest_start_date), c.interest_start_date)),
      'remaining_coupons', v_remaining::numeric(14,2)::text,
      'schedule', coalesce(v_schedule, '[]'::jsonb),
      'to_maturity', case when v_status = 'live' then jsonb_build_object(
        'date', n.maturity_date, 'coupons', (v_received + v_remaining)::numeric(14,2)::text,
        'total', v_mat_total::numeric(14,2)::text, 'profit', (v_mat_total - n.invested_amount)::numeric(14,2)::text,
        'return_pct', round((v_mat_total / n.invested_amount - 1) * 100, 2)::text,
        'annualised_pct', case when n.maturity_date > n.trade_date
          then round((power(v_mat_total / n.invested_amount, 365.0 / (n.maturity_date - n.trade_date)) - 1) * 100, 2)::text end) end,
      'if_called_next', case when v_call_total is not null then jsonb_build_object(
        'date', v_call, 'total', v_call_total::numeric(14,2)::text,
        'profit', (v_call_total - n.invested_amount)::numeric(14,2)::text,
        'return_pct', round((v_call_total / n.invested_amount - 1) * 100, 2)::text,
        'annualised_pct', case when v_call > n.trade_date
          then round((power(v_call_total / n.invested_amount, 365.0 / (v_call - n.trade_date)) - 1) * 100, 2)::text end) end,
      -- A credit event: interest stops from the last coupon date and the principal comes back at
      -- the market's recovery value, so all of it is at risk; what was received is kept.
      'credit_event', case when v_status = 'live' then jsonb_build_object(
        'principal_at_risk', n.nominal::text, 'interest_lost', v_remaining::numeric(14,2)::text,
        'accrued_lost', v_accrued::numeric(14,2)::text, 'kept', v_received::numeric(14,2)::text) end)));
end;
$$;
comment on function private.cln_evaluate(text, date) is
  'A credit-linked note as of a date: status, received, next coupon, events for the settlement, and `credit` (schedule, accrued interest, remaining coupons, held to maturity, if called next, credit-event risk).';

-- The equity evaluator keeps its body (20261027165732) under its own name; note_evaluate picks.
alter function private.note_evaluate(text, date) rename to note_evaluate_equity;
create function private.note_evaluate(p_note_code text, p_as_of date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when n.note_type = 'credit_linked' then private.cln_evaluate(n.note_code, p_as_of)
              else private.note_evaluate_equity(n.note_code, p_as_of) end
  from public.structured_notes n where n.note_code = p_note_code
$$;
comment on function private.note_evaluate(text, date) is
  'A note as of a date: the equity evaluator (note_evaluate_equity) or, for a credit-linked note, cln_evaluate.';

-- ── 4. readers ────────────────────────────────────────────────────────────
-- note_verdict (20261027200000): + cln_accruing (rate_pct, amount accrued, date = next call or
-- maturity) and cln_paying (rate_pct, amount and date of the next coupon); called and
-- credit_event have ended.

create or replace function private.note_verdict(e jsonb, p_status text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_status in ('autocalled', 'called', 'matured', 'credit_event', 'cancelled') then jsonb_build_object('kind', 'ended')
    -- A credit-linked note: interest building up to maturity, or coupons on a schedule.
    when jsonb_typeof(e->'credit') = 'object' and (e->'credit'->>'interest_at_maturity')::boolean
      then jsonb_build_object('kind', 'cln_accruing', 'rate_pct', e->'credit'->>'coupon_rate_pct',
                              'amount', e->'credit'->'accrued'->>'amount',
                              'date', coalesce(e->'credit'->>'next_call_date', e->'credit'->>'maturity_date'),
                              'call_date', e->'credit'->>'next_call_date',
                              'maturity_date', e->'credit'->>'maturity_date')
    when jsonb_typeof(e->'credit') = 'object'
      then jsonb_build_object('kind', 'cln_paying', 'rate_pct', e->'credit'->>'coupon_rate_pct',
                              'amount', e->'next'->'coupon'->>'amount', 'date', e->'next'->>'pay_date',
                              'maturity_date', e->'credit'->>'maturity_date')
    when coalesce((e->>'awaiting_prices')::boolean, false) or e->'worst_now' is null
      or jsonb_typeof(e->'worst_now') = 'null' then jsonb_build_object('kind', 'awaiting_prices')
    when ac.l is not null and (ac.l->>'distance_pct')::numeric <= 0
      then jsonb_build_object('kind', 'on_track', 'date', ac.l->>'date', 'symbol', e->'worst_now'->>'symbol',
                              'gap_pct', ac.l->>'distance_pct')
    when cp.l is not null and (cp.l->>'distance_pct')::numeric > 0
      then jsonb_build_object('kind', 'coupon_at_risk', 'symbol', e->'worst_now'->>'symbol',
                              'gap_pct', cp.l->>'distance_pct', 'date', cp.l->>'date',
                              'call_gap_pct', ac.l->>'distance_pct', 'call_date', ac.l->>'date')
    when ac.l is not null
      then jsonb_build_object('kind', 'needs', 'symbol', e->'worst_now'->>'symbol', 'gap_pct', ac.l->>'distance_pct',
                              'date', ac.l->>'date')
    else jsonb_build_object('kind', 'to_maturity', 'symbol', e->'worst_now'->>'symbol',
                            'date', coalesce(fin.d, e->'next'->>'obs_date'), 'gap_pct', be.l->>'distance_pct')
  end
  from (select (select l from jsonb_array_elements(coalesce(e->'levels', '[]'::jsonb)) l
                where l->>'kind' = 'autocall' limit 1)) ac(l)
  cross join (select (select l from jsonb_array_elements(coalesce(e->'levels', '[]'::jsonb)) l
                      where l->>'kind' = 'coupon' limit 1)) cp(l)
  cross join (select (select l from jsonb_array_elements(coalesce(e->'levels', '[]'::jsonb)) l
                      where l->>'kind' = 'break_even' limit 1)) be(l)
  cross join (select (select l->>'date' from jsonb_array_elements(coalesce(e->'levels', '[]'::jsonb)) l
                      where l->>'kind' in ('final', 'break_even') order by l->>'date' desc limit 1)) fin(d)
$$;

comment on function private.note_verdict(jsonb, text) is
  'A live note in one line from its evaluation: ended, awaiting_prices, on_track, coupon_at_risk, needs or to_maturity (equity), cln_paying or cln_accruing (credit-linked), with the share, gap, amount and date it is about.';

-- note_summary (20261027200000): + note_type and a credit-linked note's `credit` (without its
-- schedule); a note the broker called ended by the broker too.

create or replace function private.note_summary(n public.structured_notes, e jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'note_code', n.note_code, 'holding_code', n.holding_code, 'name', h.name, 'institution', h.institution,
    'product_name', n.product_name, 'isin', n.isin, 'issuer', n.issuer, 'currency', n.currency,
    'status', case when n.status = 'cancelled' then 'cancelled' when b.by_broker then n.status else e->>'status' end,
    'awaiting_prices', case when b.by_broker then false else (e->>'awaiting_prices')::boolean end,
    'trade_date', n.trade_date, 'maturity_date', n.maturity_date, 'ended_on', coalesce(n.ended_on, (e->>'ended_on')::date),
    'invested', n.invested_amount::text, 'nominal', n.nominal::text, 'purchase_price_pct', n.purchase_price_pct::text,
    'funding_account_code', n.funding_account_code,
    'received', e->'received', 'due', e->'due',
    -- Ended by the broker before its closes could tell (a synced note): the result is what the
    -- broker paid back and paid out (20261027165732).
    'result', case when b.by_broker then jsonb_build_object(
                     'total', (f.returned + f.income)::numeric(14,2)::text,
                     'profit', (f.returned + f.income - n.invested_amount)::numeric(14,2)::text,
                     'return_pct', round((f.returned + f.income) / n.invested_amount * 100 - 100, 2)::text)
                   else e->'result' end,
    'worst_now', e->'worst_now', 'break_even_pct', e->>'break_even_pct',
    'next', case when not b.by_broker then e->'next' end,
    'if_ended_today', case when not b.by_broker then e->'if_ended_today' end,
    -- What it fetches sold today (the broker's bid on the latest mark) and what it pays if called
    -- at its next autocall date (20261027165732).
    'market', (select jsonb_build_object('price_pct', case when bp.price_in_pct then bp.price::numeric(12,4)::text end,
                                         'value', bp.market_value::text, 'as_of', bp.as_of,
                                         'profit', (bp.market_value + coalesce((e->'received'->>'coupons')::numeric, 0)
                                                    - n.invested_amount)::numeric(14,2)::text)
               from public.broker_positions bp
               where bp.holding_code = n.holding_code and bp.market_value is not null and n.status = 'live'
               order by bp.as_of desc limit 1),
    'if_called_next', case when not b.by_broker then e->'scenarios'->'autocall'->0 end,
    'verdict', private.note_verdict(e, case when n.status = 'cancelled' or b.by_broker then n.status else e->>'status' end),
    'symbols', (select jsonb_agg(u.symbol order by u.ordinal) from public.structured_note_underlyings u
                where u.note_code = n.note_code),
    'note_type', n.note_type,
    -- A credit-linked note's headline terms and outlook (the schedule is in the detail).
    'credit', case when n.note_type = 'credit_linked' then (e->'credit') - 'schedule' end)
  from public.holdings h
  cross join lateral (
    select n.status in ('autocalled', 'called', 'matured') and coalesce(e->>'status', '') not in ('autocalled', 'called', 'matured') as by_broker
  ) b
  cross join lateral (
    select coalesce(sum(hf.amount) filter (where hf.kind = 'withdrawal'), 0) as returned,
           coalesce(sum(hf.amount) filter (where hf.kind = 'income'), 0) as income
    from public.holding_flows hf where hf.holding_code = n.holding_code and hf.removed_at is null
  ) f
  where h.holding_code = n.holding_code
$$;

-- structured_note_detail (20261027165732): + terms.note_type and `credit` (with the schedule).

create or replace function public.structured_note_detail(p_profile_code text, p_holding_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  n public.structured_notes;
  e jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  select * into n from public.structured_notes where holding_code = p_holding_code and profile_code = p_profile_code;
  if not found then
    raise exception 'note not found' using errcode = 'P0002';
  end if;
  e := private.note_evaluate(n.note_code, public.dubai_date(now()));
  -- Ended by the broker before its closes could tell (20261027165732): no live figures.
  if n.status in ('autocalled', 'called', 'matured') and coalesce(e->>'status', '') not in ('autocalled', 'called', 'matured') then
    e := e - 'levels' - 'scenarios' - 'next' - 'if_ended_today';
  end if;
  return private.jsonb_decimal_strings(private.note_summary(n, e) || jsonb_build_object(
    'terms', jsonb_build_object(
      'guarantor', n.guarantor, 'denomination', n.denomination::text, 'issue_price_pct', n.issue_price_pct::text,
      'strike_date', n.strike_date, 'issue_date', n.issue_date, 'final_valuation_date', n.final_valuation_date,
      'maturity_date', n.maturity_date, 'termsheet_path', n.termsheet_path, 'termsheet_filename', n.termsheet_filename,
      'note_type', n.note_type),
    'observations', coalesce((
      select jsonb_agg(jsonb_build_object('seq', o.seq, 'obs_date', o.obs_date, 'pay_date', o.pay_date,
               'coupon_rate_pct', o.coupon_rate_pct::text, 'coupon_barrier_pct', o.coupon_barrier_pct::text,
               'coupon_memory', o.coupon_memory, 'autocall_trigger_pct', o.autocall_trigger_pct::text,
               'autocall_amount_pct', o.autocall_amount_pct::text) order by o.obs_date)
      from public.structured_note_observations o where o.note_code = n.note_code), '[]'::jsonb),
    'payout', coalesce((
      select jsonb_agg(jsonb_build_object('min_worst_pct', b.min_worst_pct::text, 'intercept_pct', b.intercept_pct::text,
               'slope', b.slope::text, 'settlement', b.settlement) order by b.min_worst_pct desc)
      from public.structured_note_payout_branches b where b.note_code = n.note_code), '[]'::jsonb),
    'memory_unpaid_pct', e->>'memory_unpaid_pct',
    'underlyings', e->'underlyings', 'levels', e->'levels', 'scenarios', e->'scenarios', 'outcomes', e->'events',
    'credit', e->'credit',
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('event_code', x.event_code, 'kind', x.kind, 'obs_date', x.obs_date,
               'pay_date', x.pay_date, 'rate_pct', x.rate_pct::text, 'amount', x.amount::text, 'settlement', x.settlement,
               'shares', x.shares::text, 'share_symbol', case when x.shares is not null then x.worst_symbol end,
               'txn_code', x.txn_code, 'delivered_holding_code', x.delivered_holding_code, 'settled', x.settled_at is not null)
             order by x.pay_date desc)
      from public.structured_note_events x where x.note_code = n.note_code), '[]'::jsonb),
    'series', coalesce((
      select jsonb_object_agg(s.symbol, s.points)
      from (
        select u.symbol, jsonb_agg(jsonb_build_array(sp.price_date, round(sp.close / u.initial_level * 100, 2)::text)
                                   order by sp.price_date) as points
        from public.structured_note_underlyings u
        join public.security_prices sp on sp.symbol = u.symbol and sp.price_date >= coalesce(n.strike_date, n.trade_date)
             and sp.price_date <= coalesce(n.ended_on, public.dubai_date(now()))
        where u.note_code = n.note_code
        group by u.symbol
      ) s), '{}'::jsonb)));
end;
$$;

-- ── 5. writers ────────────────────────────────────────────────────────────
-- create_structured_note (20261027165732): + terms.note_type = 'credit_linked' with `credit`
-- {reference_entity, seniority, transaction_type, reference_obligation_isin, coupon_rate_pct (p.a.),
--  coupon_frequency, day_count, interest_start_date, first_coupon_date, longstop_maturity_date,
--  call_dates, call_notice_days} instead of underlyings, observations and payout.

create or replace function public.create_structured_note(p_profile_code text, p_draft jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  t jsonb := p_draft->'terms';
  i jsonb := p_draft->'investment';
  a public.accounts;
  v_holding text;
  v_note text;
  v_name text := btrim(coalesce(p_draft->>'name', ''));
  v_currency text := upper(coalesce(t->>'currency', ''));
  v_denom numeric := (t->>'denomination')::numeric;
  v_issue numeric := (t->>'issue_price_pct')::numeric;
  v_strike date := (t->>'strike_date')::date;
  v_final date := (t->>'final_valuation_date')::date;
  v_maturity date := (t->>'maturity_date')::date;
  v_price numeric := coalesce(nullif(i->>'purchase_price_pct', '')::numeric, v_issue);
  v_invested numeric := nullif(i->>'invested_amount', '')::numeric;
  v_nominal numeric;
  v_trade date := coalesce(nullif(i->>'trade_date', '')::date, nullif(t->>'issue_date', '')::date, v_strike);
  v_account text := nullif(i->>'funding_account_code', '');
  v_txn text;
  v_bad int;
  v_isin text := nullif(upper(btrim(t->>'isin')), '');
  v_synced boolean;
  v_buy_amount numeric;
  v_buy_date date;
  v_buy_qty numeric;
  v_buy_price numeric;
  v_type text := coalesce(nullif(t->>'note_type', ''), 'equity');
  cr jsonb := t->'credit';
  v_rate numeric;
  v_freq text;
  v_start date;
  v_first date;
begin
  perform private.assert_member(p_profile_code, true);
  if length(v_name) not between 1 and 80 then
    raise exception 'a note needs a name of 1–80 characters' using errcode = '22023';
  end if;
  if v_type not in ('equity', 'credit_linked') then
    raise exception 'a note is equity or credit_linked' using errcode = '22023';
  end if;
  if v_currency !~ '^[A-Z]{3}$' or v_denom is null or v_denom <= 0 or v_issue is null or v_issue <= 0
     or v_maturity is null or (v_type = 'equity' and (v_strike is null or v_final is null)) then
    raise exception 'terms need currency, denomination, issue price, strike, final valuation and maturity dates'
      using errcode = '22023';
  end if;
  -- A credit-linked note: a reference entity and a fixed coupon on a schedule (or at maturity).
  if v_type = 'credit_linked' then
    v_rate := nullif(cr->>'coupon_rate_pct', '')::numeric;
    v_freq := cr->>'coupon_frequency';
    v_start := coalesce(nullif(cr->>'interest_start_date', '')::date, nullif(t->>'issue_date', '')::date);
    v_first := nullif(cr->>'first_coupon_date', '')::date;
    if length(btrim(coalesce(cr->>'reference_entity', ''))) = 0 or v_rate is null or v_rate <= 0 or v_rate >= 100
       or v_freq is null or v_start is null then
      raise exception 'a credit-linked note needs a reference entity, a coupon rate, its frequency and the interest start'
        using errcode = '22023';
    end if;
    if v_freq not in ('monthly', 'quarterly', 'semiannual', 'annual', 'at_maturity')
       or (v_freq = 'at_maturity') <> (v_first is null) or v_start >= v_maturity
       or (v_first is not null and (v_first <= v_start or v_first > v_maturity)) then
      raise exception 'the coupon schedule does not fit: frequency %, interest from %, first coupon %, maturity %',
        v_freq, v_start, v_first, v_maturity using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements_text(coalesce(cr->'call_dates', '[]')) d
               where d::date <= v_start or d::date >= v_maturity) then
      raise exception 'every call date falls between the interest start and maturity' using errcode = '22023';
    end if;
    v_strike := null;
    v_final := null;
  end if;
  -- Bought on an account a broker sync keeps: what was bought, when and at what price default to
  -- the broker's own buy rows for the ISIN (20261027165732).
  v_synced := v_account is not null and v_isin is not null and private.is_broker_account(p_profile_code, v_account);
  if v_synced then
    select sum(-bt.net_amount), min(public.dubai_date(bt.booked_at)), sum(bt.quantity),
           (array_agg(bt.unit_price order by bt.booked_at))[1]
      into v_buy_amount, v_buy_date, v_buy_qty, v_buy_price
    from public.broker_transactions bt
    where bt.account_code = v_account and bt.isin = v_isin and bt.kind = 'buy' and not bt.is_reversal;
    v_invested := coalesce(v_invested, v_buy_amount);
    if nullif(i->>'trade_date', '') is null and v_buy_date is not null then
      v_trade := v_buy_date;
    end if;
    if nullif(i->>'purchase_price_pct', '') is null and v_buy_price is not null then
      v_price := round(v_buy_price * 100, 5);
    end if;
    if nullif(i->>'nominal', '') is null and v_buy_qty is not null then
      i := i || jsonb_build_object('nominal', v_buy_qty::text);
    end if;
  end if;
  if v_invested is null or v_invested <= 0 or v_invested <> round(v_invested, 2) or v_price <= 0 then
    raise exception 'the amount invested must be positive with at most 2 decimals' using errcode = '22023';
  end if;
  v_nominal := coalesce(nullif(i->>'nominal', '')::numeric, round(v_invested / v_price * 100, 2));
  if v_nominal <= 0 then
    raise exception 'nominal must be positive' using errcode = '22023';
  end if;
  if v_type = 'equity' and jsonb_array_length(coalesce(t->'underlyings', '[]')) not between 1 and 20 then
    raise exception 'a note has 1–20 underlyings' using errcode = '22023';
  end if;
  if v_type = 'equity' and (jsonb_array_length(coalesce(t->'payout', '[]')) = 0
     or not exists (select 1 from jsonb_array_elements(t->'payout') b where (b->>'min_worst_pct')::numeric = 0)) then
    raise exception 'the final payout needs a branch from 0%% (what is paid however far the worst share falls)'
      using errcode = '22023';
  end if;
  select count(*) into v_bad from jsonb_array_elements(coalesce(t->'observations', '[]')) o
  where v_type = 'equity' and ((o->>'obs_date')::date > v_final or (o->>'obs_date')::date < v_strike);
  if v_bad > 0 then
    raise exception 'every observation falls between the strike date and the final valuation' using errcode = '22023';
  end if;
  if v_account is not null then
    select * into a from public.accounts
    where account_code = v_account and profile_code = p_profile_code and kind in ('current', 'savings') and status = 'active';
    if not found then
      raise exception 'funding account not found' using errcode = 'P0002';
    end if;
    if a.currency <> v_currency then
      raise exception 'the funding account is in %, the note in %', a.currency, v_currency using errcode = '22023';
    end if;
  end if;

  -- A position the sync already holds (its ISIN) becomes the note's holding, keeping its flows
  -- and market values.
  if v_synced then
    select h.holding_code into v_holding from public.holdings h
    where h.profile_code = p_profile_code and h.external_ref = v_isin;
    if v_holding is not null and exists (select 1 from public.structured_notes x
                                         where x.holding_code = v_holding and x.status <> 'cancelled') then
      raise exception 'this ledger already has a note for %', v_isin using errcode = '23505';
    end if;
  end if;
  if v_holding is not null then
    update public.holdings set kind = 'structured_note', name = v_name, currency = v_currency, units = null, symbol = null,
      notes = coalesce(nullif(btrim(p_draft->>'notes'), ''), notes)
    where holding_code = v_holding;
  else
    insert into public.holdings (profile_code, name, kind, currency, institution, acquired_on, notes, created_by, external_ref)
    values (p_profile_code, v_name, 'structured_note', v_currency,
            coalesce(nullif(btrim(p_draft->>'institution'), ''), (select b.name from public.banks b where b.bank_code = a.bank_code)),
            v_trade, nullif(btrim(p_draft->>'notes'), ''), auth.uid(), case when v_synced then v_isin end)
    returning holding_code into v_holding;
  end if;

  insert into public.structured_notes (profile_code, holding_code, product_name, isin, issuer, guarantor, currency,
    denomination, issue_price_pct, strike_date, issue_date, final_valuation_date, maturity_date, trade_date, nominal,
    purchase_price_pct, invested_amount, funding_account_code, termsheet_path, termsheet_filename, extracted_terms, created_by,
    note_type)
  values (p_profile_code, v_holding, coalesce(nullif(btrim(t->>'product_name'), ''), v_name), nullif(upper(t->>'isin'), ''),
    nullif(btrim(t->>'issuer'), ''), nullif(btrim(t->>'guarantor'), ''), v_currency, v_denom, v_issue, v_strike,
    nullif(t->>'issue_date', '')::date, v_final, v_maturity, v_trade, v_nominal, v_price, v_invested, v_account,
    nullif(p_draft->>'termsheet_path', ''), nullif(p_draft->>'termsheet_filename', ''), p_draft->'extracted_terms', auth.uid(),
    v_type)
  returning note_code into v_note;

  if v_type = 'credit_linked' then
    insert into public.structured_note_credit_terms (profile_code, note_code, reference_entity, seniority, transaction_type,
      reference_obligation_isin, coupon_rate_pct, coupon_frequency, day_count, interest_start_date, first_coupon_date,
      longstop_maturity_date, call_dates, call_notice_days)
    values (p_profile_code, v_note, btrim(cr->>'reference_entity'), nullif(btrim(cr->>'seniority'), ''),
      nullif(btrim(cr->>'transaction_type'), ''), nullif(upper(btrim(cr->>'reference_obligation_isin')), ''), v_rate, v_freq,
      coalesce(nullif(cr->>'day_count', ''), '30/360'), v_start, v_first, nullif(cr->>'longstop_maturity_date', '')::date,
      coalesce((select array_agg(d::date order by d::date) from jsonb_array_elements_text(coalesce(cr->'call_dates', '[]')) d),
               '{}'), nullif(cr->>'call_notice_days', '')::int);
  end if;

  insert into public.structured_note_underlyings (profile_code, note_code, ordinal, name, symbol, bloomberg_code, isin,
                                                  exchange, initial_level)
  select p_profile_code, v_note, u.ord::int, btrim(u.x->>'name'), upper(btrim(u.x->>'symbol')),
         nullif(btrim(u.x->>'bloomberg_code'), ''), nullif(upper(u.x->>'isin'), ''), nullif(btrim(u.x->>'exchange'), ''),
         (u.x->>'initial_level')::numeric
  from jsonb_array_elements(case when v_type = 'equity' then t->'underlyings' else '[]' end) with ordinality u(x, ord);

  insert into public.structured_note_observations (profile_code, note_code, seq, obs_date, pay_date, coupon_rate_pct,
    coupon_barrier_pct, coupon_memory, autocall_trigger_pct, autocall_amount_pct)
  select p_profile_code, v_note, row_number() over (order by (o->>'obs_date')::date)::int, (o->>'obs_date')::date,
         (o->>'pay_date')::date, nullif(o->>'coupon_rate_pct', '')::numeric, nullif(o->>'coupon_barrier_pct', '')::numeric,
         coalesce((o->>'coupon_memory')::boolean, false), nullif(o->>'autocall_trigger_pct', '')::numeric,
         nullif(o->>'autocall_amount_pct', '')::numeric
  from jsonb_array_elements(case when v_type = 'equity' then coalesce(t->'observations', '[]') else '[]' end) o;

  insert into public.structured_note_payout_branches (profile_code, note_code, min_worst_pct, intercept_pct, slope, settlement)
  select p_profile_code, v_note, (b->>'min_worst_pct')::numeric, (b->>'intercept_pct')::numeric, (b->>'slope')::numeric,
         coalesce(b->>'settlement', 'cash')
  from jsonb_array_elements(case when v_type = 'equity' then t->'payout' else '[]' end) b;

  if v_synced then
    -- The broker's buy rows are the purchase, and the sync already linked them to the holding.
    update public.structured_notes set purchase_txn_code = (
      select bt.txn_code from public.broker_transactions bt
      where bt.account_code = v_account and bt.isin = v_isin and bt.kind = 'buy' and not bt.is_reversal
      order by bt.booked_at limit 1)
    where note_code = v_note;
  elsif v_account is not null then
    v_txn := private.evidence_txn(p_profile_code, v_account, 'transfer_out', 'debit', v_invested, v_currency, v_trade,
                                  'NOTE PURCHASE ' || coalesce(nullif(upper(t->>'isin'), ''), v_name));
    update public.structured_notes set purchase_txn_code = v_txn where note_code = v_note;
    -- The rule trigger may have linked it elsewhere; the note's own link wins.
    delete from public.holding_flows where txn_code = v_txn;
  end if;
  if not v_synced then
    insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code, source, created_by)
    values (p_profile_code, v_holding, v_trade, 'contribution', v_invested, private.to_aed(v_invested, v_currency), v_txn,
            'note', auth.uid());
  end if;

  perform private.settle_structured_note(v_note);
  return v_holding;
end;
$$;

-- settle_structured_note (20261027165732): a credit-linked note the broker redeemed before its
-- maturity was called.

create or replace function private.settle_structured_note(p_note_code text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  n public.structured_notes;
  h public.holdings;
  v_today date := public.dubai_date(now());
  v_eval jsonb;
  e jsonb;
  ev public.structured_note_events;
  v_txn text;
  v_holding text;
  v_share_value numeric;
  v_synced boolean;
  v_redeemed date;
begin
  select * into n from public.structured_notes where note_code = p_note_code for update;
  if not found or n.status = 'cancelled' then
    return;
  end if;
  select * into h from public.holdings where holding_code = n.holding_code;
  v_eval := private.note_evaluate(n.note_code, v_today);
  -- Funded from an account a broker sync keeps: the broker's rows are the payments
  -- (20261027165732). Nothing is posted here; an event settles once its row has arrived.
  v_synced := n.funding_account_code is not null and n.isin is not null
              and private.is_broker_account(n.profile_code, n.funding_account_code);
  if v_synced then
    select min(public.dubai_date(bt.booked_at)) into v_redeemed from public.broker_transactions bt
    where bt.account_code = n.funding_account_code and bt.isin = n.isin and bt.kind = 'redemption';
  end if;

  for e in select x from jsonb_array_elements(v_eval->'events') x
           where x->>'kind' in ('coupon', 'autocall', 'maturity') loop
    insert into public.structured_note_events (profile_code, note_code, kind, seq, obs_date, pay_date, worst_pct,
      worst_symbol, rate_pct, amount, settlement, shares, share_price)
    values (n.profile_code, n.note_code, e->>'kind', (e->>'seq')::int, (e->>'obs_date')::date, (e->>'pay_date')::date,
      (e->>'worst_pct')::numeric, e->>'worst_symbol', (e->>'rate_pct')::numeric, (e->>'amount')::numeric,
      coalesce(e->>'settlement', 'cash'), (e->>'shares')::numeric, (e->>'share_price')::numeric)
    on conflict (note_code, kind, obs_date) do nothing;
  end loop;

  for ev in select * from public.structured_note_events x
            where x.note_code = n.note_code and x.settled_at is null and x.pay_date <= v_today
            order by x.pay_date, x.kind loop
    v_txn := null;
    if v_synced then
      if ev.amount > 0 then
        select bt.txn_code into v_txn from public.broker_transactions bt
        where bt.account_code = n.funding_account_code and bt.isin = n.isin and bt.txn_code is not null
          and bt.kind = case ev.kind when 'coupon' then 'coupon' else 'redemption' end
          and public.dubai_date(bt.booked_at) between ev.pay_date - 10 and ev.pay_date + 30
          and not exists (select 1 from public.structured_note_events x where x.txn_code = bt.txn_code)
        order by abs(public.dubai_date(bt.booked_at) - ev.pay_date), bt.booked_at
        limit 1;
        -- A coupon paid inside the redemption price (one row for both) settles with it.
        if v_txn is null and not (ev.kind = 'coupon' and v_redeemed is not null and v_redeemed >= ev.pay_date - 10) then
          continue;
        end if;
      end if;
      update public.structured_note_events set settled_at = now(), txn_code = v_txn where event_code = ev.event_code;
      continue;
    end if;
    if ev.amount > 0 and n.funding_account_code is not null then
      v_txn := private.evidence_txn(n.profile_code, n.funding_account_code, 'transfer_in', 'credit', ev.amount,
        n.currency, ev.pay_date,
        case ev.kind when 'coupon' then 'NOTE COUPON ' when 'autocall' then 'NOTE AUTOCALL ' else 'NOTE REDEMPTION ' end
        || coalesce(n.isin, h.name));
    end if;
    if ev.kind = 'coupon' then
      if ev.amount > 0 then
        insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source, notes)
        values (n.profile_code, n.holding_code, ev.pay_date, 'income', ev.amount, private.to_aed(ev.amount, n.currency),
                'note', 'coupon ' || ev.rate_pct::numeric(9,3) || '%');
      end if;
    else
      if ev.amount > 0 then
        insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, txn_code, source, notes)
        values (n.profile_code, n.holding_code, ev.pay_date, 'withdrawal', ev.amount, private.to_aed(ev.amount, n.currency),
                v_txn, 'note', ev.kind);
      end if;
      if ev.settlement = 'physical' and coalesce(ev.shares, 0) > 0 then
        v_share_value := round(ev.shares * ev.share_price, 2);
        insert into public.holdings (profile_code, name, kind, currency, institution, units, symbol, acquired_on, notes, created_by)
        values (n.profile_code, left(ev.worst_symbol || ' shares (from ' || h.name || ')', 80), 'security', n.currency,
                h.institution, ev.shares, ev.worst_symbol, ev.pay_date, 'Delivered at maturity of ' || coalesce(n.isin, h.name),
                n.created_by)
        returning holding_code into v_holding;
        insert into public.holding_valuations (profile_code, holding_code, as_of, unit_price, source)
        values (n.profile_code, v_holding, ev.obs_date, ev.share_price, 'import');
        insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source, notes)
        values (n.profile_code, n.holding_code, ev.pay_date, 'withdrawal', v_share_value,
                private.to_aed(v_share_value, n.currency), 'note', 'shares delivered'),
               (n.profile_code, v_holding, ev.pay_date, 'contribution', v_share_value,
                private.to_aed(v_share_value, n.currency), 'note', 'delivered by ' || coalesce(n.isin, h.name));
      end if;
    end if;
    update public.structured_note_events set settled_at = now(), txn_code = v_txn, delivered_holding_code = v_holding
    where event_code = ev.event_code;
    v_holding := null;
  end loop;

  if v_eval->>'status' in ('autocalled', 'matured') and (v_eval->>'ended_on')::date <= v_today then
    update public.structured_notes set status = v_eval->>'status', ended_on = (v_eval->>'ended_on')::date
    where note_code = n.note_code;
    update public.holdings set status = 'closed' where holding_code = n.holding_code and status = 'active';
  elsif v_synced and v_redeemed is not null then
    -- The broker redeemed it (before any close could tell): it ended that day.
    update public.structured_notes
    set status = case when v_redeemed >= coalesce(n.final_valuation_date, n.maturity_date - 10) then 'matured'
                      when n.note_type = 'credit_linked' then 'called' else 'autocalled' end, ended_on = v_redeemed
    where note_code = n.note_code and status = 'live';
    update public.holdings set status = 'closed' where holding_code = n.holding_code and status = 'active';
  end if;
end;
$$;

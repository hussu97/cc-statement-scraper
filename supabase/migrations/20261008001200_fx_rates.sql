-- Daily FX-rate fallback for pending SMS transactions.
--
-- An SMS in a currency the profile has never seen on a statement (EGP, INR, …)
-- previously got amount_aed = NULL until the statement arrived. The `fx-rates`
-- Edge Function now stores a daily market rate per currency in public.fx_rates,
-- and private.estimate_fx falls back to it:
--
--   1. the profile's latest statement rate for that currency (reflects the card's
--      real FX markup, so it stays preferred)
--   2. the fixed AED / USD peg (exact by law; beats a rounded market quote)
--   3. public.fx_rates (market mid rate, no markup; the amount stays an estimate)
--
-- After every rates update, pending SMS-only transactions are re-derived so
-- their estimate appears without waiting for another event.

-- ── reference data ──────────────────────────────────────────────────────────
-- Global (not per profile): one row per ISO 4217 currency.
create table public.fx_rates (
  currency text primary key check (currency ~ '^[A-Z]{3}$'),
  aed_per_unit numeric(18,8) not null check (aed_per_unit > 0),
  source text not null,
  as_of date not null,
  updated_at timestamptz not null default now()
);
comment on table public.fx_rates is
  'Daily market FX rates (AED per 1 unit of currency), written by the fx-rates Edge Function. Global reference data.';

alter table public.fx_rates enable row level security;
create policy fx_rates_read on public.fx_rates for select to authenticated using (true);
grant select on public.fx_rates to authenticated;
grant all on public.fx_rates to service_role;

-- ── estimate ────────────────────────────────────────────────────────────────
create or replace function private.estimate_fx(p_profile text, p_currency text)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select l.fx_rate from public.statement_lines l
      where l.profile_code = p_profile and l.currency_original = p_currency and l.fx_rate is not null
      order by l.txn_date desc limit 1),
    case p_currency when 'AED' then 1 when 'USD' then 3.6725 end,
    (select r.aed_per_unit from public.fx_rates r where r.currency = p_currency)
  )
$$;

-- Re-derive every pending transaction whose AED amount is missing or estimated.
-- Returns the number of transactions refreshed.
create or replace function private.reestimate_pending_fx()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select t.txn_code from public.transactions t
    where t.status = 'pending' and (t.amount_aed is null or t.amount_aed_is_estimate)
    order by t.txn_code
  loop
    perform private.refresh_transaction(r.txn_code);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ── writer (fx-rates Edge Function only) ────────────────────────────────────
-- p_rates: {"EGP": "0.07561234", "INR": 0.0441, …} — AED per 1 unit.
-- Entries that are not a 3-letter code with a positive numeric rate are skipped.
-- An older as_of never overwrites a newer one.
create or replace function public.upsert_fx_rates(p_rates jsonb, p_source text, p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_upserted integer;
  v_reestimated integer;
begin
  perform private.assert_service_role();
  if p_rates is null or jsonb_typeof(p_rates) <> 'object' then
    raise exception 'p_rates must be a JSON object of currency -> AED per unit' using errcode = '22023';
  end if;
  if coalesce(btrim(p_source), '') = '' or p_as_of is null then
    raise exception 'p_source and p_as_of are required' using errcode = '22023';
  end if;

  insert into public.fx_rates as f (currency, aed_per_unit, source, as_of, updated_at)
  select e.key, round(e.rate, 8), p_source, p_as_of, now()
  from (
    select j.key, case when j.value ~ '^[0-9]+(\.[0-9]+)?$' then j.value::numeric end as rate
    from jsonb_each_text(p_rates) j
    where j.key ~ '^[A-Z]{3}$'
  ) e
  where e.rate is not null and round(e.rate, 8) > 0 and e.rate < 1e10
  on conflict (currency) do update set
    aed_per_unit = excluded.aed_per_unit, source = excluded.source, as_of = excluded.as_of, updated_at = now()
  where f.as_of <= excluded.as_of;
  get diagnostics v_upserted = row_count;

  v_reestimated := private.reestimate_pending_fx();
  return jsonb_build_object('upserted', v_upserted, 'reestimated', v_reestimated);
end;
$$;
grant execute on function public.upsert_fx_rates(jsonb, text, date) to service_role;

-- ── schedule ────────────────────────────────────────────────────────────────
-- 21:00 UTC = 01:00 Asia/Dubai, ahead of the 22:00 UTC nightly job.
select cron.schedule('ledger-fx-rates', '0 21 * * *', $$select private.invoke_edge('fx-rates')$$);

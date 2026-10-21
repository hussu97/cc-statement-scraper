-- RL360 sync (tasks/todo.md §8, decisions of 21 Oct): plan values, value history and premiums
-- from RL360's Online Service Centre, fetched daily by the rl360-sync Edge Function.
--
-- 1. holdings.external_ref: the provider's plan number. The first sync claims the profile's one
--    RL360 plan that has no number yet (institution or name mentions RL360); with several, it
--    claims none and reports it.
-- 2. holding_flows gains source `import` and external_ref (one imported premium per plan and
--    due date), and superseded_by: the linked card payment that stands for an imported premium.
-- 3. public.import_holding_data (service role): stores the values (source import; never over a
--    manual value of the same day) and reconciles the premiums with the linked card payments:
--    a premium with a linked payment within ±7 days and 5% of its amount is that payment;
--    otherwise it is an imported contribution. Each run re-checks, so a payment linked or
--    unlinked later moves the premium between the two; a premium the user removed stays removed.
--    Returns the month-ends since the plan started that have no value yet (the backfill).
-- 4. pg_cron `ledger-rl360-sync`, daily at 02:20 UTC (06:20 Dubai).

-- ── 1. holdings.external_ref ────────────────────────────────────────────────
alter table public.holdings add column external_ref text check (external_ref ~ '^[A-Za-z0-9-]{3,40}$');
create unique index holdings_external_ref_uq on public.holdings(profile_code, external_ref) where external_ref is not null;
comment on column public.holdings.external_ref is
  'The provider''s reference for this holding (an RL360 plan number); set by the provider sync.';

-- ── 2. holding_flows: imported premiums ─────────────────────────────────────
alter table public.holding_flows drop constraint holding_flows_source_check;
alter table public.holding_flows add constraint holding_flows_source_check
  check (source in ('manual', 'rule', 'link', 'holding_cost', 'import'));
alter table public.holding_flows add column external_ref text check (length(external_ref) <= 60);
alter table public.holding_flows add column superseded_by text;
alter table public.holding_flows add constraint holding_flows_import_ref_check
  check ((source = 'import') = (external_ref is not null));
create unique index holding_flows_external_ref_uq on public.holding_flows(holding_code, external_ref)
  where external_ref is not null;
comment on column public.holding_flows.superseded_by is
  'An imported premium that a linked card payment stands for: that payment''s flow (the import is then removed).';

-- ── 3. import_holding_data ──────────────────────────────────────────────────
-- p_valuations: [{as_of: date, value: decimal string}] in the plan's currency.
-- p_premiums: [{ref, date, amount}] (date received, amount received), or null to leave the
-- premiums alone (backfill calls).
create function public.import_holding_data(p_profile_code text, p_institution text, p_external_ref text,
                                           p_currency text, p_started_on date, p_valuations jsonb,
                                           p_premiums jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  h public.holdings;
  v_claimed boolean := false;
  v_today date := public.dubai_date(now());
  e jsonb;
  v_as_of date;
  v_value numeric;
  v_ref text;
  v_date date;
  v_amount numeric;
  v_match text;
  v_used text[] := '{}';
  f public.holding_flows;
  v_have boolean;
  n_values int := 0;
  n_imported int := 0;
  n_matched int := 0;
  n_revived int := 0;
  n_superseded int := 0;
begin
  perform private.assert_service_role();
  if p_external_ref is null or p_external_ref !~ '^[A-Za-z0-9-]{3,40}$' then
    raise exception 'external_ref must be 3-40 letters, digits or dashes' using errcode = '22023';
  end if;

  select * into h from public.holdings
  where profile_code = p_profile_code and external_ref = p_external_ref and status = 'active';
  if not found then
    -- Claim the profile's one unnumbered plan from this institution.
    if (select count(*) from public.holdings
        where profile_code = p_profile_code and kind = 'plan' and status = 'active' and external_ref is null
          and (institution ilike '%' || p_institution || '%' or name ilike '%' || p_institution || '%')) <> 1 then
      return jsonb_build_object('holding_code', null, 'external_ref', p_external_ref,
                                'reason', 'no single ' || p_institution || ' plan without a plan number to match');
    end if;
    update public.holdings set external_ref = p_external_ref
    where profile_code = p_profile_code and kind = 'plan' and status = 'active' and external_ref is null
      and (institution ilike '%' || p_institution || '%' or name ilike '%' || p_institution || '%')
    returning * into h;
    v_claimed := true;
  end if;
  if h.currency <> upper(p_currency) then
    raise exception 'plan % is in %, its holding in %', p_external_ref, upper(p_currency), h.currency
      using errcode = '22023';
  end if;
  if p_started_on is not null and (h.acquired_on is null or h.acquired_on > p_started_on) then
    update public.holdings set acquired_on = p_started_on where holding_code = h.holding_code;
  end if;

  -- Values: evidence, never updated. A new row only when the day has no manual value and its
  -- latest import differs.
  for e in select * from jsonb_array_elements(coalesce(p_valuations, '[]'::jsonb)) loop
    begin
      v_as_of := (e->>'as_of')::date;
      v_value := (e->>'value')::numeric;
    exception when others then
      raise exception 'valuation needs as_of and a decimal value' using errcode = '22023';
    end;
    if v_as_of is null or v_value is null or v_value < 0 or v_as_of > v_today then
      raise exception 'bad valuation % %', v_as_of, v_value using errcode = '22023';
    end if;
    continue when exists (select 1 from public.holding_valuations
                          where holding_code = h.holding_code and as_of = v_as_of and source = 'manual');
    continue when (select v.value from public.holding_valuations v
                   where v.holding_code = h.holding_code and v.as_of = v_as_of and v.source = 'import'
                   order by v.created_at desc, v.valuation_code desc limit 1) = round(v_value, 2);
    insert into public.holding_valuations (profile_code, holding_code, as_of, value, source)
    values (p_profile_code, h.holding_code, v_as_of, round(v_value, 2), 'import');
    n_values := n_values + 1;
  end loop;

  -- Premiums, oldest first; each linked payment stands for at most one premium.
  for e in select x from jsonb_array_elements(coalesce(p_premiums, '[]'::jsonb)) x
           order by (x->>'date')::date, x->>'ref' loop
    v_ref := e->>'ref';
    begin
      v_date := (e->>'date')::date;
      v_amount := (e->>'amount')::numeric;
    exception when others then
      raise exception 'premium needs ref, date and a decimal amount' using errcode = '22023';
    end;
    if v_ref is null or length(v_ref) > 60 or v_date is null or v_amount is null or v_amount <= 0 then
      raise exception 'bad premium % % %', v_ref, v_date, v_amount using errcode = '22023';
    end if;

    select lf.flow_code into v_match from public.holding_flows lf
    where lf.holding_code = h.holding_code and lf.source in ('rule', 'link') and lf.txn_code is not null
      and lf.kind = 'contribution' and private.flow_is_active(lf.removed_at, lf.txn_code)
      and abs(lf.flow_date - v_date) <= 7 and abs(lf.amount - v_amount) <= v_amount * 0.05
      and lf.flow_code <> all (v_used)
    order by abs(lf.flow_date - v_date), abs(lf.amount - v_amount), lf.flow_code
    limit 1;

    select * into f from public.holding_flows where holding_code = h.holding_code and external_ref = v_ref;
    v_have := found;
    if v_match is not null then
      v_used := v_used || v_match;
      n_matched := n_matched + 1;
      if v_have and f.removed_at is null then
        update public.holding_flows set removed_at = now(), superseded_by = v_match where flow_code = f.flow_code;
        n_superseded := n_superseded + 1;
      elsif v_have and f.superseded_by is distinct from v_match and f.superseded_by is not null then
        update public.holding_flows set superseded_by = v_match where flow_code = f.flow_code;
      end if;
    elsif not v_have then
      insert into public.holding_flows (profile_code, holding_code, flow_date, kind, amount, amount_aed, source,
                                        external_ref, notes)
      values (p_profile_code, h.holding_code, v_date, 'contribution', round(v_amount, 2),
              private.to_aed(v_amount, h.currency), 'import', v_ref, p_institution || ' premium');
      n_imported := n_imported + 1;
    elsif f.superseded_by is not null then
      update public.holding_flows
      set removed_at = null, superseded_by = null, flow_date = v_date, amount = round(v_amount, 2),
          amount_aed = private.to_aed(v_amount, h.currency)
      where flow_code = f.flow_code;
      n_revived := n_revived + 1;
    elsif f.removed_at is null and (f.flow_date <> v_date or f.amount <> round(v_amount, 2)) then
      update public.holding_flows
      set flow_date = v_date, amount = round(v_amount, 2), amount_aed = private.to_aed(v_amount, h.currency)
      where flow_code = f.flow_code;
    end if;
    -- else: the user removed this premium; it stays removed.
  end loop;

  return jsonb_build_object(
    'holding_code', h.holding_code, 'external_ref', p_external_ref, 'claimed', v_claimed,
    'values_added', n_values,
    'premiums', case when p_premiums is null then null else jsonb_build_object(
      'imported', n_imported, 'matched_to_payments', n_matched, 'superseded', n_superseded, 'revived', n_revived) end,
    'missing_month_ends', coalesce((
      select jsonb_agg(d order by d)
      from (select (m + interval '1 month' - interval '1 day')::date d
            from generate_series(date_trunc('month', coalesce(p_started_on, h.acquired_on, v_today)),
                                 date_trunc('month', v_today) - interval '1 month', interval '1 month') m) s
      where not exists (select 1 from public.holding_valuations v where v.holding_code = h.holding_code and v.as_of = s.d)),
      '[]'::jsonb));
end;
$$;
comment on function public.import_holding_data(text, text, text, text, date, jsonb, jsonb) is
  'Service role (rl360-sync): a provider''s plan values and premiums; premiums reconcile with linked card payments. Returns counts and the month-ends still without a value.';
grant execute on function public.import_holding_data(text, text, text, text, date, jsonb, jsonb) to service_role;

-- ── 4. daily sync ───────────────────────────────────────────────────────────
select cron.schedule('ledger-rl360-sync', '20 2 * * *', $$select private.invoke_edge('rl360-sync')$$);

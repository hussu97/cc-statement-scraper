-- Merchant key v2: one merchant per merchant, not per statement layout.
--
-- merchant_key v1 (20261008000500_ledger) kept noise that statements print around the name,
-- so one merchant became many (production, 2026-10-09: 802 keys, 91 holding a reference):
--   * the city column glued to the name, no space:   'CAREEM RIDEDUBAI', 'CAREEM HALAABU DHABI'
--   * references and countries v1 did not know:      'SPOTIFY AB P33F7BD2DC STOCKHOLM SWE',
--                                                     'WIX COM 1198729259 WWW WIX COM'
--   * a foreign amount after the place:              '... KUALA LUMPUR 2450618600 MYR 5 70 0'
-- v2 strips those (802 -> 692 keys on production's descriptions). Branch and store names stay
-- distinct ('MCDONALDS OASIS MALL', 'ADNOC AL SAFA 2'): collapsing a brand is a product
-- decision, not noise removal.
--
-- private.rekey_merchants() then moves existing data onto the new keys, and can be re-run after
-- any later change to merchant_key:
--   * merchants whose transactions now share a key merge into one survivor: the merchant that
--     already holds the key, else an existing alias's target, else the one with most
--     transactions. Survivors keep their merchant_code; the survivor's key becomes the new key.
--   * every old key is recorded in merchant_aliases (old key -> survivor), which
--     resolve_merchant consults before merchants.
--   * per profile, the survivor inherits the group's merchant category (manual beats llm; on a
--     tie the survivor's own row wins), its category skip and its recurring series. A merged-away
--     row is moved when the survivor has none; otherwise it stays, inert (its merchant has no
--     transactions left; a recurring series left behind is marked ended). Nothing is deleted.
--   * transactions are repointed by private.refresh_transaction (re-derived from evidence);
--     the categorisation triggers recompute their categories.

-- ── merchant_key v2 ─────────────────────────────────────────────────────────
create or replace function public.merchant_key(p text)
returns text
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  -- What a statement prints in its city column, often glued to the name ('RIDEDUBAI').
  c_place constant text := 'DUBAI|DXB|ABU DHABI|ABUDHABI|AUH|SHARJAH|SHJ|AJMAN|AL AIN|FUJAIRAH'
    || '|RAS AL KHAIMAH?|UMM AL QUWAIN|LONDON|NEW YORK|SAN FRANCISCO|MOUNTAIN VIEW|PALO ALTO|PHOENIX'
    || '|PITTSBURGH|BOSTON|DUBLIN|AMSTERDAM|STOCKHOLM|BERLIN|SINGAPORE|KUALA LUMPUR|PETALING JAYA'
    || '|SEPANG|IPOH|BANGKOK|PHUKET|KRABI|CAIRO|NAIROBI|MOMBASA|HYDERABAD|DELHI|GURUGRAM|GURGAON'
    || '|KUWAIT|DOHA|RIYADH|JEDDAH|MUSCAT|MANAMA';
  -- Country, region and state codes printed after the place (only ever stripped after a space).
  c_code constant text := 'AE|ARE|UAE|UN|US|USA|GB|GBR|UK|ENG|IN|IND|SA|SAU|NL|NLD|IE|IRL|SG|SGP'
    || '|SE|SWE|DE|DEU|FR|FRA|TH|THA|MY|MYS|KE|KEN|KNE|NAI|EG|EGY|KW|KWT|QA|QAT|OM|OMN|BH|BHR'
    || '|CY|CYP|LND|AJM|FUJ|AHU|CA|AZ|PA|MA|NY|WA|TX';
  c_currency constant text := 'AED|USD|GBP|EUR|THB|MYR|KES|EGP|SGD|INR|SAR|KWD|QAR|OMR|BHD';
  v text := upper(coalesce(p, ''));
  prev text;
begin
  v := regexp_replace(v, '[^A-Z0-9& ]', ' ', 'g');
  v := btrim(regexp_replace(v, '\s+', ' ', 'g'));
  v := regexp_replace(v, '^(POS|PURCHASE|SALE|APPLE PAY|GOOGLE PAY|SAMSUNG PAY|ECOM|E COM|ONLINE|PAYPAL)\s+', '');
  -- A long digit run glued to a word is a reference: 'COM4189415093ABU' -> 'COM 4189415093 ABU'.
  v := regexp_replace(v, '([A-Z]{3})([0-9]{5,})', '\1 \2', 'g');
  v := regexp_replace(v, '([0-9]{5,})([A-Z]{3})', '\1 \2', 'g');
  loop
    prev := v;
    v := regexp_replace(v, '([A-Z0-9])(' || c_place || ')$', '\1 \2');
    v := regexp_replace(v, '\s+(' || c_place || '|' || c_code || ')$', '');
    v := regexp_replace(v, '\s+[0-9]{3,}$', '');
    v := regexp_replace(v, '\s+(' || c_currency || ')(\s+[0-9]{1,3}){1,3}$', '');
    v := regexp_replace(v, '(\s+[0-9]{1,3}){1,3}\s+(' || c_currency || ')$', '');
    -- The website column: 'WIX COM WWW WIX COM' -> 'WIX COM'.
    v := regexp_replace(v, '\s+WWW(\s+[A-Z0-9]+)+\s+COM$', '');
    -- References after the first word: 5+ digits, or 6+ characters mixing letters and digits.
    select coalesce(string_agg(w, ' ' order by o), '') into v
    from regexp_split_to_table(v, ' ') with ordinality x(w, o)
    where o = 1 or not (w ~ '^[0-9]{5,}$' or (length(w) >= 6 and w ~ '[0-9]' and w ~ '[A-Z]'));
    exit when v = prev;
  end loop;
  return nullif(btrim(v), '');
end;
$$;

-- ── re-key existing merchants ───────────────────────────────────────────────
-- The plan, one row per merchant being re-keyed: its old and new key and its group's survivor.
create or replace function private.rekey_rows(p_plan jsonb)
returns table (merchant_code text, old_key text, new_key text, survivor text, by_alias boolean)
language sql
immutable
set search_path = ''
as $$
  select * from jsonb_to_recordset(p_plan)
    as x(merchant_code text, old_key text, new_key text, survivor text, by_alias boolean)
$$;

create or replace function private.rekey_merchants()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_plan jsonb;
  v_n integer;
  v_aliases integer := 0;
  v_renamed integer := 0;
  v_mpc integer := 0;
  v_skips integer := 0;
  v_series integer := 0;
  v_txns integer := 0;
begin
  perform private.assert_service_role();

  -- Existing aliases follow the new key first, so a merge made through an alias holds
  -- (unless its merchant already holds that key).
  insert into public.merchant_aliases (alias_key, merchant_code, source)
  select public.merchant_key(a.alias_key), a.merchant_code, a.source
  from public.merchant_aliases a
  where public.merchant_key(a.alias_key) is distinct from a.alias_key
    and public.merchant_key(a.alias_key) is not null
    and not exists (select 1 from public.merchants m
                    where m.merchant_code = a.merchant_code and m.merchant_key = public.merchant_key(a.alias_key))
  on conflict (alias_key) do nothing;
  get diagnostics v_n = row_count;
  v_aliases := v_aliases + v_n;

  -- Each merchant's new key: the one most of its transactions' descriptions now give (its own key
  -- re-keyed when it has none). Masked merchants (key = upper(code), 20261010000600) stay out.
  -- One survivor per new key: an existing alias's target, else the merchant holding the key,
  -- else the member with most transactions (then the oldest). Taken once, before any write.
  with per_desc as (
    select t.merchant_code, public.merchant_key(t.description) as new_key, count(*) as n
    from public.transactions t
    where t.merchant_code is not null
    group by 1, 2
  ), top_key as (
    select distinct on (d.merchant_code) d.merchant_code, d.new_key
    from per_desc d where d.new_key is not null
    order by d.merchant_code, d.n desc, d.new_key
  ), rk as (
    select * from (
      select m.merchant_code, m.merchant_key as old_key, m.created_at,
             coalesce(k.new_key, public.merchant_key(m.merchant_key)) as new_key,
             coalesce((select sum(d.n) from per_desc d where d.merchant_code = m.merchant_code), 0) as n
      from public.merchants m
      left join top_key k on k.merchant_code = m.merchant_code
      where m.merchant_key !~ '^MER_[0-9A-Z]{26}$'
    ) x
    where x.new_key is not null
  ), grp as (
    select distinct on (g.new_key) g.new_key,
           coalesce(a.merchant_code, h.merchant_code, g.merchant_code) as survivor,
           a.merchant_code is not null as by_alias
    from rk g
    left join public.merchant_aliases a on a.alias_key = g.new_key
    left join public.merchants h on h.merchant_key = g.new_key
    order by g.new_key, g.n desc, g.created_at, g.merchant_code
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'merchant_code', rk.merchant_code, 'old_key', rk.old_key, 'new_key', rk.new_key,
           'survivor', grp.survivor, 'by_alias', grp.by_alias)), '[]'::jsonb)
  into v_plan
  from rk join grp on grp.new_key = rk.new_key;

  -- Old keys map to their survivor.
  insert into public.merchant_aliases (alias_key, merchant_code, source)
  select p.old_key, p.survivor, 'auto'
  from private.rekey_rows(v_plan) p
  where p.old_key <> p.new_key
  on conflict (alias_key) do nothing;
  get diagnostics v_n = row_count;
  v_aliases := v_aliases + v_n;

  -- The survivor takes the new key (its code stays), and an auto-made name follows it.
  -- Not when the survivor is an alias target or survives for another key too.
  update public.merchants m
  set merchant_key = g.new_key,
      display_name = case when m.display_name = initcap(lower(m.merchant_key))
                          then initcap(lower(g.new_key)) else m.display_name end
  from (select distinct p.new_key, p.survivor, p.by_alias from private.rekey_rows(v_plan) p) g
  where m.merchant_code = g.survivor and m.merchant_key <> g.new_key and not g.by_alias
    and not exists (select 1 from public.merchants h where h.merchant_key = g.new_key)
    and (select count(distinct o.new_key) from private.rekey_rows(v_plan) o where o.survivor = g.survivor) = 1;
  get diagnostics v_renamed = row_count;

  -- A survivor that kept another key is reached through an alias.
  insert into public.merchant_aliases (alias_key, merchant_code, source)
  select distinct p.new_key, p.survivor, 'auto'
  from private.rekey_rows(v_plan) p join public.merchants m on m.merchant_code = p.survivor
  where m.merchant_key <> p.new_key
  on conflict (alias_key) do nothing;
  get diagnostics v_n = row_count;
  v_aliases := v_aliases + v_n;

  -- Merchant category, per profile and survivor: manual beats llm; on a tie the survivor's own
  -- row, then the latest. An llm row does not move onto a survivor whose suggestion the owner
  -- rejected.
  for r in
    with member as (
      select p.merchant_code, p.survivor from private.rekey_rows(v_plan) p
      union
      select p.survivor, p.survivor from private.rekey_rows(v_plan) p
    )
    select distinct on (c.profile_code, mm.survivor)
           c.profile_code, mm.survivor, c.merchant_code as from_code, c.category_code, c.source,
           c.confidence, c.model, c.category_set_hash
    from public.merchant_profile_category c
    join member mm on mm.merchant_code = c.merchant_code
    order by c.profile_code, mm.survivor, (c.source = 'manual') desc,
             (c.merchant_code = mm.survivor) desc, c.updated_at desc, c.merchant_code
  loop
    continue when r.from_code = r.survivor;
    if exists (select 1 from public.merchant_profile_category s
               where s.profile_code = r.profile_code and s.merchant_code = r.survivor) then
      update public.merchant_profile_category s
      set category_code = r.category_code, source = r.source, confidence = r.confidence,
          model = r.model, category_set_hash = r.category_set_hash
      where s.profile_code = r.profile_code and s.merchant_code = r.survivor;
    elsif r.source = 'manual' or not exists (
            select 1 from public.merchant_category_skips k
            where k.profile_code = r.profile_code and k.merchant_code = r.survivor and k.reason = 'rejected') then
      update public.merchant_profile_category s set merchant_code = r.survivor
      where s.profile_code = r.profile_code and s.merchant_code = r.from_code;
    else
      continue;
    end if;
    v_mpc := v_mpc + 1;
  end loop;

  -- Category skip: moved to a survivor that has neither a category nor a skip (rejected first).
  for r in
    select distinct on (k.profile_code, p.survivor) k.profile_code, p.survivor, k.merchant_code as from_code
    from public.merchant_category_skips k
    join private.rekey_rows(v_plan) p on p.merchant_code = k.merchant_code
    where k.merchant_code <> p.survivor
      and not exists (select 1 from public.merchant_category_skips s
                      where s.profile_code = k.profile_code and s.merchant_code = p.survivor)
      and not exists (select 1 from public.merchant_profile_category c
                      where c.profile_code = k.profile_code and c.merchant_code = p.survivor)
    order by k.profile_code, p.survivor, (k.reason = 'rejected') desc, k.updated_at desc, k.merchant_code
  loop
    update public.merchant_category_skips s set merchant_code = r.survivor
    where s.profile_code = r.profile_code and s.merchant_code = r.from_code;
    v_skips := v_skips + 1;
  end loop;

  -- Recurring series: moved to a survivor that has none (a dismissal is kept, then the latest);
  -- a merged-away series left behind that is still active has ended.
  for r in
    select distinct on (s.profile_code, p.survivor) s.profile_code, p.survivor, s.recurring_code
    from public.recurring_series s
    join private.rekey_rows(v_plan) p on p.merchant_code = s.merchant_code
    where s.merchant_code <> p.survivor
      and not exists (select 1 from public.recurring_series o
                      where o.profile_code = s.profile_code and o.merchant_code = p.survivor)
    order by s.profile_code, p.survivor, (s.status = 'dismissed') desc, s.last_date desc, s.recurring_code
  loop
    update public.recurring_series s set merchant_code = r.survivor where s.recurring_code = r.recurring_code;
    v_series := v_series + 1;
  end loop;
  update public.recurring_series s set status = 'ended'
  from private.rekey_rows(v_plan) p
  where s.merchant_code = p.merchant_code and p.merchant_code <> p.survivor and s.status = 'active';

  -- Transactions follow their evidence onto the survivor; categories recompute on update.
  for r in
    select t.txn_code
    from public.transactions t
    join private.rekey_rows(v_plan) p on p.merchant_code = t.merchant_code
    where p.survivor <> t.merchant_code
       or public.merchant_key(t.description) is distinct from p.new_key
  loop
    perform private.refresh_transaction(r.txn_code);
    v_txns := v_txns + 1;
  end loop;

  -- Recurring detection over the merged history.
  for r in
    select distinct t.profile_code
    from public.transactions t
    where t.merchant_code in (select p.survivor from private.rekey_rows(v_plan) p
                              where p.merchant_code <> p.survivor)
  loop
    perform private.detect_recurring(r.profile_code);
  end loop;

  return jsonb_build_object(
    'keys', (select count(distinct p.new_key) from private.rekey_rows(v_plan) p),
    'merchants_merged', (select count(*) from private.rekey_rows(v_plan) p where p.merchant_code <> p.survivor),
    'merchants_renamed', v_renamed, 'aliases', v_aliases, 'merchant_categories', v_mpc,
    'category_skips', v_skips, 'recurring_series', v_series, 'transactions_refreshed', v_txns);
end;
$$;

select private.rekey_merchants();

-- Glued cities, backfilled: the space parser 2026.10.4 now puts between a merchant and the city
-- a statement glued to it ('CAREEM HALA RIDEDUBAI' -> 'CAREEM HALA RIDE DUBAI'), applied to
-- what was ingested before it (production 2026-10-09: 1,374 current lines, mostly MASHREQ and
-- SIB history).
--
--   * statement_lines.description (the parse field transactions derive their text from) gets the
--     space; description_raw and raw stay as the bank printed them, so line_key, re-parses and
--     the history union are unaffected. Transactions are refreshed from their evidence, so their
--     description follows and categorisation recomputes. merchant_key strips the city glued or
--     not (20261010001200), so no transaction changes merchant.
--   * Rule patterns written against the glued text ('contains' KITOPIDUBAI, OSNDUBAI, CAREEMDUBAI;
--     11 seed rules per profile) get the same space, in private.seed_rules and in every non-regex
--     category_rules row, so they keep matching old and new statements alike. A seed pattern is
--     left alone when its category already has the spaced one.
--
-- private.backfill_glued_places() is idempotent and the migration runs it once.

-- The places of ccs_parser/places.py (and of c_place in public.merchant_key); add to all three.
create or replace function private.separate_glued_place(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select regexp_replace(p,
    '([[:alnum:]])(DUBAI|DXB|ABU DHABI|ABUDHABI|AUH|SHARJAH|SHJ|AJMAN|AL AIN|FUJAIRAH|RAS AL KHAIMAH'
    || '|RAS AL KHAIMA|UMM AL QUWAIN|LONDON|NEW YORK|SAN FRANCISCO|MOUNTAIN VIEW|PALO ALTO|PHOENIX'
    || '|PITTSBURGH|BOSTON|DUBLIN|AMSTERDAM|STOCKHOLM|BERLIN|SINGAPORE|KUALA LUMPUR|PETALING JAYA'
    || '|SEPANG|IPOH|BANGKOK|PHUKET|KRABI|CAIRO|NAIROBI|MOMBASA|HYDERABAD|DELHI|GURUGRAM|GURGAON'
    || '|KUWAIT|DOHA|RIYADH|JEDDAH|MUSCAT|MANAMA)$',
    '\1 \2', 'i')
$$;

create or replace function private.backfill_glued_places()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_seed integer;
  v_rules integer;
  v_lines text[];
  v_txns integer := 0;
begin
  perform private.assert_service_role();

  update private.seed_rules s set pattern = private.separate_glued_place(s.pattern)
  where s.match_type <> 'regex'
    and private.separate_glued_place(s.pattern) <> s.pattern
    and not exists (select 1 from private.seed_rules o
                    where o.category_name = s.category_name and o.pattern = private.separate_glued_place(s.pattern));
  get diagnostics v_seed = row_count;

  -- The category_rules triggers recategorise each profile.
  update public.category_rules c
  set pattern = private.separate_glued_place(btrim(c.pattern)),
      name = case when c.name = 'seed: ' || c.pattern
                  then 'seed: ' || private.separate_glued_place(btrim(c.pattern)) else c.name end
  where c.match_type <> 'regex'
    and private.separate_glued_place(btrim(c.pattern)) <> btrim(c.pattern);
  get diagnostics v_rules = row_count;

  -- Lines first, then their transactions (refresh_transaction reads the line's description).
  with u as (
    update public.statement_lines l set description = private.separate_glued_place(l.description)
    where l.is_current and private.separate_glued_place(l.description) <> l.description
    returning l.line_code
  )
  select coalesce(array_agg(u.line_code), '{}') into v_lines from u;
  for r in
    select distinct e.txn_code from public.transaction_evidence e
    where e.line_code = any (v_lines) and e.is_active
  loop
    perform private.refresh_transaction(r.txn_code);
    v_txns := v_txns + 1;
  end loop;

  return jsonb_build_object('seed_rules', v_seed, 'category_rules', v_rules,
                            'statement_lines', cardinality(v_lines), 'transactions_refreshed', v_txns);
end;
$$;

select private.backfill_glued_places();

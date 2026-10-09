-- public.activity_summary: the Activity tab's header for the current search and filters
-- (web and iOS): how many transactions, their net AED value, and the earliest and latest
-- transaction date.
--
-- The filters are the Activity list's (apps/web applyActivityFilters, LedgerKit ActivityQuery)
-- over the same view, v_transactions, so the header always describes the rows listed:
--   from/to (txn_date), account, card, category (or uncategorized), status, source
--   (sms | statement | both), and a free-text search over description OR merchant name.
-- The search term is cleaned exactly as the clients clean it for PostgREST's `or=(…)`:
-- trimmed, first 80 characters, `, ( ) * : "` become the single-character wildcard `_`, and
-- `\ % _` are escaped.
--
-- net_aed: debits add, credits (refunds, payments) subtract; void transactions and rows
-- without an AED amount are left out of the sum (unpriced_count says how many lacked one).
-- txn_count counts every matching row, void included, like the list. Money is a decimal string.

create or replace function private.activity_search_pattern(p_q text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when coalesce(btrim(p_q), '') = '' then null
         else '%' || regexp_replace(
                        replace(replace(replace(left(btrim(p_q), 80), '\', '\\'), '%', '\%'), '_', '\_'),
                        '[,()*:"]', '_', 'g') || '%'
         end
$$;

create or replace function public.activity_summary(
  p_profile_code text,
  p_from date default null,
  p_to date default null,
  p_account_code text default null,
  p_card_code text default null,
  p_category_code text default null,
  p_uncategorized boolean default false,
  p_status text default null,
  p_source text default null,
  p_q text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pattern text := private.activity_search_pattern(p_q);
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_status is not null and p_status not in ('pending', 'posted', 'void', 'orphaned') then
    raise exception 'p_status must be pending, posted, void or orphaned' using errcode = '22023';
  end if;
  if p_source is not null and p_source not in ('sms', 'statement', 'both') then
    raise exception 'p_source must be sms, statement or both' using errcode = '22023';
  end if;

  select jsonb_build_object(
           'txn_count', count(*),
           'net_aed', coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)
                                 filter (where t.status <> 'void'), 0)::numeric(14,2)::text,
           'unpriced_count', count(*) filter (where t.status <> 'void' and t.amount_aed is null),
           'has_estimate', coalesce(bool_or(t.amount_aed_is_estimate) filter (where t.status <> 'void'), false),
           'earliest_date', min(t.txn_date),
           'latest_date', max(t.txn_date))
  into v_out
  from public.v_transactions t
  where t.profile_code = p_profile_code
    and (p_from is null or t.txn_date >= p_from)
    and (p_to is null or t.txn_date <= p_to)
    and (p_account_code is null or t.account_code = p_account_code)
    and (p_card_code is null or t.card_code = p_card_code)
    and (case when coalesce(p_uncategorized, false) then t.category_code is null
              else p_category_code is null or t.category_code = p_category_code end)
    and (p_status is null or t.status = p_status)
    and (p_source is null
         or (p_source = 'sms' and t.has_sms and not t.has_statement)
         or (p_source = 'statement' and t.has_statement and not t.has_sms)
         or (p_source = 'both' and t.has_sms and t.has_statement))
    and (v_pattern is null or t.description ilike v_pattern or t.merchant_name ilike v_pattern);
  return v_out;
end;
$$;

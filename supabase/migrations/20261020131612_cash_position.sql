-- Phase 2d (tasks/todo.md §3): the screens' data.
--
-- 1. filter_meta lists bank accounts again, cards first, each with its kind and account_ref, so
--    Activity can filter by a bank account (2a hid them until their transactions existed).
-- 2. cash_position(profile): every active bank account's balance, as of when, and the AED total,
--    for Overview's cash tile and the Accounts list. Money as decimal strings (§1.3).

create or replace function public.filter_meta(p_profile_code text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('account_code', a.account_code, 'bank_code', a.bank_code,
                  'nickname', a.nickname, 'product_name', a.product_name, 'kind', a.kind,
                  'account_ref', a.account_ref) order by a.kind = 'credit_card' desc, a.bank_code, a.nickname nulls last, a.account_code)
                from public.accounts a where a.profile_code = p_profile_code), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('card_code', c.card_code, 'account_code', c.account_code,
                  'bank_code', c.bank_code, 'last4', c.last4, 'is_supplementary', c.is_supplementary) order by c.bank_code, c.last4)
                from public.cards c where c.profile_code = p_profile_code), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('category_code', c.category_code, 'name', c.name,
                  'kind', c.kind, 'color_token', c.color_token, 'parent_code', c.parent_code, 'archived', c.archived_at is not null)
                  order by c.sort_order, c.name)
                from public.categories c where c.profile_code = p_profile_code), '[]'::jsonb),
    'banks', coalesce((select jsonb_agg(jsonb_build_object('bank_code', b.bank_code, 'name', b.name,
                  'logo_path', b.logo_path) order by b.bank_code)
                from public.banks b), '[]'::jsonb),
    'date_range', (select jsonb_build_object('min', min(txn_date), 'max', max(txn_date))
                from public.transactions where profile_code = p_profile_code)
  )
$$;

create or replace function public.cash_position(p_profile_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  select jsonb_build_object(
           -- The total counts AED balances only; complete says whether that is every account.
           'total_aed', coalesce(sum(b.balance_aed), 0)::numeric(14,2)::text,
           'complete', coalesce(bool_and(b.balance_aed is not null and b.unpriced_count = 0), true),
           'stale_count', count(*) filter (where b.is_stale)::int,
           'missing_count', count(*) filter (where b.balance is null)::int,
           'as_of', min(b.as_of),
           'accounts', coalesce(jsonb_agg(jsonb_build_object(
               'account_code', a.account_code, 'bank_code', a.bank_code, 'kind', a.kind,
               'nickname', a.nickname, 'account_ref', a.account_ref, 'currency', a.currency,
               'balance', b.balance::text, 'balance_aed', b.balance_aed::text,
               'as_of', b.as_of, 'anchor_source', b.anchor_source,
               'is_stale', b.is_stale, 'unpriced_count', b.unpriced_count)
             order by a.bank_code, a.nickname nulls last, a.account_code), '[]'::jsonb))
  into v_out
  from public.accounts a
  join public.v_bank_balances b on b.account_code = a.account_code
  where a.profile_code = p_profile_code and a.status = 'active';
  return v_out;
end;
$$;
comment on function public.cash_position(text) is
  'Member: active bank accounts with balance (latest checkpoint + later activity), as_of and staleness, and the AED total. Phase 2d.';
grant execute on function public.cash_position(text) to authenticated, service_role;

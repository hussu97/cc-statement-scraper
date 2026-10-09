-- LLM categorisation tuning (worker llm_categorize):
--   * batches of 100 merchants (was 25): the category list is sent once per call, and the
--     worker now sends short refs (m1…, c1…) instead of codes, so a call stays small.
--   * a suggestion made against an older category set is re-asked only when it can change:
--     its category was archived or edited after the suggestion, or its confidence is < 0.8.
--     Before, ANY category change re-asked every LLM-categorised merchant. Declined merchants
--     are still re-asked on a category-set change (a new category may fit them).
--   * worker_llm_context sends up to 3 DISTINCT example descriptions (it took 3 rows, then
--     de-duplicated, so often sent one), skipping ones equal to the merchant name.

create or replace function private.enqueue_llm_categorize()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  p text;
  v_hash text;
  v_batch text[];
  v_count integer := 0;
  v_state text;
  v_msg text;
begin
  for p in select profile_code from public.profiles loop
    begin
      v_hash := private.category_set_hash(p);
      for v_batch in
        select array_agg(merchant_code) from (
          select merchant_code, (row_number() over (order by merchant_code) - 1) / 100 as grp
          from (
            select distinct t.merchant_code
            from public.transactions t
            left join public.merchant_profile_category mpc
              on mpc.profile_code = t.profile_code and mpc.merchant_code = t.merchant_code
            left join public.merchant_category_skips k
              on k.profile_code = t.profile_code and k.merchant_code = t.merchant_code
            left join public.categories c
              on c.profile_code = mpc.profile_code and c.category_code = mpc.category_code
            where t.profile_code = p and t.merchant_code is not null and t.rule_category_code is null
              and t.manual_category_code is null
              and (mpc.merchant_code is null
                   or (mpc.source = 'llm' and mpc.category_set_hash is distinct from v_hash
                       and (coalesce(mpc.confidence, 0) < 0.8
                            or c.archived_at is not null
                            or c.kind = 'ignore'
                            or c.updated_at > mpc.updated_at)))
              and not (k.reason is not distinct from 'rejected')
              and not (k.reason is not distinct from 'declined' and k.category_set_hash is not distinct from v_hash)
          ) m
        ) g group by grp
      loop
        perform pgmq.send('llm_categorize', jsonb_build_object('profile_code', p, 'merchant_codes', v_batch,
                                                               'category_set_hash', v_hash));
        v_count := v_count + 1;
      end loop;
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('enqueue_llm_categorize', p, null, v_state, v_msg);
    end;
  end loop;
  return v_count;
end;
$$;

create or replace function public.worker_llm_context(p_profile_code text, p_merchant_codes text[])
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.assert_service_role();

  select jsonb_build_object(
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('category_code', c.category_code, 'name', c.name,
                     'kind', c.kind) order by c.sort_order, c.name), '[]'::jsonb)
                   from public.categories c
                   where c.profile_code = p_profile_code and c.archived_at is null and c.kind <> 'ignore'),
    'merchants', (select coalesce(jsonb_agg(jsonb_build_object('merchant_code', m.merchant_code,
                     'name', m.display_name,
                     'examples', (select jsonb_agg(x.description order by x.description) from (
                                    select distinct t.description from public.transactions t
                                    where t.merchant_code = m.merchant_code and t.profile_code = p_profile_code
                                      and upper(t.description) <> upper(m.display_name)
                                    order by t.description
                                    limit 3) x)) order by m.merchant_code), '[]'::jsonb)
                  from public.merchants m where m.merchant_code = any (p_merchant_codes)),
    'category_set_hash', private.category_set_hash(p_profile_code)
  )
$$;

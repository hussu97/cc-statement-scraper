-- One context read per review list (audit WEB-10r).
--
-- Each card on the web Review page loaded its own context with 1–3 queries (the statement line,
-- SMS, transaction or statement it is about; its candidate transactions; a proposed SMS format),
-- so a page of 100 reviews made up to 300 requests, and every realtime `transactions` event
-- refetched all of them. public.review_context returns the context of every review on a page in
-- one call, in the order the codes were given:
--
--   review_code  the review
--   line         statement_lines row     (subject_type 'statement_line'), else null
--   sms          sms_messages row without `body` (subject_type 'sms'); the body is loaded on
--                demand, as before
--   txn          v_transactions row      (subject_type 'transaction')
--   statement    statements row          (subject_type 'statement')
--   candidates   v_transactions rows of the review's candidate txn_codes, in candidate order;
--                codes that no longer exist are left out ([] when none)
--   template     the proposed SMS format of an unparsed_sms review (the client-visible columns of
--                sms_templates: never `examples`, never `scope_profile_code`)
--
-- A user RPC (§1.6–1.7): SECURITY DEFINER, search_path '', a member check in the body, and every
-- read filtered by p_profile_code. Codes of reviews in other profiles, or unknown codes, return
-- no row. At most 2000 codes (the largest page size, X-07).

create function public.review_context(p_profile_code text, p_review_codes text[])
returns table (review_code text, line jsonb, sms jsonb, txn jsonb, statement jsonb, candidates jsonb,
               template jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, false);
  if cardinality(p_review_codes) > 2000 then
    raise exception 'review_context takes at most 2000 review codes' using errcode = '22023';
  end if;

  return query
  select r.review_code,
         (select to_jsonb(l) from public.statement_lines l
          where r.subject_type = 'statement_line' and l.line_code = r.subject_code
            and l.profile_code = p_profile_code),
         (select to_jsonb(s) - 'body' from public.sms_messages s
          where r.subject_type = 'sms' and s.sms_code = r.subject_code and s.profile_code = p_profile_code),
         (select to_jsonb(t) from public.v_transactions t
          where r.subject_type = 'transaction' and t.txn_code = r.subject_code and t.profile_code = p_profile_code),
         (select to_jsonb(st) from public.statements st
          where r.subject_type = 'statement' and st.stmt_code = r.subject_code and st.profile_code = p_profile_code),
         coalesce((select jsonb_agg(to_jsonb(t) order by c.ord)
                   from jsonb_array_elements(case when jsonb_typeof(r.candidates) = 'array' then r.candidates
                                                  else '[]'::jsonb end) with ordinality c(cand, ord)
                   join public.v_transactions t
                     on t.txn_code = c.cand->>'txn_code' and t.profile_code = p_profile_code), '[]'::jsonb),
         (select jsonb_build_object(
                   'template_code', tp.template_code, 'bank_code', tp.bank_code, 'name', tp.name,
                   'sender_pattern', tp.sender_pattern, 'body_pattern', tp.body_pattern,
                   'field_groups', tp.field_groups, 'date_format', tp.date_format, 'msg_kind', tp.msg_kind,
                   'priority', tp.priority, 'active', tp.active, 'version', tp.version, 'source', tp.source,
                   'created_at', tp.created_at, 'updated_at', tp.updated_at)
          from public.sms_templates tp
          where r.reason = 'unparsed_sms'
            and tp.template_code = (select c.cand->>'template_code'
                                    from jsonb_array_elements(case when jsonb_typeof(r.candidates) = 'array'
                                                                   then r.candidates else '[]'::jsonb end)
                                         with ordinality c(cand, ord)
                                    where c.cand ? 'template_code'
                                    order by c.ord limit 1))
  from unnest(p_review_codes) with ordinality q(code, ord)
  join public.match_reviews r on r.review_code = q.code and r.profile_code = p_profile_code
  order by q.ord;
end;
$$;
grant execute on function public.review_context(text, text[]) to authenticated, service_role;

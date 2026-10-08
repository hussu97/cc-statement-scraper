-- Categorisation and batch jobs from the audit backlog (docs/audit/BACKLOG.md):
--   DB-24   short seed rules match whole words (REST, NOON, LIME, HEALTH, BONUS)
--   DP-09   MURABAHA PROFIT / BONUS are Cashback only as credits (a finance charge is spend)
--   DB-25   cron batch jobs isolate errors per profile (private.job_errors)
--   DB-29r  generate_insights produces spend_pace, new_recurring, large_transaction, review_backlog
--   DB-31   preview_rule mirrors recategorize's tie-break and can exclude the rule being edited
--   DB-37 / WEB-14  merchants the LLM declined, and suggestions the owner rejected, are not
--           re-asked every night (public.merchant_category_skips)

-- ── DB-24 / DP-09: seed rules ───────────────────────────────────────────────
alter table private.seed_rules
  add column match_type text not null default 'contains' check (match_type in ('exact', 'prefix', 'contains', 'regex')),
  add column conditions jsonb not null default '{}'::jsonb;

create temp table _seed_fix (category_name text, old_pattern text, new_type text, new_pattern text, new_conditions jsonb);
insert into _seed_fix values
  -- 'REST' matched INTEREST, FOREST; keep REST, RESTO, RESTAURANT(S)
  ('Dining', 'REST', 'regex', '\mREST(AURANT[A-Z]*|O)?\M', '{}'),
  -- 'NOON' matched AFTERNOON
  ('Shopping', 'NOON', 'regex', '\mNOON\M', '{}'),
  -- 'LIME' matched SUBLIME
  ('Entertainment', 'LIME', 'regex', '\mLIME\M', '{}'),
  -- 'HEALTH' matched mid-word; keep HEALTH, HEALTHCARE
  ('Medicine', 'HEALTH', 'regex', '\mHEALTH', '{}'),
  -- Cashback is income: only a credit is a bonus or profit paid to the card (DP-09)
  ('Cashback', 'BONUS', 'regex', '\mBONUS\M', '{"direction":"credit"}'),
  ('Cashback', 'MURABAHA PROFIT', 'contains', 'MURABAHA PROFIT', '{"direction":"credit"}');

update private.seed_rules r set match_type = f.new_type, pattern = f.new_pattern, conditions = f.new_conditions
from _seed_fix f
where r.category_name = f.category_name and r.pattern = f.old_pattern and r.match_type = 'contains';

-- Existing profiles: only seed rules still exactly as seeded (content migration, guarded).
update public.category_rules r set match_type = f.new_type, pattern = f.new_pattern, conditions = f.new_conditions
from _seed_fix f, public.categories c
where c.profile_code = r.profile_code and c.category_code = r.category_code and c.name = f.category_name
  and r.source = 'seed' and r.match_type = 'contains' and r.pattern = f.old_pattern and r.conditions = '{}'::jsonb;
drop table _seed_fix;

create or replace function private.seed_profile_defaults(p_profile_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.categories where profile_code = p_profile_code) then
    return;
  end if;
  insert into public.categories (profile_code, name, kind, sort_order, color_token)
  select p_profile_code, name, kind, sort_order, color_token from private.seed_categories;
  insert into public.category_rules (profile_code, category_code, name, match_type, pattern, conditions, source)
  select p_profile_code, c.category_code,
         'seed: ' || regexp_replace(r.pattern, '\\[mM]|\(.*\)\?', '', 'g'), r.match_type, r.pattern, r.conditions, 'seed'
  from private.seed_rules r
  join public.categories c on c.profile_code = p_profile_code and c.name = r.category_name;
end;
$$;

-- ── DB-25: per-profile error isolation for batch jobs ───────────────────────
create table private.job_errors (
  job_error_code text primary key default public.gen_code('jer')
    check (job_error_code ~ '^jer_[0-9a-z]{26}$'),
  job text not null,
  profile_code text,          -- opaque code; no FK so a deleted profile keeps its history
  subject_code text,          -- e.g. the transaction a per-row job failed on
  sqlstate text,
  message text,
  created_at timestamptz not null default now()
);
create index job_errors_created_idx on private.job_errors (created_at);
revoke all on private.job_errors from public, anon, authenticated;

create or replace function private.log_job_error(p_job text, p_profile text, p_subject text, p_sqlstate text,
                                                 p_message text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise warning '% failed for % % (%): %', p_job, coalesce(p_profile, '-'), coalesce(p_subject, ''), p_sqlstate,
    left(p_message, 300);
  insert into private.job_errors (job, profile_code, subject_code, sqlstate, message)
  values (p_job, p_profile, p_subject, p_sqlstate, left(p_message, 500));
  delete from private.job_errors where created_at < now() - interval '30 days';
end;
$$;

create or replace function private.nightly(p_profile_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p text;
  v_void int;
  v_out jsonb := '{}'::jsonb;
  v_state text;
  v_msg text;
begin
  begin
    v_void := private.void_released_authorisations();
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    perform private.log_job_error('nightly.void_released_authorisations', null, null, v_state, v_msg);
  end;
  for p in select profile_code from public.profiles where p_profile_code is null or profile_code = p_profile_code loop
    begin
      v_out := v_out || jsonb_build_object(p, jsonb_build_object(
        'recurring', private.detect_recurring(p),
        'insights', private.generate_insights(p)
      ));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('nightly', p, null, v_state, v_msg);
      v_out := v_out || jsonb_build_object(p, jsonb_build_object('error', v_state));
    end;
  end loop;
  return v_out || jsonb_build_object('voided', v_void);
end;
$$;

create or replace function private.recategorize_stale()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_total integer := 0;
  v_state text;
  v_msg text;
begin
  for r in
    select distinct t.profile_code
    from public.transactions t
    join public.profile_state s on s.profile_code = t.profile_code
    where t.rules_version < s.rules_version
  loop
    begin
      v_total := v_total + private.recategorize(r.profile_code, null);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('recategorize_stale', r.profile_code, null, v_state, v_msg);
    end;
  end loop;
  return v_total;
end;
$$;

create or replace function private.reestimate_pending_fx()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_count integer := 0;
  v_state text;
  v_msg text;
begin
  for r in
    select t.txn_code, t.profile_code from public.transactions t
    where t.status = 'pending' and (t.amount_aed is null or t.amount_aed_is_estimate)
    order by t.txn_code
  loop
    begin
      perform private.refresh_transaction(r.txn_code);
      v_count := v_count + 1;
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      perform private.log_job_error('reestimate_pending_fx', r.profile_code, r.txn_code, v_state, v_msg);
    end;
  end loop;
  return v_count;
end;
$$;

-- ── DB-37 / WEB-14: merchants not to ask the LLM about again ────────────────
-- 'declined': the LLM was asked and gave no confident answer for this category
-- set (re-asked once the profile's categories change). 'rejected': an owner
-- rejected the suggestion (never re-asked; the owner can still categorise).
create table public.merchant_category_skips (
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  merchant_code text not null references public.merchants(merchant_code) on delete cascade,
  reason text not null check (reason in ('declined', 'rejected')),
  category_set_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (profile_code, merchant_code)
);
create trigger merchant_category_skips_touch before update on public.merchant_category_skips
  for each row execute function private.touch_updated_at();
alter table public.merchant_category_skips enable row level security;
create policy merchant_category_skips_member_read on public.merchant_category_skips for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.merchant_category_skips to authenticated;
grant all on public.merchant_category_skips to service_role;

-- Owner rejects an LLM suggestion: drop it and remember not to ask again.
create or replace function public.reject_merchant_suggestion(p_profile_code text, p_merchant_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, true);
  if not exists (select 1 from public.merchants m where m.merchant_code = p_merchant_code) then
    raise exception 'unknown merchant %', p_merchant_code using errcode = 'P0002';
  end if;
  delete from public.merchant_profile_category
  where profile_code = p_profile_code and merchant_code = p_merchant_code and source = 'llm';
  insert into public.merchant_category_skips (profile_code, merchant_code, reason, category_set_hash)
  values (p_profile_code, p_merchant_code, 'rejected', private.category_set_hash(p_profile_code))
  on conflict (profile_code, merchant_code) do update
    set reason = 'rejected', category_set_hash = excluded.category_set_hash;
end;
$$;

-- p_merchant_codes: the merchants the LLM was asked about. Any of them without an
-- accepted suggestion (missing or confidence < 0.5) is recorded as declined for
-- this category set. Optional, so the old 4-argument call keeps working.
drop function if exists public.apply_llm_suggestions(text, jsonb, text, text);
create or replace function public.apply_llm_suggestions(p_profile_code text, p_suggestions jsonb, p_model text,
                                                        p_category_set_hash text, p_merchant_codes text[] default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  perform private.assert_service_role();
  create temp table if not exists _llm_ok (merchant_code text primary key) on commit drop;
  truncate _llm_ok;

  with ins as (
    insert into public.merchant_profile_category (profile_code, merchant_code, category_code, source, confidence, model,
      category_set_hash)
    select p_profile_code, s->>'merchant_code', s->>'category_code', 'llm',
           least(greatest((s->>'confidence')::numeric, 0), 1), p_model, p_category_set_hash
    from jsonb_array_elements(p_suggestions) s
    where exists (select 1 from public.categories c
                  where c.profile_code = p_profile_code and c.category_code = s->>'category_code' and c.archived_at is null)
      and exists (select 1 from public.merchants m where m.merchant_code = s->>'merchant_code')
      and coalesce((s->>'confidence')::numeric, 0) >= 0.5
    on conflict (profile_code, merchant_code) do update set
      category_code = excluded.category_code, confidence = excluded.confidence, model = excluded.model,
      category_set_hash = excluded.category_set_hash
    where public.merchant_profile_category.source = 'llm'
    returning merchant_code
  )
  insert into _llm_ok select distinct merchant_code from ins;
  get diagnostics v_count = row_count;

  delete from public.merchant_category_skips k
  where k.profile_code = p_profile_code and k.reason = 'declined'
    and k.merchant_code in (select merchant_code from _llm_ok);

  insert into public.merchant_category_skips (profile_code, merchant_code, reason, category_set_hash)
  select distinct p_profile_code, x.merchant_code, 'declined', p_category_set_hash
  from (select unnest(coalesce(p_merchant_codes, '{}')) as merchant_code
        union
        select s->>'merchant_code' from jsonb_array_elements(p_suggestions) s
        where coalesce((s->>'confidence')::numeric, 0) < 0.5) x
  where x.merchant_code is not null
    and x.merchant_code not in (select merchant_code from _llm_ok)
    and exists (select 1 from public.merchants m where m.merchant_code = x.merchant_code)
    and not exists (select 1 from public.merchant_profile_category mpc
                    where mpc.profile_code = p_profile_code and mpc.merchant_code = x.merchant_code)
  on conflict (profile_code, merchant_code) do update
    set category_set_hash = excluded.category_set_hash
    where public.merchant_category_skips.reason = 'declined';
  return v_count;
end;
$$;

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
          select merchant_code, (row_number() over (order by merchant_code) - 1) / 25 as grp
          from (
            select distinct t.merchant_code
            from public.transactions t
            left join public.merchant_profile_category mpc
              on mpc.profile_code = t.profile_code and mpc.merchant_code = t.merchant_code
            left join public.merchant_category_skips k
              on k.profile_code = t.profile_code and k.merchant_code = t.merchant_code
            where t.profile_code = p and t.merchant_code is not null and t.rule_category_code is null
              and t.manual_category_code is null
              and (mpc.merchant_code is null or (mpc.source = 'llm' and mpc.category_set_hash is distinct from v_hash))
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

-- ── DB-31: preview_rule mirrors recategorize ────────────────────────────────
-- A matched transaction would change when no manual choice outranks the rule
-- and the previewed rule beats the best *other* active rule under recategorize's
-- full order: priority, longer pattern, exact > prefix > contains > regex, code.
-- p_rule_code is the rule being edited: it is left out of the competition and
-- keeps its own code for the final tie-break (a new rule loses exact ties, as
-- its code sorts after every existing one).
drop function if exists public.preview_rule(text, text, text, text, jsonb, integer);
create or replace function public.preview_rule(p_profile_code text, p_match_type text, p_pattern text,
                                               p_category_code text, p_conditions jsonb default '{}'::jsonb,
                                               p_priority integer default 100, p_rule_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pattern text := upper(btrim(p_pattern));
  v_conditions jsonb := coalesce(p_conditions, '{}'::jsonb);
  v_rank int := case p_match_type when 'exact' then 0 when 'prefix' then 1 when 'contains' then 2 else 3 end;
  v_problem text;
  v_matched integer;
  v_changed integer;
  v_sample jsonb;
begin
  perform private.assert_member(p_profile_code, false);
  if p_match_type not in ('exact', 'prefix', 'contains', 'regex') then
    raise exception 'invalid rule: unknown match type %', p_match_type using errcode = '22023';
  end if;
  v_problem := private.rule_problem(p_profile_code, p_match_type, p_pattern, v_conditions);
  if v_problem is not null then
    raise exception 'invalid rule: %', v_problem using errcode = '22023';
  end if;

  with m as (
    select t.txn_code, t.description, t.amount_aed, t.txn_date, t.effective_category_code,
           t.manual_category_code, t.merchant_category_source, t.kind, t.direction, t.currency_original,
           t.card_code, a.bank_code
    from public.transactions t
    join public.accounts a on a.profile_code = t.profile_code and a.account_code = t.account_code
    where t.profile_code = p_profile_code
      and case p_match_type
            when 'exact' then t.description = v_pattern
            when 'prefix' then starts_with(t.description, v_pattern)
            when 'contains' then strpos(t.description, v_pattern) > 0
            else t.description ~* p_pattern
          end
      and (not v_conditions ? 'amount_min' or t.amount_aed >= private.safe_numeric(v_conditions->>'amount_min'))
      and (not v_conditions ? 'amount_max' or t.amount_aed <= private.safe_numeric(v_conditions->>'amount_max'))
      and (not v_conditions ? 'bank_code' or a.bank_code = v_conditions->>'bank_code')
      and (not v_conditions ? 'card_code' or t.card_code = v_conditions->>'card_code')
      and (not v_conditions ? 'currency' or t.currency_original = v_conditions->>'currency')
      and (not v_conditions ? 'kind' or t.kind = v_conditions->>'kind')
      and (not v_conditions ? 'direction' or t.direction = v_conditions->>'direction')
  ),
  scored as (
    select m.*, b.priority as b_priority, b.len as b_len, b.rank as b_rank, b.rule_code as b_code
    from m
    left join lateral (
      select r.priority, length(r.pattern_upper) as len,
             case r.match_type when 'exact' then 0 when 'prefix' then 1 when 'contains' then 2 else 3 end as rank,
             r.rule_code
      from public.category_rules r
      where r.profile_code = p_profile_code and r.active
        and r.rule_code is distinct from p_rule_code
        and case r.match_type
              when 'exact' then m.description = r.pattern_upper
              when 'prefix' then starts_with(m.description, r.pattern_upper)
              when 'contains' then strpos(m.description, r.pattern_upper) > 0
              else m.description ~* r.pattern
            end
        and (not r.conditions ? 'amount_min' or m.amount_aed >= private.safe_numeric(r.conditions->>'amount_min'))
        and (not r.conditions ? 'amount_max' or m.amount_aed <= private.safe_numeric(r.conditions->>'amount_max'))
        and (not r.conditions ? 'bank_code' or m.bank_code = r.conditions->>'bank_code')
        and (not r.conditions ? 'card_code' or m.card_code = r.conditions->>'card_code')
        and (not r.conditions ? 'currency' or m.currency_original = r.conditions->>'currency')
        and (not r.conditions ? 'kind' or m.kind = r.conditions->>'kind')
        and (not r.conditions ? 'direction' or m.direction = r.conditions->>'direction')
      order by r.priority, length(r.pattern_upper) desc,
               case r.match_type when 'exact' then 0 when 'prefix' then 1 when 'contains' then 2 else 3 end,
               r.rule_code
      limit 1
    ) b on true
  ),
  totals as (
    select count(*)::int as matched,
           count(*) filter (
             where manual_category_code is null
               and coalesce(merchant_category_source, '') <> 'manual'
               and (b_code is null
                    or (p_priority, -length(v_pattern), v_rank) < (b_priority, -b_len, b_rank)
                    or ((p_priority, -length(v_pattern), v_rank) = (b_priority, -b_len, b_rank)
                        and p_rule_code is not null and p_rule_code < b_code))
               and effective_category_code is distinct from p_category_code
           )::int as would_change
    from scored
  ),
  sample as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'txn_code', s.txn_code, 'description', s.description, 'amount_aed', s.amount_aed::text,
             'txn_date', s.txn_date, 'current_category_code', s.effective_category_code
           ) order by s.txn_date desc, s.txn_code desc), '[]'::jsonb) as rows
    from (select * from m order by txn_date desc, txn_code desc limit 20) s
  )
  select totals.matched, totals.would_change, sample.rows
  into v_matched, v_changed, v_sample
  from totals, sample;

  return jsonb_build_object('matched', v_matched, 'would_change', v_changed, 'sample', v_sample);
end;
$$;

-- ── DB-29r: the remaining insight kinds ─────────────────────────────────────
CREATE OR REPLACE FUNCTION private.generate_insights(p_profile_code text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_today date := public.dubai_date(now());
  v_month date := date_trunc('month', v_today)::date;
  v_day int := extract(day from v_today)::int;
  v_days_in_month int := extract(day from ((v_month + interval '1 month')::date - 1))::int;
  v_count int := 0;
  n int;
begin
  -- Category spending ahead of its usual pace this month.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'category_spike', case when cur > base * 2 then 'alert' else 'warn' end,
         x.category_code || ':' || v_month,
         x.name || ' is running ' || round((cur / base - 1) * 100) || '% above usual',
         'You''ve spent ' || private.fmt_aed(cur) || ' on ' || x.name || ' so far this month, against a typical '
           || private.fmt_aed(base) || ' by day ' || v_day || '.',
         jsonb_build_object('category_code', x.category_code, 'current', cur::text, 'baseline', base::text),
         (v_month + interval '1 month')::date - 1
  from (
    select s.category_code, c.name,
           sum(s.spend_aed) filter (where s.txn_date >= v_month) as cur,
           sum(s.spend_aed) filter (where s.txn_date < v_month
                                      and extract(day from s.txn_date) <= v_day) / 3 as base
    from public.v_spend s join public.categories c on c.category_code = s.category_code
    where s.profile_code = p_profile_code and s.txn_date >= (v_month - interval '3 month')::date
    group by s.category_code, c.name
  ) x
  where x.base > 0 and x.cur > x.base * 1.3 and x.cur - x.base > 200
  on conflict (profile_code, kind, dedupe_key) do update
    set title = excluded.title, body = excluded.body, data = excluded.data, severity = excluded.severity;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Budgets projected to overrun.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'budget_risk', case when b.share_used >= 1 then 'alert' else 'warn' end,
         coalesce(b.category_code, 'total') || ':' || v_month,
         b.category_name || case when b.share_used >= 1 then ' budget exceeded' else ' budget at risk' end,
         private.fmt_aed(b.spent_aed) || ' of ' || private.fmt_aed(b.budget_aed) || ' spent; on pace for '
           || private.fmt_aed(b.projected_aed) || ' this month.',
         jsonb_build_object('budget_code', b.budget_code, 'spent', b.spent_aed::text, 'projected', b.projected_aed::text),
         (v_month + interval '1 month')::date - 1
  from public.budget_status(p_profile_code, v_month) b
  where b.projected_aed > b.budget_aed and v_day >= 5
  on conflict (profile_code, kind, dedupe_key) do update
    set title = excluded.title, body = excluded.body, data = excluded.data, severity = excluded.severity;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Subscription price changes.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data)
  select p_profile_code, 'price_change', 'info', r.recurring_code || ':' || r.last_date,
         m.display_name || ' changed price',
         m.display_name || ' charged ' || private.fmt_aed(r.last_amount) || ', usually ' || private.fmt_aed(r.expected_amount) || '.',
         jsonb_build_object('recurring_code', r.recurring_code)
  from public.recurring_series r join public.merchants m on m.merchant_code = r.merchant_code
  where r.profile_code = p_profile_code and r.status = 'active' and r.last_date >= v_today - 14
    and abs(r.last_amount - r.expected_amount) > greatest(r.expected_amount * 0.05, 1)
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Statements due soon.
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'statement_due', case when st.due_date - v_today <= 2 then 'alert' else 'warn' end,
         st.stmt_code,
         a.bank_code || ' payment due ' || to_char(st.due_date, 'FMDD Mon'),
         coalesce('Closing balance ' || private.fmt_aed(st.closing_balance), 'Statement')
           || coalesce(', minimum due ' || private.fmt_aed(st.min_due), '') || '.',
         jsonb_build_object('stmt_code', st.stmt_code, 'due_date', st.due_date),
         st.due_date
  from public.statements st join public.accounts a on a.account_code = st.account_code
  where st.profile_code = p_profile_code and st.kind = 'statement' and st.status = 'active'
    and st.due_date between v_today and v_today + 5
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Housekeeping nudges.
  select count(*) into n from public.v_spend
  where profile_code = p_profile_code and category_code is null and txn_date >= v_today - 30;
  if n >= 10 then
    insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
    values (p_profile_code, 'uncategorized', 'info', to_char(v_today, 'IYYY-IW'),
            n || ' transactions need a category', 'Categorise them once and set a rule so it sticks.',
            jsonb_build_object('count', n), v_today + 7)
    on conflict (profile_code, kind, dedupe_key) do update set title = excluded.title, data = excluded.data;
    v_count := v_count + 1;
  end if;

  -- Total spend ahead of its usual pace this month (DB-29r).
  if v_day >= 5 then
    insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
    select p_profile_code, 'spend_pace', case when x.cur > x.base * 1.5 then 'alert' else 'warn' end,
           v_month::text,
           'Spending is ' || round((x.cur / x.base - 1) * 100) || '% ahead of your usual pace',
           private.fmt_aed(x.cur) || ' spent by day ' || v_day || ', against a typical ' || private.fmt_aed(x.base)
             || '; on pace for ' || private.fmt_aed(round(x.cur / v_day * v_days_in_month, 2)) || ' this month.',
           jsonb_build_object('current', x.cur::text, 'baseline', x.base::text,
                              'projected', round(x.cur / v_day * v_days_in_month, 2)::text),
           (v_month + interval '1 month')::date - 1
    from (
      select sum(s.spend_aed) filter (where s.txn_date >= v_month) as cur,
             round(sum(s.spend_aed) filter (where s.txn_date < v_month
                                              and extract(day from s.txn_date) <= v_day) / 3, 2) as base
      from public.v_spend s
      where s.profile_code = p_profile_code and s.txn_date >= (v_month - interval '3 month')::date
    ) x
    where x.base > 0 and x.cur > x.base * 1.25 and x.cur - x.base > 500
    on conflict (profile_code, kind, dedupe_key) do update
      set title = excluded.title, body = excluded.body, data = excluded.data, severity = excluded.severity;
    get diagnostics n = row_count; v_count := v_count + n;
  end if;

  -- Newly detected subscriptions (DB-29r).
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'new_recurring', 'info', r.recurring_code,
         'New ' || r.cadence || ' charge: ' || m.display_name,
         m.display_name || ' has charged about ' || private.fmt_aed(r.expected_amount) || ' ' || r.occurrences
           || ' times; next expected ' || to_char(r.next_expected, 'FMDD Mon') || '.',
         jsonb_build_object('recurring_code', r.recurring_code, 'merchant_code', r.merchant_code),
         v_today + 14
  from public.recurring_series r join public.merchants m on m.merchant_code = r.merchant_code
  where r.profile_code = p_profile_code and r.status = 'active' and r.detected_by = 'auto'
    and r.created_at >= now() - interval '7 days'
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Unusually large charges of the last three days, from public.anomalies (DB-29r).
  insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
  select p_profile_code, 'large_transaction', 'warn', a.txn_code,
         'Unusually large: ' || initcap(lower(left(a.description, 40))),
         private.fmt_aed(a.amount) || case when a.reason = 'new_merchant_large' then ' at a merchant you haven''t used before.'
                                        else ', usually about ' || private.fmt_aed(a.baseline_mean) || '.' end,
         jsonb_build_object('txn_code', a.txn_code, 'amount', a.amount::text, 'reason', a.reason),
         v_today + 14
  from public.anomalies(p_profile_code, v_today - 3, v_today) a
  on conflict (profile_code, kind, dedupe_key) do nothing;
  get diagnostics n = row_count; v_count := v_count + n;

  -- Review backlog nudge (DB-29r).
  select count(*) into n from public.match_reviews where profile_code = p_profile_code and status = 'open';
  if n >= 10 then
    insert into public.insights (profile_code, kind, severity, dedupe_key, title, body, data, valid_until)
    values (p_profile_code, 'review_backlog', 'info', to_char(v_today, 'IYYY-IW'),
            n || ' items to review', 'Some statement lines and messages need a decision before they count.',
            jsonb_build_object('count', n), v_today + 7)
    on conflict (profile_code, kind, dedupe_key) do update set title = excluded.title, data = excluded.data;
    v_count := v_count + 1;
  end if;

  delete from public.insights where profile_code = p_profile_code and valid_until < v_today;
  return v_count;
end;
$function$;

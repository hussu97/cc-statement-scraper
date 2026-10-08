-- Audit fixes (docs/audit/01-database.md, 02-data-parity.md, 06-cross-cutting.md):
--
--   DB-04  merchants / merchant_aliases / sms_templates are no longer readable by
--          any signed-in stranger. Merchants: only those the caller's profiles
--          reference. Templates: bank formats for the caller's banks, templates
--          their messages used, and proposals made for their messages; the
--          `examples` column (LLM proposals embed a user's raw SMS) is not
--          readable by clients at all.
--   DB-05  the legacy import never adopts a profile it did not create
--          (private.legacy_import_profiles records provenance)
--   DB-11 / X-02 / DP-05  legacy_parity_report casts the legacy varchar columns and
--          reports line-level losses (legacy fingerprints with no current v2 line)
--   DB-12  legacy category choices are evaluated at most once per transaction and
--          never re-applied over a later user edit; the nightly job stops itself
--          when nothing is left or 30 days after staging; unmatched choices are
--          reported by private.legacy_unmatched_choices()
--   ops    pg_cron run history older than 7 days is purged nightly

-- ── DB-04: merchants ────────────────────────────────────────────────────────
drop policy merchants_read on public.merchants;
create policy merchants_member_read on public.merchants for select to authenticated
  using (
    merchant_code in (select t.merchant_code from public.transactions t
                      where t.profile_code = any ((select authz.my_profile_codes())::text[]))
    or merchant_code in (select m.merchant_code from public.merchant_profile_category m
                         where m.profile_code = any ((select authz.my_profile_codes())::text[]))
    or merchant_code in (select r.merchant_code from public.recurring_series r
                         where r.profile_code = any ((select authz.my_profile_codes())::text[]))
  );

drop policy merchant_aliases_read on public.merchant_aliases;
create policy merchant_aliases_member_read on public.merchant_aliases for select to authenticated
  using (merchant_code in (select m.merchant_code from public.merchants m));  -- merchants' own RLS applies

-- ── DB-04: SMS templates ────────────────────────────────────────────────────
drop policy sms_templates_read on public.sms_templates;
create policy sms_templates_member_read on public.sms_templates for select to authenticated
  using (
    (source <> 'llm' and bank_code in (select a.bank_code from public.accounts a
                                       where a.profile_code = any ((select authz.my_profile_codes())::text[])))
    or template_code in (select s.template_code from public.sms_messages s
                         where s.profile_code = any ((select authz.my_profile_codes())::text[])
                           and s.template_code is not null)
    or exists (select 1 from public.match_reviews r
               where r.profile_code = any ((select authz.my_profile_codes())::text[])
                 and r.reason = 'unparsed_sms'
                 and r.candidates @> jsonb_build_array(jsonb_build_object('template_code', sms_templates.template_code)))
  );
-- Table privilege, not EXECUTE: column grants hide `examples` from clients.
revoke select on public.sms_templates from authenticated;
grant select (template_code, bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind,
              priority, active, version, source, created_at, updated_at)
  on public.sms_templates to authenticated;

-- ── DB-05: import provenance ────────────────────────────────────────────────
create table private.legacy_import_profiles (
  profile_code text primary key references public.profiles(profile_code) on delete cascade,
  legacy_key text not null unique,
  imported_at timestamptz not null default now()
);
-- Profiles an earlier import run already created (only the import and the
-- migration script write these rows).
insert into private.legacy_import_profiles (profile_code, legacy_key)
select p.profile_code, p.key from public.profiles p
where exists (select 1 from private.legacy_category_choices c where c.profile_code = p.profile_code)
   or exists (select 1 from public.category_rules r where r.profile_code = p.profile_code and r.source = 'legacy')
   or exists (select 1 from public.documents d where d.profile_code = p.profile_code and d.source = 'legacy')
on conflict do nothing;

-- ── DB-12: choices are evaluated once per transaction ──────────────────────
alter table private.legacy_category_choices add column staged_at timestamptz not null default now();
create index if not exists statement_lines_profile_legacy_fp_idx on public.statement_lines(profile_code, legacy_fingerprint)
  where legacy_fingerprint is not null;

create table private.legacy_choice_applications (
  profile_code text not null,
  txn_code text not null,
  legacy_fingerprint text not null,
  source text not null check (source in ('override', 'line')),
  outcome text not null check (outcome in ('applied', 'agreed', 'kept_manual')),
  category_code text,
  applied_at timestamptz not null default now(),
  primary key (profile_code, txn_code),
  foreign key (profile_code, txn_code) references public.transactions(profile_code, txn_code) on delete cascade
);
-- Transactions an earlier run already handled are never re-evaluated.
insert into private.legacy_choice_applications (profile_code, txn_code, legacy_fingerprint, source, outcome)
select distinct on (t.profile_code, t.txn_code) t.profile_code, t.txn_code, ch.legacy_fingerprint, ch.source, 'agreed'
from private.legacy_category_choices ch
join public.statement_lines l on l.profile_code = ch.profile_code and l.legacy_fingerprint = ch.legacy_fingerprint
                             and l.is_current
join public.transaction_evidence e on e.profile_code = l.profile_code and e.line_code = l.line_code and e.is_active
join public.transactions t on t.profile_code = e.profile_code and t.txn_code = e.txn_code
where ch.applied_at is not null
order by t.profile_code, t.txn_code, case ch.source when 'override' then 0 else 1 end
on conflict do nothing;

-- Apply staged legacy category choices to re-parsed transactions. Each
-- transaction is evaluated exactly once, the first time a choice meets it:
--   kept_manual  it already has a manual category
--   agreed       v2 already gives it that category (nothing frozen)
--   applied      manual_category_code := the legacy choice (an override always
--                wins over v2 rules; a plain legacy line category only where v2 disagrees)
-- A later user edit (e.g. "apply to merchant", which clears manual) is never undone.
create or replace function private.apply_legacy_category_choices()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  -- Lines first (materialized): joining choices to transactions on profile_code
  -- alone is a plan the planner otherwise likes, at ~10 s for 2.6k choices.
  -- Evidence and transactions share the line's profile by composite FK.
  with m as materialized (
    select ch.profile_code, ch.legacy_fingerprint, ch.source, ch.category_name, l.line_code
    from private.legacy_category_choices ch
    join public.statement_lines l on l.profile_code = ch.profile_code and l.legacy_fingerprint = ch.legacy_fingerprint
                                 and l.is_current
  ),
  cand as (
    select distinct on (t.profile_code, t.txn_code)
           t.profile_code, t.txn_code, c.category_code, m.legacy_fingerprint, m.source,
           case when t.manual_category_code is not null then 'kept_manual'
                when t.effective_category_code is not distinct from c.category_code then 'agreed'
                else 'applied' end as outcome
    from m
    join public.transaction_evidence e on e.line_code = m.line_code and e.is_active
    join public.transactions t on t.txn_code = e.txn_code
    join public.categories c on c.profile_code = m.profile_code and lower(c.name) = lower(m.category_name)
    where not exists (select 1 from private.legacy_choice_applications a
                      where a.profile_code = t.profile_code and a.txn_code = t.txn_code)
    order by t.profile_code, t.txn_code, case m.source when 'override' then 0 else 1 end
  ),
  rec as (
    insert into private.legacy_choice_applications (profile_code, txn_code, legacy_fingerprint, source, outcome,
                                                    category_code)
    select profile_code, txn_code, legacy_fingerprint, source, outcome, category_code from cand
    returning txn_code
  ),
  upd as (
    update public.transactions t set manual_category_code = cand.category_code
    from cand
    where t.profile_code = cand.profile_code and t.txn_code = cand.txn_code and cand.outcome = 'applied'
    returning t.txn_code
  )
  select count(*) into v_count from upd;

  -- A choice is done once it has met its line.
  update private.legacy_category_choices ch set applied_at = now()
  where ch.applied_at is null
    and exists (select 1 from public.statement_lines l
                where l.profile_code = ch.profile_code and l.legacy_fingerprint = ch.legacy_fingerprint and l.is_current);
  return v_count;
end;
$$;

-- Choices whose fingerprint never met a current v2 line: reported, not retried forever.
create or replace function private.legacy_unmatched_choices()
returns table (profile_key text, legacy_fingerprint text, category_name text, source text, staged_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select p.key, ch.legacy_fingerprint, ch.category_name, ch.source, ch.staged_at
  from private.legacy_category_choices ch
  join public.profiles p on p.profile_code = ch.profile_code
  where ch.applied_at is null
  order by 1, 5, 2
$$;

-- The nightly job: apply, then stop once nothing is pending or 30 days after the
-- last staging (import_legacy_metadata schedules it again on a new import).
create or replace function private.legacy_choices_cron()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_applied integer;
begin
  v_applied := private.apply_legacy_category_choices();
  if not exists (select 1 from private.legacy_category_choices where applied_at is null)
     or not exists (select 1 from private.legacy_category_choices where staged_at > now() - interval '30 days') then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'ledger-legacy-choices';
  end if;
  return v_applied;
end;
$$;

select cron.unschedule(jobid) from cron.job where jobname = 'ledger-legacy-choices';
select cron.schedule('ledger-legacy-choices', '45 22 * * *', $$select private.legacy_choices_cron()$$);

-- ── import (DB-05; p_schema lets tests use a mock schema) ──────────────────
drop function private.import_legacy_metadata(jsonb);

-- p_member_emails: {"alice": "someone@example.com", ...} maps legacy profile
-- keys to the people who should own them in v2.
create or replace function private.import_legacy_metadata(
  p_member_emails jsonb default '{}'::jsonb, p_schema text default 'legacy'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_profile text;
  v_out jsonb := '{}'::jsonb;
  v_n int;
begin
  if to_regclass(format('%I.profiles', p_schema)) is null then
    return jsonb_build_object('skipped', 'no legacy schema');
  end if;

  for r in execute format('select id, key::text as key, name::text as name from %I.profiles order by id', p_schema) loop
    select profile_code into v_profile from public.profiles where key = r.key;
    if v_profile is null then
      insert into public.profiles (key, name) values (r.key, r.name) returning profile_code into v_profile;
      insert into private.legacy_import_profiles (profile_code, legacy_key) values (v_profile, r.key);
    elsif not exists (select 1 from private.legacy_import_profiles where profile_code = v_profile) then
      -- Someone created this key before the import ran: never adopt their profile.
      raise exception 'profile key % exists but was not created by the legacy import; resolve it manually first', r.key
        using errcode = '23505';
    end if;
    insert into public.profile_state (profile_code) values (v_profile) on conflict do nothing;
    perform private.seed_profile_defaults(v_profile);

    if p_member_emails ? r.key then
      insert into private.pending_members (profile_code, email, role)
      values (v_profile, lower(p_member_emails->>r.key), 'owner')
      on conflict (profile_code, email) do nothing;
      insert into public.profile_members (profile_code, user_id, role)
      select v_profile, u.id, 'owner' from auth.users u where lower(u.email) = lower(p_member_emails->>r.key)
      on conflict do nothing;
      delete from private.pending_members pm
      where pm.profile_code = v_profile
        and exists (select 1 from auth.users u where lower(u.email) = lower(pm.email));
    end if;

    -- Categories that exist in legacy but not in the v2 defaults.
    execute format($q$
      insert into public.categories (profile_code, name, kind, sort_order, color_token)
      select $1, c.name::text, 'spend', 500, 'cat-12'
      from %1$I.categories c
      where c.name::text <> 'Uncategorized'
        and not exists (select 1 from public.categories x where x.profile_code = $1 and lower(x.name) = lower(c.name::text))
      on conflict do nothing $q$, p_schema) using v_profile;

    -- User-created legacy rules (seed-* rules are already the v2 defaults).
    execute format($q$
      insert into public.category_rules (profile_code, category_code, name, match_type, pattern, active, source)
      select $1, c.category_code, lr.name::text, lr.match_type::text, lr.pattern::text, lr.active, 'legacy'
      from %1$I.category_rules lr
      join public.categories c on c.profile_code = $1 and lower(c.name) = lower(lr.category_name::text)
      where lr.name::text not like 'seed-%%'
        and not exists (select 1 from public.category_rules x
                        where x.profile_code = $1 and x.pattern = lr.pattern::text and x.match_type = lr.match_type::text) $q$,
      p_schema) using v_profile;
    get diagnostics v_n = row_count;

    -- Category choices to re-apply once the PDFs are re-parsed. Fingerprints are
    -- global in legacy; scope them through the line's statement → profile.
    execute format($q$
      insert into private.legacy_category_choices (profile_code, legacy_fingerprint, category_name, source)
      select distinct $1, l.fingerprint::text, coalesce(o.category_name, l.category_override)::text, 'override'
      from %1$I.statement_lines l
      join %1$I.statements s on s.id = l.statement_id
      left join %1$I.category_overrides o on o.fingerprint = l.fingerprint
      where s.profile_id = $2 and l.fingerprint is not null
        and coalesce(o.category_name, l.category_override) is not null
      on conflict do nothing $q$, p_schema) using v_profile, r.id;
    execute format($q$
      insert into private.legacy_category_choices (profile_code, legacy_fingerprint, category_name, source)
      select distinct on (l.fingerprint) $1, l.fingerprint::text, l.category::text, 'line'
      from %1$I.statement_lines l
      join %1$I.statements s on s.id = l.statement_id
      where s.profile_id = $2 and l.fingerprint is not null
        and l.category is not null and l.category::text <> 'Uncategorized'
      order by l.fingerprint, l.id desc
      on conflict do nothing $q$, p_schema) using v_profile, r.id;

    -- Email ingestion config (OAuth refresh tokens move to Vault via the script).
    execute format($q$
      insert into public.email_mailboxes (profile_code, provider, mailbox_email, enabled, sync_state)
      select $1, case m.provider::text when 'microsoft' then 'outlook' else m.provider::text end, m.mailbox_email::text,
             m.is_active, coalesce(m.sync_state_json::jsonb, '{}'::jsonb)
      from %1$I.email_mailboxes m where m.profile_id = $2
      on conflict (profile_code, provider, mailbox_email) do nothing $q$, p_schema) using v_profile, r.id;
    execute format($q$
      insert into public.email_routes (profile_code, mailbox_code, bank_code, enabled, sender_allowlist,
        subject_keywords, attachment_filename_regex, gmail_label_filter)
      select $1, nm.mailbox_code, rt.bank_code::text, rt.is_active,
             coalesce(array(select jsonb_array_elements_text(coalesce(rt.sender_allowlist_json::jsonb, '[]'))), '{}'),
             coalesce(array(select jsonb_array_elements_text(coalesce(rt.subject_keywords_json::jsonb, '[]'))), '{}'),
             rt.attachment_filename_regex::text,
             coalesce(array(select jsonb_array_elements_text(
               case jsonb_typeof(rt.gmail_label_filter_json::jsonb)
                 when 'array' then rt.gmail_label_filter_json::jsonb
                 when 'object' then coalesce(rt.gmail_label_filter_json::jsonb->'labels', '[]')
                 else '[]' end)), '{}')
      from %1$I.email_bank_routes rt
      join %1$I.email_mailboxes lm on lm.id = rt.mailbox_id
      join public.email_mailboxes nm on nm.profile_code = $1
                                     and nm.provider = case lm.provider::text when 'microsoft' then 'outlook' else lm.provider::text end
                                     and nm.mailbox_email = lm.mailbox_email::text
      where rt.profile_id = $2
      on conflict (profile_code, bank_code) do nothing $q$, p_schema) using v_profile, r.id;

    v_out := v_out || jsonb_build_object(r.key, jsonb_build_object(
      'profile_code', v_profile,
      'legacy_rules_imported', v_n,
      'category_choices', (select count(*) from private.legacy_category_choices where profile_code = v_profile)
    ));
  end loop;

  -- (Re)start the nightly job that applies choices as documents are re-parsed.
  perform cron.schedule('ledger-legacy-choices', '45 22 * * *', $c$select private.legacy_choices_cron()$c$);
  return v_out;
end;
$$;

-- ── parity (DB-11 / X-02 / DP-05) ───────────────────────────────────────────
-- Legacy columns are varchar / enums: everything is cast to the declared types.
-- legacy_lines_missing / legacy_aed_missing count legacy lines whose fingerprint
-- has no *current* v2 line in the same profile: a lost line, not a month delta.
drop function private.legacy_parity_report();

create or replace function private.legacy_parity_report(p_schema text default 'legacy')
returns table (profile_key text, bank_code text, month date, legacy_lines bigint, v2_lines bigint,
               legacy_aed numeric, v2_aed numeric, delta_aed numeric,
               legacy_lines_missing bigint, legacy_aed_missing numeric)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if to_regclass(format('%I.statement_lines', p_schema)) is null then
    return;
  end if;
  return query execute format($q$
    with ll as (
      select p.key::text as profile_key, s.bank_code::text as bank_code,
             date_trunc('month', sl.transaction_date)::date as month,
             coalesce(sl.amount_aed, 0)::numeric as aed,
             sl.fingerprint is not null and not exists (
               select 1 from public.statement_lines vl
               join public.profiles vp on vp.profile_code = vl.profile_code
               where vp.key = p.key::text and vl.legacy_fingerprint = sl.fingerprint::text and vl.is_current
             ) as missing
      from %1$I.statement_lines sl
      join %1$I.statements s on s.id = sl.statement_id
      join %1$I.profiles p on p.id = s.profile_id
    ),
    l as (
      select ll.profile_key, ll.bank_code, ll.month, count(*)::bigint as n, sum(ll.aed)::numeric as aed,
             count(*) filter (where ll.missing)::bigint as n_missing,
             coalesce(sum(ll.aed) filter (where ll.missing), 0)::numeric as aed_missing
      from ll group by 1, 2, 3
    ),
    v as (
      select p.key::text as profile_key, a.bank_code::text as bank_code, date_trunc('month', t.txn_date)::date as month,
             count(*)::bigint as n,
             sum(case when t.direction = 'debit' then coalesce(t.amount_aed, 0) else -coalesce(t.amount_aed, 0) end)::numeric as aed
      from public.transactions t
      join public.accounts a on a.profile_code = t.profile_code and a.account_code = t.account_code
      join public.profiles p on p.profile_code = t.profile_code
      where t.status = 'posted'
      group by 1, 2, 3
    )
    select coalesce(l.profile_key, v.profile_key), coalesce(l.bank_code, v.bank_code), coalesce(l.month, v.month),
           coalesce(l.n, 0)::bigint, coalesce(v.n, 0)::bigint, coalesce(l.aed, 0)::numeric, coalesce(v.aed, 0)::numeric,
           (coalesce(v.aed, 0) - coalesce(l.aed, 0))::numeric,
           coalesce(l.n_missing, 0)::bigint, coalesce(l.aed_missing, 0)::numeric
    from l full join v using (profile_key, bank_code, month)
    order by 1, 2, 3 $q$, p_schema);
end;
$$;

-- Line-level detail for the parity sign-off: each legacy line with no current
-- v2 line. Codes, dates and amounts only.
create or replace function private.legacy_missing_lines(p_schema text default 'legacy')
returns table (profile_key text, bank_code text, statement_date date, txn_date date, amount_aed numeric,
               direction text, legacy_fingerprint text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if to_regclass(format('%I.statement_lines', p_schema)) is null then
    return;
  end if;
  return query execute format($q$
    select p.key::text, s.bank_code::text, s.statement_date::date, sl.transaction_date::date,
           sl.amount_aed::numeric, sl.direction::text, sl.fingerprint::text
    from %1$I.statement_lines sl
    join %1$I.statements s on s.id = sl.statement_id
    join %1$I.profiles p on p.id = s.profile_id
    where sl.fingerprint is not null
      and not exists (select 1 from public.statement_lines vl
                      join public.profiles vp on vp.profile_code = vl.profile_code
                      where vp.key = p.key::text and vl.legacy_fingerprint = sl.fingerprint::text and vl.is_current)
    order by 1, 2, 4 $q$, p_schema);
end;
$$;

-- ── ops: keep pg_cron's run history bounded ────────────────────────────────
select cron.unschedule(jobid) from cron.job where jobname = 'ledger-cron-history-purge';
select cron.schedule('ledger-cron-history-purge', '50 23 * * *',
  $$delete from cron.job_run_details where coalesce(end_time, start_time) < now() - interval '7 days'$$);

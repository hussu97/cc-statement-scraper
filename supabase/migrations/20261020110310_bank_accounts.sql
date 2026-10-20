-- Phase 2a (tasks/todo.md §3): current and savings accounts next to the cards, and their balances.
--
-- 1. accounts.kind adds 'current' and 'savings'; account_ref is the masked suffix a bank prints
--    ("account number XXX310001" → '310001'). Card-only columns stay null on a bank account.
-- 2. balance_checkpoints: a balance as of a moment (entered by hand now; read from SMS in 2b).
--    Evidence: never updated, a correction is a newer checkpoint.
-- 3. v_bank_balances: the latest checkpoint plus the account's transactions after it, the same
--    anchor-then-activity rule as v_account_balances.
-- 4. create_bank_account / record_balance: owner-only RPCs.
-- 5. Every reader that assumes an account is a card now says so (kind = 'credit_card'):
--    v_account_balances, overview, filter_meta, resolve_review, the "bank has one active account"
--    fallbacks in process_sms, reprocess_waiting_sms, resolve_statement_account and
--    successor_card_account, and merge_accounts refuses to mix kinds.
--    supabase/tests/60_bank_accounts.test.sql lists every function that reads accounts, so a new
--    reader fails the build until it is classified.

-- ── 1. accounts ─────────────────────────────────────────────────────────────
alter table public.accounts drop constraint accounts_kind_check;
alter table public.accounts add constraint accounts_kind_check
  check (kind in ('credit_card', 'current', 'savings'));
alter table public.accounts add column account_ref text
  check (account_ref is null or account_ref ~ '^[0-9]{3,12}$');
comment on column public.accounts.account_ref is
  'Bank accounts: the unmasked digits the bank prints at the end of the account number in alerts (XXX310001 → 310001).';
alter table public.accounts add constraint accounts_card_columns_check
  check (kind = 'credit_card' or (credit_limit is null and cycle_close_day is null));
create unique index accounts_bank_ref_uq on public.accounts(profile_code, bank_code, account_ref)
  where account_ref is not null;

-- ── 2. balance_checkpoints ───────────────────────────────────────────────────
create table public.balance_checkpoints (
  checkpoint_code text primary key default public.gen_code('bal')
    check (checkpoint_code ~ '^bal_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  account_code text not null,
  as_of timestamptz not null,
  balance numeric(14,2) not null,                 -- in the account's currency
  source text not null check (source in ('manual', 'sms')),
  sms_code text references public.sms_messages(sms_code) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint balance_checkpoints_account_fkey foreign key (profile_code, account_code)
    references public.accounts(profile_code, account_code) on delete cascade,
  constraint balance_checkpoints_sms_check check (source <> 'sms' or sms_code is not null)
);
create index balance_checkpoints_account_idx on public.balance_checkpoints(account_code, as_of desc);
create index balance_checkpoints_profile_idx on public.balance_checkpoints(profile_code);
comment on table public.balance_checkpoints is
  'A bank account''s balance as of a moment (manual, or from an SMS in Phase 2b). Never updated: a newer checkpoint supersedes.';

create or replace function private.balance_checkpoint_bank_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.accounts a
                 where a.account_code = new.account_code and a.kind in ('current', 'savings')) then
    raise exception 'balances are recorded on bank accounts only' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger balance_checkpoints_bank_only before insert or update on public.balance_checkpoints
  for each row execute function private.balance_checkpoint_bank_only();

alter table public.balance_checkpoints enable row level security;
create policy balance_checkpoints_member_read on public.balance_checkpoints for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.balance_checkpoints to authenticated;
grant all on public.balance_checkpoints to service_role;

-- ── 3. v_bank_balances ───────────────────────────────────────────────────────
-- Balance = latest checkpoint + the account's pending and posted transactions after it, in the
-- account's currency: amount_aed on an AED account, else amount_original when the currency
-- matches; anything else is unpriced and counted. No checkpoint yet: balance is null.
create or replace view public.v_bank_balances with (security_invoker = true) as
select a.profile_code, a.account_code, a.bank_code, a.kind, a.currency,
       c.checkpoint_code, c.as_of, c.source as anchor_source, c.balance as anchor_balance,
       (c.balance + coalesce(x.activity, 0))::numeric(14,2) as balance,
       case when a.currency = 'AED' then (c.balance + coalesce(x.activity, 0))::numeric(14,2) end as balance_aed,
       coalesce(x.unpriced_count, 0)::int as unpriced_count,
       coalesce(c.as_of < now() - interval '7 days', false) as is_stale
from public.accounts a
left join lateral (
  select bc.checkpoint_code, bc.as_of, bc.source, bc.balance
  from public.balance_checkpoints bc
  where bc.account_code = a.account_code
  order by bc.as_of desc, bc.created_at desc
  limit 1
) c on true
left join lateral (
  select sum(case when t.direction = 'credit' then v.amt else -v.amt end) as activity,
         count(*) filter (where v.amt is null) as unpriced_count
  from public.transactions t
  cross join lateral (select case when a.currency = 'AED' then t.amount_aed
                                  when t.currency_original = a.currency then t.amount_original end as amt) v
  where t.account_code = a.account_code and t.status in ('pending', 'posted')
    and c.as_of is not null and coalesce(t.txn_at, t.txn_date::timestamptz) > c.as_of
) x on true
where a.kind in ('current', 'savings');
comment on view public.v_bank_balances is
  'A bank account''s balance: latest balance_checkpoints row plus its transactions after it (Phase 2a). Cards are v_account_balances.';
grant select on public.v_bank_balances to authenticated;
grant select on public.v_bank_balances to service_role;

-- ── 4. RPCs ──────────────────────────────────────────────────────────────────
create or replace function public.create_bank_account(
  p_profile_code text, p_bank_code text, p_kind text, p_account_ref text,
  p_nickname text default null, p_currency text default 'AED'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_ref text := nullif(btrim(p_account_ref), '');
begin
  perform private.assert_member(p_profile_code, true);
  if p_kind not in ('current', 'savings') then
    raise exception 'a bank account is current or savings, not %', p_kind using errcode = '22023';
  end if;
  if not exists (select 1 from public.banks where bank_code = p_bank_code) then
    raise exception 'unknown bank %', p_bank_code using errcode = 'P0002';
  end if;
  if v_ref is not null and v_ref !~ '^[0-9]{3,12}$' then
    raise exception 'account_ref is the 3–12 digits the bank shows at the end of the account number'
      using errcode = '22023';
  end if;
  if v_ref is not null and exists (select 1 from public.accounts
                                   where profile_code = p_profile_code and bank_code = p_bank_code
                                     and account_ref = v_ref) then
    raise exception 'this ledger already has a % account ending %', p_bank_code, v_ref using errcode = '23505';
  end if;
  insert into public.accounts (profile_code, bank_code, kind, account_ref, nickname, currency)
  values (p_profile_code, p_bank_code, p_kind, v_ref, nullif(btrim(p_nickname), ''), upper(p_currency))
  returning account_code into v_code;
  return v_code;
end;
$$;
comment on function public.create_bank_account(text, text, text, text, text, text) is
  'Owner-only: adds a current or savings account to a ledger (Phase 2a). Returns its account_code.';

-- Money arrives as a decimal string (CLAUDE.md §1.3).
create or replace function public.record_balance(
  p_profile_code text, p_account_code text, p_balance text, p_as_of timestamptz default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_as_of timestamptz := coalesce(p_as_of, now());
  v_balance numeric(14,2);
begin
  perform private.assert_member(p_profile_code, true);
  if not exists (select 1 from public.accounts
                 where account_code = p_account_code and profile_code = p_profile_code
                   and kind in ('current', 'savings')) then
    raise exception 'unknown bank account %', p_account_code using errcode = 'P0002';
  end if;
  if p_balance is null or btrim(p_balance) !~ '^-?[0-9]{1,12}(\.[0-9]{1,2})?$' then
    raise exception 'balance must be a number with at most two decimals' using errcode = '22023';
  end if;
  v_balance := btrim(p_balance)::numeric(14,2);
  if v_as_of > now() + interval '5 minutes' then
    raise exception 'a balance can''t be dated in the future' using errcode = '22023';
  end if;
  insert into public.balance_checkpoints (profile_code, account_code, as_of, balance, source, created_by)
  values (p_profile_code, p_account_code, v_as_of, v_balance, 'manual', auth.uid())
  returning checkpoint_code into v_code;
  return v_code;
end;
$$;
comment on function public.record_balance(text, text, text, timestamptz) is
  'Owner-only: records a bank account''s balance as of now (or p_as_of). Balance as a decimal string.';

-- ── 5. card-only readers ─────────────────────────────────────────────────────
create or replace view public.v_account_balances with (security_invoker = true) as
select a.profile_code,
       a.account_code,
       k.anchor_kind,
       case k.anchor_kind when 'statement' then s.statement_date when 'balance_migration' then m.migration_date end
         as anchor_date,
       case when k.anchor_kind = 'statement' then s.stmt_code end as anchor_stmt_code,
       case k.anchor_kind when 'statement' then s.closing_balance when 'balance_migration' then 0::numeric(14,2) end
         as anchor_balance,
       case when k.anchor_kind <> 'none' then x.activity_aed end as activity_aed,
       case k.anchor_kind
         when 'statement' then (s.closing_balance + x.activity_aed)::numeric(14,2)
         when 'balance_migration' then x.activity_aed::numeric(14,2)
       end as outstanding_aed,
       x.unpriced_count,
       x.has_estimate
from public.accounts a
left join lateral (
  select st.stmt_code, st.statement_date, st.closing_balance,
         (st.sms_code is not null and st.doc_code is null) as from_sms
  from public.statements st
  where st.account_code = a.account_code and st.kind = 'statement' and st.status = 'active'
    and st.closing_balance is not null
  order by st.statement_date desc, st.created_at desc
  limit 1
) s on true
left join lateral (
  select max(t.txn_date) as migration_date
  from public.transactions t
  where t.account_code = a.account_code and t.status in ('pending', 'posted')
    and t.kind = 'adjustment' and t.direction = 'debit' and t.description ilike 'BALANCE MIGRATION%'
) m on true
cross join lateral (
  select case when m.migration_date is not null
                   and (s.statement_date is null or m.migration_date > s.statement_date) then 'balance_migration'
              when s.stmt_code is not null then 'statement'
              else 'none' end as anchor_kind
) k
cross join lateral (
  select coalesce(sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end), 0)::numeric(14,2)
           as activity_aed,
         count(*) filter (where t.amount_aed is null)::integer as unpriced_count,
         coalesce(bool_or(t.amount_aed_is_estimate), false) as has_estimate
  from public.transactions t
  where t.account_code = a.account_code and t.status in ('pending', 'posted')
    and case k.anchor_kind
          when 'statement' then
            case when s.from_sms then t.txn_date > s.statement_date
                                      or (t.txn_date = s.statement_date and t.status = 'pending')
                 else t.stmt_code is null
                      or exists (select 1 from public.statements ts
                                 where ts.stmt_code = t.stmt_code and ts.statement_date > s.statement_date)
            end
          when 'balance_migration' then t.txn_date >= m.migration_date
          else true
        end
) x
-- Cards only: a bank account's balance is v_bank_balances (Phase 2a).
where a.kind = 'credit_card';

create or replace function public.overview(p_profile_code text, p_month date default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_today date := public.dubai_date(now());
  v_month date := date_trunc('month', coalesce(p_month, v_today))::date;
  v_next date := (v_month + interval '1 month')::date;
  v_prev date := (v_month - interval '1 month')::date;
  v_prev_mtd_end date := public.prev_month_to_date_end(v_month, v_today);
  v_spend numeric;
  v_prev_month numeric;
  v_prev_mtd numeric;
  v_avg_3m numeric;
  v_base numeric;
  v_pace jsonb := public.spend_pace(p_profile_code, v_month, v_today);
  r jsonb;
begin
  v_spend := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_month and txn_date < v_next), 0);
  v_prev_month := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_prev and txn_date < v_month), 0);
  -- same day-of-month last month, for a fair month-to-date comparison (DB-18)
  v_prev_mtd := coalesce((select sum(spend_aed) from public.v_spend
                       where profile_code = p_profile_code and txn_date >= v_prev and txn_date < v_prev_mtd_end), 0);
  v_avg_3m := coalesce((select round(sum(spend_aed) / 3, 2) from public.v_spend
                       where profile_code = p_profile_code
                         and txn_date >= (v_month - interval '3 month')::date and txn_date < v_month), 0);
  v_base := case when v_month < date_trunc('month', v_today)::date then v_prev_month else v_prev_mtd end;

  select jsonb_build_object(
    'month', v_month,
    'spend', v_spend::text,
    'spend_prev_month', v_prev_month::text,
    'spend_prev_month_to_date', v_prev_mtd::text,
    'spend_avg_3m', v_avg_3m::text,
    -- The 3-month average up to the same day of the month, and the projected month end (WEB-26;
    -- public.spend_pace documents both).
    'spend_avg_3m_to_date', v_pace->>'spend_avg_3m_to_date',
    'projected_month_end', v_pace->>'projected_month_end',
    'change_vs_prev_month_to_date', round((v_spend - v_base) / nullif(v_base, 0), 4)::text,
    'change_vs_avg_3m', round((v_spend - v_avg_3m) / nullif(v_avg_3m, 0), 4)::text,
    'payments', coalesce((select sum(amount_aed) from public.transactions
                       where profile_code = p_profile_code and kind = 'payment' and direction = 'credit'
                         and status in ('pending', 'posted') and txn_date >= v_month and txn_date < v_next), 0)::text,
    -- What the active cards owe today (v_account_balances): positive is owed, negative is credit.
    -- Complete only when every active account has a balance anchor and every AED amount is known.
    'outstanding', (select coalesce(sum(b.outstanding_aed), 0)::numeric(14,2)::text
                    from public.v_account_balances b join public.accounts a on a.account_code = b.account_code
                    where b.profile_code = p_profile_code and a.status = 'active'),
    'outstanding_complete', coalesce((select bool_and(b.anchor_kind <> 'none' and b.unpriced_count = 0)
                    from public.v_account_balances b join public.accounts a on a.account_code = b.account_code
                    where b.profile_code = p_profile_code and a.status = 'active'), true),
    'outstanding_has_estimate', coalesce((select bool_or(b.has_estimate)
                    from public.v_account_balances b join public.accounts a on a.account_code = b.account_code
                    where b.profile_code = p_profile_code and a.status = 'active'), false),
    'pending_count', (select count(*) from public.transactions where profile_code = p_profile_code and status = 'pending'),
    'pending_amount', coalesce((select sum(case when direction = 'debit' then amount_aed else -amount_aed end)
                       from public.transactions where profile_code = p_profile_code and status = 'pending'), 0)::text,
    -- Pending foreign charges with no rate yet: not in spend or pending_amount (DB-45).
    'pending_unpriced_count', (select count(*) from public.transactions
                       where profile_code = p_profile_code and status = 'pending' and amount_aed is null),
    'uncategorized_count', (select count(*) from public.v_spend
                       where profile_code = p_profile_code and category_code is null
                         and txn_date >= v_month and txn_date < v_next),
    'open_reviews', (select count(*) from public.match_reviews where profile_code = p_profile_code and status = 'open'),
    'last_sms_at', (select max(received_at) from public.sms_messages where profile_code = p_profile_code),
    'top_categories', coalesce((
      select jsonb_agg(x order by x.amount desc) from (
        select s.category_code, c.name, c.color_token, sum(s.spend_aed) as amount, count(*) as txn_count
        from public.v_spend s left join public.categories c on c.category_code = s.category_code
        where s.profile_code = p_profile_code and s.txn_date >= v_month and s.txn_date < v_next
        group by s.category_code, c.name, c.color_token
        order by sum(s.spend_aed) desc limit 6
      ) x), '[]'::jsonb),
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'account_code', a.account_code, 'bank_code', a.bank_code, 'nickname', a.nickname,
        'product_name', a.product_name, 'credit_limit', a.credit_limit::text,
        'logo_path', (select b.logo_path from public.banks b where b.bank_code = a.bank_code),
        'last4', (select string_agg(cd.last4, ',' order by cd.is_supplementary, cd.last4)
                  from public.cards cd where cd.account_code = a.account_code),
        -- payment_status / amount_paid: public.v_statement_payments (UX-1r, WEB-36).
        'latest_statement', (
          select jsonb_build_object('stmt_code', st.stmt_code, 'statement_date', st.statement_date,
            'due_date', st.due_date, 'closing_balance', st.closing_balance::text, 'min_due', st.min_due::text,
            'payment_status', sp.payment_status, 'amount_paid', sp.amount_paid::text)
          from public.statements st
          left join public.v_statement_payments sp on sp.profile_code = st.profile_code and sp.stmt_code = st.stmt_code
          where st.account_code = a.account_code and st.kind = 'statement' and st.status = 'active'
          order by st.statement_date desc limit 1),
        -- A card in credit has used none of its limit (DB-39).
        'utilisation', (
          select round(greatest(st.closing_balance, 0) / nullif(coalesce(st.credit_limit, a.credit_limit), 0), 4)::text
          from public.statements st
          where st.account_code = a.account_code and st.kind = 'statement' and st.status = 'active'
          order by st.statement_date desc limit 1),
        'unbilled_aed', coalesce((
          select sum(case when t.direction = 'debit' then t.amount_aed else -t.amount_aed end)
          from public.transactions t
          where t.account_code = a.account_code and t.status in ('pending', 'posted')
            and t.txn_date > coalesce((select max(st.statement_date) from public.statements st
                                       where st.account_code = a.account_code and st.kind = 'statement'
                                         and st.status = 'active'), '1900-01-01'::date)), 0)::text,
        -- The balance the bank would show now, and what it is anchored on (v_account_balances).
        'outstanding_aed', b.outstanding_aed::text,
        'balance_anchor', b.anchor_kind,
        'balance_anchor_date', b.anchor_date,
        'balance_has_estimate', b.has_estimate,
        'balance_unpriced_count', b.unpriced_count
      ) order by a.bank_code)
      from public.accounts a
      join public.v_account_balances b on b.account_code = a.account_code
      where a.profile_code = p_profile_code and a.status = 'active' and a.kind = 'credit_card'), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(to_jsonb(v) order by v.txn_date desc, v.txn_at desc nulls last)
      from (select txn_code, txn_date, txn_at, description, merchant_name, amount_aed::text as amount_aed,
                   amount_original::text as amount_original, currency_original, direction, status, category_name,
                   category_color, has_sms, has_statement
            from public.v_transactions where profile_code = p_profile_code
            order by txn_date desc, txn_at desc nulls last limit 8) v), '[]'::jsonb)
  ) into r;
  return r;
end;
$$;

create or replace function public.filter_meta(p_profile_code text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('account_code', a.account_code, 'bank_code', a.bank_code,
                  'nickname', a.nickname, 'product_name', a.product_name) order by a.bank_code)
                from public.accounts a where a.profile_code = p_profile_code and a.kind = 'credit_card'), '[]'::jsonb),
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

create or replace function public.resolve_review(p_review_code text, p_action jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.match_reviews%rowtype;
  v_profile text;
  v_txn text;
  v_txn_account text;
  v_account text;
  v_target text;
  v_line public.statement_lines%rowtype;
  v_sms public.sms_messages%rowtype;
  v_displaced text[];
  v_outcome text;
begin
  select profile_code into v_profile from public.match_reviews where review_code = p_review_code;
  if not found then
    raise exception 'review % is not open', p_review_code using errcode = 'P0002';
  end if;
  perform private.assert_member(v_profile, true);
  perform private.lock_profile(v_profile);
  select * into r from public.match_reviews where review_code = p_review_code for update;
  if r.status <> 'open' then
    raise exception 'review % is not open', p_review_code using errcode = 'P0002';
  end if;
  if p_action is null or jsonb_typeof(p_action) <> 'object' then
    raise exception 'unsupported action %', p_action using errcode = '22023';
  end if;

  if p_action ? 'dismiss' then
    -- An orphaned transaction has lost all its evidence (CLAUDE.md §1.10): checking it off voids
    -- it, so it stops counting in every total. One whose evidence came back is no longer orphaned
    -- and stays as it is.
    if r.reason = 'orphaned' and r.subject_type = 'transaction' then
      update public.transactions set voided_at = now(), void_reason = 'orphan_dismissed'
      where txn_code = r.subject_code and profile_code = r.profile_code and status = 'orphaned';
      if found then
        perform private.refresh_transaction(r.subject_code);
        v_txn := r.subject_code;
      end if;
    end if;
    v_outcome := 'dismissed';

  elsif p_action ? 'link' then
    v_txn := p_action->>'link';
    select account_code into v_txn_account from public.transactions
    where txn_code = v_txn and profile_code = r.profile_code;
    if not found then
      raise exception 'unknown transaction %', v_txn using errcode = 'P0002';
    end if;
    if r.subject_type = 'statement_line' then
      select * into v_line from public.statement_lines where line_code = r.subject_code and profile_code = r.profile_code;
      if not found then
        raise exception 'unknown statement line %', r.subject_code using errcode = 'P0002';
      end if;
      if v_line.account_code <> v_txn_account then
        raise exception 'transaction % is on a different account', v_txn using errcode = '22023';
      end if;
      if exists (select 1 from public.transaction_evidence e
                 where e.profile_code = r.profile_code and e.txn_code = v_txn and e.is_active
                   and e.evidence_type = v_line.evidence_type and e.is_locked) then
        raise exception 'transaction % already has a confirmed %', v_txn, v_line.evidence_type using errcode = '22023';
      end if;
      with d as (
        update public.transaction_evidence set is_active = false, deactivated_at = now()
        where profile_code = r.profile_code and txn_code = v_txn and is_active
          and evidence_type = v_line.evidence_type and not is_locked
        returning line_code
      )
      select array_agg(line_code) into v_displaced from d;
      insert into public.transaction_evidence (txn_code, profile_code, evidence_type, line_code, role, method, is_locked)
      values (v_txn, r.profile_code, v_line.evidence_type, v_line.line_code, 'post', 'manual', true);
      perform private.refresh_transaction(v_txn);
      -- A line pushed off the transaction stays in the ledger as its own transaction (DB-27).
      perform private.new_transaction_from_line(x.line_code)
      from unnest(coalesce(v_displaced, '{}')) as x(line_code)
      join public.statement_lines l on l.line_code = x.line_code and l.profile_code = r.profile_code and l.is_current
      where not exists (select 1 from public.transaction_evidence e where e.line_code = x.line_code and e.is_active);
    elsif r.subject_type = 'sms' then
      select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
      if not found then
        raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
      end if;
      if v_sms.account_code is distinct from v_txn_account then
        raise exception 'transaction % is not on this message''s account', v_txn using errcode = '22023';
      end if;
      insert into public.transaction_evidence (txn_code, profile_code, evidence_type, sms_code, role, method, is_locked)
      values (v_txn, r.profile_code, 'sms', v_sms.sms_code, 'auth', 'manual', true);
      perform private.refresh_transaction(v_txn);
    else
      raise exception 'link is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    v_outcome := 'linked';

  elsif p_action ? 'create_new' then
    if r.subject_type = 'statement_line' then
      if not exists (select 1 from public.statement_lines
                     where line_code = r.subject_code and profile_code = r.profile_code) then
        raise exception 'unknown statement line %', r.subject_code using errcode = 'P0002';
      end if;
      v_txn := private.new_transaction_from_line(r.subject_code, 'manual');
    elsif r.subject_type = 'sms' then
      select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
      if not found then
        raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
      end if;
      if v_sms.account_code is null or v_sms.amount is null then
        raise exception 'sms % has no account or amount; register its card first', r.subject_code using errcode = '22023';
      end if;
      v_txn := private.new_transaction_from_sms(r.subject_code, 'manual');
    else
      raise exception 'create_new is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    v_outcome := 'created';

  elsif p_action ? 'card' and r.reason = 'unknown_card' then
    v_account := p_action->'card'->>'account_code';
    select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
    if not found then
      raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
    end if;
    -- A Wallet event carries no card number to register: its card is found by Wallet name.
    if v_sms.source = 'wallet' then
      raise exception 'this payment names its card "%", not a card number: set the card''s Wallet name to it instead',
        v_sms.wallet_pass_name using errcode = '22023';
    end if;
    if not exists (select 1 from public.accounts a
                   where a.account_code = v_account and a.profile_code = r.profile_code
                     and a.bank_code = v_sms.bank_code and a.kind = 'credit_card') then
      raise exception 'unknown account %', v_account using errcode = 'P0002';
    end if;
    update public.match_reviews set status = 'resolved', resolution = p_action, resolved_by = auth.uid(), resolved_at = now()
    where review_code = p_review_code;
    if v_sms.card_last4 is null then
      -- No card number to register (DB-43): bind this one message to the chosen account.
      update public.sms_messages set account_code = v_account where sms_code = v_sms.sms_code;
      perform private.match_sms(v_sms.sms_code);
    else
      perform private.ensure_card(r.profile_code, v_account, v_sms.bank_code, v_sms.card_last4, null, true);
      -- Every message waiting on this card can now be processed.
      perform private.process_sms(s.sms_code)
      from public.sms_messages s
      where s.profile_code = r.profile_code and s.bank_code = v_sms.bank_code and s.card_last4 = v_sms.card_last4
        and s.account_code is null;
    end if;
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'card_registered'),
      resolved_at = now()
    where profile_code = r.profile_code and reason = 'unknown_card' and status = 'open'
      and subject_code in (select sms_code from public.sms_messages
                           where profile_code = r.profile_code and account_code is not null);
    return jsonb_build_object('review_code', p_review_code, 'outcome', 'card_registered');

  elsif p_action ? 'not_a_transaction' then
    if r.subject_type <> 'sms' then
      raise exception 'not_a_transaction is not valid for % reviews', r.subject_type using errcode = '22023';
    end if;
    select * into v_sms from public.sms_messages where sms_code = r.subject_code and profile_code = r.profile_code;
    if not found then
      raise exception 'unknown sms %', r.subject_code using errcode = 'P0002';
    end if;
    if exists (select 1 from public.transaction_evidence e where e.sms_code = v_sms.sms_code and e.is_active) then
      raise exception 'sms % is already part of a transaction', v_sms.sms_code using errcode = '22023';
    end if;
    update public.sms_messages set parse_status = 'ignored', ignore_reason = 'user_not_txn'
    where sms_code = v_sms.sms_code;
    -- Any other open review about the same message is moot now.
    update public.match_reviews set status = 'resolved', resolution = jsonb_build_object('auto', 'user_not_txn'),
      resolved_by = auth.uid(), resolved_at = now()
    where profile_code = r.profile_code and subject_type = 'sms' and subject_code = v_sms.sms_code
      and status = 'open' and review_code <> p_review_code;
    v_outcome := 'ignored';

  elsif p_action ? 'supersede' and r.reason = 'period_overlap' then
    select st.stmt_code into v_target
    from public.statements st
    where st.stmt_code = p_action->>'supersede'
      and st.profile_code = r.profile_code
      and st.account_code = r.account_code
      and st.kind = 'statement' and st.status = 'active'
      and st.stmt_code <> r.subject_code
      and r.candidates @> jsonb_build_array(jsonb_build_object('stmt_code', st.stmt_code));
    if v_target is null then
      raise exception 'statement % is not a candidate of review %', p_action->>'supersede', p_review_code
        using errcode = 'P0002';
    end if;
    perform private.supersede_statement(v_target, r.subject_code);
    v_outcome := 'superseded';

  else
    raise exception 'unsupported action %', p_action using errcode = '22023';
  end if;

  update public.match_reviews
  set status = case when v_outcome = 'dismissed' then 'dismissed' else 'resolved' end,
      resolution = p_action, resolved_by = auth.uid(), resolved_at = now()
  where review_code = p_review_code;
  return jsonb_build_object('review_code', p_review_code, 'outcome', v_outcome, 'txn_code', v_txn);
end;
$$;

create or replace function private.process_sms(p_sms_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  s public.sms_messages%rowtype;
  m record;
  v_card public.cards%rowtype;
  v_account text;
  v_n int;
  v_event timestamptz;
  v_fields jsonb;
  v_ignored boolean;
  v_result text;
begin
  select * into s from public.sms_messages where sms_code = p_sms_code for update;
  if exists (select 1 from public.transaction_evidence e where e.sms_code = p_sms_code and e.is_active) then
    return 'already_linked';
  end if;
  -- A Wallet event names its card by the phone's display name, not by template.
  if s.source = 'wallet' then
    return private.process_wallet_sms(p_sms_code);
  end if;

  select * into m from private.match_sms_template(s.sender, s.body, null, s.profile_code) limit 1;
  if m.template_code is null then
    update public.sms_messages set parse_status = 'unparsed', template_code = null where sms_code = p_sms_code;
    return 'unparsed';
  end if;
  v_fields := m.fields;

  v_event := s.received_at;
  if m.fields ? 'date' then
    begin
      v_event := ((m.fields->>'date') || ' ' || coalesce(m.fields->>'time', to_char(s.received_at at time zone 'Asia/Dubai', 'HH24:MI:SS')))::timestamp
                 at time zone 'Asia/Dubai';
    exception when others then
      v_event := s.received_at;
    end;
    -- A bank alert arrives within minutes of the charge. A template date far from
    -- the arrival time is a DD/MM vs MM/DD misread: keep the arrival time (DB-36).
    if abs(extract(epoch from v_event - s.received_at)) > 7 * 86400 then
      raise warning 'sms %: template date % is more than 7 days from received_at; using received_at',
        p_sms_code, v_event;
      v_fields := v_fields || jsonb_build_object('event_at_rejected', v_event);
      v_event := s.received_at;
    end if;
  end if;

  if m.fields ? 'last4' then
    select * into v_card from public.cards
    where profile_code = s.profile_code and bank_code = m.bank_code and last4 = m.fields->>'last4';
    v_account := v_card.account_code;
  end if;
  if v_account is null and not (m.fields ? 'last4') then
    select count(*), min(account_code) into v_n, v_account
    from public.accounts where profile_code = s.profile_code and bank_code = m.bank_code and status = 'active'
      and kind = 'credit_card';
    if v_n <> 1 then v_account := null; end if;
  end if;

  -- Declined alerts are not transactions: stored 'ignored' like debit-card and other alerts (DB-34).
  v_ignored := m.msg_kind in ('debit_card', 'other', 'declined');
  update public.sms_messages set
    parse_status = case when v_ignored then 'ignored' else 'parsed' end,
    ignore_reason = case when v_ignored then m.msg_kind end,
    template_code = m.template_code,
    template_version = m.template_version,
    bank_code = m.bank_code,
    msg_kind = m.msg_kind,
    card_last4 = m.fields->>'last4',
    card_code = v_card.card_code,
    account_code = v_account,
    amount = (m.fields->>'amount')::numeric,
    currency = coalesce(m.fields->>'currency', 'AED'),
    merchant_raw = m.fields->>'merchant',
    description = private.normalize_text(m.fields->>'merchant'),
    available_limit = (m.fields->>'available')::numeric,
    event_at = v_event,
    parsed_fields = v_fields
  where sms_code = p_sms_code;

  if v_ignored then
    return 'ignored';
  end if;
  if v_account is null then
    insert into public.match_reviews (profile_code, subject_type, subject_code, reason, candidates)
    values (s.profile_code, 'sms', p_sms_code, 'unknown_card',
            jsonb_build_array(jsonb_build_object('bank_code', m.bank_code, 'last4', m.fields->>'last4')))
    on conflict do nothing;
    return 'unknown_card';
  end if;

  -- A statement summary is a statement header, not a transaction.
  if m.msg_kind = 'statement_summary' then
    return private.apply_sms_statement(p_sms_code);
  end if;

  -- The same purchase may already be in the ledger from a Wallet event.
  v_result := private.link_wallet_twin(p_sms_code);
  if v_result is null then
    v_result := private.match_sms(p_sms_code);
  end if;
  return v_result;
end;
$$;

create or replace function private.reprocess_waiting_sms(p_profile text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_code text;
  v_state text;
  v_bound integer;
begin
  for v_code in
    select s.sms_code from public.sms_messages s
    where s.profile_code = p_profile and s.account_code is null and s.parse_status = 'parsed'
      and exists (select 1 from public.match_reviews r
                  where r.profile_code = p_profile and r.subject_type = 'sms' and r.subject_code = s.sms_code
                    and r.reason = 'unknown_card' and r.status = 'open')
      and case when s.card_last4 is not null
               then exists (select 1 from public.cards c
                            where c.profile_code = p_profile and c.bank_code = s.bank_code and c.last4 = s.card_last4)
               else (select count(*) from public.accounts a
                     where a.profile_code = p_profile and a.bank_code = s.bank_code and a.status = 'active'
                       and a.kind = 'credit_card') = 1
          end
    order by s.received_at, s.sms_code
  loop
    begin
      perform private.process_sms(v_code);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      raise warning 'reprocess_waiting_sms: sms % failed (%)', v_code, v_state;
    end;
  end loop;

  update public.match_reviews r set status = 'resolved', resolution = jsonb_build_object('auto', 'card_registered'),
    resolved_at = now()
  where r.profile_code = p_profile and r.reason = 'unknown_card' and r.status = 'open' and r.subject_type = 'sms'
    and exists (select 1 from public.sms_messages s
                where s.profile_code = p_profile and s.sms_code = r.subject_code and s.account_code is not null);
  get diagnostics v_bound = row_count;
  return v_bound;
end;
$$;

create or replace function private.resolve_statement_account(
  p_profile text, p_bank text, p_last4 text, p_holder text, p_card_type text, p_credit_limit numeric,
  p_doc_code text, p_reference text, p_reference_source text, p_kind text, p_first_txn_date date
)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_account text;
  v_n int;
  v_accounts text[];
  v_new_card boolean := false;
begin
  if p_last4 is not null then
    select account_code into v_account from public.cards
    where profile_code = p_profile and bank_code = p_bank and last4 = p_last4;
    -- An unknown card on a history extract: the successor of the account's card?
    if v_account is null and p_kind = 'history_extract' then
      v_account := private.successor_card_account(p_profile, p_bank, p_card_type, p_first_txn_date);
      v_new_card := v_account is not null;
    end if;
  else
    -- No card number (the parser's "unknown card" sentinel). Never invent an
    -- account when the choice is ambiguous: that duplicated the ledger on every
    -- ingest (DB-07).
    -- 1. A re-parse of the same document keeps its account.
    select array_agg(distinct st.account_code) into v_accounts
    from public.statements st join public.accounts a on a.account_code = st.account_code
    where st.profile_code = p_profile and st.doc_code = p_doc_code and a.bank_code = p_bank;
    if cardinality(v_accounts) = 1 then
      v_account := v_accounts[1];
    end if;
    -- 2. The bank has exactly one active account.
    if v_account is null then
      select count(*), min(account_code) into v_n, v_account
      from public.accounts where profile_code = p_profile and bank_code = p_bank and status = 'active'
        and kind = 'credit_card';
      if v_n <> 1 then
        v_account := null;
      end if;
    end if;
    -- 3. An explicit statement reference already seen on exactly one account.
    if v_account is null and p_reference is not null and p_reference_source = 'explicit' then
      select array_agg(distinct st.account_code) into v_accounts
      from public.statements st join public.accounts a on a.account_code = st.account_code
      where st.profile_code = p_profile and a.bank_code = p_bank
        and st.statement_reference = p_reference and st.reference_source = 'explicit';
      if cardinality(v_accounts) = 1 then
        v_account := v_accounts[1];
      end if;
    end if;
    -- 4. Ambiguous: a permanent ingest failure the owner can see, not a new account.
    if v_account is null and v_n > 1 then
      raise exception 'statement has no card number and % has % accounts in this profile; cannot choose one',
        p_bank, v_n using errcode = '22023';
    end if;
  end if;
  if v_account is null then
    insert into public.accounts (profile_code, bank_code, product_name, credit_limit)
    values (p_profile, p_bank, p_card_type, p_credit_limit)
    returning account_code into v_account;
  end if;
  if p_last4 is not null then
    perform private.ensure_card(p_profile, v_account, p_bank, p_last4, p_holder, false);
  end if;
  if v_new_card then
    update public.cards c set status = 'replaced'
    where c.profile_code = p_profile and c.account_code = v_account and c.last4 <> p_last4
      and c.status = 'active' and not c.is_supplementary;
  end if;
  if p_credit_limit is not null then
    update public.accounts set credit_limit = p_credit_limit
    where account_code = v_account and credit_limit is distinct from p_credit_limit;
  end if;
  return v_account;
end;
$$;

create or replace function private.successor_card_account(p_profile text, p_bank text, p_card_type text,
                                                          p_first_txn_date date)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_n int;
  v_account text;
  v_product text;
  v_last date;
begin
  if p_first_txn_date is null then
    return null;
  end if;
  select count(*), min(a.account_code) into v_n, v_account
  from public.accounts a where a.profile_code = p_profile and a.bank_code = p_bank and a.status = 'active'
    and a.kind = 'credit_card';
  if v_n <> 1 then
    return null;
  end if;
  select a.product_name into v_product from public.accounts a where a.account_code = v_account;
  if p_card_type is not null and v_product is not null
     and upper(btrim(p_card_type)) <> upper(btrim(v_product)) then
    return null;
  end if;
  select max(l.txn_date) into v_last from public.statement_lines l
  where l.profile_code = p_profile and l.account_code = v_account and l.is_current;
  if v_last is not null and p_first_txn_date < v_last - 31 then
    return null;   -- overlapping activity: a second live card, not a replacement
  end if;
  return v_account;
end;
$$;

create or replace function private.merge_accounts(p_profile_code text, p_from text, p_into text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  f public.accounts%rowtype;
  t public.accounts%rowtype;
  v_cards int; v_stmts int; v_lines int; v_txns int; v_sms int; v_reviews int; v_budgets int;
begin
  perform private.lock_profile(p_profile_code);
  select * into f from public.accounts where account_code = p_from and profile_code = p_profile_code;
  select * into t from public.accounts where account_code = p_into and profile_code = p_profile_code;
  if f.account_code is null or t.account_code is null then
    raise exception 'both accounts must belong to profile %', p_profile_code using errcode = 'P0002';
  end if;
  if f.account_code = t.account_code then
    raise exception 'cannot merge an account into itself' using errcode = '22023';
  end if;
  -- A card and a bank account are different things: their cards, statements and balances don't mix.
  if f.kind <> t.kind then
    raise exception 'cannot merge a % account into a % account', f.kind, t.kind using errcode = '22023';
  end if;
  if f.bank_code <> t.bank_code then
    raise exception 'cannot merge a % account into a % account', f.bank_code, t.bank_code using errcode = '22023';
  end if;

  update public.cards set account_code = p_into where account_code = p_from;
  get diagnostics v_cards = row_count;
  update public.statements set account_code = p_into where account_code = p_from;
  get diagnostics v_stmts = row_count;
  update public.statement_lines set account_code = p_into where account_code = p_from;
  get diagnostics v_lines = row_count;
  -- line_key hashes the account: re-key the moved lines so a re-parse of their documents (which
  -- now resolves to p_into) finds them unchanged instead of superseding and re-creating them.
  update public.statement_lines l set line_key = k.line_key
  from (
    select x.line_code, private.statement_line_key(p_into, x.txn_date, x.posting_date, x.amount_original,
             x.currency_original, x.amount_aed, x.direction,
             coalesce((select mo.original from private.masked_originals mo
                        where mo.table_name = 'statement_lines' and mo.row_code = x.line_code
                          and mo.column_name = 'description_raw'), x.description_raw)) as line_key
    from public.statement_lines x
    where x.account_code = p_into
  ) k
  where l.line_code = k.line_code and l.line_key is distinct from k.line_key;
  update public.transactions set account_code = p_into where account_code = p_from;
  get diagnostics v_txns = row_count;
  update public.sms_messages set account_code = p_into where account_code = p_from;
  get diagnostics v_sms = row_count;
  update public.match_reviews set account_code = p_into where account_code = p_from;
  get diagnostics v_reviews = row_count;
  -- A card budget follows its card, unless the surviving card already has one for the
  -- same category and start month (that one wins; the other stays on the closed card).
  update public.budgets b set account_code = p_into
  where b.account_code = p_from
    and not exists (select 1 from public.budgets x
                    where x.profile_code = b.profile_code and x.account_code = p_into
                      and x.category_code is not distinct from b.category_code
                      and x.effective_from = b.effective_from);
  get diagnostics v_budgets = row_count;

  update public.accounts set
    credit_limit = coalesce(f.credit_limit, t.credit_limit),   -- the merged-in account is the newer one
    product_name = coalesce(t.product_name, f.product_name),
    nickname = coalesce(t.nickname, f.nickname),
    cycle_close_day = coalesce(t.cycle_close_day, f.cycle_close_day)
  where account_code = p_into;
  update public.accounts set status = 'closed' where account_code = p_from;

  return jsonb_build_object('account_code', p_into, 'merged_account_code', p_from, 'cards', v_cards,
                            'statements', v_stmts, 'statement_lines', v_lines, 'transactions', v_txns,
                            'sms_messages', v_sms, 'match_reviews', v_reviews,
                            'budgets', v_budgets);
end;
$$;

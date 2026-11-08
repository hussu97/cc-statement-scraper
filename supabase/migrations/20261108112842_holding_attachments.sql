-- Holding attachments: proof of purchase (an invoice photo or PDF, a certificate) kept with a
-- holding and shown in the web and iPhone apps.
--
-- 1. A private `holding-attachments` bucket. Objects live at
--    `<profile_code>/<holding_code>/<file>`: members read their ledger's folders, owners upload
--    and delete. The bucket limits type (JPEG, PNG, WebP, HEIC, PDF) and size (10 MB).
-- 2. public.holding_attachments: one row per file, read-only to members; written only through
--    the RPCs below, which check the object is really in the bucket under that holding.
-- 3. add_holding_attachment / remove_holding_attachment (owner). Removing returns the object's
--    path for the client to delete from storage (Storage refuses SQL deletes of its objects).
-- 4. holding_detail gains `attachments`, newest first.

-- ── 1. bucket ────────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('holding-attachments', 'holding-attachments', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do nothing;

create policy holding_attachments_bucket_member_read on storage.objects for select to authenticated
  using (
    bucket_id = 'holding-attachments'
    and (storage.foldername(name))[1] = any ((select authz.my_profile_codes())::text[])
  );
create policy holding_attachments_bucket_owner_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'holding-attachments'
    and (storage.foldername(name))[1] = any ((select authz.my_owned_profile_codes())::text[])
  );
create policy holding_attachments_bucket_owner_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'holding-attachments'
    and (storage.foldername(name))[1] = any ((select authz.my_owned_profile_codes())::text[])
  );

-- ── 2. holding_attachments ───────────────────────────────────────────────────
create table public.holding_attachments (
  attachment_code text primary key default public.gen_code('hat')
    check (attachment_code ~ '^hat_[0-9a-z]{26}$'),
  profile_code text not null references public.profiles(profile_code) on delete cascade,
  holding_code text not null references public.holdings(holding_code) on delete cascade,
  storage_path text not null unique check (length(storage_path) between 1 and 300),
  file_name text not null check (length(btrim(file_name)) between 1 and 200),
  mime_type text not null
    check (mime_type in ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf')),
  size_bytes bigint not null check (size_bytes > 0),
  caption text check (length(caption) <= 120),
  created_by uuid,
  created_at timestamptz not null default now()
);
create index holding_attachments_holding_idx on public.holding_attachments(holding_code, created_at desc);
create index holding_attachments_profile_idx on public.holding_attachments(profile_code);
comment on table public.holding_attachments is
  'Files kept with a holding (invoice photos, certificates) in the private holding-attachments bucket. Written by add/remove_holding_attachment.';
alter table public.holding_attachments enable row level security;
create policy holding_attachments_member_read on public.holding_attachments for select to authenticated
  using (profile_code = any ((select authz.my_profile_codes())::text[]));
grant select on public.holding_attachments to authenticated;
grant all on public.holding_attachments to service_role;

-- ── 3. RPCs ──────────────────────────────────────────────────────────────────
-- Owner: records a file already uploaded to `<profile>/<holding>/<file>` in the bucket. Type and
-- size come from Storage, not the caller. Returns the attachment_code.
create function public.add_holding_attachment(
  p_profile_code text, p_holding_code text, p_storage_path text, p_file_name text, p_caption text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mime text;
  v_size bigint;
  v_code text;
begin
  perform private.assert_member(p_profile_code, true);
  if not exists (select 1 from public.holdings
                 where holding_code = p_holding_code and profile_code = p_profile_code and status = 'active') then
    raise exception 'holding not found' using errcode = 'P0002';
  end if;
  if p_storage_path is null or split_part(p_storage_path, '/', 1) <> p_profile_code
     or split_part(p_storage_path, '/', 2) <> p_holding_code or split_part(p_storage_path, '/', 3) = ''
     or split_part(p_storage_path, '/', 4) <> '' then
    raise exception 'the file must be at <profile>/<holding>/<file>' using errcode = '22023';
  end if;
  if p_file_name is null or btrim(p_file_name) = '' then
    raise exception 'file name is required' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_caption, ''))) > 120 then
    raise exception 'caption is at most 120 characters' using errcode = '22023';
  end if;
  select o.metadata->>'mimetype', (o.metadata->>'size')::bigint into v_mime, v_size
  from storage.objects o
  where o.bucket_id = 'holding-attachments' and o.name = p_storage_path;
  if not found then
    raise exception 'the file has not been uploaded' using errcode = 'P0002';
  end if;
  if (select count(*) from public.holding_attachments where holding_code = p_holding_code) >= 20 then
    raise exception 'a holding keeps at most 20 attachments' using errcode = '22023';
  end if;
  insert into public.holding_attachments (profile_code, holding_code, storage_path, file_name, mime_type, size_bytes,
                                          caption, created_by)
  values (p_profile_code, p_holding_code, p_storage_path, left(btrim(p_file_name), 200), v_mime, v_size,
          nullif(btrim(coalesce(p_caption, '')), ''), auth.uid())
  on conflict (storage_path) do nothing
  returning attachment_code into v_code;
  if v_code is null then
    select attachment_code into v_code from public.holding_attachments
    where storage_path = p_storage_path and profile_code = p_profile_code;
  end if;
  return v_code;
end;
$$;
comment on function public.add_holding_attachment(text, text, text, text, text) is
  'Owner: records a file uploaded to holding-attachments/<profile>/<holding>/<file> (type and size from Storage). Idempotent per path.';
grant execute on function public.add_holding_attachment(text, text, text, text, text) to authenticated, service_role;

-- Owner: forgets an attachment. Returns its storage path; the client deletes the object.
create function public.remove_holding_attachment(p_profile_code text, p_attachment_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_path text;
begin
  perform private.assert_member(p_profile_code, true);
  delete from public.holding_attachments
  where attachment_code = p_attachment_code and profile_code = p_profile_code
  returning storage_path into v_path;
  if v_path is null then
    raise exception 'attachment not found' using errcode = 'P0002';
  end if;
  return v_path;
end;
$$;
comment on function public.remove_holding_attachment(text, text) is
  'Owner: removes an attachment row and returns its storage path for the client to delete.';
grant execute on function public.remove_holding_attachment(text, text) to authenticated, service_role;

-- ── 4. holding_detail: + attachments ─────────────────────────────────────────
create or replace function public.holding_detail(p_profile_code text, p_holding_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_member(p_profile_code, false);
  if not exists (select 1 from public.holdings where holding_code = p_holding_code and profile_code = p_profile_code) then
    raise exception 'holding not found' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'flows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'flow_code', f.flow_code, 'flow_date', f.flow_date, 'kind', f.kind, 'amount', f.amount::text,
               'amount_aed', f.amount_aed::text, 'source', f.source, 'notes', f.notes, 'txn_code', f.txn_code,
               'txn_description', t.description, 'txn_bank_code', a.bank_code, 'txn_account_kind', a.kind)
             order by f.flow_date desc, f.created_at desc)
      from public.holding_flows f
      left join public.transactions t on t.txn_code = f.txn_code
      left join public.accounts a on a.account_code = t.account_code
      where f.holding_code = p_holding_code and private.flow_is_active(f.removed_at, f.txn_code)), '[]'::jsonb),
    'valuations', coalesce((
      select jsonb_agg(jsonb_build_object('valuation_code', v.valuation_code, 'as_of', v.as_of,
                                          'value', v.value::text, 'unit_price', v.unit_price::text, 'source', v.source)
             order by v.as_of desc, v.created_at desc)
      from public.holding_valuations v where v.holding_code = p_holding_code), '[]'::jsonb),
    'attachments', coalesce((
      select jsonb_agg(jsonb_build_object('attachment_code', x.attachment_code, 'storage_path', x.storage_path,
                                          'file_name', x.file_name, 'mime_type', x.mime_type,
                                          'size_bytes', x.size_bytes, 'caption', x.caption, 'created_at', x.created_at)
             order by x.created_at desc, x.attachment_code desc)
      from public.holding_attachments x where x.holding_code = p_holding_code), '[]'::jsonb));
end;
$$;

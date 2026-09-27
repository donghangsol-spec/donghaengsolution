-- Transaction evidence is separate from inbound email attachments.
-- Object path: organization_id/company_id/transaction_id/random_uuid.extension
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('transaction-evidence-private','transaction-evidence-private',false,10485760,
  array['application/pdf','image/png','image/jpeg'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create policy "transaction evidence read" on storage.objects for select to authenticated using (
  bucket_id='transaction-evidence-private' and exists (
    select 1 from public.transactions t join public.companies c on c.id=t.company_id
    where c.organization_id::text=(storage.foldername(name))[1]
      and c.id::text=(storage.foldername(name))[2]
      and t.id::text=(storage.foldername(name))[3]
      and private.is_org_member(c.organization_id)
  )
);
create policy "transaction evidence upload" on storage.objects for insert to authenticated with check (
  bucket_id='transaction-evidence-private'
  and array_length(storage.foldername(name),1)=3
  and lower(storage.extension(name)) in ('pdf','png','jpg','jpeg')
  and (storage.filename(name)) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(pdf|png|jpg|jpeg)$'
  and exists (
    select 1 from public.transactions t join public.companies c on c.id=t.company_id
    where c.organization_id::text=(storage.foldername(name))[1]
      and c.id::text=(storage.foldername(name))[2]
      and t.id::text=(storage.foldername(name))[3]
      and private.has_org_role(c.organization_id,array['owner','admin'])
  )
);
create policy "transaction evidence delete" on storage.objects for delete to authenticated using (
  bucket_id='transaction-evidence-private' and exists (
    select 1 from public.transactions t join public.companies c on c.id=t.company_id
    where c.organization_id::text=(storage.foldername(name))[1]
      and c.id::text=(storage.foldername(name))[2]
      and t.id::text=(storage.foldername(name))[3]
      and private.has_org_role(c.organization_id,array['owner','admin'])
  )
);
-- No UPDATE policy: overwrites and moves are blocked.

alter table public.evidence_files add constraint evidence_storage_path_unique unique(storage_path);
create or replace function private.validate_transaction_evidence_path()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare v_org uuid; v_company uuid;
begin
  select c.organization_id,c.id into v_org,v_company
  from public.transactions t join public.companies c on c.id=t.company_id
  where t.id=new.transaction_id;
  if v_org is null or new.storage_path !~* '^[0-9a-f-]+/[0-9a-f-]+/[0-9a-f-]+/[0-9a-f-]+\.(pdf|png|jpg|jpeg)$'
    or split_part(new.storage_path,'/',1)<>v_org::text
    or split_part(new.storage_path,'/',2)<>v_company::text
    or split_part(new.storage_path,'/',3)<>new.transaction_id::text
    or new.mime_type not in ('application/pdf','image/png','image/jpeg') then
    raise exception 'invalid transaction evidence path or MIME' using errcode='23514';
  end if;
  return new;
end $$;
create trigger validate_transaction_evidence_path before insert or update on public.evidence_files
for each row execute function private.validate_transaction_evidence_path();
revoke all on function private.validate_transaction_evidence_path() from public,anon,authenticated;

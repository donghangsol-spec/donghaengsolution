-- Qualify the outer object path inside correlated transaction/company lookups.
-- An unqualified `name` in that scope resolves to companies.name and blocks every upload.
alter policy "transaction evidence read" on storage.objects using (
  bucket_id='transaction-evidence-private' and exists (
    select 1 from public.transactions t join public.companies c on c.id=t.company_id
    where c.organization_id::text=(storage.foldername(objects.name))[1]
      and c.id::text=(storage.foldername(objects.name))[2]
      and t.id::text=(storage.foldername(objects.name))[3]
      and private.is_org_member(c.organization_id)
  )
);
alter policy "transaction evidence upload" on storage.objects with check (
  bucket_id='transaction-evidence-private'
  and array_length(storage.foldername(objects.name),1)=3
  and lower(storage.extension(objects.name)) in ('pdf','png','jpg','jpeg')
  and storage.filename(objects.name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(pdf|png|jpg|jpeg)$'
  and exists (
    select 1 from public.transactions t join public.companies c on c.id=t.company_id
    where c.organization_id::text=(storage.foldername(objects.name))[1]
      and c.id::text=(storage.foldername(objects.name))[2]
      and t.id::text=(storage.foldername(objects.name))[3]
      and private.has_org_role(c.organization_id,array['owner','admin'])
  )
);
alter policy "transaction evidence delete" on storage.objects using (
  bucket_id='transaction-evidence-private' and exists (
    select 1 from public.transactions t join public.companies c on c.id=t.company_id
    where c.organization_id::text=(storage.foldername(objects.name))[1]
      and c.id::text=(storage.foldername(objects.name))[2]
      and t.id::text=(storage.foldername(objects.name))[3]
      and private.has_org_role(c.organization_id,array['owner','admin'])
  )
);

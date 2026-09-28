drop policy if exists "email intake storage read" on storage.objects;
drop policy if exists "email intake storage insert" on storage.objects;
drop policy if exists "email intake storage delete" on storage.objects;

create policy "email intake storage read" on storage.objects for select to authenticated using(
 bucket_id='email-intake-private' and exists(
  select 1 from public.organizations o
  where o.id::text=(storage.foldername(name))[1] and private.is_org_member(o.id)
 )
);
create policy "email intake storage insert" on storage.objects for insert to authenticated with check(
 bucket_id='email-intake-private' and exists(
  select 1 from public.organizations o
  where o.id::text=(storage.foldername(name))[1]
    and private.has_org_role(o.id,array['owner','admin','reviewer','staff'])
 )
 and lower(storage.extension(name)) in ('pdf','png','jpg','jpeg','xls','xlsx','csv')
);
create policy "email intake storage delete" on storage.objects for delete to authenticated using(
 bucket_id='email-intake-private' and exists(
  select 1 from public.organizations o
  where o.id::text=(storage.foldername(name))[1]
    and private.has_org_role(o.id,array['owner','admin'])
 )
);

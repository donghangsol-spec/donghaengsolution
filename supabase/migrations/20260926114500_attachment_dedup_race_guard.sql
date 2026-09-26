create or replace function public.ingest_email_attachment_metadata(
 p_message_id uuid,p_organization_id uuid,p_original_filename text,p_mime_type text,p_byte_size bigint,p_sha256 text,p_storage_path text
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;

 insert into public.email_intake_attachments(message_id,organization_id,original_filename,mime_type,byte_size,sha256,storage_path,processing_status)
 values(p_message_id,p_organization_id,p_original_filename,p_mime_type,p_byte_size,p_sha256,p_storage_path,'received')
 on conflict(organization_id,sha256) do nothing
 returning id into v_id;

 if v_id is null then
   select a.id into v_id
   from public.email_intake_attachments a
   where a.organization_id=p_organization_id and a.sha256=p_sha256;
 end if;

 if v_id is null then raise exception 'attachment metadata ingest failed'; end if;
 return v_id;
end $$;
revoke all on function public.ingest_email_attachment_metadata(uuid,uuid,text,text,bigint,text,text) from public,anon,authenticated;
grant execute on function public.ingest_email_attachment_metadata(uuid,uuid,text,text,bigint,text,text) to service_role;

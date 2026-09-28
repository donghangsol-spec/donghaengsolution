create or replace function public.ingest_inbound_email_metadata(
 p_organization_id uuid,p_provider text,p_provider_message_id text,p_sender text,p_subject text,p_received_at timestamptz
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 insert into public.email_intake_messages(organization_id,provider,provider_message_id,sender,subject,received_at,processing_status)
 values(p_organization_id,p_provider,p_provider_message_id,p_sender,p_subject,p_received_at,'received')
 on conflict(provider,provider_message_id) do update set updated_at=now()
 returning id into v_id;
 return v_id;
end $$;
revoke all on function public.ingest_inbound_email_metadata(uuid,text,text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.ingest_inbound_email_metadata(uuid,text,text,text,text,timestamptz) to service_role;

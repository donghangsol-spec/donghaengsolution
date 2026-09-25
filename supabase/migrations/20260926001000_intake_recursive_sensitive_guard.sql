create or replace function private.intake_payload_has_sensitive_key(p_value jsonb)
returns boolean language plpgsql immutable security invoker set search_path=pg_catalog as $fn$
declare k text; v jsonb;
begin
 if jsonb_typeof(p_value)='object' then
  for k,v in select key,value from jsonb_each(p_value) loop
   if lower(k) in ('resident_registration_number','rrn','certificate_password','private_key','password','certificate_private_key') then return true; end if;
   if private.intake_payload_has_sensitive_key(v) then return true; end if;
  end loop;
 elsif jsonb_typeof(p_value)='array' then
  for v in select value from jsonb_array_elements(p_value) loop
   if private.intake_payload_has_sensitive_key(v) then return true; end if;
  end loop;
 end if;
 return false;
end $fn$;
revoke all on function private.intake_payload_has_sensitive_key(jsonb) from public,anon,authenticated;

create or replace function public.set_intake_extraction_payload(p_draft_id uuid,p_organization_id uuid,p_payload jsonb,p_confidence jsonb,p_errors jsonb default '[]'::jsonb,p_warnings jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_id uuid;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 if jsonb_typeof(coalesce(p_payload,'{}'::jsonb))<>'object' then raise exception 'payload must be object'; end if;
 if private.intake_payload_has_sensitive_key(p_payload) then raise exception 'forbidden sensitive field'; end if;
 update public.document_extraction_drafts
 set extracted_payload=coalesce(p_payload,'{}'::jsonb),confidence_payload=coalesce(p_confidence,'{}'::jsonb),
 validation_errors=coalesce(p_errors,'[]'::jsonb),validation_warnings=coalesce(p_warnings,'[]'::jsonb),
 review_status='review_required',updated_at=now()
 where id=p_draft_id and organization_id=p_organization_id returning id into v_id;
 if v_id is null then raise exception 'draft organization mismatch'; end if;
 return v_id;
end $$;
revoke all on function public.set_intake_extraction_payload(uuid,uuid,jsonb,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.set_intake_extraction_payload(uuid,uuid,jsonb,jsonb,jsonb,jsonb) to service_role;

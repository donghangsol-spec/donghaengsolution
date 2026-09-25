create or replace function private.intake_payload_has_sensitive_key(p_value jsonb)
returns boolean language sql immutable security invoker set search_path=pg_catalog as $$
 with recursive walk(v) as (
   select coalesce(p_value,'null'::jsonb)
   union all
   select x.value from walk w cross join lateral jsonb_each(w.v) x where jsonb_typeof(w.v)='object'
   union all
   select x.value from walk w cross join lateral jsonb_array_elements(w.v) x where jsonb_typeof(w.v)='array'
 )
 select exists(
   select 1 from walk w cross join lateral jsonb_object_keys(w.v) k
   where jsonb_typeof(w.v)='object'
   and lower(k) in ('resident_registration_number','rrn','certificate_password','private_key','password','certificate_private_key')
 );
$$;
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

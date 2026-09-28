create or replace function public.set_intake_extraction_payload(
 p_draft_id uuid,p_organization_id uuid,p_payload jsonb,p_confidence jsonb,p_errors jsonb default '[]'::jsonb,p_warnings jsonb default '[]'::jsonb
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 if jsonb_typeof(coalesce(p_payload,'{}'::jsonb))<>'object' then raise exception 'payload must be object'; end if;
 if p_payload ?| array['resident_registration_number','certificate_password','private_key','password'] then raise exception 'forbidden sensitive field'; end if;
 update public.document_extraction_drafts set
  extracted_payload=coalesce(p_payload,'{}'::jsonb),
  confidence_payload=coalesce(p_confidence,'{}'::jsonb),
  validation_errors=coalesce(p_errors,'[]'::jsonb),
  validation_warnings=coalesce(p_warnings,'[]'::jsonb),
  review_status='review_required',updated_at=now()
 where id=p_draft_id and organization_id=p_organization_id
 returning id into v_id;
 if v_id is null then raise exception 'draft organization mismatch'; end if;
 return v_id;
end $$;
revoke all on function public.set_intake_extraction_payload(uuid,uuid,jsonb,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.set_intake_extraction_payload(uuid,uuid,jsonb,jsonb,jsonb,jsonb) to service_role;

create or replace function public.review_intake_draft(p_draft_id uuid,p_decision text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_org uuid; v_id uuid;
begin
 select organization_id into v_org from public.document_extraction_drafts where id=p_draft_id;
 if v_org is null or not private.has_org_role(v_org,array['owner','admin','reviewer']) then raise exception 'not authorized'; end if;
 if p_decision not in ('approved','rejected') then raise exception 'invalid decision'; end if;
 update public.document_extraction_drafts set review_status=p_decision,reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()
 where id=p_draft_id and organization_id=v_org and review_status='review_required'
 returning id into v_id;
 if v_id is null then raise exception 'draft is not reviewable'; end if;
 return v_id;
end $$;
revoke all on function public.review_intake_draft(uuid,text) from public,anon;
grant execute on function public.review_intake_draft(uuid,text) to authenticated;

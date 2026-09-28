create or replace function public.create_intake_classification_draft(
 p_attachment_id uuid,p_organization_id uuid,p_filename text,p_mime_type text
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid; v_type text; v_name text:=lower(coalesce(p_filename,''));
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 if not exists(select 1 from public.email_intake_attachments a where a.id=p_attachment_id and a.organization_id=p_organization_id) then raise exception 'attachment organization mismatch'; end if;
 v_type:=case
  when v_name like '%사업자%등록%' then 'business_registration'
  when v_name like '%취득%' then 'insurance_acquisition'
  when v_name like '%상실%' then 'insurance_loss'
  when v_name like '%보수%월액%' or v_name like '%변경%' then 'insurance_change'
  when v_name like '%급여%' or v_name like '%임금%' then 'payroll'
  else 'unknown' end;
 insert into public.document_extraction_drafts(attachment_id,organization_id,document_type,extracted_payload,confidence_payload,validation_warnings,review_status)
 values(p_attachment_id,p_organization_id,v_type,'{}'::jsonb,jsonb_build_object('classification_source','filename','requires_content_review',true),case when v_type='unknown' then jsonb_build_array('문서 유형을 확인해 주세요') else '[]'::jsonb end,'review_required')
 on conflict(attachment_id) do update set document_type=excluded.document_type,confidence_payload=excluded.confidence_payload,validation_warnings=excluded.validation_warnings,review_status='review_required',updated_at=now()
 returning id into v_id;
 update public.email_intake_attachments set classification=v_type,processing_status='review_required' where id=p_attachment_id and organization_id=p_organization_id;
 return v_id;
end $$;
revoke all on function public.create_intake_classification_draft(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.create_intake_classification_draft(uuid,uuid,text,text) to service_role;

create or replace function public.review_intake_draft(p_draft_id uuid,p_decision text)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
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

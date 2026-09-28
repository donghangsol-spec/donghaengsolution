create or replace function public.match_intake_draft_entities(p_draft_id uuid,p_organization_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.document_extraction_drafts; v_company uuid; v_employee uuid; v_method text:='unmatched'; v_conf numeric:=0; v_review boolean:=true; v_id uuid; v_name text; v_employee_no text; v_company_count integer:=0; v_employee_count integer:=0;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 select * into d from public.document_extraction_drafts where id=p_draft_id and organization_id=p_organization_id;
 if d.id is null then raise exception 'draft organization mismatch'; end if;

 v_name=nullif(btrim(d.extracted_payload->>'company_name'),'');
 if v_name is not null then
   select count(*), min(c.id::text)::uuid into v_company_count,v_company
   from public.companies c
   where c.organization_id=p_organization_id and c.is_active and lower(btrim(c.name))=lower(v_name);
   if v_company_count=1 then
     v_method:='company_name_exact'; v_conf:=0.80;
   else
     v_company:=null;
     if v_company_count>1 then v_method:='company_name_ambiguous'; end if;
   end if;
 end if;

 v_employee_no=nullif(btrim(d.extracted_payload->>'employee_no'),'');
 if v_company is not null and v_employee_no is not null then
   select count(*), min(e.id::text)::uuid into v_employee_count,v_employee
   from public.employees e where e.company_id=v_company and e.employee_no=v_employee_no;
   if v_employee_count=1 then
     v_method:='company_name_exact+employee_no_exact'; v_conf:=0.95;
   else
     v_employee:=null;
     if v_employee_count>1 then v_method:='employee_no_ambiguous'; v_conf:=0.80; end if;
   end if;
 end if;

 insert into public.intake_entity_matches(draft_id,organization_id,company_id,employee_id,match_method,confidence,requires_review)
 values(d.id,p_organization_id,v_company,v_employee,v_method,v_conf,v_review)
 on conflict(draft_id) do update set company_id=excluded.company_id,employee_id=excluded.employee_id,match_method=excluded.match_method,confidence=excluded.confidence,requires_review=true
 returning id into v_id;
 return v_id;
end $$;
revoke all on function public.match_intake_draft_entities(uuid,uuid) from public,anon,authenticated;
grant execute on function public.match_intake_draft_entities(uuid,uuid) to service_role;

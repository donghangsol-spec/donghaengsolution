create unique index if not exists uq_intake_entity_matches_draft on public.intake_entity_matches(draft_id);

create or replace function public.match_intake_draft_entities(p_draft_id uuid,p_organization_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare d public.document_extraction_drafts; v_company uuid; v_employee uuid; v_method text:='unmatched'; v_conf numeric:=0; v_review boolean:=true; v_id uuid; v_name text; v_employee_no text;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 select * into d from public.document_extraction_drafts where id=p_draft_id and organization_id=p_organization_id;
 if d.id is null then raise exception 'draft organization mismatch'; end if;

 v_name=nullif(btrim(d.extracted_payload->>'company_name'),'');
 if v_name is not null then
   select c.id into v_company from public.companies c where c.organization_id=p_organization_id and c.is_active and lower(btrim(c.name))=lower(v_name) order by c.created_at limit 1;
   if v_company is not null then v_method:='company_name_exact'; v_conf:=0.80; end if;
 end if;

 v_employee_no=nullif(btrim(d.extracted_payload->>'employee_no'),'');
 if v_company is not null and v_employee_no is not null then
   select e.id into v_employee from public.employees e where e.company_id=v_company and e.employee_no=v_employee_no order by e.created_at limit 1;
   if v_employee is not null then v_method:='company_name_exact+employee_no_exact'; v_conf:=0.95; end if;
 end if;

 -- Matching never auto-commits production entities. Human review remains mandatory.
 insert into public.intake_entity_matches(draft_id,organization_id,company_id,employee_id,match_method,confidence,requires_review)
 values(d.id,p_organization_id,v_company,v_employee,v_method,v_conf,v_review)
 on conflict(draft_id) do update set company_id=excluded.company_id,employee_id=excluded.employee_id,match_method=excluded.match_method,confidence=excluded.confidence,requires_review=true
 returning id into v_id;
 return v_id;
end $$;
revoke all on function public.match_intake_draft_entities(uuid,uuid) from public,anon,authenticated;
grant execute on function public.match_intake_draft_entities(uuid,uuid) to service_role;

alter table public.intake_work_drafts add column if not exists committed_by uuid references auth.users(id);

create or replace function public.authorize_intake_work_commit(p_id uuid)
returns boolean language plpgsql security invoker set search_path=public,private,pg_temp as $fn$
declare v_org uuid;
begin
 if auth.uid() is null then raise exception 'authentication required'; end if;
 select organization_id into v_org from public.intake_work_drafts where id=p_id and status='approved' and reviewed_by is not null and reviewed_at is not null;
 if v_org is null then return false; end if;
 if not private.has_org_role(v_org,array['owner','admin','reviewer']) then raise exception 'forbidden'; end if;
 return true;
end $fn$;
revoke all on function public.authorize_intake_work_commit(uuid) from public,anon;
grant execute on function public.authorize_intake_work_commit(uuid) to authenticated;

create or replace function public.commit_intake_work_draft(p_id uuid,p_actor_id uuid)
returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $fn$
declare w public.intake_work_drafts; v_id uuid; v_month date; v_request text; v_effective date;
begin
 if current_user not in ('postgres','service_role') then raise exception 'server only'; end if;
 select * into w from public.intake_work_drafts where id=p_id for update;
 if w.id is null then raise exception 'work draft not found'; end if;
 if w.status<>'approved' or w.reviewed_by is null or w.reviewed_at is null then raise exception 'human approval required'; end if;
 if p_actor_id is null or not private.has_org_role_for_user(w.organization_id,p_actor_id,array['owner','admin','reviewer']) then raise exception 'actor forbidden'; end if;
 if w.committed_entity_id is not null then return w.committed_entity_id; end if;
 if w.company_id is null then raise exception 'matched company required'; end if;
 if w.work_type='payroll' then
   if w.employee_id is null then raise exception 'matched employee required'; end if;
   if not exists(select 1 from public.employees e join public.companies c on c.id=e.company_id where e.id=w.employee_id and e.company_id=w.company_id and c.organization_id=w.organization_id) then raise exception 'organization relationship mismatch'; end if;
   v_month=date_trunc('month',(w.proposed_payload->>'period_month')::date)::date;
   insert into public.payroll_periods(company_id,period_month,status,source_type) values(w.company_id,v_month,'초안','연동')
   on conflict(company_id,period_month) do update set updated_at=now() returning id into v_id;
   insert into public.payroll_entries(payroll_period_id,company_id,employee_id,payroll_type,base_salary,taxable_allowance,non_taxable_allowance,source_type,source_payload)
   select v_id,w.company_id,w.employee_id,coalesce(nullif(w.proposed_payload->>'payroll_type',''),e.payroll_type),greatest(coalesce(nullif(w.proposed_payload->>'base_salary','')::numeric,0),0),greatest(coalesce(nullif(w.proposed_payload->>'taxable_allowance','')::numeric,0),0),greatest(coalesce(nullif(w.proposed_payload->>'non_taxable_allowance','')::numeric,0),0),'연동',jsonb_build_object('intake_work_draft_id',w.id) from public.employees e where e.id=w.employee_id and e.company_id=w.company_id on conflict(payroll_period_id,employee_id) do nothing;
 elsif w.work_type in ('insurance_acquisition','insurance_loss','insurance_change') then
   if w.employee_id is null then raise exception 'matched employee required'; end if;
   if not exists(select 1 from public.employees e join public.companies c on c.id=e.company_id where e.id=w.employee_id and e.company_id=w.company_id and c.organization_id=w.organization_id) then raise exception 'organization relationship mismatch'; end if;
   v_request=case w.work_type when 'insurance_acquisition' then '취득' when 'insurance_loss' then '상실' else '변경' end;
   v_effective=(w.proposed_payload->>'effective_date')::date;
   insert into public.insurance_requests(company_id,employee_id,request_type,effective_date,monthly_remuneration,loss_reason,payload,status) values(w.company_id,w.employee_id,v_request,v_effective,nullif(w.proposed_payload->>'monthly_remuneration','')::numeric,nullif(w.proposed_payload->>'loss_reason',''),jsonb_build_object('intake_work_draft_id',w.id),'요청접수') returning id into v_id;
 else raise exception 'unsupported work type'; end if;
 update public.intake_work_drafts set status='committed',committed_entity_id=v_id,committed_at=now(),committed_by=p_actor_id,updated_at=now() where id=w.id;
 return v_id;
end $fn$;
revoke all on function public.commit_intake_work_draft(uuid,uuid) from public,anon,authenticated;
grant execute on function public.commit_intake_work_draft(uuid,uuid) to service_role;
revoke all on function public.commit_intake_work_draft(uuid) from public,anon,authenticated,service_role;

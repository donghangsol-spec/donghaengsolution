-- 운영 감사에서 발견된 승인 우회/검증 stale 상태 보완

alter table public.insurance_requests
  add column if not exists validation_warnings jsonb not null default '[]'::jsonb;

create unique index if not exists uq_insurance_active_acquisition_loss
on public.insurance_requests(employee_id,request_type,effective_date)
where request_type in ('취득','상실') and status not in ('취소','반려');

create or replace function private.guard_insurance_request_insert()
returns trigger language plpgsql set search_path=public,private as $$
begin
  if new.status <> '요청접수' then raise exception 'new insurance request must start as 요청접수'; end if;
  if new.approved_by is not null or new.approved_at is not null or new.submitted_at is not null or new.completed_at is not null then
    raise exception 'approval/submission fields cannot be set on insert';
  end if;
  new.validation_errors := '[]'::jsonb;
  new.validation_warnings := '[]'::jsonb;
  if auth.uid() is not null then new.requested_by := auth.uid(); new.requested_at := now(); end if;
  return new;
end; $$;

drop trigger if exists trg_guard_insurance_request_insert on public.insurance_requests;
create trigger trg_guard_insurance_request_insert before insert on public.insurance_requests
for each row execute function private.guard_insurance_request_insert();

create or replace function private.guard_payroll_period_insert()
returns trigger language plpgsql set search_path=public,private as $$
begin
  if new.status <> '초안' then raise exception 'new payroll period must start as 초안'; end if;
  if new.confirmed_by is not null or new.confirmed_at is not null then raise exception 'confirmation fields cannot be set on insert'; end if;
  new.validation_errors := '[]'::jsonb;
  new.validation_warnings := '[]'::jsonb;
  if auth.uid() is not null then new.created_by := auth.uid(); end if;
  return new;
end; $$;

drop trigger if exists trg_guard_payroll_period_insert on public.payroll_periods;
create trigger trg_guard_payroll_period_insert before insert on public.payroll_periods
for each row execute function private.guard_payroll_period_insert();

create or replace function private.guard_confirmed_payroll_entries()
returns trigger language plpgsql set search_path=public,private as $$
declare v_period_id uuid; v_status text;
begin
  v_period_id := coalesce(new.payroll_period_id,old.payroll_period_id);
  select status into v_status from public.payroll_periods where id=v_period_id for update;
  if v_status in ('확정','신고반영') then raise exception 'confirmed payroll entries are locked'; end if;
  return coalesce(new,old);
end; $$;

create or replace function private.invalidate_payroll_review()
returns trigger language plpgsql set search_path=public,private as $$
declare v_period_id uuid;
begin
  v_period_id := coalesce(new.payroll_period_id,old.payroll_period_id);
  update public.payroll_periods
  set status='초안',validation_errors='[]'::jsonb,validation_warnings='[]'::jsonb,updated_at=now()
  where id=v_period_id and status in ('검토중','오류');
  return coalesce(new,old);
end; $$;

drop trigger if exists trg_invalidate_payroll_review on public.payroll_entries;
create trigger trg_invalidate_payroll_review
after insert or delete or update of payroll_type,work_hours,hourly_rate,base_salary,taxable_allowance,non_taxable_allowance,national_pension,health_insurance,long_term_care,employment_insurance,income_tax,local_income_tax,other_deduction,insurance_request_id
on public.payroll_entries for each row execute function private.invalidate_payroll_review();

create or replace function public.generate_payroll_draft(p_company_id uuid,p_period_month date)
returns uuid language plpgsql security definer set search_path=public,private as $$
declare v_org uuid; v_period uuid; v_status text;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select organization_id into v_org from public.companies where id=p_company_id;
  if v_org is null or not private.has_org_role(v_org,array['owner','admin','reviewer','staff']) then raise exception 'forbidden'; end if;
  select id,status into v_period,v_status from public.payroll_periods
  where company_id=p_company_id and period_month=date_trunc('month',p_period_month)::date for update;
  if v_period is not null and v_status in ('확정','신고반영') then raise exception 'confirmed payroll period cannot be regenerated'; end if;
  if v_period is null then
    insert into public.payroll_periods(company_id,period_month,status,source_type,created_by)
    values(p_company_id,date_trunc('month',p_period_month)::date,'초안','직원마스터',auth.uid()) returning id into v_period;
  end if;
  insert into public.payroll_entries(payroll_period_id,company_id,employee_id,payroll_type,work_hours,hourly_rate,base_salary,insurance_request_id,source_type)
  select v_period,e.company_id,e.id,e.payroll_type,
         case when e.payroll_type='시간제' then 0 else null end,
         e.hourly_rate,
         case when e.payroll_type='월급제' then coalesce(e.monthly_remuneration,0) else 0 end,
         ir.id,'직원마스터'
  from public.employees e
  left join lateral (
    select r.id from public.insurance_requests r
    where r.employee_id=e.id and r.status in ('승인완료','제출대기','접수완료','처리완료')
    order by r.effective_date desc,r.requested_at desc limit 1
  ) ir on true
  where e.company_id=p_company_id
    and (e.hire_date is null or e.hire_date <= (date_trunc('month',p_period_month)+interval '1 month - 1 day')::date)
    and (e.termination_date is null or e.termination_date >= date_trunc('month',p_period_month)::date)
  on conflict(payroll_period_id,employee_id) do nothing;
  return v_period;
end; $$;

create or replace function public.revise_insurance_request(req_id uuid,p_patch jsonb)
returns public.insurance_requests language plpgsql security definer set search_path=public,private as $$
declare r public.insurance_requests; org_id uuid; k text;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'patch object required'; end if;
  for k in select jsonb_object_keys(p_patch) loop
    if k not in ('request_type','effective_date','monthly_remuneration','loss_reason','national_pension','health_insurance','employment_insurance','industrial_accident','payload') then
      raise exception 'field not editable: %',k;
    end if;
  end loop;
  select * into r from public.insurance_requests where id=req_id for update;
  if r.id is null then raise exception 'request not found'; end if;
  select organization_id into org_id from public.companies where id=r.company_id;
  if not private.has_org_role(org_id,array['owner','admin','reviewer','staff']) then raise exception 'forbidden'; end if;
  if r.status not in ('요청접수','검증필요','보완요청','검증완료','승인대기') then raise exception 'approved/submitted request cannot be revised'; end if;
  update public.insurance_requests set
    request_type=case when p_patch ? 'request_type' then p_patch->>'request_type' else request_type end,
    effective_date=case when p_patch ? 'effective_date' then (p_patch->>'effective_date')::date else effective_date end,
    monthly_remuneration=case when p_patch ? 'monthly_remuneration' then nullif(p_patch->>'monthly_remuneration','')::numeric else monthly_remuneration end,
    loss_reason=case when p_patch ? 'loss_reason' then nullif(p_patch->>'loss_reason','') else loss_reason end,
    national_pension=case when p_patch ? 'national_pension' then (p_patch->>'national_pension')::boolean else national_pension end,
    health_insurance=case when p_patch ? 'health_insurance' then (p_patch->>'health_insurance')::boolean else health_insurance end,
    employment_insurance=case when p_patch ? 'employment_insurance' then (p_patch->>'employment_insurance')::boolean else employment_insurance end,
    industrial_accident=case when p_patch ? 'industrial_accident' then (p_patch->>'industrial_accident')::boolean else industrial_accident end,
    payload=case when p_patch ? 'payload' then coalesce(p_patch->'payload','{}'::jsonb) else payload end,
    validation_errors='[]'::jsonb,validation_warnings='[]'::jsonb,status='요청접수',approved_by=null,approved_at=null,updated_at=now()
  where id=req_id returning * into r;
  return r;
end; $$;
revoke all on function public.revise_insurance_request(uuid,jsonb) from public,anon;
grant execute on function public.revise_insurance_request(uuid,jsonb) to authenticated;

create or replace function public.confirm_payroll_period(p_period_id uuid)
returns public.payroll_periods language plpgsql security definer set search_path=public,private as $$
declare v_period public.payroll_periods; v_org uuid; v_result jsonb;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into v_period from public.payroll_periods where id=p_period_id for update;
  if v_period.id is null then raise exception 'payroll period not found'; end if;
  select organization_id into v_org from public.companies where id=v_period.company_id;
  if not private.has_org_role(v_org,array['owner','admin','reviewer']) then raise exception 'confirmation role required'; end if;
  if v_period.status in ('확정','신고반영') then raise exception 'payroll period already confirmed'; end if;
  v_result:=public.validate_payroll_period(p_period_id);
  if jsonb_array_length(coalesce(v_result->'errors','[]'::jsonb))>0 then raise exception 'payroll errors must be resolved first'; end if;
  perform set_config('app.payroll_status_authorized','1',true);
  update public.payroll_periods set status='확정',confirmed_by=auth.uid(),confirmed_at=now(),updated_at=now()
  where id=p_period_id returning * into v_period;
  return v_period;
end; $$;
revoke all on function public.confirm_payroll_period(uuid) from public,anon;
grant execute on function public.confirm_payroll_period(uuid) to authenticated;

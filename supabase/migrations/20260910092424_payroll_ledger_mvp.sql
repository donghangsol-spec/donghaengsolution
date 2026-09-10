-- 급여대장 MVP: 월급제/시간제, 4대보험 요청 연계, 엑셀/연동 입력 기반

alter table public.employees
  add column if not exists payroll_type text not null default '월급제'
    check (payroll_type in ('월급제','시간제')),
  add column if not exists hourly_rate numeric(15,2);

create table if not exists public.payroll_periods (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period_month date not null,
  status text not null default '초안'
    check (status in ('초안','검토중','오류','확정','신고반영')),
  source_type text not null default '직원마스터'
    check (source_type in ('직원마스터','엑셀','연동','혼합')),
  validation_errors jsonb not null default '[]'::jsonb,
  created_by uuid references auth.users(id),
  confirmed_by uuid references auth.users(id),
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,period_month)
);

create table if not exists public.payroll_entries (
  id uuid primary key default gen_random_uuid(),
  payroll_period_id uuid not null references public.payroll_periods(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  payroll_type text not null check (payroll_type in ('월급제','시간제')),
  work_hours numeric(10,2),
  hourly_rate numeric(15,2),
  base_salary numeric(15,2) not null default 0,
  taxable_allowance numeric(15,2) not null default 0,
  non_taxable_allowance numeric(15,2) not null default 0,
  national_pension numeric(15,2) not null default 0,
  health_insurance numeric(15,2) not null default 0,
  long_term_care numeric(15,2) not null default 0,
  employment_insurance numeric(15,2) not null default 0,
  income_tax numeric(15,2) not null default 0,
  local_income_tax numeric(15,2) not null default 0,
  other_deduction numeric(15,2) not null default 0,
  gross_pay numeric(15,2) not null default 0,
  total_deduction numeric(15,2) not null default 0,
  net_pay numeric(15,2) not null default 0,
  insurance_request_id uuid references public.insurance_requests(id) on delete set null,
  source_type text not null default '직원마스터'
    check (source_type in ('직원마스터','엑셀','연동','수동')),
  source_payload jsonb not null default '{}'::jsonb,
  validation_errors jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(payroll_period_id,employee_id)
);

create index if not exists idx_payroll_periods_company_month on public.payroll_periods(company_id,period_month desc);
create index if not exists idx_payroll_entries_period on public.payroll_entries(payroll_period_id);
create index if not exists idx_payroll_entries_employee on public.payroll_entries(employee_id);
create index if not exists idx_payroll_entries_company on public.payroll_entries(company_id);
create index if not exists idx_payroll_entries_insurance_request on public.payroll_entries(insurance_request_id);

alter table public.payroll_periods enable row level security;
alter table public.payroll_entries enable row level security;

create policy "payroll periods select" on public.payroll_periods for select
using (exists(select 1 from public.companies c where c.id=company_id and private.is_org_member(c.organization_id)));
create policy "payroll periods insert" on public.payroll_periods for insert
with check (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));
create policy "payroll periods update" on public.payroll_periods for update
using (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer'])))
with check (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer'])));

create policy "payroll entries select" on public.payroll_entries for select
using (exists(select 1 from public.companies c where c.id=company_id and private.is_org_member(c.organization_id)));
create policy "payroll entries insert" on public.payroll_entries for insert
with check (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));
create policy "payroll entries update" on public.payroll_entries for update
using (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])))
with check (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));

create or replace function private.recalculate_payroll_entry()
returns trigger language plpgsql set search_path=public,private as $$
begin
  if new.payroll_type='시간제' then
    new.base_salary := round(coalesce(new.work_hours,0)*coalesce(new.hourly_rate,0),0);
  end if;
  new.gross_pay := coalesce(new.base_salary,0)+coalesce(new.taxable_allowance,0)+coalesce(new.non_taxable_allowance,0);
  new.total_deduction := coalesce(new.national_pension,0)+coalesce(new.health_insurance,0)+coalesce(new.long_term_care,0)+coalesce(new.employment_insurance,0)+coalesce(new.income_tax,0)+coalesce(new.local_income_tax,0)+coalesce(new.other_deduction,0);
  new.net_pay := new.gross_pay-new.total_deduction;
  new.updated_at := now();
  return new;
end; $$;

drop trigger if exists trg_recalculate_payroll_entry on public.payroll_entries;
create trigger trg_recalculate_payroll_entry before insert or update on public.payroll_entries
for each row execute function private.recalculate_payroll_entry();

create or replace function public.generate_payroll_draft(p_company_id uuid,p_period_month date)
returns uuid language plpgsql security definer set search_path=public,private as $$
declare v_org uuid; v_period uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select organization_id into v_org from public.companies where id=p_company_id;
  if v_org is null or not private.has_org_role(v_org,array['owner','admin','reviewer','staff']) then raise exception 'forbidden'; end if;
  insert into public.payroll_periods(company_id,period_month,status,source_type,created_by)
  values(p_company_id,date_trunc('month',p_period_month)::date,'초안','직원마스터',auth.uid())
  on conflict(company_id,period_month) do update set updated_at=now()
  returning id into v_period;

  insert into public.payroll_entries(payroll_period_id,company_id,employee_id,payroll_type,work_hours,hourly_rate,base_salary,insurance_request_id,source_type)
  select v_period,e.company_id,e.id,e.payroll_type,
         case when e.payroll_type='시간제' then 0 else null end,
         e.hourly_rate,
         case when e.payroll_type='월급제' then coalesce(ir.monthly_remuneration,e.monthly_remuneration,0) else 0 end,
         ir.id,'직원마스터'
  from public.employees e
  left join lateral (
    select r.id,r.monthly_remuneration from public.insurance_requests r
    where r.employee_id=e.id and r.status in ('승인완료','제출대기','접수완료','처리완료')
    order by r.effective_date desc,r.requested_at desc limit 1
  ) ir on true
  where e.company_id=p_company_id
    and (e.hire_date is null or e.hire_date <= (date_trunc('month',p_period_month)+interval '1 month - 1 day')::date)
    and (e.termination_date is null or e.termination_date >= date_trunc('month',p_period_month)::date)
  on conflict(payroll_period_id,employee_id) do nothing;
  return v_period;
end; $$;

create or replace function public.validate_payroll_period(p_period_id uuid)
returns jsonb language plpgsql security definer set search_path=public,private as $$
declare v_period public.payroll_periods; v_org uuid; v_errors jsonb:='[]'::jsonb; v_count int;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into v_period from public.payroll_periods where id=p_period_id;
  if v_period.id is null then return jsonb_build_array('급여대장을 찾을 수 없습니다.'); end if;
  select organization_id into v_org from public.companies where id=v_period.company_id;
  if not private.has_org_role(v_org,array['owner','admin','reviewer','staff']) then raise exception 'forbidden'; end if;
  select count(*) into v_count from public.payroll_entries where payroll_period_id=p_period_id;
  if v_count=0 then v_errors:=v_errors||jsonb_build_array('급여대장에 직원이 없습니다.'); end if;
  update public.payroll_entries pe set validation_errors=errs.errors
  from (
    select id,
      (case when payroll_type='시간제' and (work_hours is null or work_hours<=0) then jsonb_build_array('시간제 직원의 근무시간이 필요합니다.') else '[]'::jsonb end)
      || (case when payroll_type='시간제' and (hourly_rate is null or hourly_rate<=0) then jsonb_build_array('시간제 직원의 시급이 필요합니다.') else '[]'::jsonb end)
      || (case when payroll_type='월급제' and base_salary<=0 then jsonb_build_array('월급제 직원의 기본급을 확인해 주세요.') else '[]'::jsonb end)
      || (case when gross_pay<0 or net_pay<0 then jsonb_build_array('지급액 또는 실지급액이 음수입니다.') else '[]'::jsonb end) as errors
    from public.payroll_entries where payroll_period_id=p_period_id
  ) errs where pe.id=errs.id;
  if exists(select 1 from public.payroll_entries where payroll_period_id=p_period_id and jsonb_array_length(validation_errors)>0) then
    v_errors:=v_errors||jsonb_build_array('직원별 급여 오류가 있습니다.');
  end if;
  update public.payroll_periods set validation_errors=v_errors,status=case when jsonb_array_length(v_errors)=0 then '검토중' else '오류' end,updated_at=now() where id=p_period_id;
  return v_errors;
end; $$;

revoke all on function public.generate_payroll_draft(uuid,date) from public,anon;
grant execute on function public.generate_payroll_draft(uuid,date) to authenticated;
revoke all on function public.validate_payroll_period(uuid) from public,anon;
grant execute on function public.validate_payroll_period(uuid) to authenticated;

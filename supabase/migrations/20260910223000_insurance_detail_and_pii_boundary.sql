alter table public.employees
  add column if not exists monthly_base_salary numeric(15,2);

update public.employees
set monthly_base_salary = monthly_remuneration
where monthly_base_salary is null and monthly_remuneration is not null;

alter table public.employees drop constraint if exists employees_nonnegative_monthly_base_salary;
alter table public.employees add constraint employees_nonnegative_monthly_base_salary
check (monthly_base_salary is null or monthly_base_salary >= 0);

create table if not exists public.insurance_request_details (
  id uuid primary key default gen_random_uuid(),
  insurance_request_id uuid not null references public.insurance_requests(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  insurance_type text not null check (insurance_type in ('국민연금','건강보험','고용보험','산재보험')),
  effective_date date not null,
  remuneration_amount numeric(15,2),
  weekly_hours numeric(8,2),
  contract_end_date date,
  occupation_code text,
  nationality_code text,
  visa_status_code text,
  eligibility_status text not null default '미판정'
    check (eligibility_status in ('미판정','가입대상','적용제외','확인필요')),
  exclusion_code text,
  eligibility_evidence jsonb not null default '{}'::jsonb,
  validation_errors jsonb not null default '[]'::jsonb,
  validation_warnings jsonb not null default '[]'::jsonb,
  source_type text not null default '요청기본값'
    check (source_type in ('요청기본값','수동','연동')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(insurance_request_id, insurance_type),
  check (remuneration_amount is null or remuneration_amount >= 0),
  check (weekly_hours is null or weekly_hours >= 0)
);

create index if not exists idx_insurance_request_details_request on public.insurance_request_details(insurance_request_id);
create index if not exists idx_insurance_request_details_employee on public.insurance_request_details(employee_id, insurance_type);
create index if not exists idx_insurance_request_details_company on public.insurance_request_details(company_id, insurance_type, effective_date desc);

alter table public.insurance_request_details enable row level security;

create policy "insurance request details select" on public.insurance_request_details for select
using (exists(select 1 from public.companies c where c.id=company_id and private.is_org_member(c.organization_id)));

create policy "insurance request details insert" on public.insurance_request_details for insert
with check (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));

create policy "insurance request details update" on public.insurance_request_details for update
using (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])))
with check (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));

create or replace function private.guard_insurance_detail_integrity()
returns trigger language plpgsql set search_path=public,private as $$
declare r public.insurance_requests; e public.employees;
begin
  select * into r from public.insurance_requests where id=new.insurance_request_id;
  if r.id is null then raise exception 'insurance request not found'; end if;
  if r.company_id <> new.company_id or r.employee_id <> new.employee_id then
    raise exception 'insurance detail request/company/employee mismatch';
  end if;
  select * into e from public.employees where id=new.employee_id;
  if e.id is null or e.company_id <> new.company_id then
    raise exception 'insurance detail employee/company mismatch';
  end if;
  if r.status in ('승인완료','제출대기','접수완료','처리완료','반려','취소') then
    raise exception 'approved or closed insurance request details are locked';
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_guard_insurance_detail_integrity on public.insurance_request_details;
create trigger trg_guard_insurance_detail_integrity
before insert or update on public.insurance_request_details
for each row execute function private.guard_insurance_detail_integrity();

create or replace function private.sync_insurance_request_details()
returns trigger language plpgsql set search_path=public,private as $$
begin
  if new.status in ('승인완료','제출대기','접수완료','처리완료','반려','취소') then
    return new;
  end if;
  if new.national_pension then
    insert into public.insurance_request_details(insurance_request_id,company_id,employee_id,insurance_type,effective_date,remuneration_amount,source_type)
    values(new.id,new.company_id,new.employee_id,'국민연금',new.effective_date,new.monthly_remuneration,'요청기본값')
    on conflict(insurance_request_id,insurance_type) do update set effective_date=excluded.effective_date,remuneration_amount=excluded.remuneration_amount,updated_at=now()
    where public.insurance_request_details.source_type='요청기본값';
  else delete from public.insurance_request_details where insurance_request_id=new.id and insurance_type='국민연금' and source_type='요청기본값'; end if;
  if new.health_insurance then
    insert into public.insurance_request_details(insurance_request_id,company_id,employee_id,insurance_type,effective_date,remuneration_amount,source_type)
    values(new.id,new.company_id,new.employee_id,'건강보험',new.effective_date,new.monthly_remuneration,'요청기본값')
    on conflict(insurance_request_id,insurance_type) do update set effective_date=excluded.effective_date,remuneration_amount=excluded.remuneration_amount,updated_at=now()
    where public.insurance_request_details.source_type='요청기본값';
  else delete from public.insurance_request_details where insurance_request_id=new.id and insurance_type='건강보험' and source_type='요청기본값'; end if;
  if new.employment_insurance then
    insert into public.insurance_request_details(insurance_request_id,company_id,employee_id,insurance_type,effective_date,remuneration_amount,source_type)
    values(new.id,new.company_id,new.employee_id,'고용보험',new.effective_date,new.monthly_remuneration,'요청기본값')
    on conflict(insurance_request_id,insurance_type) do update set effective_date=excluded.effective_date,remuneration_amount=excluded.remuneration_amount,updated_at=now()
    where public.insurance_request_details.source_type='요청기본값';
  else delete from public.insurance_request_details where insurance_request_id=new.id and insurance_type='고용보험' and source_type='요청기본값'; end if;
  if new.industrial_accident then
    insert into public.insurance_request_details(insurance_request_id,company_id,employee_id,insurance_type,effective_date,remuneration_amount,source_type)
    values(new.id,new.company_id,new.employee_id,'산재보험',new.effective_date,new.monthly_remuneration,'요청기본값')
    on conflict(insurance_request_id,insurance_type) do update set effective_date=excluded.effective_date,remuneration_amount=excluded.remuneration_amount,updated_at=now()
    where public.insurance_request_details.source_type='요청기본값';
  else delete from public.insurance_request_details where insurance_request_id=new.id and insurance_type='산재보험' and source_type='요청기본값'; end if;
  return new;
end $$;

drop trigger if exists trg_sync_insurance_request_details on public.insurance_requests;
create trigger trg_sync_insurance_request_details
after insert or update of effective_date,monthly_remuneration,national_pension,health_insurance,employment_insurance,industrial_accident on public.insurance_requests
for each row execute function private.sync_insurance_request_details();

insert into public.insurance_request_details(insurance_request_id,company_id,employee_id,insurance_type,effective_date,remuneration_amount,source_type)
select r.id,r.company_id,r.employee_id,x.insurance_type,r.effective_date,r.monthly_remuneration,'요청기본값'
from public.insurance_requests r
cross join lateral (values ('국민연금',r.national_pension),('건강보험',r.health_insurance),('고용보험',r.employment_insurance),('산재보험',r.industrial_accident)) x(insurance_type,selected)
where x.selected
on conflict(insurance_request_id,insurance_type) do nothing;

create table if not exists private.employee_identity_secrets (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  identity_type text not null check (identity_type in ('주민등록번호','외국인등록번호')),
  vault_secret_id uuid not null,
  masked_value text not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
revoke all on private.employee_identity_secrets from public,anon,authenticated;
grant select,insert,update,delete on private.employee_identity_secrets to service_role;

create or replace function private.store_employee_identity_secret(p_employee_id uuid,p_identity_type text,p_plain_identifier text)
returns uuid language plpgsql security definer set search_path=public,private,vault as $$
declare v_company uuid; v_secret uuid; v_clean text; v_existing uuid;
begin
  if p_identity_type not in ('주민등록번호','외국인등록번호') then raise exception 'invalid identity type'; end if;
  v_clean := regexp_replace(coalesce(p_plain_identifier,''),'[^0-9A-Za-z]','','g');
  if length(v_clean) < 8 then raise exception 'invalid identifier'; end if;
  select company_id into v_company from public.employees where id=p_employee_id;
  if v_company is null then raise exception 'employee not found'; end if;
  select vault_secret_id into v_existing from private.employee_identity_secrets where employee_id=p_employee_id;
  if v_existing is null then
    v_secret := vault.create_secret(p_plain_identifier,'employee_identity:'||p_employee_id::text,'Encrypted employee identity identifier',null);
  else
    perform vault.update_secret(v_existing,p_plain_identifier,null,null,null);
    v_secret := v_existing;
  end if;
  insert into private.employee_identity_secrets(employee_id,company_id,identity_type,vault_secret_id,masked_value,updated_by,updated_at)
  values(p_employee_id,v_company,p_identity_type,v_secret,'***-***-'||right(v_clean,4),auth.uid(),now())
  on conflict(employee_id) do update set company_id=excluded.company_id,identity_type=excluded.identity_type,vault_secret_id=excluded.vault_secret_id,masked_value=excluded.masked_value,updated_by=excluded.updated_by,updated_at=now();
  return v_secret;
end $$;
revoke all on function private.store_employee_identity_secret(uuid,text,text) from public,anon,authenticated;
grant execute on function private.store_employee_identity_secret(uuid,text,text) to service_role;

comment on table private.employee_identity_secrets is '민감 식별번호 원문은 Supabase Vault에만 저장하고, 업무 테이블에는 Vault 참조와 마스킹 값만 보관한다.';
comment on column public.employees.monthly_base_salary is '실제 급여대장 초안의 월 기본급. 4대보험 신고 보수월액과 분리한다.';
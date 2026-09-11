-- 4대보험 취득/상실 자동화 MVP migration
-- 고객 요청 -> 검증 -> 담당자 승인 -> 제출대기 -> 접수/처리결과 관리
-- 보안: 공동인증서 원본/비밀번호 저장 컬럼 없음

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_no text,
  name text not null,
  resident_id_masked text,
  birth_date date,
  hire_date date,
  termination_date date,
  monthly_remuneration numeric(15,2),
  weekly_hours numeric(6,2),
  employment_type text,
  phone text,
  status text not null default '재직' check (status in ('입사예정','재직','퇴사예정','퇴사')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.insurance_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  request_type text not null check (request_type in ('취득','상실','변경')),
  effective_date date not null,
  national_pension boolean not null default true,
  health_insurance boolean not null default true,
  employment_insurance boolean not null default true,
  industrial_accident boolean not null default true,
  monthly_remuneration numeric(15,2),
  loss_reason text,
  payload jsonb not null default '{}'::jsonb,
  validation_errors jsonb not null default '[]'::jsonb,
  status text not null default '요청접수' check (status in ('요청접수','검증필요','보완요청','검증완료','승인대기','승인완료','제출대기','접수완료','처리완료','반려','취소')),
  requested_by uuid references auth.users(id),
  requested_at timestamptz not null default now(),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  submitted_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.insurance_submissions (
  id uuid primary key default gen_random_uuid(),
  insurance_request_id uuid not null references public.insurance_requests(id) on delete cascade,
  channel text not null default 'EDI',
  provider text,
  external_receipt_no text,
  external_status text,
  response_payload jsonb not null default '{}'::jsonb,
  error_code text,
  error_message text,
  attempt_no integer not null default 1,
  submitted_by uuid references auth.users(id),
  submitted_at timestamptz,
  checked_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.insurance_delegations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  delegate_type text not null default '업무대행',
  status text not null default '미등록' check (status in ('미등록','신청중','유효','만료','해임')),
  valid_from date,
  valid_until date,
  reference_no text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_employees_company_status on public.employees(company_id, status);
create index if not exists idx_insurance_requests_company_status on public.insurance_requests(company_id, status, requested_at desc);
create index if not exists idx_insurance_requests_employee on public.insurance_requests(employee_id, effective_date desc);
create index if not exists idx_insurance_submissions_request on public.insurance_submissions(insurance_request_id, created_at desc);
create index if not exists idx_insurance_delegations_company on public.insurance_delegations(company_id, status);

alter table public.employees enable row level security;
alter table public.insurance_requests enable row level security;
alter table public.insurance_submissions enable row level security;
alter table public.insurance_delegations enable row level security;

create policy "employees_select" on public.employees for select
using (exists (select 1 from public.companies c where c.id = company_id and private.is_org_member(c.organization_id)));
create policy "employees_insert" on public.employees for insert
with check (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));
create policy "employees_update" on public.employees for update
using (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer'])))
with check (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer'])));
create policy "employees_delete" on public.employees for delete
using (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin'])));

create policy "insurance_requests_select" on public.insurance_requests for select
using (exists (select 1 from public.companies c where c.id = company_id and private.is_org_member(c.organization_id)));
create policy "insurance_requests_insert" on public.insurance_requests for insert
with check (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));
create policy "insurance_requests_update" on public.insurance_requests for update
using (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer'])))
with check (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer'])));
create policy "insurance_requests_delete" on public.insurance_requests for delete
using (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin'])));

create policy "insurance_submissions_select" on public.insurance_submissions for select
using (exists (select 1 from public.insurance_requests r join public.companies c on c.id = r.company_id where r.id = insurance_request_id and private.is_org_member(c.organization_id)));

create policy "insurance_delegations_select" on public.insurance_delegations for select
using (exists (select 1 from public.companies c where c.id = company_id and private.is_org_member(c.organization_id)));
create policy "insurance_delegations_insert" on public.insurance_delegations for insert
with check (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin'])));
create policy "insurance_delegations_update" on public.insurance_delegations for update
using (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin'])))
with check (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin'])));
create policy "insurance_delegations_delete" on public.insurance_delegations for delete
using (exists (select 1 from public.companies c where c.id = company_id and private.has_org_role(c.organization_id,array['owner','admin'])));

create or replace function public.validate_insurance_request(req_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  r public.insurance_requests;
  e public.employees;
  errors jsonb := '[]'::jsonb;
  org_id uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into r from public.insurance_requests where id = req_id;
  if r.id is null then return jsonb_build_array('요청을 찾을 수 없습니다.'); end if;
  select c.organization_id into org_id from public.companies c where c.id = r.company_id;
  if not private.is_org_member(org_id) then raise exception 'forbidden'; end if;
  select * into e from public.employees where id = r.employee_id;
  if e.name is null or btrim(e.name) = '' then errors := errors || jsonb_build_array('직원명이 필요합니다.'); end if;
  if r.request_type = '취득' and e.hire_date is null then errors := errors || jsonb_build_array('취득신고에는 입사일이 필요합니다.'); end if;
  if r.request_type = '상실' and e.termination_date is null then errors := errors || jsonb_build_array('상실신고에는 퇴사일이 필요합니다.'); end if;
  if r.monthly_remuneration is null or r.monthly_remuneration < 0 then errors := errors || jsonb_build_array('보수월액을 확인해 주세요.'); end if;
  update public.insurance_requests
  set validation_errors = errors,
      status = case when jsonb_array_length(errors) = 0 then '검증완료' else '보완요청' end,
      updated_at = now()
  where id = req_id;
  return errors;
end;
$$;
revoke all on function public.validate_insurance_request(uuid) from public, anon;
grant execute on function public.validate_insurance_request(uuid) to authenticated;

comment on table public.insurance_requests is '4대보험 취득/상실/변경 요청 상태 관리. 인증서 원본 및 비밀번호 저장 금지.';

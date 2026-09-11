-- 급여 엑셀/외부연동 가져오기 추적
create table if not exists public.payroll_import_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payroll_period_id uuid references public.payroll_periods(id) on delete cascade,
  source_type text not null check (source_type in ('엑셀','연동')),
  source_name text,
  status text not null default '접수' check (status in ('접수','검증중','오류','반영완료','취소')),
  row_count integer not null default 0 check (row_count >= 0),
  matched_count integer not null default 0 check (matched_count >= 0),
  error_count integer not null default 0 check (error_count >= 0),
  warning_count integer not null default 0 check (warning_count >= 0),
  summary jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.payroll_import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.payroll_import_batches(id) on delete cascade,
  row_no integer not null check (row_no > 0),
  employee_no text,
  employee_name text,
  matched_employee_id uuid references public.employees(id),
  raw_payload jsonb not null default '{}'::jsonb,
  status text not null default '검증대기' check (status in ('검증대기','매칭완료','미매칭','중복','오류','반영완료')),
  validation_errors jsonb not null default '[]'::jsonb,
  validation_warnings jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  unique(batch_id,row_no)
);

create index if not exists idx_payroll_import_batches_company_created on public.payroll_import_batches(company_id,created_at desc);
create index if not exists idx_payroll_import_batches_period on public.payroll_import_batches(payroll_period_id);
create index if not exists idx_payroll_import_batches_created_by on public.payroll_import_batches(created_by);
create index if not exists idx_payroll_import_rows_batch on public.payroll_import_rows(batch_id,row_no);
create index if not exists idx_payroll_import_rows_employee on public.payroll_import_rows(matched_employee_id);

alter table public.payroll_import_batches enable row level security;
alter table public.payroll_import_rows enable row level security;

create policy "payroll import batches select" on public.payroll_import_batches for select
using (exists(select 1 from public.companies c where c.id=company_id and private.is_org_member(c.organization_id)));
create policy "payroll import batches insert" on public.payroll_import_batches for insert
with check (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));
create policy "payroll import batches update" on public.payroll_import_batches for update
using (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])))
with check (exists(select 1 from public.companies c where c.id=company_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));

create policy "payroll import rows select" on public.payroll_import_rows for select
using (exists(select 1 from public.payroll_import_batches b join public.companies c on c.id=b.company_id where b.id=batch_id and private.is_org_member(c.organization_id)));
create policy "payroll import rows insert" on public.payroll_import_rows for insert
with check (exists(select 1 from public.payroll_import_batches b join public.companies c on c.id=b.company_id where b.id=batch_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));
create policy "payroll import rows update" on public.payroll_import_rows for update
using (exists(select 1 from public.payroll_import_batches b join public.companies c on c.id=b.company_id where b.id=batch_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])))
with check (exists(select 1 from public.payroll_import_batches b join public.companies c on c.id=b.company_id where b.id=batch_id and private.has_org_role(c.organization_id,array['owner','admin','reviewer','staff'])));

comment on table public.payroll_import_batches is '급여 엑셀/외부연동 가져오기 단위 추적';
comment on table public.payroll_import_rows is '급여 가져오기 행별 매칭 및 오류 추적';
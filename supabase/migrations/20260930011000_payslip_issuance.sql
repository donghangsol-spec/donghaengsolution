-- 급여명세서 발급
-- 지금까지는 급여를 확정하는 기능(validate/confirm)까지는 있었지만, 확정된
-- 급여를 직원별 명세서 형태로 안전하게 조회하거나, 누가 언제 명세서를
-- 내보냈는지 남기는 기능이 없었다.
--
-- 실제 PDF 렌더링은 화면(프론트엔드) 쪽 몫이다. 이 마이그레이션은
-- (1) 명세서에 필요한 데이터를 안전하게 한 번에 모아주는 조회 RPC와
-- (2) "누가 언제 어떤 방식으로 내려받았는지" 남기는 발급 이력만 담당한다.

create table if not exists public.payslip_issuances (
  id              uuid primary key default gen_random_uuid(),
  entry_id        uuid not null references public.payroll_entries(id) on delete cascade,
  delivery_method text not null default '다운로드' check (delivery_method in ('다운로드','이메일')),
  issued_by       uuid references auth.users(id),
  issued_at       timestamptz not null default now(),
  created_at      timestamptz not null default now()
);

create index if not exists idx_payslip_issuances_entry on public.payslip_issuances(entry_id);

alter table public.payslip_issuances enable row level security;

-- 조회: 그 급여행이 속한 사업장 구성원이면 누구나 (payroll_entries_select와 동일 기준)
create policy "payslip_issuances_select" on public.payslip_issuances for select
using (
  exists (
    select 1 from public.payroll_entries pe
    join public.companies c on c.id = pe.company_id
    where pe.id = payslip_issuances.entry_id
      and private.is_org_member(c.organization_id)
  )
);

-- 쓰기는 issue_payslip RPC 전용
create policy "payslip_issuances_no_direct_write" on public.payslip_issuances
for all using (false) with check (false);

-- ---------------------------------------------------------------------
-- 1. 명세서 데이터 조회 — 확정된 급여대장만 가능
-- ---------------------------------------------------------------------
create or replace function public.get_payslip_data(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private
stable
as $$
declare
  v_entry    public.payroll_entries;
  v_period   public.payroll_periods;
  v_company  public.companies;
  v_employee public.employees;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;

  select * into v_entry from public.payroll_entries where id = p_entry_id;
  if v_entry.id is null then raise exception 'payroll entry not found'; end if;

  select * into v_period from public.payroll_periods where id = v_entry.payroll_period_id;
  select * into v_company from public.companies where id = v_period.company_id;

  if not private.is_org_member(v_company.organization_id) then raise exception 'forbidden'; end if;
  if v_period.status <> '확정' then raise exception 'only confirmed payroll periods can issue payslips'; end if;

  select * into v_employee from public.employees where id = v_entry.employee_id;

  return jsonb_build_object(
    '사업장', v_company.name,
    '귀속월', to_char(v_period.period_month, 'YYYY-MM'),
    '확정일', v_period.confirmed_at,
    '직원명', v_employee.name,
    '직원번호', v_employee.employee_no,
    '급여구분', v_entry.payroll_type,
    '근무시간', v_entry.work_hours,
    '시급', v_entry.hourly_rate,
    '기본급', v_entry.base_salary,
    '과세수당', v_entry.taxable_allowance,
    '비과세수당', v_entry.non_taxable_allowance,
    '지급액합계', v_entry.gross_pay,
    '국민연금', v_entry.national_pension,
    '건강보험', v_entry.health_insurance,
    '장기요양보험', v_entry.long_term_care,
    '고용보험', v_entry.employment_insurance,
    '소득세', v_entry.income_tax,
    '지방소득세', v_entry.local_income_tax,
    '기타공제', v_entry.other_deduction,
    '공제액합계', v_entry.total_deduction,
    '실지급액', v_entry.net_pay
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 2. 발급 이력 기록 — 실제 PDF는 화면에서 만들고, 다운로드 시점에
--    이 RPC를 호출해 이력만 남긴다.
-- ---------------------------------------------------------------------
create or replace function public.issue_payslip(p_entry_id uuid, p_delivery_method text default '다운로드')
returns public.payslip_issuances
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_entry    public.payroll_entries;
  v_period   public.payroll_periods;
  v_company  public.companies;
  v_issuance public.payslip_issuances;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;

  select * into v_entry from public.payroll_entries where id = p_entry_id;
  if v_entry.id is null then raise exception 'payroll entry not found'; end if;

  select * into v_period from public.payroll_periods where id = v_entry.payroll_period_id;
  select * into v_company from public.companies where id = v_period.company_id;

  if not private.is_org_member(v_company.organization_id) then raise exception 'forbidden'; end if;
  if v_period.status <> '확정' then raise exception 'only confirmed payroll periods can issue payslips'; end if;
  if p_delivery_method not in ('다운로드','이메일') then raise exception 'invalid delivery method'; end if;

  insert into public.payslip_issuances (entry_id, delivery_method, issued_by)
  values (p_entry_id, p_delivery_method, auth.uid())
  returning * into v_issuance;

  insert into public.audit_logs(organization_id, company_id, actor_user_id, action, target_type, target_id, detail)
  values (v_company.organization_id, v_company.id, auth.uid(), 'PAYSLIP_ISSUED', 'payslip_issuances', v_issuance.id::text,
          jsonb_build_object('entry_id', p_entry_id, 'delivery_method', p_delivery_method));

  return v_issuance;
end;
$$;

revoke all on function public.get_payslip_data(uuid) from public, anon;
revoke all on function public.issue_payslip(uuid, text) from public, anon;

grant execute on function public.get_payslip_data(uuid) to authenticated;
grant execute on function public.issue_payslip(uuid, text) to authenticated;

comment on table public.payslip_issuances is '급여명세서 발급 이력. 실제 PDF 렌더링은 프론트엔드 담당.';

-- 4대보험 자동화 MVP smoke test
-- Supabase SQL Editor 또는 CI에서 마이그레이션 적용 후 실행
-- 데이터 생성 없이 구조/함수 존재 여부를 확인한다.

begin;

do $$
begin
  if to_regclass('public.employees') is null then raise exception 'employees table missing'; end if;
  if to_regclass('public.insurance_requests') is null then raise exception 'insurance_requests table missing'; end if;
  if to_regclass('public.insurance_submissions') is null then raise exception 'insurance_submissions table missing'; end if;
  if to_regclass('public.insurance_delegations') is null then raise exception 'insurance_delegations table missing'; end if;

  if to_regprocedure('public.validate_insurance_request(uuid)') is null then
    raise exception 'validate_insurance_request(uuid) missing';
  end if;
end $$;

-- 상태 제약에 필요한 대표 값들이 정상 입력 가능한지 임시 레코드로 확인한다.
with org as (
  insert into public.organizations(name) values ('SMOKE TEST ORG') returning id
), company as (
  insert into public.companies(organization_id,name)
  select id,'SMOKE TEST COMPANY' from org returning id
), employee as (
  insert into public.employees(company_id,name,hire_date,monthly_remuneration,weekly_hours,status)
  select id,'테스트직원',current_date,3000000,40,'재직' from company returning id,company_id
), request as (
  insert into public.insurance_requests(
    company_id,employee_id,request_type,effective_date,monthly_remuneration,
    national_pension,health_insurance,employment_insurance,industrial_accident,status
  )
  select company_id,id,'취득',current_date,3000000,true,true,true,true,'요청접수'
  from employee
  returning id
)
select public.validate_insurance_request(id) as validation_errors from request;

-- smoke test는 항상 롤백하여 운영 데이터를 남기지 않는다.
rollback;

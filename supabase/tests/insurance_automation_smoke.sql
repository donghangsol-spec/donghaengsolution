-- 4대보험 자동화 MVP smoke test
-- SQL Editor/CI에서는 인증 컨텍스트가 없으므로 RPC 호출 대신 구조/제약을 확인한다.
-- 실제 validate/approve RPC는 로그인 사용자 E2E 테스트에서 검증한다.

begin;

do $$
begin
  if to_regclass('public.employees') is null then raise exception 'employees table missing'; end if;
  if to_regclass('public.insurance_requests') is null then raise exception 'insurance_requests table missing'; end if;
  if to_regclass('public.insurance_submissions') is null then raise exception 'insurance_submissions table missing'; end if;
  if to_regclass('public.insurance_delegations') is null then raise exception 'insurance_delegations table missing'; end if;
  if to_regprocedure('public.validate_insurance_request(uuid)') is null then raise exception 'validate_insurance_request(uuid) missing'; end if;
  if to_regprocedure('public.approve_insurance_request(uuid)') is null then raise exception 'approve_insurance_request(uuid) missing'; end if;
end $$;

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
select count(*) as inserted_request_count from request;

rollback;

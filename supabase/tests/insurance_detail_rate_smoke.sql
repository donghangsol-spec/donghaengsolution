begin;

do $$
declare v_org uuid; v_company uuid; v_employee uuid; v_request uuid; v_count int;
begin
  if to_regclass('public.insurance_request_details') is null then raise exception 'insurance_request_details missing'; end if;
  if to_regclass('private.employee_identity_secrets') is null then raise exception 'employee_identity_secrets missing'; end if;
  if to_regclass('public.insurance_rule_versions') is null then raise exception 'insurance_rule_versions missing'; end if;
  if to_regclass('public.statutory_rate_versions') is null then raise exception 'statutory_rate_versions missing'; end if;
  if to_regprocedure('public.evaluate_insurance_request_eligibility(uuid)') is null then raise exception 'eligibility rpc missing'; end if;
  if to_regprocedure('public.estimate_payroll_statutory_deductions(uuid)') is null then raise exception 'deduction estimate rpc missing'; end if;
  if has_function_privilege('authenticated','private.store_employee_identity_secret(uuid,text,text)','EXECUTE') then raise exception 'authenticated must not store PII directly'; end if;
  if (select count(*) from public.statutory_rate_versions where effective_from='2026-01-01') <> 5 then raise exception '2026 rate rows missing'; end if;
  if position('monthly_base_salary' in pg_get_functiondef('public.generate_payroll_draft(uuid,date)'::regprocedure)) = 0 then raise exception 'payroll draft is not using monthly_base_salary'; end if;

  insert into public.organizations(name) values('INSURANCE DETAIL SMOKE') returning id into v_org;
  insert into public.companies(organization_id,name) values(v_org,'DETAIL COMPANY') returning id into v_company;
  insert into public.employees(company_id,name,birth_date,hire_date,monthly_base_salary,monthly_remuneration,weekly_hours,payroll_type,status)
  values(v_company,'테스트직원','1990-01-01','2026-09-01',2500000,2300000,40,'월급제','재직') returning id into v_employee;
  insert into public.insurance_requests(company_id,employee_id,request_type,effective_date,national_pension,health_insurance,employment_insurance,industrial_accident,monthly_remuneration,status)
  values(v_company,v_employee,'취득','2026-09-01',true,true,true,true,2300000,'요청접수') returning id into v_request;
  select count(*) into v_count from public.insurance_request_details where insurance_request_id=v_request;
  if v_count<>4 then raise exception 'expected 4 insurance detail rows, got %',v_count; end if;
  if (select monthly_base_salary from public.employees where id=v_employee) = (select monthly_remuneration from public.insurance_requests where id=v_request) then raise exception 'salary/remuneration separation failed'; end if;
end $$;

rollback;
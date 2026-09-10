-- 급여 가져오기 추적 / 사업장 교차연결 무결성 smoke test
begin;

do $$
begin
  if to_regclass('public.payroll_import_batches') is null then raise exception 'payroll_import_batches missing'; end if;
  if to_regclass('public.payroll_import_rows') is null then raise exception 'payroll_import_rows missing'; end if;
  if not exists(select 1 from pg_indexes where schemaname='public' and indexname='uq_employees_company_employee_no') then
    raise exception 'employee number unique index missing';
  end if;
end $$;

do $$
declare o1 uuid; o2 uuid; c1 uuid; c2 uuid; e1 uuid; p2 uuid; blocked_ins boolean:=false; blocked_pay boolean:=false;
begin
  insert into public.organizations(name) values('IMPORT SMOKE ORG 1') returning id into o1;
  insert into public.organizations(name) values('IMPORT SMOKE ORG 2') returning id into o2;
  insert into public.companies(organization_id,name) values(o1,'IMPORT C1') returning id into c1;
  insert into public.companies(organization_id,name) values(o2,'IMPORT C2') returning id into c2;
  insert into public.employees(company_id,employee_no,name,hire_date,payroll_type,status)
  values(c1,'SMOKE-E1','테스트직원',current_date,'월급제','재직') returning id into e1;
  insert into public.payroll_periods(company_id,period_month,status)
  values(c2,date_trunc('month',current_date)::date,'초안') returning id into p2;

  begin
    insert into public.insurance_requests(company_id,employee_id,request_type,effective_date,monthly_remuneration)
    values(c2,e1,'취득',current_date,1000000);
  exception when others then blocked_ins:=true; end;

  begin
    insert into public.payroll_entries(payroll_period_id,company_id,employee_id,payroll_type,base_salary)
    values(p2,c2,e1,'월급제',1000000);
  exception when others then blocked_pay:=true; end;

  if not blocked_ins then raise exception 'insurance employee/company mismatch not blocked'; end if;
  if not blocked_pay then raise exception 'payroll employee/company mismatch not blocked'; end if;
end $$;

rollback;
-- 승인/확정 우회 및 검증 stale 상태 회귀 방지 테스트
begin;

do $$
declare v_org uuid; v_company uuid; v_employee uuid; v_period uuid; v_entry uuid;
begin
  insert into public.organizations(name) values('WORKFLOW SECURITY SMOKE ORG') returning id into v_org;
  insert into public.companies(organization_id,name) values(v_org,'WORKFLOW SECURITY SMOKE COMPANY') returning id into v_company;
  insert into public.employees(company_id,name,hire_date,status,monthly_remuneration,payroll_type)
  values(v_company,'보안테스트',current_date,'재직',2500000,'월급제') returning id into v_employee;

  begin
    insert into public.insurance_requests(company_id,employee_id,request_type,effective_date,monthly_remuneration,status)
    values(v_company,v_employee,'취득',current_date,2500000,'승인완료');
    raise exception 'insurance approval insert bypass was not blocked';
  exception when others then
    if sqlerrm='insurance approval insert bypass was not blocked' then raise; end if;
  end;

  begin
    insert into public.payroll_periods(company_id,period_month,status)
    values(v_company,date_trunc('month',current_date)::date,'확정');
    raise exception 'payroll confirmation insert bypass was not blocked';
  exception when others then
    if sqlerrm='payroll confirmation insert bypass was not blocked' then raise; end if;
  end;

  insert into public.payroll_periods(company_id,period_month,status)
  values(v_company,date_trunc('month',current_date)::date,'초안') returning id into v_period;
  insert into public.payroll_entries(payroll_period_id,company_id,employee_id,payroll_type,base_salary)
  values(v_period,v_company,v_employee,'월급제',2500000) returning id into v_entry;

  update public.payroll_periods set status='검토중' where id=v_period;
  update public.payroll_entries set base_salary=2600000 where id=v_entry;
  if (select status from public.payroll_periods where id=v_period) <> '초안' then
    raise exception 'payroll review was not invalidated after entry edit';
  end if;
end $$;

select 'workflow_security_regression_smoke_ok' as result;
rollback;

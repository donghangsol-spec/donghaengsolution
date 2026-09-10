-- 급여대장 구조/계산/확정우회 방지 smoke test
begin;

do $$
begin
  if to_regclass('public.payroll_periods') is null then raise exception 'payroll_periods missing'; end if;
  if to_regclass('public.payroll_entries') is null then raise exception 'payroll_entries missing'; end if;
  if to_regprocedure('public.generate_payroll_draft(uuid,date)') is null then raise exception 'generate_payroll_draft missing'; end if;
  if to_regprocedure('public.validate_payroll_period(uuid)') is null then raise exception 'validate_payroll_period missing'; end if;
  if to_regprocedure('public.confirm_payroll_period(uuid)') is null then raise exception 'confirm_payroll_period missing'; end if;
end $$;

create temporary table smoke_ids(period_id uuid, entry_id uuid) on commit drop;

do $$
declare v_org uuid; v_company uuid; v_employee uuid; v_period uuid; v_entry uuid; v_base numeric; v_gross numeric; v_net numeric;
begin
  insert into public.organizations(name) values('PAYROLL SMOKE ORG') returning id into v_org;
  insert into public.companies(organization_id,name) values(v_org,'PAYROLL SMOKE COMPANY') returning id into v_company;
  insert into public.employees(company_id,name,hire_date,payroll_type,hourly_rate,status)
  values(v_company,'시간제테스트',current_date,'시간제',12000,'재직') returning id into v_employee;
  insert into public.payroll_periods(company_id,period_month,status,source_type)
  values(v_company,date_trunc('month',current_date)::date,'초안','직원마스터') returning id into v_period;
  insert into public.payroll_entries(payroll_period_id,company_id,employee_id,payroll_type,work_hours,hourly_rate,taxable_allowance)
  values(v_period,v_company,v_employee,'시간제',80,12000,100000)
  returning id,base_salary,gross_pay,net_pay into v_entry,v_base,v_gross,v_net;
  if v_base <> 960000 then raise exception 'hourly base calculation failed: %',v_base; end if;
  if v_gross <> 1060000 then raise exception 'gross calculation failed: %',v_gross; end if;
  if v_net <> 1060000 then raise exception 'net calculation failed: %',v_net; end if;
  insert into smoke_ids values(v_period,v_entry);
end $$;

-- RPC를 거치지 않은 확정 상태 변경은 차단되어야 한다.
do $$
declare v_period uuid;
begin
  select period_id into v_period from smoke_ids limit 1;
  begin
    update public.payroll_periods set status='확정' where id=v_period;
    raise exception 'direct confirmation was not blocked';
  exception when others then
    if sqlerrm='direct confirmation was not blocked' then raise; end if;
  end;
end $$;

rollback;

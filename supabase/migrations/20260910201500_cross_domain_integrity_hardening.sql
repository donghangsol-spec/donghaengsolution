-- 직원/급여/4대보험 간 데이터 무결성 보강
create unique index if not exists uq_employees_company_employee_no
on public.employees(company_id,employee_no)
where employee_no is not null and btrim(employee_no) <> '';

create or replace function private.enforce_employee_company_match()
returns trigger language plpgsql set search_path=public,private as $$
declare v_company uuid; v_period_company uuid;
begin
  select company_id into v_company from public.employees where id=new.employee_id;
  if v_company is null or v_company <> new.company_id then
    raise exception 'employee/company mismatch';
  end if;
  if tg_table_name='payroll_entries' then
    select company_id into v_period_company from public.payroll_periods where id=new.payroll_period_id;
    if v_period_company is null or v_period_company <> new.company_id then
      raise exception 'payroll period/company mismatch';
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_insurance_employee_company_match on public.insurance_requests;
create trigger trg_insurance_employee_company_match
before insert or update of company_id,employee_id on public.insurance_requests
for each row execute function private.enforce_employee_company_match();

drop trigger if exists trg_payroll_employee_company_match on public.payroll_entries;
create trigger trg_payroll_employee_company_match
before insert or update of company_id,employee_id,payroll_period_id on public.payroll_entries
for each row execute function private.enforce_employee_company_match();

alter table public.employees drop constraint if exists employees_nonnegative_payroll_values;
alter table public.employees add constraint employees_nonnegative_payroll_values check (
  (monthly_remuneration is null or monthly_remuneration >= 0)
  and (weekly_hours is null or weekly_hours >= 0)
  and (hourly_rate is null or hourly_rate >= 0)
  and (termination_date is null or hire_date is null or termination_date >= hire_date)
);

alter table public.payroll_entries drop constraint if exists payroll_entries_nonnegative_inputs;
alter table public.payroll_entries add constraint payroll_entries_nonnegative_inputs check (
  coalesce(work_hours,0) >= 0 and coalesce(hourly_rate,0) >= 0 and base_salary >= 0
  and taxable_allowance >= 0 and non_taxable_allowance >= 0
  and national_pension >= 0 and health_insurance >= 0 and long_term_care >= 0
  and employment_insurance >= 0 and income_tax >= 0 and local_income_tax >= 0 and other_deduction >= 0
);

alter table public.insurance_requests drop constraint if exists insurance_requests_at_least_one_insurance;
alter table public.insurance_requests add constraint insurance_requests_at_least_one_insurance check (
  national_pension or health_insurance or employment_insurance or industrial_accident
);
create index if not exists idx_payroll_entries_company_fk on public.payroll_entries(company_id);
create index if not exists idx_payroll_periods_created_by on public.payroll_periods(created_by);
create index if not exists idx_payroll_periods_confirmed_by on public.payroll_periods(confirmed_by);

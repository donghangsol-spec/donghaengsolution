create index if not exists idx_employee_identity_secrets_company on private.employee_identity_secrets(company_id);

alter function public.evaluate_insurance_request_eligibility(uuid) security invoker;
alter function public.estimate_payroll_statutory_deductions(uuid) security invoker;

revoke all on function public.evaluate_insurance_request_eligibility(uuid) from public,anon;
grant execute on function public.evaluate_insurance_request_eligibility(uuid) to authenticated;
revoke all on function public.estimate_payroll_statutory_deductions(uuid) from public,anon;
grant execute on function public.estimate_payroll_statutory_deductions(uuid) to authenticated;
-- Certificate filing queue structural and duplicate-submission smoke test.
begin;

do $$
declare
  v_org uuid;
  v_company uuid;
  v_employee uuid;
  v_request uuid;
  v_user uuid := gen_random_uuid();
begin
  insert into auth.users(id, aud, role, email)
  values(v_user, 'authenticated', 'authenticated', 'certificate-smoke@example.invalid');

  insert into public.organizations(name)
  values('CERTIFICATE FILING SMOKE ORG')
  returning id into v_org;

  insert into public.companies(organization_id,name)
  values(v_org,'CERTIFICATE FILING SMOKE COMPANY')
  returning id into v_company;

  insert into public.employees(company_id,name,hire_date,status,monthly_remuneration,payroll_type)
  values(v_company,'인증서테스트',current_date,'재직',2500000,'월급제')
  returning id into v_employee;

  insert into public.insurance_requests(
    company_id,employee_id,request_type,effective_date,monthly_remuneration,
    status,approved_by,approved_at
  )
  values(
    v_company,v_employee,'취득',current_date,2500000,
    '승인완료',v_user,now()
  )
  returning id into v_request;

  insert into public.insurance_filing_jobs(
    insurance_request_id,company_id,provider,created_by
  )
  values(v_request,v_company,'4INSURE',v_user);

  begin
    insert into public.insurance_filing_jobs(
      insurance_request_id,company_id,provider,created_by
    )
    values(v_request,v_company,'4INSURE',v_user);
    raise exception 'duplicate active filing job was not blocked';
  exception when unique_violation then
    null;
  end;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='insurance_filing_jobs'
      and column_name in ('certificate','certificate_bytes','private_key','password','credential_ciphertext')
  ) then
    raise exception 'secret-bearing column exists on filing job table';
  end if;
end $$;

select 'certificate_filing_queue_smoke_ok' as result;
rollback;

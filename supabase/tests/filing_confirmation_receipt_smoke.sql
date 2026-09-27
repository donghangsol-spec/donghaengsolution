-- Filing confirmation/receipt security contract smoke test.
begin;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='insurance_filing_jobs'
      and column_name='preview_hash'
  ) then raise exception 'preview hash column missing'; end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.insurance_filing_jobs'::regclass
      and tgname='trg_guard_insurance_filing_job_transition'
      and not tgisinternal
  ) then raise exception 'filing transition guard missing'; end if;

  if has_function_privilege('anon',
      'public.confirm_certificate_filing(uuid,text)','EXECUTE') then
    raise exception 'anon can confirm filing'; end if;

  if not has_function_privilege('authenticated',
      'public.confirm_certificate_filing(uuid,text)','EXECUTE') then
    raise exception 'authenticated role cannot call guarded confirmation RPC'; end if;

  if has_function_privilege('authenticated',
      'private.record_filing_receipt(uuid,text,text,text,text,boolean)','EXECUTE') then
    raise exception 'authenticated role can record trusted-worker receipt'; end if;
end $$;

-- Confirm that protected transitions fail without human confirmation.
do $$
declare
  v_user uuid := gen_random_uuid();
  v_org uuid;
  v_company uuid;
  v_employee uuid;
  v_request uuid;
  v_job uuid;
  v_hash text := repeat('a',64);
begin
  insert into auth.users(id,aud,role,email)
  values(v_user,'authenticated','authenticated','filing-guard@example.invalid');

  insert into public.organizations(name) values('FILING GUARD TEST') returning id into v_org;
  insert into public.companies(organization_id,name) values(v_org,'FILING GUARD COMPANY') returning id into v_company;
  insert into public.employees(company_id,name,hire_date,status,payroll_type)
  values(v_company,'FILING GUARD EMPLOYEE',current_date,'재직','월급제') returning id into v_employee;
  insert into public.insurance_requests(
    company_id,employee_id,request_type,effective_date,status
  ) values(v_company,v_employee,'취득',current_date,'요청접수')
  returning id into v_request;
  insert into public.insurance_filing_jobs(
    insurance_request_id,company_id,provider,status,created_by,preview_hash,preview_created_at
  ) values(v_request,v_company,'4INSURE','awaiting_human_confirmation',v_user,v_hash,now())
  returning id into v_job;

  begin
    update public.insurance_filing_jobs set status='submitting' where id=v_job;
    raise exception 'submission without human confirmation was not blocked';
  exception when others then
    if sqlerrm='submission without human confirmation was not blocked' then raise; end if;
  end;
end $$;

select 'filing_confirmation_receipt_smoke_ok' as result;
rollback;

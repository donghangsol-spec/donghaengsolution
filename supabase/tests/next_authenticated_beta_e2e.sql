-- NEXT authenticated beta E2E. auth.users 테스트 계정과 업무데이터를 트랜잭션 안에서 만들고 전부 rollback한다.
begin;
create temporary table beta_ids(owner_id uuid, staff_id uuid, org_id uuid, company_id uuid, monthly_employee uuid, hourly_employee uuid, request_id uuid, period_id uuid) on commit drop;

do $$
declare
  v_owner uuid:=gen_random_uuid(); v_staff uuid:=gen_random_uuid(); v_org uuid; v_company uuid; v_monthly uuid; v_hourly uuid; v_request uuid; v_period uuid;
  v_err jsonb; v_d jsonb; v_count int; v_blocked boolean; rec record; v_entry uuid;
begin
  insert into auth.users(id,aud,role,email,email_confirmed_at,created_at,updated_at,is_sso_user,is_anonymous)
  values
    (v_owner,'authenticated','authenticated','next-owner-'||replace(v_owner::text,'-','')||'@invalid.local',now(),now(),now(),false,false),
    (v_staff,'authenticated','authenticated','next-staff-'||replace(v_staff::text,'-','')||'@invalid.local',now(),now(),now(),false,false);
  insert into public.organizations(name) values('NEXT BETA E2E ORG') returning id into v_org;
  insert into public.organization_members(organization_id,user_id,role) values(v_org,v_owner,'owner'),(v_org,v_staff,'staff');
  insert into public.companies(organization_id,name,account_type,company_type,is_active)
  values(v_org,'NEXT BETA COMPANY','비영리','장기요양기관',true) returning id into v_company;
  insert into public.employees(company_id,employee_no,name,birth_date,hire_date,monthly_base_salary,monthly_remuneration,weekly_hours,payroll_type,status)
  values(v_company,'NEXT-M01','월급직원','1990-01-01','2026-09-01',3000000,2800000,40,'월급제','재직') returning id into v_monthly;
  insert into public.employees(company_id,employee_no,name,birth_date,hire_date,hourly_rate,weekly_hours,payroll_type,status)
  values(v_company,'NEXT-H01','시간직원','1995-01-01','2026-09-01',12000,20,'시간제','재직') returning id into v_hourly;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  insert into public.insurance_requests(company_id,employee_id,request_type,effective_date,monthly_remuneration,national_pension,health_insurance,employment_insurance,industrial_accident,status)
  values(v_company,v_monthly,'취득','2026-09-01',2800000,true,true,true,true,'요청접수') returning id into v_request;
  select count(*) into v_count from public.insurance_request_details where insurance_request_id=v_request;
  if v_count<>4 then raise exception 'expected 4 insurance detail rows'; end if;
  v_err:=public.validate_insurance_request(v_request);
  if jsonb_array_length(v_err)<>0 then raise exception 'insurance validation failed: %',v_err; end if;
  if (select count(*) from public.insurance_request_details where insurance_request_id=v_request and eligibility_status='확인필요')<>3 then raise exception 'expected 3 review details'; end if;
  if (select count(*) from public.insurance_request_details where insurance_request_id=v_request and insurance_type='국민연금' and eligibility_status='가입대상')<>1 then raise exception 'pension eligibility missing'; end if;

  v_blocked:=false; begin perform public.approve_insurance_request(v_request); exception when others then v_blocked:=true; end;
  if not v_blocked then raise exception 'approval without detail review was not blocked'; end if;

  perform set_config('request.jwt.claim.sub',v_staff::text,true);
  select id into v_entry from public.insurance_request_details where insurance_request_id=v_request and eligibility_status='확인필요' limit 1;
  v_blocked:=false; begin perform public.acknowledge_insurance_detail(v_entry,'staff fail'); exception when others then v_blocked:=true; end;
  if not v_blocked then raise exception 'staff review acknowledgement was not blocked'; end if;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  for rec in select id from public.insurance_request_details where insurance_request_id=v_request and eligibility_status='확인필요' loop
    perform public.acknowledge_insurance_detail(rec.id,'NEXT beta 담당자 검토');
  end loop;
  perform public.approve_insurance_request(v_request);
  if (select status from public.insurance_requests where id=v_request)<>'승인완료' then raise exception 'insurance approval failed'; end if;

  v_blocked:=false; begin perform public.revise_insurance_request(v_request,jsonb_build_object('monthly_remuneration',2900000)); exception when others then v_blocked:=true; end;
  if not v_blocked then raise exception 'approved request revision was not blocked'; end if;
  v_blocked:=false; begin update public.insurance_request_details set remuneration_amount=2900000 where insurance_request_id=v_request and insurance_type='국민연금'; exception when others then v_blocked:=true; end;
  if not v_blocked then raise exception 'approved detail update was not blocked'; end if;
  v_blocked:=false; begin
    insert into public.insurance_requests(company_id,employee_id,request_type,effective_date,monthly_remuneration,national_pension,health_insurance,employment_insurance,industrial_accident,status)
    values(v_company,v_monthly,'취득','2026-09-01',2800000,true,true,true,true,'요청접수');
  exception when others then v_blocked:=true; end;
  if not v_blocked then raise exception 'duplicate acquisition was not blocked'; end if;

  perform set_config('request.jwt.claim.sub',v_staff::text,true);
  v_period:=public.generate_payroll_draft(v_company,'2026-09-01');
  select id into v_entry from public.payroll_entries where payroll_period_id=v_period and employee_id=v_hourly;
  update public.payroll_entries set work_hours=80 where id=v_entry;
  v_d:=public.validate_payroll_period(v_period);
  if jsonb_array_length(coalesce(v_d->'errors','[]'::jsonb))<>0 then raise exception 'payroll validation failed: %',v_d; end if;
  if (select base_salary from public.payroll_entries where id=v_entry)<>960000 then raise exception 'hourly calculation wrong'; end if;
  v_blocked:=false; begin perform public.confirm_payroll_period(v_period); exception when others then v_blocked:=true; end;
  if not v_blocked then raise exception 'staff confirmation was not blocked'; end if;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform public.confirm_payroll_period(v_period);
  if (select status from public.payroll_periods where id=v_period)<>'확정' then raise exception 'owner confirmation failed'; end if;
  v_blocked:=false; begin update public.payroll_entries set work_hours=81 where id=v_entry; exception when others then v_blocked:=true; end;
  if not v_blocked then raise exception 'confirmed payroll edit was not blocked'; end if;
  v_blocked:=false; begin perform public.generate_payroll_draft(v_company,'2026-09-01'); exception when others then v_blocked:=true; end;
  if not v_blocked then raise exception 'confirmed payroll regeneration was not blocked'; end if;

  select id into v_entry from public.payroll_entries where payroll_period_id=v_period and employee_id=v_monthly;
  v_d:=public.estimate_payroll_statutory_deductions(v_entry);
  if coalesce((v_d->>'national_pension')::numeric,0)<=0 or coalesce((v_d->>'health_insurance')::numeric,0)<=0 or coalesce((v_d->>'employment_insurance')::numeric,0)<=0 then raise exception 'deduction estimate missing: %',v_d; end if;
  insert into beta_ids values(v_owner,v_staff,v_org,v_company,v_monthly,v_hourly,v_request,v_period);
end $$;

select 'NEXT_AUTHENTICATED_BETA_E2E_OK' as result,
       (select count(*) from public.insurance_request_details d join beta_ids b on b.request_id=d.insurance_request_id) as insurance_detail_rows,
       (select count(*) from public.payroll_entries p join beta_ids b on b.period_id=p.payroll_period_id) as payroll_rows;
rollback;
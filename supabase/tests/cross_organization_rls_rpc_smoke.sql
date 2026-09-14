-- Cross-organization RLS and privileged RPC isolation smoke test.
-- Run in a transaction; all fixtures are rolled back.
begin;

insert into auth.users(id,aud,role,email) values
('10000000-0000-4000-8000-000000000001','authenticated','authenticated','cross-a@example.invalid'),
('20000000-0000-4000-8000-000000000002','authenticated','authenticated','cross-b@example.invalid');

insert into public.organizations(id,name) values
('a0000000-0000-4000-8000-000000000001','RLS CROSS ORG A'),
('b0000000-0000-4000-8000-000000000002','RLS CROSS ORG B');

insert into public.organization_members(organization_id,user_id,role) values
('a0000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','owner'),
('b0000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000002','owner');

insert into public.companies(id,organization_id,name) values
('a1000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001','RLS COMPANY A'),
('b1000000-0000-4000-8000-000000000002','b0000000-0000-4000-8000-000000000002','RLS COMPANY B');

insert into public.employees(id,company_id,name,hire_date,status,payroll_type,monthly_base_salary,monthly_remuneration)
values('b2000000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000002','RLS EMPLOYEE B',current_date,'재직','월급제',2500000,2500000);

insert into public.insurance_requests(id,company_id,employee_id,request_type,effective_date,monthly_remuneration,status)
values('b3000000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000002','b2000000-0000-4000-8000-000000000002','취득',current_date,2500000,'요청접수');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}',true);

do $$
declare v_count int; v_rows int;
begin
  select count(*) into v_count from public.companies where id='b1000000-0000-4000-8000-000000000002';
  if v_count<>0 then raise exception 'cross-org company read allowed'; end if;

  select count(*) into v_count from public.employees where company_id='b1000000-0000-4000-8000-000000000002';
  if v_count<>0 then raise exception 'cross-org employee read allowed'; end if;

  select count(*) into v_count from public.insurance_requests where company_id='b1000000-0000-4000-8000-000000000002';
  if v_count<>0 then raise exception 'cross-org insurance read allowed'; end if;

  update public.employees set name='CROSS ORG MUTATION' where id='b2000000-0000-4000-8000-000000000002';
  get diagnostics v_rows=row_count;
  if v_rows<>0 then raise exception 'cross-org employee update allowed'; end if;

  begin
    perform public.validate_insurance_request('b3000000-0000-4000-8000-000000000002');
    raise exception 'cross-org validation RPC allowed';
  exception when others then
    if sqlerrm='cross-org validation RPC allowed' then raise; end if;
    if sqlerrm<>'forbidden' then raise exception 'unexpected RPC error: %',sqlerrm; end if;
  end;
end $$;

reset role;
select 'cross_organization_rls_rpc_smoke_ok' as result;
rollback;

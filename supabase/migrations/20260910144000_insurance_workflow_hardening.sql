-- 4대보험 workflow hardening
-- 운영 DB 권한 구조(private.is_org_member / private.has_org_role)에 맞춘 보안 보강

create index if not exists idx_insurance_requests_requested_by on public.insurance_requests(requested_by);
create index if not exists idx_insurance_requests_approved_by on public.insurance_requests(approved_by);
create index if not exists idx_insurance_submissions_submitted_by on public.insurance_submissions(submitted_by);

create or replace function public.validate_insurance_request(req_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  r public.insurance_requests;
  e public.employees;
  errors jsonb := '[]'::jsonb;
  org_id uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;

  select r0.* into r
  from public.insurance_requests r0
  where r0.id = req_id;

  if r.id is null then
    return jsonb_build_array('요청을 찾을 수 없습니다.');
  end if;

  select c.organization_id into org_id
  from public.companies c
  where c.id = r.company_id;

  if not private.is_org_member(org_id) then raise exception 'forbidden'; end if;

  select * into e from public.employees where id = r.employee_id;

  if e.id is null then errors := errors || jsonb_build_array('직원 정보를 찾을 수 없습니다.'); end if;
  if e.name is null or btrim(e.name) = '' then errors := errors || jsonb_build_array('직원명이 필요합니다.'); end if;
  if r.request_type = '취득' and e.hire_date is null then errors := errors || jsonb_build_array('취득신고에는 입사일이 필요합니다.'); end if;
  if r.request_type = '상실' and e.termination_date is null then errors := errors || jsonb_build_array('상실신고에는 퇴사일이 필요합니다.'); end if;
  if r.request_type = '상실' and (r.loss_reason is null or btrim(r.loss_reason) = '') then errors := errors || jsonb_build_array('상실신고에는 상실사유가 필요합니다.'); end if;
  if r.monthly_remuneration is null or r.monthly_remuneration < 0 then errors := errors || jsonb_build_array('보수월액을 확인해 주세요.'); end if;
  if not (r.national_pension or r.health_insurance or r.employment_insurance or r.industrial_accident) then errors := errors || jsonb_build_array('신고할 보험을 하나 이상 선택해 주세요.'); end if;

  update public.insurance_requests
  set validation_errors = errors,
      status = case when jsonb_array_length(errors) = 0 then '승인대기' else '보완요청' end,
      updated_at = now()
  where id = req_id;

  return errors;
end;
$$;

revoke all on function public.validate_insurance_request(uuid) from public, anon;
grant execute on function public.validate_insurance_request(uuid) to authenticated;

create or replace function public.approve_insurance_request(req_id uuid)
returns public.insurance_requests
language plpgsql
security definer
set search_path = public, private
as $$
declare
  r public.insurance_requests;
  org_id uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;

  select * into r from public.insurance_requests where id = req_id;
  if r.id is null then raise exception 'request not found'; end if;

  select c.organization_id into org_id from public.companies c where c.id = r.company_id;
  if not private.has_org_role(org_id, array['owner','admin','reviewer']) then raise exception 'approval role required'; end if;
  if r.status not in ('검증완료','승인대기') then raise exception 'request is not ready for approval'; end if;
  if jsonb_array_length(coalesce(r.validation_errors,'[]'::jsonb)) > 0 then raise exception 'validation errors must be resolved first'; end if;

  update public.insurance_requests
  set status = '승인완료',
      approved_by = auth.uid(),
      approved_at = now(),
      updated_at = now()
  where id = req_id
  returning * into r;

  return r;
end;
$$;

revoke all on function public.approve_insurance_request(uuid) from public, anon;
grant execute on function public.approve_insurance_request(uuid) to authenticated;

create or replace function private.audit_insurance_changes()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_company uuid;
  v_org uuid;
  v_target text;
  v_action text;
  v_detail jsonb;
begin
  if tg_table_name = 'employees' then
    v_company := coalesce(new.company_id, old.company_id);
    v_target := coalesce(new.id, old.id)::text;
  elsif tg_table_name = 'insurance_requests' then
    v_company := coalesce(new.company_id, old.company_id);
    v_target := coalesce(new.id, old.id)::text;
  else
    return coalesce(new, old);
  end if;

  select organization_id into v_org from public.companies where id = v_company;
  v_action := tg_table_name || '_' || lower(tg_op);
  v_detail := case when tg_op = 'UPDATE'
    then jsonb_build_object('old_status', to_jsonb(old)->>'status', 'new_status', to_jsonb(new)->>'status')
    else '{}'::jsonb end;

  insert into public.audit_logs(organization_id, company_id, actor_user_id, action, target_type, target_id, detail)
  values(v_org, v_company, auth.uid(), v_action, tg_table_name, v_target, v_detail);

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_audit_employees on public.employees;
create trigger trg_audit_employees
after insert or update or delete on public.employees
for each row execute function private.audit_insurance_changes();

drop trigger if exists trg_audit_insurance_requests on public.insurance_requests;
create trigger trg_audit_insurance_requests
after insert or update or delete on public.insurance_requests
for each row execute function private.audit_insurance_changes();

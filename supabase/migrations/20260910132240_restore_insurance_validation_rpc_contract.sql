-- 검증 경고는 DB에 저장하되 기존 프론트가 기대하는 오류 배열 반환 계약은 유지
create or replace function public.validate_insurance_request(req_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,private
as $$
declare r public.insurance_requests; e public.employees; errors jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; org_id uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into r from public.insurance_requests where id=req_id for update;
  if r.id is null then return jsonb_build_array('요청을 찾을 수 없습니다.'); end if;
  select c.organization_id into org_id from public.companies c where c.id=r.company_id;
  if not private.is_org_member(org_id) then raise exception 'forbidden'; end if;
  select * into e from public.employees where id=r.employee_id;
  if e.id is null then errors:=errors||jsonb_build_array('직원 정보를 찾을 수 없습니다.');
  else
    if e.name is null or btrim(e.name)='' then errors:=errors||jsonb_build_array('직원명이 필요합니다.'); end if;
    if r.request_type='취득' and e.hire_date is null then errors:=errors||jsonb_build_array('취득신고에는 입사일이 필요합니다.'); end if;
    if r.request_type='취득' and e.hire_date is not null and r.effective_date<>e.hire_date then warnings:=warnings||jsonb_build_array('취득 적용일과 직원 입사일이 다릅니다. 보험별 자격취득일을 확인해 주세요.'); end if;
    if r.request_type='상실' and e.termination_date is null then errors:=errors||jsonb_build_array('상실신고에는 퇴사일이 필요합니다.'); end if;
  end if;
  if r.request_type='상실' and (r.loss_reason is null or btrim(r.loss_reason)='') then errors:=errors||jsonb_build_array('상실신고에는 상실사유가 필요합니다.'); end if;
  if r.monthly_remuneration is null or r.monthly_remuneration<0 then errors:=errors||jsonb_build_array('보수월액을 확인해 주세요.'); end if;
  if not (r.national_pension or r.health_insurance or r.employment_insurance or r.industrial_accident) then errors:=errors||jsonb_build_array('신고할 보험을 하나 이상 선택해 주세요.'); end if;
  update public.insurance_requests set validation_errors=errors,validation_warnings=warnings,
    status=case when jsonb_array_length(errors)=0 then '승인대기' else '보완요청' end,updated_at=now()
  where id=req_id;
  return errors;
end; $$;
revoke all on function public.validate_insurance_request(uuid) from public,anon;
grant execute on function public.validate_insurance_request(uuid) to authenticated;

create or replace function public.approve_insurance_request(req_id uuid)
returns public.insurance_requests
language plpgsql
security definer
set search_path=public,private
as $$
declare r public.insurance_requests; org_id uuid; v_errors jsonb;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into r from public.insurance_requests where id=req_id for update;
  if r.id is null then raise exception 'request not found'; end if;
  select c.organization_id into org_id from public.companies c where c.id=r.company_id;
  if not private.has_org_role(org_id,array['owner','admin','reviewer']) then raise exception 'approval role required'; end if;
  if r.status not in ('검증완료','승인대기','요청접수','검증필요','보완요청') then raise exception 'request is not ready for approval'; end if;
  v_errors:=public.validate_insurance_request(req_id);
  if jsonb_array_length(coalesce(v_errors,'[]'::jsonb))>0 then raise exception 'validation errors must be resolved first'; end if;
  update public.insurance_requests set status='승인완료',approved_by=auth.uid(),approved_at=now(),updated_at=now()
  where id=req_id returning * into r;
  return r;
end; $$;
revoke all on function public.approve_insurance_request(uuid) from public,anon;
grant execute on function public.approve_insurance_request(uuid) to authenticated;

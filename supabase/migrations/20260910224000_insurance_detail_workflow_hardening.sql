-- NEXT release hardening: 보험별 상세행을 승인 필수 검증에 포함하고 직접 상태조작을 차단한다.

alter table public.insurance_request_details
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_note text;

create index if not exists idx_insurance_request_details_reviewed_by
  on public.insurance_request_details(reviewed_by);

create or replace function private.sync_insurance_request_details()
returns trigger
language plpgsql
security definer
set search_path=public,private
as $$
begin
  if new.status in ('승인완료','제출대기','접수완료','처리완료','반려','취소') then return new; end if;

  if new.national_pension then
    insert into public.insurance_request_details(insurance_request_id,company_id,employee_id,insurance_type,effective_date,remuneration_amount,weekly_hours,source_type)
    select new.id,new.company_id,new.employee_id,'국민연금',new.effective_date,new.monthly_remuneration,e.weekly_hours,'요청기본값'
      from public.employees e where e.id=new.employee_id
    on conflict(insurance_request_id,insurance_type) do update
      set effective_date=excluded.effective_date,remuneration_amount=excluded.remuneration_amount,weekly_hours=coalesce(public.insurance_request_details.weekly_hours,excluded.weekly_hours),updated_at=now()
      where public.insurance_request_details.source_type='요청기본값';
  else delete from public.insurance_request_details where insurance_request_id=new.id and insurance_type='국민연금'; end if;

  if new.health_insurance then
    insert into public.insurance_request_details(insurance_request_id,company_id,employee_id,insurance_type,effective_date,remuneration_amount,weekly_hours,source_type)
    select new.id,new.company_id,new.employee_id,'건강보험',new.effective_date,new.monthly_remuneration,e.weekly_hours,'요청기본값'
      from public.employees e where e.id=new.employee_id
    on conflict(insurance_request_id,insurance_type) do update
      set effective_date=excluded.effective_date,remuneration_amount=excluded.remuneration_amount,weekly_hours=coalesce(public.insurance_request_details.weekly_hours,excluded.weekly_hours),updated_at=now()
      where public.insurance_request_details.source_type='요청기본값';
  else delete from public.insurance_request_details where insurance_request_id=new.id and insurance_type='건강보험'; end if;

  if new.employment_insurance then
    insert into public.insurance_request_details(insurance_request_id,company_id,employee_id,insurance_type,effective_date,remuneration_amount,weekly_hours,source_type)
    select new.id,new.company_id,new.employee_id,'고용보험',new.effective_date,new.monthly_remuneration,e.weekly_hours,'요청기본값'
      from public.employees e where e.id=new.employee_id
    on conflict(insurance_request_id,insurance_type) do update
      set effective_date=excluded.effective_date,remuneration_amount=excluded.remuneration_amount,weekly_hours=coalesce(public.insurance_request_details.weekly_hours,excluded.weekly_hours),updated_at=now()
      where public.insurance_request_details.source_type='요청기본값';
  else delete from public.insurance_request_details where insurance_request_id=new.id and insurance_type='고용보험'; end if;

  if new.industrial_accident then
    insert into public.insurance_request_details(insurance_request_id,company_id,employee_id,insurance_type,effective_date,remuneration_amount,weekly_hours,source_type)
    select new.id,new.company_id,new.employee_id,'산재보험',new.effective_date,new.monthly_remuneration,e.weekly_hours,'요청기본값'
      from public.employees e where e.id=new.employee_id
    on conflict(insurance_request_id,insurance_type) do update
      set effective_date=excluded.effective_date,remuneration_amount=excluded.remuneration_amount,weekly_hours=coalesce(public.insurance_request_details.weekly_hours,excluded.weekly_hours),updated_at=now()
      where public.insurance_request_details.source_type='요청기본값';
  else delete from public.insurance_request_details where insurance_request_id=new.id and insurance_type='산재보험'; end if;
  return new;
end $$;
revoke all on function private.sync_insurance_request_details() from public,anon,authenticated;

create or replace function private.guard_insurance_detail_integrity()
returns trigger
language plpgsql
set search_path=public,private
as $$
declare r public.insurance_requests; e public.employees;
begin
  select * into r from public.insurance_requests where id=new.insurance_request_id;
  if r.id is null then raise exception 'insurance request not found'; end if;
  if r.company_id<>new.company_id or r.employee_id<>new.employee_id then raise exception 'insurance detail request/company/employee mismatch'; end if;
  select * into e from public.employees where id=new.employee_id;
  if e.id is null or e.company_id<>new.company_id then raise exception 'insurance detail employee/company mismatch'; end if;
  if r.status in ('승인완료','제출대기','접수완료','처리완료','반려','취소') then raise exception 'approved or closed insurance request details are locked'; end if;
  if tg_op='UPDATE' and (
       new.effective_date is distinct from old.effective_date
    or new.remuneration_amount is distinct from old.remuneration_amount
    or new.weekly_hours is distinct from old.weekly_hours
    or new.contract_end_date is distinct from old.contract_end_date
    or new.occupation_code is distinct from old.occupation_code
    or new.nationality_code is distinct from old.nationality_code
    or new.visa_status_code is distinct from old.visa_status_code
  ) then
    new.source_type:='수동'; new.eligibility_status:='미판정'; new.exclusion_code:=null;
    new.eligibility_evidence:='{}'::jsonb; new.validation_errors:='[]'::jsonb; new.validation_warnings:='[]'::jsonb;
    new.reviewed_by:=null; new.reviewed_at:=null; new.review_note:=null;
  end if;
  new.updated_at:=now(); return new;
end $$;

revoke insert, update, delete on public.insurance_request_details from authenticated;
grant update(effective_date,remuneration_amount,weekly_hours,contract_end_date,occupation_code,nationality_code,visa_status_code)
  on public.insurance_request_details to authenticated;

create or replace function public.evaluate_insurance_request_eligibility(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,private
as $$
declare
  r public.insurance_requests; e public.employees; v_org uuid; d public.insurance_request_details;
  v_weekly numeric; v_income numeric; v_result jsonb:='[]'::jsonb; v_status text; v_reason text;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into r from public.insurance_requests where id=p_request_id;
  if r.id is null then raise exception 'request not found'; end if;
  select organization_id into v_org from public.companies where id=r.company_id;
  if not private.is_org_member(v_org) then raise exception 'forbidden'; end if;
  select * into e from public.employees where id=r.employee_id;
  if e.id is null then raise exception 'employee not found'; end if;
  for d in select * from public.insurance_request_details where insurance_request_id=p_request_id order by insurance_type loop
    v_weekly:=coalesce(d.weekly_hours,e.weekly_hours); v_income:=coalesce(d.remuneration_amount,r.monthly_remuneration);
    v_status:='확인필요'; v_reason:='보험별 상세 예외규칙을 담당자가 확인해야 합니다.';
    if d.insurance_type='국민연금' then
      if e.birth_date is null then v_reason:='생년월일이 없어 연령조건을 확인할 수 없습니다.';
      elsif extract(year from age(d.effective_date,e.birth_date))<18 or extract(year from age(d.effective_date,e.birth_date))>=60 then v_reason:='국민연금 일반 연령범위 밖입니다. 적용예외·임의적용 여부를 확인해야 합니다.';
      elsif coalesce(v_weekly,0)>=15 or coalesce(v_income,0)>=2200000 then v_status:='가입대상'; v_reason:='2026 국민연금 보조기준 중 주 15시간 또는 월소득 220만원 기준을 충족합니다.';
      else v_reason:='월 근로일수·월 근로시간·계속근로기간 및 예외조건 추가 확인이 필요합니다.'; end if;
    elsif d.insurance_type='산재보험' then v_reason:='산재보험은 사업·종사형태별 예외 및 업종요율 확인이 필요합니다.';
    elsif d.insurance_type='고용보험' then v_reason:='고용보험은 근로형태·소정근로시간·연령·예외직종 상세판정이 필요합니다.';
    elsif d.insurance_type='건강보험' then v_reason:='건강보험 직장가입 적용·제외 세부조건 확인이 필요합니다.'; end if;
    update public.insurance_request_details set eligibility_status=v_status,
      eligibility_evidence=jsonb_build_object('rule_version','2026-01','weekly_hours',v_weekly,'remuneration_amount',v_income,'reason',v_reason,'evaluated_at',now()),updated_at=now()
      where id=d.id;
    v_result:=v_result||jsonb_build_array(jsonb_build_object('insurance_type',d.insurance_type,'status',v_status,'reason',v_reason));
  end loop;
  return v_result;
end $$;
revoke all on function public.evaluate_insurance_request_eligibility(uuid) from public,anon,authenticated;

create or replace function public.acknowledge_insurance_detail(p_detail_id uuid,p_note text default null)
returns public.insurance_request_details
language plpgsql
security definer
set search_path=public,private
as $$
declare d public.insurance_request_details; r public.insurance_requests; v_org uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into d from public.insurance_request_details where id=p_detail_id for update;
  if d.id is null then raise exception 'insurance detail not found'; end if;
  select * into r from public.insurance_requests where id=d.insurance_request_id;
  select organization_id into v_org from public.companies where id=d.company_id;
  if not private.has_org_role(v_org,array['owner','admin','reviewer']) then raise exception 'review role required'; end if;
  if r.status not in ('요청접수','검증필요','보완요청','검증완료','승인대기') then raise exception 'request is locked'; end if;
  if d.eligibility_status<>'확인필요' then raise exception 'only 확인필요 detail can be acknowledged'; end if;
  update public.insurance_request_details set reviewed_by=auth.uid(),reviewed_at=now(),review_note=coalesce(nullif(btrim(p_note),''),'담당자 검토확인'),updated_at=now()
  where id=p_detail_id returning * into d;
  return d;
end $$;
revoke all on function public.acknowledge_insurance_detail(uuid,text) from public,anon;
grant execute on function public.acknowledge_insurance_detail(uuid,text) to authenticated;

create or replace function public.validate_insurance_request(req_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,private
as $$
declare
  r public.insurance_requests; e public.employees; errors jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; org_id uuid;
  d public.insurance_request_details; d_errors jsonb; d_warnings jsonb; expected_count int; actual_count int;
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
  expected_count:=(case when r.national_pension then 1 else 0 end)+(case when r.health_insurance then 1 else 0 end)+(case when r.employment_insurance then 1 else 0 end)+(case when r.industrial_accident then 1 else 0 end);
  select count(*) into actual_count from public.insurance_request_details where insurance_request_id=req_id;
  if actual_count<>expected_count then errors:=errors||jsonb_build_array('선택한 보험과 보험별 상세 신고행 수가 일치하지 않습니다.'); end if;
  if r.national_pension and not exists(select 1 from public.insurance_request_details where insurance_request_id=req_id and insurance_type='국민연금') then errors:=errors||jsonb_build_array('국민연금 상세 신고행이 없습니다.'); end if;
  if r.health_insurance and not exists(select 1 from public.insurance_request_details where insurance_request_id=req_id and insurance_type='건강보험') then errors:=errors||jsonb_build_array('건강보험 상세 신고행이 없습니다.'); end if;
  if r.employment_insurance and not exists(select 1 from public.insurance_request_details where insurance_request_id=req_id and insurance_type='고용보험') then errors:=errors||jsonb_build_array('고용보험 상세 신고행이 없습니다.'); end if;
  if r.industrial_accident and not exists(select 1 from public.insurance_request_details where insurance_request_id=req_id and insurance_type='산재보험') then errors:=errors||jsonb_build_array('산재보험 상세 신고행이 없습니다.'); end if;
  if e.id is not null and actual_count>0 then perform public.evaluate_insurance_request_eligibility(req_id); end if;
  for d in select * from public.insurance_request_details where insurance_request_id=req_id order by insurance_type loop
    d_errors:='[]'::jsonb; d_warnings:='[]'::jsonb;
    if r.request_type='취득' and d.remuneration_amount is null then d_errors:=d_errors||jsonb_build_array('취득신고 보수월액이 필요합니다.'); end if;
    if r.request_type='취득' and d.weekly_hours is null then d_warnings:=d_warnings||jsonb_build_array('주 소정근로시간을 확인해 주세요.'); end if;
    if d.eligibility_status='미판정' then d_errors:=d_errors||jsonb_build_array('가입대상 판정이 완료되지 않았습니다.'); end if;
    if d.eligibility_status='적용제외' then d_errors:=d_errors||jsonb_build_array('적용제외 판정 보험이 신고대상으로 선택되어 있습니다.'); end if;
    if d.eligibility_status='확인필요' then
      d_warnings:=d_warnings||jsonb_build_array('담당자 자격 검토가 필요합니다.');
      if d.reviewed_by is null then d_warnings:=d_warnings||jsonb_build_array('승인 전 검토확인이 필요합니다.'); end if;
    end if;
    update public.insurance_request_details set validation_errors=d_errors,validation_warnings=d_warnings,updated_at=now() where id=d.id;
    if jsonb_array_length(d_errors)>0 then errors:=errors||jsonb_build_array(d.insurance_type||': 상세 신고정보 오류가 있습니다.'); end if;
    if jsonb_array_length(d_warnings)>0 then warnings:=warnings||jsonb_build_array(d.insurance_type||': '||(d_warnings->>0)); end if;
  end loop;
  update public.insurance_requests set validation_errors=errors,validation_warnings=warnings,
    status=case when jsonb_array_length(errors)=0 then '승인대기' else '보완요청' end,updated_at=now() where id=req_id;
  return errors;
end $$;
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
  if exists(select 1 from public.insurance_request_details where insurance_request_id=req_id and eligibility_status='확인필요' and reviewed_by is null) then raise exception 'insurance detail review acknowledgement required'; end if;
  update public.insurance_requests set status='승인완료',approved_by=auth.uid(),approved_at=now(),updated_at=now()
  where id=req_id returning * into r;
  return r;
end $$;
revoke all on function public.approve_insurance_request(uuid) from public,anon;
grant execute on function public.approve_insurance_request(uuid) to authenticated;

create or replace function private.audit_insurance_changes()
returns trigger
language plpgsql
security definer
set search_path=public,private
as $$
declare v_company uuid; v_org uuid; v_target text; v_action text; v_detail jsonb;
begin
  v_company:=coalesce(new.company_id,old.company_id); v_target:=coalesce(new.id,old.id)::text;
  select organization_id into v_org from public.companies where id=v_company;
  v_action:=tg_table_name||'_'||lower(tg_op);
  if tg_op='UPDATE' and tg_table_name='insurance_request_details' then
    v_detail:=jsonb_build_object('insurance_type',coalesce(new.insurance_type,old.insurance_type),'old_eligibility',old.eligibility_status,'new_eligibility',new.eligibility_status,'reviewed',new.reviewed_by is not null);
  elsif tg_op='UPDATE' then v_detail:=jsonb_build_object('old_status',to_jsonb(old)->>'status','new_status',to_jsonb(new)->>'status');
  else v_detail:='{}'::jsonb; end if;
  insert into public.audit_logs(organization_id,company_id,actor_user_id,action,target_type,target_id,detail)
  values(v_org,v_company,auth.uid(),v_action,tg_table_name,v_target,v_detail);
  return coalesce(new,old);
end $$;

drop trigger if exists trg_audit_insurance_request_details on public.insurance_request_details;
create trigger trg_audit_insurance_request_details after insert or update or delete on public.insurance_request_details
for each row execute function private.audit_insurance_changes();
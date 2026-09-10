-- 급여대장 검토/오류/확정 흐름 보강

alter table public.payroll_entries add column if not exists validation_warnings jsonb not null default '[]'::jsonb;
alter table public.payroll_periods add column if not exists validation_warnings jsonb not null default '[]'::jsonb;

create or replace function public.validate_payroll_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_period public.payroll_periods;
  v_org uuid;
  v_errors jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into v_period from public.payroll_periods where id = p_period_id;
  if v_period.id is null then return jsonb_build_array('급여대장을 찾을 수 없습니다.'); end if;
  select organization_id into v_org from public.companies where id = v_period.company_id;
  if not private.has_org_role(v_org,array['owner','admin','reviewer','staff']) then raise exception 'forbidden'; end if;

  select count(*) into v_count from public.payroll_entries where payroll_period_id = p_period_id;
  if v_count = 0 then v_errors := v_errors || jsonb_build_array('급여대장에 직원이 없습니다.'); end if;

  update public.payroll_entries pe
  set validation_errors = q.errors,
      validation_warnings = q.warnings
  from (
    select pe0.id,
      (case when pe0.payroll_type='시간제' and (pe0.work_hours is null or pe0.work_hours<=0) then jsonb_build_array('시간제 직원의 근무시간이 필요합니다.') else '[]'::jsonb end)
      || (case when pe0.payroll_type='시간제' and (pe0.hourly_rate is null or pe0.hourly_rate<=0) then jsonb_build_array('시간제 직원의 시급이 필요합니다.') else '[]'::jsonb end)
      || (case when pe0.payroll_type='월급제' and pe0.base_salary<=0 then jsonb_build_array('월급제 직원의 기본급을 확인해 주세요.') else '[]'::jsonb end)
      || (case when pe0.gross_pay<0 or pe0.net_pay<0 then jsonb_build_array('지급액 또는 실지급액이 음수입니다.') else '[]'::jsonb end)
      || (case when e.hire_date is not null and e.hire_date > (date_trunc('month',v_period.period_month)+interval '1 month - 1 day')::date then jsonb_build_array('귀속월 이후 입사한 직원입니다.') else '[]'::jsonb end)
      || (case when e.termination_date is not null and e.termination_date < date_trunc('month',v_period.period_month)::date then jsonb_build_array('귀속월 이전 퇴사한 직원입니다.') else '[]'::jsonb end) as errors,
      (case when e.hire_date between date_trunc('month',v_period.period_month)::date and (date_trunc('month',v_period.period_month)+interval '1 month - 1 day')::date then jsonb_build_array('입사월입니다. 일할계산 여부를 확인해 주세요.') else '[]'::jsonb end)
      || (case when e.termination_date between date_trunc('month',v_period.period_month)::date and (date_trunc('month',v_period.period_month)+interval '1 month - 1 day')::date then jsonb_build_array('퇴사월입니다. 퇴사월 급여 및 공제 정산을 확인해 주세요.') else '[]'::jsonb end)
      || (case when ir.monthly_remuneration is not null and pe0.payroll_type='월급제' and abs(coalesce(pe0.base_salary,0)-ir.monthly_remuneration) > 0 then jsonb_build_array('4대보험 신고 보수월액과 급여 기본급이 다릅니다. 신고 기준과 실제 지급액을 확인해 주세요.') else '[]'::jsonb end) as warnings
    from public.payroll_entries pe0
    join public.employees e on e.id = pe0.employee_id
    left join public.insurance_requests ir on ir.id = pe0.insurance_request_id
    where pe0.payroll_period_id = p_period_id
  ) q
  where pe.id = q.id;

  if exists(select 1 from public.payroll_entries where payroll_period_id=p_period_id and jsonb_array_length(validation_errors)>0) then
    v_errors := v_errors || jsonb_build_array('직원별 급여 오류가 있습니다.');
  end if;
  if exists(select 1 from public.payroll_entries where payroll_period_id=p_period_id and jsonb_array_length(validation_warnings)>0) then
    v_warnings := v_warnings || jsonb_build_array('직원별 확인이 필요한 주의사항이 있습니다.');
  end if;

  update public.payroll_periods
  set validation_errors=v_errors,
      validation_warnings=v_warnings,
      status=case when jsonb_array_length(v_errors)=0 then '검토중' else '오류' end,
      updated_at=now()
  where id=p_period_id;
  return jsonb_build_object('errors',v_errors,'warnings',v_warnings);
end;
$$;

revoke all on function public.validate_payroll_period(uuid) from public, anon;
grant execute on function public.validate_payroll_period(uuid) to authenticated;

create or replace function public.confirm_payroll_period(p_period_id uuid)
returns public.payroll_periods
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_period public.payroll_periods;
  v_org uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into v_period from public.payroll_periods where id=p_period_id;
  if v_period.id is null then raise exception 'payroll period not found'; end if;
  select organization_id into v_org from public.companies where id=v_period.company_id;
  if not private.has_org_role(v_org,array['owner','admin','reviewer']) then raise exception 'confirmation role required'; end if;
  if v_period.status <> '검토중' then raise exception 'payroll period must pass validation before confirmation'; end if;
  if jsonb_array_length(coalesce(v_period.validation_errors,'[]'::jsonb)) > 0 then raise exception 'payroll errors must be resolved first'; end if;
  update public.payroll_periods
  set status='확정',confirmed_by=auth.uid(),confirmed_at=now(),updated_at=now()
  where id=p_period_id returning * into v_period;
  return v_period;
end;
$$;
revoke all on function public.confirm_payroll_period(uuid) from public, anon;
grant execute on function public.confirm_payroll_period(uuid) to authenticated;

create or replace function private.audit_payroll_changes()
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
  v_company := coalesce(new.company_id,old.company_id);
  v_target := coalesce(new.id,old.id)::text;
  select organization_id into v_org from public.companies where id=v_company;
  v_action := tg_table_name || '_' || lower(tg_op);
  v_detail := case when tg_op='UPDATE' then jsonb_build_object('old_status',to_jsonb(old)->>'status','new_status',to_jsonb(new)->>'status') else '{}'::jsonb end;
  insert into public.audit_logs(organization_id,company_id,actor_user_id,action,target_type,target_id,detail)
  values(v_org,v_company,auth.uid(),v_action,tg_table_name,v_target,v_detail);
  return coalesce(new,old);
end;
$$;

drop trigger if exists trg_audit_payroll_periods on public.payroll_periods;
create trigger trg_audit_payroll_periods after insert or update or delete on public.payroll_periods
for each row execute function private.audit_payroll_changes();

drop trigger if exists trg_audit_payroll_entries on public.payroll_entries;
create trigger trg_audit_payroll_entries after insert or update or delete on public.payroll_entries
for each row execute function private.audit_payroll_changes();

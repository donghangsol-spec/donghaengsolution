create table if not exists public.insurance_rule_versions (
  id uuid primary key default gen_random_uuid(),
  insurance_type text not null check (insurance_type in ('국민연금','건강보험','고용보험','산재보험')),
  rule_code text not null,
  rule_name text not null,
  effective_from date not null,
  effective_to date,
  parameters jsonb not null default '{}'::jsonb,
  source_url text,
  source_note text,
  verified_at timestamptz not null default now(),
  is_active boolean not null default true,
  unique(insurance_type,rule_code,effective_from)
);
alter table public.insurance_rule_versions enable row level security;
create policy "insurance rule versions select" on public.insurance_rule_versions for select using (true);
revoke insert,update,delete on public.insurance_rule_versions from anon,authenticated;

insert into public.insurance_rule_versions(insurance_type,rule_code,rule_name,effective_from,effective_to,parameters,source_url,source_note)
values('국민연금','SHORT_TIME_THRESHOLD','단시간·일용근로자 사업장가입 판단 보조기준','2026-01-01','2026-12-31','{"weekly_hours_threshold":15,"monthly_hours_threshold":60,"monthly_income_threshold":2200000,"work_days_threshold":8}'::jsonb,'https://www.nps.or.kr/pnsinfo/ntpsklg/getOHAF0097M0.do','2026년 국민연금공단 안내: 1개월 이상 근로하고 월 8일 이상 또는 월 60시간(주 15시간) 이상, 또는 월소득 220만원 이상이면 사업장가입 대상. 예외조건은 별도 검토.')
on conflict(insurance_type,rule_code,effective_from) do update set parameters=excluded.parameters,source_url=excluded.source_url,source_note=excluded.source_note,verified_at=now(),is_active=true;

create table if not exists public.statutory_rate_versions (
  id uuid primary key default gen_random_uuid(),
  component_code text not null check (component_code in ('NATIONAL_PENSION','HEALTH_INSURANCE','LONG_TERM_CARE','EMPLOYMENT_INSURANCE','INDUSTRIAL_ACCIDENT')),
  effective_from date not null,
  effective_to date,
  total_rate numeric(12,8),
  employee_rate numeric(12,8),
  employer_rate numeric(12,8),
  calculation_basis text not null,
  metadata jsonb not null default '{}'::jsonb,
  source_url text,
  verified_at timestamptz not null default now(),
  unique(component_code,effective_from)
);
alter table public.statutory_rate_versions enable row level security;
create policy "statutory rate versions select" on public.statutory_rate_versions for select using (true);
revoke insert,update,delete on public.statutory_rate_versions from anon,authenticated;

insert into public.statutory_rate_versions(component_code,effective_from,effective_to,total_rate,employee_rate,employer_rate,calculation_basis,metadata,source_url)
values
('NATIONAL_PENSION','2026-01-01','2026-12-31',0.095,0.0475,0.0475,'기준소득월액','{"minimum_standard_income_from_2026_07":410000,"maximum_standard_income_from_2026_07":6590000,"rounding":"기준소득월액은 신고소득월액에서 천원 미만 절사"}'::jsonb,'https://www.nps.or.kr/eng/ntnlpnsplan/cntb/getOHAI0013M0.do'),
('HEALTH_INSURANCE','2026-01-01','2026-12-31',0.0719,0.03595,0.03595,'보수월액','{}'::jsonb,'https://edi.nhis.or.kr/portal/images/popup/20251204_pop01longdesc.html'),
('LONG_TERM_CARE','2026-01-01','2026-12-31',0.009448,0.004724,0.004724,'건강보험료 연동','{"health_rate":0.0719,"ltc_rate":0.009448,"formula":"건강보험료 × (0.009448 / 0.0719)"}'::jsonb,'https://edi.nhis.or.kr/portal/images/popup/20251204_pop01longdesc.html'),
('EMPLOYMENT_INSURANCE','2026-01-01','2026-12-31',0.018,0.009,0.009,'보수월액','{"employer_extra":"고용안정·직업능력개발 부담은 사업장 규모 등에 따라 별도"}'::jsonb,'https://www.nps.or.kr/pnsinfo/ntpsklg/getOHAF0097M0.do'),
('INDUSTRIAL_ACCIDENT','2026-01-01','2026-12-31',null,0,null,'업종별 보수','{"employee_share":0,"employer_rate":"업종별 상이","national_average_2026":0.0147}'::jsonb,'https://www.moel.go.kr/news/enews/report/enewsView.do?news_seq=18810')
on conflict(component_code,effective_from) do update set effective_to=excluded.effective_to,total_rate=excluded.total_rate,employee_rate=excluded.employee_rate,employer_rate=excluded.employer_rate,calculation_basis=excluded.calculation_basis,metadata=excluded.metadata,source_url=excluded.source_url,verified_at=now();

create or replace function public.evaluate_insurance_request_eligibility(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,private as $$
declare r public.insurance_requests; e public.employees; v_org uuid; d public.insurance_request_details; v_weekly numeric; v_income numeric; v_result jsonb:='[]'::jsonb; v_status text; v_reason text;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into r from public.insurance_requests where id=p_request_id;
  if r.id is null then raise exception 'request not found'; end if;
  select organization_id into v_org from public.companies where id=r.company_id;
  if not private.is_org_member(v_org) then raise exception 'forbidden'; end if;
  select * into e from public.employees where id=r.employee_id;
  if e.id is null then raise exception 'employee not found'; end if;
  for d in select * from public.insurance_request_details where insurance_request_id=p_request_id order by insurance_type loop
    v_weekly:=coalesce(d.weekly_hours,e.weekly_hours); v_income:=coalesce(d.remuneration_amount,r.monthly_remuneration); v_status:='확인필요'; v_reason:='보험별 상세 예외규칙을 담당자가 확인해야 합니다.';
    if d.insurance_type='국민연금' then
      if e.birth_date is null then v_reason:='생년월일이 없어 연령조건을 확인할 수 없습니다.';
      elsif extract(year from age(d.effective_date,e.birth_date)) < 18 or extract(year from age(d.effective_date,e.birth_date)) >= 60 then v_reason:='국민연금 일반 연령범위 밖입니다. 적용예외·임의적용 여부를 확인해야 합니다.';
      elsif coalesce(v_weekly,0)>=15 or coalesce(v_income,0)>=2200000 then v_status:='가입대상'; v_reason:='2026 국민연금 단시간근로자 보조기준 중 주 15시간 또는 월소득 220만원 기준을 충족합니다.';
      else v_reason:='월 근로일수·월 근로시간·계속근로기간 및 예외조건 추가 확인이 필요합니다.'; end if;
    elsif d.insurance_type='산재보험' then v_reason:='산재보험은 근로자 사용 사업장에 원칙 적용되지만 사업·종사형태별 예외 및 업종요율 확인이 필요합니다.';
    elsif d.insurance_type='고용보험' then v_reason:='고용보험 피보험자격은 근로형태·소정근로시간·연령·예외직종 등 상세판정이 필요합니다.';
    elsif d.insurance_type='건강보험' then v_reason:='건강보험 직장가입 적용·제외 세부조건을 확인해야 합니다.'; end if;
    update public.insurance_request_details set eligibility_status=v_status,eligibility_evidence=jsonb_build_object('rule_version','2026-01','weekly_hours',v_weekly,'remuneration_amount',v_income,'reason',v_reason,'evaluated_at',now()),updated_at=now() where id=d.id;
    v_result:=v_result||jsonb_build_array(jsonb_build_object('insurance_type',d.insurance_type,'status',v_status,'reason',v_reason));
  end loop;
  return v_result;
end $$;
revoke all on function public.evaluate_insurance_request_eligibility(uuid) from public,anon;
grant execute on function public.evaluate_insurance_request_eligibility(uuid) to authenticated;

create or replace function public.estimate_payroll_statutory_deductions(p_entry_id uuid)
returns jsonb language plpgsql security definer set search_path=public,private as $$
declare pe public.payroll_entries; pp public.payroll_periods; v_org uuid; v_pension_base numeric; v_health_base numeric; v_employment_base numeric; v_health_employee numeric; v_ltc_employee numeric; v_pension_employee numeric; v_employment_employee numeric; v_warnings jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into pe from public.payroll_entries where id=p_entry_id; if pe.id is null then raise exception 'payroll entry not found'; end if;
  select * into pp from public.payroll_periods where id=pe.payroll_period_id; select organization_id into v_org from public.companies where id=pe.company_id; if not private.is_org_member(v_org) then raise exception 'forbidden'; end if;
  select d.remuneration_amount into v_pension_base from public.insurance_request_details d where d.insurance_request_id=pe.insurance_request_id and d.insurance_type='국민연금';
  select d.remuneration_amount into v_health_base from public.insurance_request_details d where d.insurance_request_id=pe.insurance_request_id and d.insurance_type='건강보험';
  select d.remuneration_amount into v_employment_base from public.insurance_request_details d where d.insurance_request_id=pe.insurance_request_id and d.insurance_type='고용보험';
  if v_pension_base is null then v_warnings:=v_warnings||jsonb_build_array('국민연금 기준소득월액이 연결되지 않아 연금 공제액을 자동계산하지 않았습니다.'); end if;
  if v_health_base is null then v_warnings:=v_warnings||jsonb_build_array('건강보험 보수월액이 연결되지 않아 건강/장기요양 공제액을 자동계산하지 않았습니다.'); end if;
  if v_employment_base is null then v_warnings:=v_warnings||jsonb_build_array('고용보험 보수월액이 연결되지 않아 고용보험 공제액을 자동계산하지 않았습니다.'); end if;
  if v_pension_base is not null then if pp.period_month>=date '2026-07-01' then v_pension_base:=least(greatest(v_pension_base,410000),6590000); end if; v_pension_employee:=round(trunc(v_pension_base/1000)*1000*0.0475,0); end if;
  if v_health_base is not null then v_health_employee:=round(v_health_base*0.03595,0); v_ltc_employee:=round(v_health_employee*(0.009448/0.0719),0); end if;
  if v_employment_base is not null then v_employment_employee:=round(v_employment_base*0.009,0); end if;
  return jsonb_build_object('period_month',pp.period_month,'national_pension',v_pension_employee,'health_insurance',v_health_employee,'long_term_care',v_ltc_employee,'employment_insurance',v_employment_employee,'industrial_accident_employee',0,'warnings',v_warnings,'calculation_mode','estimate_only','rate_version','2026');
end $$;
revoke all on function public.estimate_payroll_statutory_deductions(uuid) from public,anon;
grant execute on function public.estimate_payroll_statutory_deductions(uuid) to authenticated;

create or replace function public.generate_payroll_draft(p_company_id uuid,p_period_month date)
returns uuid language plpgsql security definer set search_path=public,private as $$
declare v_org uuid; v_period uuid; v_status text;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select organization_id into v_org from public.companies where id=p_company_id; if v_org is null or not private.has_org_role(v_org,array['owner','admin','reviewer','staff']) then raise exception 'forbidden'; end if;
  select id,status into v_period,v_status from public.payroll_periods where company_id=p_company_id and period_month=date_trunc('month',p_period_month)::date for update;
  if v_period is not null and v_status in ('확정','신고반영') then raise exception 'confirmed payroll period cannot be regenerated'; end if;
  if v_period is null then insert into public.payroll_periods(company_id,period_month,status,source_type,created_by) values(p_company_id,date_trunc('month',p_period_month)::date,'초안','직원마스터',auth.uid()) returning id into v_period; end if;
  insert into public.payroll_entries(payroll_period_id,company_id,employee_id,payroll_type,work_hours,hourly_rate,base_salary,insurance_request_id,source_type)
  select v_period,e.company_id,e.id,e.payroll_type,case when e.payroll_type='시간제' then 0 else null end,e.hourly_rate,case when e.payroll_type='월급제' then coalesce(e.monthly_base_salary,0) else 0 end,ir.id,'직원마스터'
  from public.employees e left join lateral (select r.id from public.insurance_requests r where r.employee_id=e.id and r.status in ('승인완료','제출대기','접수완료','처리완료') order by r.effective_date desc,r.requested_at desc limit 1) ir on true
  where e.company_id=p_company_id and (e.hire_date is null or e.hire_date <= (date_trunc('month',p_period_month)+interval '1 month - 1 day')::date) and (e.termination_date is null or e.termination_date >= date_trunc('month',p_period_month)::date)
  on conflict(payroll_period_id,employee_id) do nothing;
  return v_period;
end $$;
revoke all on function public.generate_payroll_draft(uuid,date) from public,anon;
grant execute on function public.generate_payroll_draft(uuid,date) to authenticated;
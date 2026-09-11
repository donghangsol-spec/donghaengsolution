-- 급여대장 확정/신고반영 상태의 직접 변경 차단
create or replace function private.guard_payroll_period_status()
returns trigger
language plpgsql
set search_path=public,private
as $$
begin
  if new.status in ('확정','신고반영') and new.status is distinct from old.status then
    if coalesce(current_setting('app.payroll_status_authorized',true),'') <> '1' then
      raise exception 'protected payroll status transition';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_payroll_period_status on public.payroll_periods;
create trigger trg_guard_payroll_period_status
before update of status on public.payroll_periods
for each row execute function private.guard_payroll_period_status();

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
  perform set_config('app.payroll_status_authorized','1',true);
  update public.payroll_periods
  set status='확정',confirmed_by=auth.uid(),confirmed_at=now(),updated_at=now()
  where id=p_period_id returning * into v_period;
  return v_period;
end;
$$;
revoke all on function public.confirm_payroll_period(uuid) from public,anon;
grant execute on function public.confirm_payroll_period(uuid) to authenticated;

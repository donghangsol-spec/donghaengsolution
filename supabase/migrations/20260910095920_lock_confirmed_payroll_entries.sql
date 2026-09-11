-- 확정된 급여대장의 상태 되돌리기 및 항목 수정 차단
create or replace function private.guard_payroll_period_status()
returns trigger
language plpgsql
set search_path=public,private
as $$
begin
  if new.status is distinct from old.status
     and (new.status in ('확정','신고반영') or old.status in ('확정','신고반영')) then
    if coalesce(current_setting('app.payroll_status_authorized',true),'') <> '1' then
      raise exception 'protected payroll status transition';
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.guard_confirmed_payroll_entries()
returns trigger
language plpgsql
set search_path=public,private
as $$
declare v_period_id uuid; v_status text;
begin
  v_period_id := coalesce(new.payroll_period_id,old.payroll_period_id);
  select status into v_status from public.payroll_periods where id=v_period_id;
  if v_status in ('확정','신고반영') then
    raise exception 'confirmed payroll entries are locked';
  end if;
  return coalesce(new,old);
end;
$$;

drop trigger if exists trg_guard_confirmed_payroll_entries on public.payroll_entries;
create trigger trg_guard_confirmed_payroll_entries
before insert or update or delete on public.payroll_entries
for each row execute function private.guard_confirmed_payroll_entries();

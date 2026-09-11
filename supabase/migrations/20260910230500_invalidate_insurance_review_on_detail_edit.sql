create or replace function private.invalidate_insurance_request_from_detail()
returns trigger
language plpgsql
security definer
set search_path=public,private
as $$
begin
  if new.effective_date is distinct from old.effective_date
     or new.remuneration_amount is distinct from old.remuneration_amount
     or new.weekly_hours is distinct from old.weekly_hours
     or new.contract_end_date is distinct from old.contract_end_date
     or new.occupation_code is distinct from old.occupation_code
     or new.nationality_code is distinct from old.nationality_code
     or new.visa_status_code is distinct from old.visa_status_code then
    update public.insurance_requests
      set status='요청접수',validation_errors='[]'::jsonb,validation_warnings='[]'::jsonb,approved_by=null,approved_at=null,updated_at=now()
      where id=new.insurance_request_id
        and status in ('요청접수','검증필요','보완요청','검증완료','승인대기');
  end if;
  return new;
end $$;
revoke all on function private.invalidate_insurance_request_from_detail() from public,anon,authenticated;

drop trigger if exists trg_invalidate_insurance_request_from_detail on public.insurance_request_details;
create trigger trg_invalidate_insurance_request_from_detail
after update of effective_date,remuneration_amount,weekly_hours,contract_end_date,occupation_code,nationality_code,visa_status_code
on public.insurance_request_details
for each row execute function private.invalidate_insurance_request_from_detail();
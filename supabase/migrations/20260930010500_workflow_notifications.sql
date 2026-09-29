-- 담당자 알림 체계
-- 지금까지는 급여대장이 검토 대기 상태가 되거나 4대보험 상세 항목에
-- 확인이 필요해도, 담당자가 화면에 직접 들어가서 확인하기 전까지는
-- 알아낼 방법이 없었다. 이 마이그레이션은 그런 상태 변화가 생기는 순간
-- 자동으로 알림 레코드를 쌓아두는 큐(notification_logs)와, 그 큐를 처리하는
-- 트리거·조회 RPC를 추가한다.
--
-- 실제 메일 발송(SMTP/Resend)은 이 마이그레이션의 범위가 아니다. 여기서는
-- "누구에게 무슨 알림이 필요한지" 큐에 '대기' 상태로 쌓는 것까지만 하고,
-- 발송은 notification_logs를 주기적으로 읽는 별도 Edge Function이 처리하며
-- 그 Edge Function이 발송 결과를 기록할 때 mark_notification_sent/failed를
-- 사용한다.

create table if not exists public.notification_logs (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid references public.companies(id) on delete cascade,
  recipient_user_id uuid not null references auth.users(id),
  channel           text not null default 'email',
  subject           text not null,
  body              text not null,
  related_table     text not null,
  related_id        uuid not null,
  status            text not null default '대기' check (status in ('대기','발송됨','실패')),
  sent_at           timestamptz,
  failure_reason    text,
  created_at        timestamptz not null default now()
);

create index if not exists idx_notification_logs_company on public.notification_logs(company_id);
create index if not exists idx_notification_logs_recipient on public.notification_logs(recipient_user_id, status);
create index if not exists idx_notification_logs_pending on public.notification_logs(status) where status = '대기';

alter table public.notification_logs enable row level security;

create policy "notification_logs_select" on public.notification_logs for select
using (
  recipient_user_id = auth.uid()
  or (company_id is not null and exists (
    select 1 from public.companies c where c.id = notification_logs.company_id
    and private.has_org_role(c.organization_id, array['owner','admin','reviewer'])
  ))
);

-- 쓰기는 트리거·아래 RPC 전용
create policy "notification_logs_no_direct_write" on public.notification_logs
for all using (false) with check (false);

-- ---------------------------------------------------------------------
-- 1. 알림 생성 내부 헬퍼
-- ---------------------------------------------------------------------
create or replace function private.queue_notification(
  p_company_id    uuid,
  p_recipient     uuid,
  p_subject       text,
  p_body          text,
  p_related_table text,
  p_related_id    uuid
)
returns void
language sql
security definer
set search_path = public, private
as $$
  insert into public.notification_logs (company_id, recipient_user_id, subject, body, related_table, related_id)
  values (p_company_id, p_recipient, p_subject, p_body, p_related_table, p_related_id);
$$;

-- ---------------------------------------------------------------------
-- 2. 급여대장이 '검토중'(검증 통과, 확정 대기)으로 전환되면
--    owner·admin·reviewer에게 알림
-- ---------------------------------------------------------------------
create or replace function private.notify_payroll_review_needed()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_recipient record;
  v_company   public.companies;
begin
  if new.status = '검토중' and (old is null or old.status is distinct from new.status) then
    select * into v_company from public.companies where id = new.company_id;

    for v_recipient in
      select m.user_id from public.organization_members m
      where m.organization_id = v_company.organization_id
        and m.role in ('owner','admin','reviewer')
    loop
      perform private.queue_notification(
        new.company_id,
        v_recipient.user_id,
        format('[%s] %s 급여대장 확정 대기', v_company.name, to_char(new.period_month, 'YYYY-MM')),
        format('%s 급여대장이 검증을 통과해 확정 대기 상태입니다. 확인 후 확정해 주세요.', to_char(new.period_month, 'YYYY-MM')),
        'payroll_periods',
        new.id
      );
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_payroll_review_needed on public.payroll_periods;
create trigger trg_notify_payroll_review_needed
  after insert or update of status on public.payroll_periods
  for each row execute function private.notify_payroll_review_needed();

-- ---------------------------------------------------------------------
-- 3. 4대보험 상세 항목이 '확인필요'로 표시되면 요청자 및
--    owner·admin·reviewer에게 알림
-- ---------------------------------------------------------------------
create or replace function private.notify_insurance_detail_needs_review()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_recipient record;
  v_employee  public.employees;
  v_requested_by uuid;
begin
  if new.eligibility_status = '확인필요' and (old is null or old.eligibility_status is distinct from new.eligibility_status) then
    select * into v_employee from public.employees where id = new.employee_id;
    select requested_by into v_requested_by from public.insurance_requests where id = new.insurance_request_id;

    if v_requested_by is not null then
      perform private.queue_notification(
        new.company_id,
        v_requested_by,
        format('[4대보험] %s님 %s 확인 필요', v_employee.name, new.insurance_type),
        format('%s님의 %s 항목에 담당자 확인이 필요합니다.', v_employee.name, new.insurance_type),
        'insurance_request_details',
        new.id
      );
    end if;

    for v_recipient in
      select m.user_id from public.organization_members m
      where m.organization_id = (select organization_id from public.companies where id = new.company_id)
        and m.role in ('owner','admin','reviewer')
        and m.user_id is distinct from v_requested_by
    loop
      perform private.queue_notification(
        new.company_id,
        v_recipient.user_id,
        format('[4대보험] %s님 %s 확인 필요', v_employee.name, new.insurance_type),
        format('%s님의 %s 항목에 담당자 확인이 필요합니다.', v_employee.name, new.insurance_type),
        'insurance_request_details',
        new.id
      );
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_insurance_detail_needs_review on public.insurance_request_details;
create trigger trg_notify_insurance_detail_needs_review
  after insert or update of eligibility_status on public.insurance_request_details
  for each row execute function private.notify_insurance_detail_needs_review();

-- ---------------------------------------------------------------------
-- 4. 알림 조회 / 발송 결과 기록 RPC
-- ---------------------------------------------------------------------
create or replace function public.list_my_notifications(p_only_unsent boolean default false)
returns setof public.notification_logs
language sql
security definer
set search_path = public, private
stable
as $$
  select * from public.notification_logs
  where recipient_user_id = auth.uid()
    and (not p_only_unsent or status = '대기')
  order by created_at desc;
$$;

-- 실제 발송을 담당하는 Edge Function(service_role)만 결과를 기록할 수 있다.
-- authenticated에 권한을 주면 다른 사용자가 남의 알림을 "발송됨"으로 조작해
-- 실제로는 발송되지 않은 알림을 숨길 수 있으므로 절대 부여하지 않는다.
create or replace function public.mark_notification_sent(p_notification_id uuid)
returns public.notification_logs
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_log public.notification_logs;
begin
  update public.notification_logs set status = '발송됨', sent_at = now()
  where id = p_notification_id and status = '대기'
  returning * into v_log;
  if v_log.id is null then raise exception 'pending notification not found'; end if;
  return v_log;
end;
$$;

create or replace function public.mark_notification_failed(p_notification_id uuid, p_reason text)
returns public.notification_logs
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_log public.notification_logs;
begin
  update public.notification_logs set status = '실패', failure_reason = p_reason
  where id = p_notification_id and status = '대기'
  returning * into v_log;
  if v_log.id is null then raise exception 'pending notification not found'; end if;
  return v_log;
end;
$$;

revoke all on function public.list_my_notifications(boolean) from public, anon;
revoke all on function public.mark_notification_sent(uuid) from public, anon, authenticated;
revoke all on function public.mark_notification_failed(uuid, text) from public, anon, authenticated;

grant execute on function public.list_my_notifications(boolean) to authenticated;
grant execute on function public.mark_notification_sent(uuid) to service_role;
grant execute on function public.mark_notification_failed(uuid, text) to service_role;

comment on table public.notification_logs is '급여·4대보험 담당자 알림 발송 대기열. 실제 발송은 service_role Edge Function 담당.';

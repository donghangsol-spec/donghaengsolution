-- 업무포털(My) "업무 요청하기" 기능.
-- 실무자가 담당자에게 업무를 요청하면 접수 -> 처리중 -> 검토 -> 완료 순으로
-- 상태가 전이되는 단순 티켓 큐를 만든다. 상태 전이는 반드시 아래 RPC를 통해서만
-- 이뤄지며(직접 update 금지), 생성/완료 시점에 기존 notification_logs 큐에
-- 알림을 쌓는다(실제 발송은 기존 Edge Function이 담당).

create table if not exists public.work_tickets (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  company_id      uuid references public.companies(id) on delete set null,
  requested_by    uuid not null references auth.users(id),
  assigned_to     uuid references auth.users(id),
  category        text not null default '기타'
    check (category in ('회계·세무','4대보험','급여','평가·컨설팅','사무자동화','기타')),
  title           text not null,
  description     text,
  status          text not null default '접수'
    check (status in ('접수','처리중','검토','완료')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  completed_at    timestamptz
);

create index if not exists idx_work_tickets_org_status on public.work_tickets(organization_id, status);
create index if not exists idx_work_tickets_company on public.work_tickets(company_id);
create index if not exists idx_work_tickets_requested_by on public.work_tickets(requested_by);

alter table public.work_tickets enable row level security;

create policy "work_tickets_select" on public.work_tickets for select
using (public.is_org_member(organization_id));

-- 쓰기는 모두 아래 RPC 전용(상태 전이 규칙·권한을 한 곳에서 강제하기 위함).
create policy "work_tickets_no_direct_write" on public.work_tickets
for all using (false) with check (false);

-- ---------------------------------------------------------------------
-- 1. 티켓 생성 - 같은 조직 구성원 누구나 요청 가능
-- ---------------------------------------------------------------------
create or replace function public.create_work_ticket(
  p_organization_id uuid,
  p_company_id      uuid,
  p_category        text,
  p_title           text,
  p_description     text
)
returns public.work_tickets
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_ticket public.work_tickets;
  v_recipient record;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if not public.is_org_member(p_organization_id) then raise exception 'organization membership required'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'title required'; end if;
  if p_company_id is not null and not exists (
    select 1 from public.companies c where c.id = p_company_id and c.organization_id = p_organization_id
  ) then
    raise exception 'company does not belong to this organization';
  end if;

  insert into public.work_tickets (organization_id, company_id, requested_by, category, title, description)
  values (p_organization_id, p_company_id, auth.uid(), coalesce(p_category, '기타'), trim(p_title), nullif(trim(coalesce(p_description, '')), ''))
  returning * into v_ticket;

  for v_recipient in
    select m.user_id from public.organization_members m
    where m.organization_id = p_organization_id
      and m.role in ('owner','admin','reviewer','staff')
      and m.user_id is distinct from auth.uid()
  loop
    perform private.queue_notification(
      p_company_id,
      v_recipient.user_id,
      format('[업무요청] %s', v_ticket.title),
      format('새 업무 요청이 접수되었습니다. (%s)', v_ticket.category),
      'work_tickets',
      v_ticket.id
    );
  end loop;

  return v_ticket;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. 상태 전이 - 접수→처리중→검토는 담당자(owner/admin/reviewer/staff),
--    검토→완료는 승인권자(owner/admin/reviewer)만 가능.
-- ---------------------------------------------------------------------
create or replace function public.advance_work_ticket(
  p_ticket_id uuid,
  p_status    text,
  p_note      text default null
)
returns public.work_tickets
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_ticket public.work_tickets;
  v_next_of_status text;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if p_status not in ('처리중','검토','완료') then raise exception 'invalid target status'; end if;

  select * into v_ticket from public.work_tickets where id = p_ticket_id for update;
  if v_ticket.id is null then raise exception 'ticket not found'; end if;
  if not public.is_org_member(v_ticket.organization_id) then raise exception 'organization membership required'; end if;

  v_next_of_status := case v_ticket.status
    when '접수' then '처리중'
    when '처리중' then '검토'
    when '검토' then '완료'
    else null
  end;
  if p_status is distinct from v_next_of_status then
    raise exception '% 상태에서는 %(으)로 전이할 수 없습니다. 다음 단계는 %입니다.', v_ticket.status, p_status, coalesce(v_next_of_status, '없음(완료됨)');
  end if;

  if p_status = '완료' then
    if not private.has_org_role(v_ticket.organization_id, array['owner','admin','reviewer']) then
      raise exception 'approval role required to complete a ticket';
    end if;
  else
    if not private.has_org_role(v_ticket.organization_id, array['owner','admin','reviewer','staff']) then
      raise exception 'staff role required';
    end if;
  end if;

  update public.work_tickets
  set status = p_status,
      updated_at = now(),
      assigned_to = coalesce(assigned_to, case when p_status = '처리중' then auth.uid() else assigned_to end),
      completed_at = case when p_status = '완료' then now() else completed_at end
  where id = p_ticket_id
  returning * into v_ticket;

  if p_status = '완료' then
    perform private.queue_notification(
      v_ticket.company_id,
      v_ticket.requested_by,
      format('[업무요청 완료] %s', v_ticket.title),
      coalesce(nullif(trim(p_note), ''), '요청하신 업무가 완료 처리되었습니다.'),
      'work_tickets',
      v_ticket.id
    );
  end if;

  return v_ticket;
end;
$$;

revoke all on function public.create_work_ticket(uuid, uuid, text, text, text) from public, anon;
revoke all on function public.advance_work_ticket(uuid, text, text) from public, anon;
grant execute on function public.create_work_ticket(uuid, uuid, text, text, text) to authenticated;
grant execute on function public.advance_work_ticket(uuid, text, text) to authenticated;

comment on table public.work_tickets is '업무포털 "업무 요청하기": 접수->처리중->검토->완료 티켓 큐. 상태 전이는 advance_work_ticket RPC 전용.';

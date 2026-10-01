-- Local smoke test for supabase/migrations/20261001140000_work_tickets.sql
-- Run against a scratch database that already has schema.sql + all migrations applied.
begin;

do $$
declare
  v_org uuid := gen_random_uuid();
  v_company uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_ticket public.work_tickets;
begin
  insert into auth.users (id) values (v_owner), (v_staff), (v_outsider);
  insert into public.organizations (id, name) values (v_org, '스모크기관');
  insert into public.organization_members (organization_id, user_id, role)
    values (v_org, v_owner, 'owner'), (v_org, v_staff, 'staff');
  insert into public.companies (id, organization_id, name) values (v_company, v_org, '스모크 사업장');

  -- staff creates a ticket
  set local role authenticated;
  perform set_config('app.current_uid', v_staff::text, true);
  v_ticket := public.create_work_ticket(v_org, v_company, '회계·세무', '7월 거래내역 확인 요청', '첨부 확인 부탁드립니다');
  assert v_ticket.status = '접수', 'new ticket should start at 접수, got ' || v_ticket.status;
  assert v_ticket.requested_by = v_staff, 'requested_by should be the creator';

  -- outsider (not an org member) cannot even see it, and cannot advance it
  perform set_config('app.current_uid', v_outsider::text, true);
  begin
    perform public.advance_work_ticket(v_ticket.id, '처리중');
    raise exception 'outsider should not be able to advance a ticket';
  exception when others then
    if sqlerrm not like '%organization membership required%' then raise; end if;
  end;

  -- staff advances 접수 -> 처리중
  perform set_config('app.current_uid', v_staff::text, true);
  v_ticket := public.advance_work_ticket(v_ticket.id, '처리중');
  assert v_ticket.status = '처리중', 'expected 처리중, got ' || v_ticket.status;
  assert v_ticket.assigned_to = v_staff, 'advancing to 처리중 should auto-assign the mover';

  -- staff advances 처리중 -> 검토
  v_ticket := public.advance_work_ticket(v_ticket.id, '검토');
  assert v_ticket.status = '검토', 'expected 검토, got ' || v_ticket.status;

  -- staff cannot do the final 검토 -> 완료 (approval role required)
  begin
    perform public.advance_work_ticket(v_ticket.id, '완료');
    raise exception 'staff should not be able to complete a ticket';
  exception when others then
    if sqlerrm not like '%approval role required%' then raise; end if;
  end;

  -- owner completes it
  perform set_config('app.current_uid', v_owner::text, true);
  v_ticket := public.advance_work_ticket(v_ticket.id, '완료');
  assert v_ticket.status = '완료', 'expected 완료, got ' || v_ticket.status;
  assert v_ticket.completed_at is not null, 'completed_at should be set';

  -- cannot skip stages (접수 -> 검토 directly) on a fresh ticket
  perform set_config('app.current_uid', v_staff::text, true);
  v_ticket := public.create_work_ticket(v_org, null, '기타', '두번째 요청', null);
  begin
    perform public.advance_work_ticket(v_ticket.id, '검토');
    raise exception 'should not be able to skip 처리중';
  exception when others then
    if sqlerrm not like '%상태에서는%' then raise; end if;
  end;

  -- completed ticket notified the requester
  perform set_config('app.current_uid', v_staff::text, true);
  if not exists (
    select 1 from public.notification_logs
    where recipient_user_id = v_staff and related_table = 'work_tickets' and subject like '[업무요청 완료]%'
  ) then
    raise exception 'requester should have been notified on completion';
  end if;

  reset role;
  raise notice 'work_tickets smoke test passed';
end $$;

rollback;

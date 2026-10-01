-- 메일 첨부파일(엑셀/CSV/PDF) 미리보기를 실무자가 확인한 뒤 "가져오기"를
-- 누르면 거래내역으로 반영한다. 실제 insert는 기존 public.transactions의
-- "org members manage transactions" RLS 정책을 그대로 사용하므로(클라이언트가
-- 수동 CSV 업로드와 동일한 경로로 직접 insert) 새 RPC가 필요하지 않다.
--
-- 이 마이그레이션은 그 가져오기가 끝난 뒤 email_intake_messages의
-- processing_status를 갱신하는 역할만 한다. 이 테이블에는 update RLS 정책이
-- 없으므로(의도적으로 직접 갱신을 막아둠) 상태 전이는 반드시 아래 함수를
-- 통해서만 가능하다.

create or replace function public.mark_email_intake_imported(
  p_message_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_message public.email_intake_messages;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;

  select * into v_message
  from public.email_intake_messages
  where id = p_message_id
  for update;

  if v_message.id is null then raise exception 'email intake message not found'; end if;

  if not private.has_org_role(v_message.organization_id, array['owner','admin','reviewer','staff']) then
    raise exception 'import role required';
  end if;

  if v_message.processing_status not in ('received','classified','review_required') then
    raise exception 'message is not awaiting import';
  end if;

  update public.email_intake_messages
  set processing_status = 'drafted',
      updated_at = now()
  where id = p_message_id;
end;
$$;

revoke all on function public.mark_email_intake_imported(uuid) from public, anon;
grant execute on function public.mark_email_intake_imported(uuid) to authenticated;

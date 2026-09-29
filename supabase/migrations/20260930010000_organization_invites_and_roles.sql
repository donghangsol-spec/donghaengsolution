-- 조직 구성원 초대 및 역할 관리
-- 지금까지는 organization_members에 사람을 추가/변경/제거하는 경로가
-- onboard_owner_internal(최초 1인 owner 생성)뿐이었다. 이 마이그레이션은
-- 로그인한 owner/admin이 동료를 이메일로 초대하고, 역할을 바꾸고,
-- 구성원을 내보낼 수 있는 RPC를 연다.
--
-- 실제 초대 메일 발송은 이 마이그레이션의 범위가 아니다. 여기서는
-- "초대 레코드를 만들고 수락한다"까지만 하고, 메일 발송은 이미 프로젝트가
-- 쓰고 있는 Resend 연동 쪽(예: onboard-owner와 같은 위치의 Edge Function)이
-- organization_invites를 읽어 처리해야 한다.

create table if not exists public.organization_invites (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email           text not null,
  role            text not null default 'staff' check (role in ('owner','admin','reviewer','staff')),
  token           uuid not null default gen_random_uuid(),
  status          text not null default '대기' check (status in ('대기','수락됨','취소됨','만료됨')),
  invited_by      uuid references auth.users(id),
  accepted_by     uuid references auth.users(id),
  accepted_at     timestamptz,
  expires_at      timestamptz not null default (now() + interval '7 days'),
  created_at      timestamptz not null default now(),
  unique (token)
);

create index if not exists idx_org_invites_org on public.organization_invites(organization_id);
create index if not exists idx_org_invites_email on public.organization_invites(lower(email));

-- 같은 조직·같은 이메일로 "대기" 중인 초대는 1건만 (중복 초대 방지)
create unique index if not exists uq_org_invites_pending_per_email
  on public.organization_invites (organization_id, lower(email))
  where status = '대기';

alter table public.organization_invites enable row level security;

create policy "organization_invites_select" on public.organization_invites for select
using (private.has_org_role(organization_id, array['owner','admin']));

-- 쓰기는 전부 아래 SECURITY DEFINER 함수 전용. 직접 insert/update를 허용하면
-- 소유자 보호(마지막 owner 제거 금지) 같은 안전장치를 우회할 수 있다.
create policy "organization_invites_no_direct_write" on public.organization_invites
for all using (false) with check (false);

-- ---------------------------------------------------------------------
-- 1. 초대 생성 — owner/admin 전용
-- ---------------------------------------------------------------------
create or replace function public.create_organization_invite(p_organization_id uuid, p_email text, p_role text)
returns public.organization_invites
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_invite public.organization_invites;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if not private.has_org_role(p_organization_id, array['owner','admin']) then raise exception 'forbidden'; end if;

  if p_email is null or btrim(p_email) = '' then raise exception 'email required'; end if;
  if p_role not in ('owner','admin','reviewer','staff') then raise exception 'invalid role'; end if;

  if exists (
    select 1 from public.organization_members m
    join auth.users u on u.id = m.user_id
    where m.organization_id = p_organization_id and lower(u.email) = lower(btrim(p_email))
  ) then
    raise exception 'user already a member of this organization';
  end if;

  insert into public.organization_invites (organization_id, email, role, invited_by)
  values (p_organization_id, lower(btrim(p_email)), p_role, auth.uid())
  returning * into v_invite;

  insert into public.audit_logs(organization_id, actor_user_id, action, target_type, target_id, detail)
  values (p_organization_id, auth.uid(), 'ORGANIZATION_INVITE_CREATED', 'organization_invites', v_invite.id::text,
          jsonb_build_object('email', v_invite.email, 'role', v_invite.role));

  return v_invite;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. 초대 취소 — owner/admin 전용
-- ---------------------------------------------------------------------
create or replace function public.cancel_organization_invite(p_invite_id uuid)
returns public.organization_invites
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_invite public.organization_invites;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;

  select * into v_invite from public.organization_invites where id = p_invite_id for update;
  if v_invite.id is null then raise exception 'invite not found'; end if;
  if not private.has_org_role(v_invite.organization_id, array['owner','admin']) then raise exception 'forbidden'; end if;
  if v_invite.status <> '대기' then raise exception 'invite already resolved'; end if;

  update public.organization_invites set status = '취소됨' where id = p_invite_id
  returning * into v_invite;

  insert into public.audit_logs(organization_id, actor_user_id, action, target_type, target_id, detail)
  values (v_invite.organization_id, auth.uid(), 'ORGANIZATION_INVITE_CANCELLED', 'organization_invites', v_invite.id::text, '{}'::jsonb);

  return v_invite;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. 초대 수락 — 초대받은 이메일로 로그인한 본인만 가능
-- ---------------------------------------------------------------------
create or replace function public.accept_organization_invite(p_token uuid)
returns public.organization_members
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_invite public.organization_invites;
  v_email  text;
  v_member public.organization_members;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;

  select * into v_invite from public.organization_invites where token = p_token for update;
  if v_invite.id is null then raise exception 'invite not found'; end if;

  if v_invite.status = '대기' and v_invite.expires_at < now() then
    update public.organization_invites set status = '만료됨' where id = v_invite.id;
    raise exception 'invite expired';
  end if;
  if v_invite.status <> '대기' then raise exception 'invite already resolved'; end if;

  select email into v_email from auth.users where id = auth.uid();
  if v_email is null or lower(v_email) <> v_invite.email then
    raise exception 'invite email mismatch';
  end if;

  insert into public.organization_members (organization_id, user_id, role)
  values (v_invite.organization_id, auth.uid(), v_invite.role)
  on conflict (organization_id, user_id) do update set role = excluded.role
  returning * into v_member;

  update public.organization_invites
  set status = '수락됨', accepted_by = auth.uid(), accepted_at = now()
  where id = v_invite.id;

  insert into public.audit_logs(organization_id, actor_user_id, action, target_type, target_id, detail)
  values (v_invite.organization_id, auth.uid(), 'ORGANIZATION_INVITE_ACCEPTED', 'organization_members', v_member.user_id::text,
          jsonb_build_object('role', v_member.role));

  return v_member;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. 역할 변경 — owner 전용. 마지막 owner는 강등 불가.
-- ---------------------------------------------------------------------
create or replace function public.change_organization_member_role(p_organization_id uuid, p_user_id uuid, p_new_role text)
returns public.organization_members
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_member      public.organization_members;
  v_owner_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if not private.has_org_role(p_organization_id, array['owner']) then raise exception 'forbidden'; end if;
  if p_new_role not in ('owner','admin','reviewer','staff') then raise exception 'invalid role'; end if;

  select * into v_member from public.organization_members
  where organization_id = p_organization_id and user_id = p_user_id for update;
  if v_member.user_id is null then raise exception 'member not found'; end if;

  if v_member.role = 'owner' and p_new_role <> 'owner' then
    select count(*) into v_owner_count from public.organization_members
    where organization_id = p_organization_id and role = 'owner';
    if v_owner_count <= 1 then
      raise exception 'cannot demote the last remaining owner';
    end if;
  end if;

  update public.organization_members set role = p_new_role
  where organization_id = p_organization_id and user_id = p_user_id
  returning * into v_member;

  insert into public.audit_logs(organization_id, actor_user_id, action, target_type, target_id, detail)
  values (p_organization_id, auth.uid(), 'ORGANIZATION_MEMBER_ROLE_CHANGED', 'organization_members', p_user_id::text,
          jsonb_build_object('new_role', p_new_role));

  return v_member;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. 구성원 제거 — owner 전용. 마지막 owner는 제거 불가.
-- ---------------------------------------------------------------------
create or replace function public.remove_organization_member(p_organization_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_member      public.organization_members;
  v_owner_count integer;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if not private.has_org_role(p_organization_id, array['owner']) then raise exception 'forbidden'; end if;

  select * into v_member from public.organization_members
  where organization_id = p_organization_id and user_id = p_user_id for update;
  if v_member.user_id is null then raise exception 'member not found'; end if;

  if v_member.role = 'owner' then
    select count(*) into v_owner_count from public.organization_members
    where organization_id = p_organization_id and role = 'owner';
    if v_owner_count <= 1 then
      raise exception 'cannot remove the last remaining owner';
    end if;
  end if;

  delete from public.organization_members
  where organization_id = p_organization_id and user_id = p_user_id;

  insert into public.audit_logs(organization_id, actor_user_id, action, target_type, target_id, detail)
  values (p_organization_id, auth.uid(), 'ORGANIZATION_MEMBER_REMOVED', 'organization_members', p_user_id::text, '{}'::jsonb);
end;
$$;

revoke all on function public.create_organization_invite(uuid, text, text) from public, anon;
revoke all on function public.cancel_organization_invite(uuid) from public, anon;
revoke all on function public.accept_organization_invite(uuid) from public, anon;
revoke all on function public.change_organization_member_role(uuid, uuid, text) from public, anon;
revoke all on function public.remove_organization_member(uuid, uuid) from public, anon;

grant execute on function public.create_organization_invite(uuid, text, text) to authenticated;
grant execute on function public.cancel_organization_invite(uuid) to authenticated;
grant execute on function public.accept_organization_invite(uuid) to authenticated;
grant execute on function public.change_organization_member_role(uuid, uuid, text) to authenticated;
grant execute on function public.remove_organization_member(uuid, uuid) to authenticated;

comment on table public.organization_invites is '조직 구성원 초대 상태 관리. 실제 메일 발송은 별도 서버 쪽 코드가 담당.';

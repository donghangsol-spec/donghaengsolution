-- =====================================================================
--  최고관리자 승인형 가입 전환
--
--  지금까지: 로그인했는데 소속 사업장이 없으면 onboard-owner 함수가
--  자동으로 "본인 소유 조직"을 하나 뚝딱 만들어줬다. 그래서 아무나
--  가입만 하면 바로 자기 사업장을 손에 쥐었고, accounting.html의
--  "사업장 설정" 화면은 (조직당 사업장 1개만 다루는 화면이라) 저장할
--  때마다 기존 사업장 내용을 덮어썼다.
--
--  이 마이그레이션부터는:
--  1) 누구나 이메일/비밀번호 + 사업자등록번호로 가입 신청만 할 수 있다.
--  2) 이메일 인증(Supabase Auth 기본 기능)까지는 되지만, 그 뒤로는
--     organizations/companies/organization_members에 아무것도 자동으로
--     생기지 않는다 — "대기" 상태의 signup_requests 한 줄만 생긴다.
--  3) platform_admins 표에 등록된 최고관리자(대표님 계정)만 가입 신청
--     목록을 보고, 기존 사업장에 매칭하거나 새 사업장을 만들어 연결하거나
--     반려할 수 있다. 일반 사업장의 owner/admin과는 완전히 별개 권한이다.
--  4) 자동 1인 조직 생성 경로(onboard_owner_internal)는 호출하면 바로
--     에러가 나도록 막아둔다 — 완전히 비활성화.
--
--  사용법: Supabase [SQL Editor] → New query → 이 파일 전체 붙여넣고 Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. 사업자등록번호에서 숫자만 뽑는 보조 함수 (하이픈 유무 상관없이 비교하기 위함)
-- ---------------------------------------------------------------------
create or replace function public.brn_digits(p_value text)
returns text
language sql
immutable
as $$
  select regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g');
$$;

-- ---------------------------------------------------------------------
-- 1. 최고관리자 명단 (대표님 계정 등 소수) — 가입/탈퇴는 SQL Editor에서 직접
-- ---------------------------------------------------------------------
create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;

create policy "platform_admins_self_select" on public.platform_admins
  for select using (user_id = auth.uid());

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 2. 사업장(companies)에 사업자등록번호 칸 추가 — 같은 번호로 중복 등록 방지
-- ---------------------------------------------------------------------
alter table public.companies add column if not exists business_registration_number text;

create unique index if not exists uq_companies_brn
  on public.companies (public.brn_digits(business_registration_number))
  where business_registration_number is not null and public.brn_digits(business_registration_number) <> '';

-- ---------------------------------------------------------------------
-- 3. 가입 신청 표
-- ---------------------------------------------------------------------
create table if not exists public.signup_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  business_registration_number text not null,
  requested_company_name text,
  contact_phone text,
  status text not null default '대기' check (status in ('대기', '승인됨', '반려됨')),
  matched_organization_id uuid references public.organizations(id),
  matched_company_id uuid references public.companies(id),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  reject_reason text,
  created_at timestamptz not null default now()
);
create index if not exists idx_signup_requests_status on public.signup_requests(status);
create index if not exists idx_signup_requests_brn on public.signup_requests(public.brn_digits(business_registration_number));

alter table public.signup_requests enable row level security;

create policy "signup_requests_self_or_admin_select" on public.signup_requests
  for select using (user_id = auth.uid() or public.is_platform_admin());

-- 쓰기는 전부 아래 함수/트리거 전용 — 직접 insert/update로 상태를 바꿀 수 없게 막는다.
create policy "signup_requests_no_direct_write" on public.signup_requests
  for all using (false) with check (false);

-- ---------------------------------------------------------------------
-- 4. 가입하면 자동으로 "대기" 신청 한 줄 생성 (가입 화면에서 메타데이터로 전달)
-- ---------------------------------------------------------------------
create or replace function public.handle_new_signup_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_brn text;
begin
  v_brn := nullif(btrim(new.raw_user_meta_data->>'business_registration_number'), '');
  if v_brn is not null then
    insert into public.signup_requests (user_id, business_registration_number, requested_company_name, contact_phone)
    values (
      new.id,
      v_brn,
      nullif(btrim(new.raw_user_meta_data->>'company_name'), ''),
      nullif(btrim(new.raw_user_meta_data->>'phone'), '')
    )
    on conflict (user_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_signup_request on auth.users;
create trigger on_auth_user_created_signup_request
  after insert on auth.users
  for each row execute function public.handle_new_signup_request();

-- ---------------------------------------------------------------------
-- 5. 최고관리자용 조회 함수 (auth.users의 이메일을 같이 보여주기 위해
--    security definer로 감싼다 — 클라이언트는 auth.users를 직접 못 봄)
-- ---------------------------------------------------------------------
create or replace function public.platform_list_signups(p_status text default null)
returns table (
  id uuid,
  user_id uuid,
  email text,
  email_confirmed boolean,
  business_registration_number text,
  requested_company_name text,
  contact_phone text,
  status text,
  matched_company_id uuid,
  reject_reason text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception '최고관리자만 가입 신청 목록을 볼 수 있습니다.';
  end if;
  return query
    select r.id, r.user_id, u.email, (u.email_confirmed_at is not null),
           r.business_registration_number, r.requested_company_name, r.contact_phone,
           r.status, r.matched_company_id, r.reject_reason, r.created_at
    from public.signup_requests r
    join auth.users u on u.id = r.user_id
    where p_status is null or r.status = p_status
    order by r.created_at asc;
end;
$$;
revoke all on function public.platform_list_signups(text) from public, anon;
grant execute on function public.platform_list_signups(text) to authenticated;

-- 기존 사업장에 매칭할 때 검색용 — 조직 이름까지 같이 보여준다.
create or replace function public.platform_list_companies(p_search text default null)
returns table (
  id uuid,
  organization_id uuid,
  organization_name text,
  name text,
  business_registration_number text,
  account_type text,
  company_type text,
  is_active boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception '최고관리자만 전체 사업장 목록을 볼 수 있습니다.';
  end if;
  return query
    select c.id, c.organization_id, o.name, c.name, c.business_registration_number,
           c.account_type, c.company_type, c.is_active
    from public.companies c
    join public.organizations o on o.id = c.organization_id
    where p_search is null or btrim(p_search) = ''
       or c.name ilike '%' || p_search || '%'
       or o.name ilike '%' || p_search || '%'
       or (public.brn_digits(p_search) <> '' and public.brn_digits(c.business_registration_number) = public.brn_digits(p_search))
    order by o.name, c.name;
end;
$$;
revoke all on function public.platform_list_companies(text) from public, anon;
grant execute on function public.platform_list_companies(text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. 승인 — 기존 사업장에 매칭 (이미 등록된 동료 직원이 추가 가입하는 경우 등)
-- ---------------------------------------------------------------------
create or replace function public.platform_approve_signup_existing(p_request_id uuid, p_company_id uuid, p_role text default 'owner')
returns public.signup_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.signup_requests;
  v_org uuid;
begin
  if not public.is_platform_admin() then
    raise exception '최고관리자만 승인할 수 있습니다.';
  end if;
  if p_role not in ('owner', 'admin', 'reviewer', 'staff') then
    raise exception '올바르지 않은 역할입니다.';
  end if;

  select * into v_req from public.signup_requests where id = p_request_id for update;
  if v_req.id is null then raise exception '가입 신청을 찾을 수 없습니다.'; end if;
  if v_req.status <> '대기' then raise exception '이미 처리된 신청입니다.'; end if;

  select organization_id into v_org from public.companies where id = p_company_id;
  if v_org is null then raise exception '사업장을 찾을 수 없습니다.'; end if;

  insert into public.organization_members (organization_id, user_id, role)
  values (v_org, v_req.user_id, p_role)
  on conflict (organization_id, user_id) do update set role = excluded.role;

  update public.signup_requests
    set status = '승인됨', matched_company_id = p_company_id, matched_organization_id = v_org,
        reviewed_by = auth.uid(), reviewed_at = now(), reject_reason = null
    where id = p_request_id
    returning * into v_req;

  insert into public.audit_logs (organization_id, company_id, actor_user_id, action, target_type, target_id, detail)
  values (v_org, p_company_id, auth.uid(), 'SIGNUP_APPROVED_EXISTING_COMPANY', 'signup_requests', p_request_id::text,
          jsonb_build_object('user_id', v_req.user_id, 'role', p_role));

  return v_req;
end;
$$;
revoke all on function public.platform_approve_signup_existing(uuid, uuid, text) from public, anon;
grant execute on function public.platform_approve_signup_existing(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 7. 승인 — 새 사업장을 만들어서 연결 (신청자가 그 사업장의 owner가 됨)
-- ---------------------------------------------------------------------
create or replace function public.platform_approve_signup_new(
  p_request_id uuid,
  p_organization_name text,
  p_company_name text,
  p_account_type text default '비영리',
  p_company_type text default '장기요양기관'
)
returns public.signup_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.signup_requests;
  v_org_id uuid;
  v_company_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception '최고관리자만 승인할 수 있습니다.';
  end if;

  select * into v_req from public.signup_requests where id = p_request_id for update;
  if v_req.id is null then raise exception '가입 신청을 찾을 수 없습니다.'; end if;
  if v_req.status <> '대기' then raise exception '이미 처리된 신청입니다.'; end if;

  insert into public.organizations (name)
  values (left(coalesce(nullif(btrim(p_organization_name), ''), v_req.requested_company_name, '동행솔루션'), 80))
  returning id into v_org_id;

  insert into public.companies (organization_id, name, account_type, company_type, business_registration_number)
  values (
    v_org_id,
    left(coalesce(nullif(btrim(p_company_name), ''), v_req.requested_company_name, '사업장'), 120),
    p_account_type, p_company_type, v_req.business_registration_number
  )
  returning id into v_company_id;

  insert into public.organization_members (organization_id, user_id, role)
  values (v_org_id, v_req.user_id, 'owner');

  update public.signup_requests
    set status = '승인됨', matched_company_id = v_company_id, matched_organization_id = v_org_id,
        reviewed_by = auth.uid(), reviewed_at = now(), reject_reason = null
    where id = p_request_id
    returning * into v_req;

  insert into public.audit_logs (organization_id, company_id, actor_user_id, action, target_type, target_id, detail)
  values (v_org_id, v_company_id, auth.uid(), 'SIGNUP_APPROVED_NEW_COMPANY', 'signup_requests', p_request_id::text,
          jsonb_build_object('user_id', v_req.user_id));

  return v_req;
end;
$$;
revoke all on function public.platform_approve_signup_new(uuid, text, text, text, text) from public, anon;
grant execute on function public.platform_approve_signup_new(uuid, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 8. 반려
-- ---------------------------------------------------------------------
create or replace function public.platform_reject_signup(p_request_id uuid, p_reason text)
returns public.signup_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.signup_requests;
begin
  if not public.is_platform_admin() then
    raise exception '최고관리자만 반려할 수 있습니다.';
  end if;
  select * into v_req from public.signup_requests where id = p_request_id for update;
  if v_req.id is null then raise exception '가입 신청을 찾을 수 없습니다.'; end if;
  if v_req.status <> '대기' then raise exception '이미 처리된 신청입니다.'; end if;

  update public.signup_requests
    set status = '반려됨', reject_reason = p_reason, reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_request_id
    returning * into v_req;

  return v_req;
end;
$$;
revoke all on function public.platform_reject_signup(uuid, text) from public, anon;
grant execute on function public.platform_reject_signup(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 9. 본인 가입 상태 확인 (로그인했는데 소속 사업장이 없을 때 화면에 안내용)
-- ---------------------------------------------------------------------
create or replace function public.my_signup_status()
returns public.signup_requests
language sql
stable
security definer
set search_path = public
as $$
  select * from public.signup_requests where user_id = auth.uid();
$$;
grant execute on function public.my_signup_status() to authenticated;

-- ---------------------------------------------------------------------
-- 10. 자동 1인 조직 생성(onboard_owner_internal) 완전 비활성화
--     기존에도 service_role 전용으로 잠겨 있어 브라우저에서 직접 호출할 수는
--     없었지만, onboard-owner Edge Function이 더 이상 이 경로를 쓰지 않도록
--     바꾼 뒤에도 혹시 모를 호출에 대비해 함수 자체를 막아둔다.
-- ---------------------------------------------------------------------
create or replace function public.onboard_owner_internal(p_user_id uuid, p_org_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
begin
  raise exception '자동 사업장 생성은 더 이상 지원되지 않습니다. 가입 후 최고관리자 승인을 기다려주세요.';
end;
$$;
revoke all on function public.onboard_owner_internal(uuid, text) from public, anon, authenticated;
grant execute on function public.onboard_owner_internal(uuid, text) to service_role;

-- =====================================================================
--  마지막으로, 본인(대표님) 계정을 최고관리자로 등록해야 합니다.
--  아래 한 줄의 'YOUR-EMAIL@...'을 실제 로그인 이메일로 바꿔서 따로 실행하세요.
--
--  insert into public.platform_admins (user_id)
--  select id from auth.users where email = 'YOUR-EMAIL@...'
--  on conflict do nothing;
-- =====================================================================

-- =====================================================================
--  복지커뮤니티 게시판 + 댓글
--
--  - 누구나(비로그인 포함) 게시된 글과 댓글을 읽을 수 있다.
--  - 공지사항·자료실 글과 상단 고정은 최고관리자(platform_admins)만 쓴다.
--  - 정보공유·현장이야기·질문답변 글과 댓글은 승인된 회원
--    (organization_members에 소속된 계정)과 최고관리자가 쓴다.
--  - 테이블에 직접 insert/update/delete는 막고, 아래 함수로만 쓴다.
--    작성자 표시명(기관명)과 분류별 양식은 서버가 정한다.
--  - 첨부파일은 공개 버킷 community-files에 최고관리자만 올린다.
--
--  사용법: Supabase [SQL Editor] → New query → 이 파일 전체 붙여넣고 Run.
--  (20261001090000_platform_admin_signup_approval.sql 적용 후 실행)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 게시글
-- ---------------------------------------------------------------------
create table if not exists public.community_posts (
  id uuid primary key default gen_random_uuid(),
  category text not null check (category in ('notice', 'library', 'info', 'story', 'qna')),
  template text not null check (template in ('notice', 'resource', 'free')),
  title text not null check (char_length(btrim(title)) between 2 and 120),
  body text not null default '' check (char_length(body) <= 20000),
  -- 자료 양식
  summary text check (summary is null or char_length(summary) <= 200),
  audiences text[] not null default '{}',
  reference_date date,
  resource_type text check (resource_type is null or char_length(resource_type) <= 40),
  key_points text[] not null default '{}' check (cardinality(key_points) <= 8),
  source_ref text check (source_ref is null or char_length(source_ref) <= 300),
  -- 공지 양식
  event_period text check (event_period is null or char_length(event_period) <= 100),
  notice_target text check (notice_target is null or char_length(notice_target) <= 100),
  contact text check (contact is null or char_length(contact) <= 100),
  attachments jsonb not null default '[]'::jsonb check (jsonb_typeof(attachments) = 'array'),
  is_pinned boolean not null default false,
  allow_comments boolean not null default true,
  status text not null default 'published' check (status in ('published', 'hidden')),
  author_id uuid references auth.users(id) on delete set null,
  author_label text not null,
  is_official boolean not null default false,
  view_count integer not null default 0,
  comment_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_community_posts_list
  on public.community_posts (status, is_pinned desc, created_at desc);
create index if not exists idx_community_posts_category
  on public.community_posts (category, created_at desc);
create index if not exists idx_community_posts_author on public.community_posts (author_id);

-- ---------------------------------------------------------------------
-- 2. 댓글 (답글은 한 단계만)
-- ---------------------------------------------------------------------
create table if not exists public.community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  parent_id uuid references public.community_comments(id) on delete cascade,
  author_id uuid references auth.users(id) on delete set null,
  author_label text not null,
  is_official boolean not null default false,
  body text not null,
  status text not null default 'published' check (status in ('published', 'hidden', 'deleted')),
  created_at timestamptz not null default now(),
  constraint community_comments_body_len check (
    status <> 'published' or char_length(btrim(body)) between 1 and 500
  )
);
create index if not exists idx_community_comments_post on public.community_comments (post_id, created_at);
create index if not exists idx_community_comments_parent on public.community_comments (parent_id);
create index if not exists idx_community_comments_author on public.community_comments (author_id, created_at desc);

-- ---------------------------------------------------------------------
-- 3. 읽기 권한 — 쓰기 정책은 두지 않는다 (함수 전용)
-- ---------------------------------------------------------------------
alter table public.community_posts enable row level security;
alter table public.community_comments enable row level security;

drop policy if exists "community_posts_read" on public.community_posts;
create policy "community_posts_read" on public.community_posts
  for select using (status = 'published' or public.is_platform_admin());

drop policy if exists "community_comments_read" on public.community_comments;
create policy "community_comments_read" on public.community_comments
  for select using (
    (status in ('published', 'deleted') or public.is_platform_admin())
    and exists (
      select 1 from public.community_posts p
      where p.id = post_id and (p.status = 'published' or public.is_platform_admin())
    )
  );

grant select on public.community_posts, public.community_comments to anon, authenticated;
revoke insert, update, delete on public.community_posts, public.community_comments from anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. 보조 함수
-- ---------------------------------------------------------------------
create or replace function public.community_is_member()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.organization_members where user_id = auth.uid());
$$;

-- 작성자 표시명: 최고관리자는 '동행솔루션', 회원은 처음 소속된 기관명
create or replace function public.community_author_label()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when public.is_platform_admin() then '동행솔루션'
    else (
      select o.name
      from public.organization_members m
      join public.organizations o on o.id = m.organization_id
      where m.user_id = auth.uid()
      order by m.created_at, o.name
      limit 1
    )
  end;
$$;

-- 화면에서 버튼을 보여줄지 정할 때 쓰는 현재 사용자 정보
create or replace function public.community_viewer()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'signed_in', auth.uid() is not null,
    'user_id', auth.uid(),
    'is_admin', coalesce(public.is_platform_admin(), false),
    'is_member', coalesce(public.community_is_member(), false),
    'label', public.community_author_label()
  );
$$;

create or replace function public.community_clean_text(p_value text)
returns text
language sql
immutable
as $$
  select nullif(btrim(coalesce(p_value, '')), '');
$$;

-- 첨부 목록은 버킷 안 posts/ 경로와 이름·크기만 허용
create or replace function public.community_clean_attachments(p_value jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_item jsonb;
  v_out jsonb := '[]'::jsonb;
  v_path text;
  v_name text;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'array' then
    return '[]'::jsonb;
  end if;
  if jsonb_array_length(p_value) > 10 then
    raise exception '첨부파일은 10개까지 올릴 수 있습니다.';
  end if;
  for v_item in select * from jsonb_array_elements(p_value) loop
    v_path := v_item->>'path';
    v_name := btrim(coalesce(v_item->>'name', ''));
    if v_path is null or v_path !~ '^posts/[A-Za-z0-9/_.-]{1,200}$' or v_path like '%..%' then
      raise exception '첨부파일 경로가 올바르지 않습니다.';
    end if;
    if v_name = '' or char_length(v_name) > 200 then
      raise exception '첨부파일 이름이 올바르지 않습니다.';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'path', v_path,
      'name', v_name,
      'size', greatest(coalesce((v_item->>'size')::bigint, 0), 0)
    ));
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. 글 저장 (새 글: p_id null / 수정: p_id)
-- ---------------------------------------------------------------------
create or replace function public.community_save_post(p_id uuid, p_post jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_admin boolean := public.is_platform_admin();
  v_category text := p_post->>'category';
  v_template text;
  v_title text := public.community_clean_text(p_post->>'title');
  v_body text := coalesce(p_post->>'body', '');
  v_points text[];
  v_audiences text[];
  v_existing public.community_posts;
  v_id uuid;
  v_recent integer;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not v_admin and not public.community_is_member() then
    raise exception '가입 승인된 회원만 글을 쓸 수 있습니다.';
  end if;
  if v_category is null or v_category not in ('notice', 'library', 'info', 'story', 'qna') then
    raise exception '분류를 선택해 주세요.';
  end if;
  if v_category in ('notice', 'library') and not v_admin then
    raise exception '공지사항과 자료실은 운영자만 쓸 수 있습니다.';
  end if;
  if v_title is null or char_length(v_title) < 2 or char_length(v_title) > 120 then
    raise exception '제목은 2~120자로 입력해 주세요.';
  end if;

  v_template := case v_category when 'notice' then 'notice' when 'library' then 'resource' else 'free' end;

  select coalesce(array_agg(x), '{}') into v_points
  from (
    select left(btrim(value), 200) as x
    from jsonb_array_elements_text(coalesce(p_post->'key_points', '[]'::jsonb))
    where btrim(value) <> ''
    limit 8
  ) s;

  select coalesce(array_agg(x), '{}') into v_audiences
  from (
    select distinct left(btrim(value), 40) as x
    from jsonb_array_elements_text(coalesce(p_post->'audiences', '[]'::jsonb))
    where btrim(value) <> ''
    limit 10
  ) s;

  if v_template = 'resource' and public.community_clean_text(p_post->>'summary') is null then
    raise exception '자료 양식은 한 줄 요약이 필요합니다.';
  end if;
  if v_template <> 'resource' and btrim(v_body) = '' then
    raise exception '본문을 입력해 주세요.';
  end if;

  if p_id is null then
    select count(*) into v_recent
    from public.community_posts
    where author_id = v_uid and created_at > now() - interval '10 minutes';
    if not v_admin and v_recent >= 5 then
      raise exception '잠시 후 다시 작성해 주세요.';
    end if;

    insert into public.community_posts (
      category, template, title, body, summary, audiences, reference_date, resource_type,
      key_points, source_ref, event_period, notice_target, contact, attachments,
      is_pinned, allow_comments, author_id, author_label, is_official
    ) values (
      v_category, v_template, v_title, v_body,
      case when v_template = 'resource' then public.community_clean_text(p_post->>'summary') end,
      case when v_template = 'resource' then v_audiences else '{}' end,
      case when v_template = 'resource' then nullif(p_post->>'reference_date', '')::date end,
      case when v_template = 'resource' then left(public.community_clean_text(p_post->>'resource_type'), 40) end,
      case when v_template = 'resource' then v_points else '{}' end,
      case when v_template = 'resource' then left(public.community_clean_text(p_post->>'source_ref'), 300) end,
      case when v_template = 'notice' then left(public.community_clean_text(p_post->>'event_period'), 100) end,
      case when v_template = 'notice' then left(public.community_clean_text(p_post->>'notice_target'), 100) end,
      case when v_template = 'notice' then left(public.community_clean_text(p_post->>'contact'), 100) end,
      case when v_admin then public.community_clean_attachments(p_post->'attachments') else '[]'::jsonb end,
      v_admin and coalesce((p_post->>'is_pinned')::boolean, false),
      coalesce((p_post->>'allow_comments')::boolean, true),
      v_uid,
      coalesce(public.community_author_label(), '회원'),
      v_admin
    )
    returning id into v_id;
    return v_id;
  end if;

  select * into v_existing from public.community_posts where id = p_id for update;
  if not found then
    raise exception '글을 찾을 수 없습니다.';
  end if;
  if not v_admin and (v_existing.author_id is distinct from v_uid or v_existing.status <> 'published') then
    raise exception '본인이 쓴 글만 수정할 수 있습니다.';
  end if;

  update public.community_posts set
    category = v_category,
    template = v_template,
    title = v_title,
    body = v_body,
    summary = case when v_template = 'resource' then public.community_clean_text(p_post->>'summary') end,
    audiences = case when v_template = 'resource' then v_audiences else '{}' end,
    reference_date = case when v_template = 'resource' then nullif(p_post->>'reference_date', '')::date end,
    resource_type = case when v_template = 'resource' then left(public.community_clean_text(p_post->>'resource_type'), 40) end,
    key_points = case when v_template = 'resource' then v_points else '{}' end,
    source_ref = case when v_template = 'resource' then left(public.community_clean_text(p_post->>'source_ref'), 300) end,
    event_period = case when v_template = 'notice' then left(public.community_clean_text(p_post->>'event_period'), 100) end,
    notice_target = case when v_template = 'notice' then left(public.community_clean_text(p_post->>'notice_target'), 100) end,
    contact = case when v_template = 'notice' then left(public.community_clean_text(p_post->>'contact'), 100) end,
    attachments = case when v_admin then public.community_clean_attachments(p_post->'attachments') else attachments end,
    is_pinned = case when v_admin then coalesce((p_post->>'is_pinned')::boolean, false) else is_pinned end,
    allow_comments = coalesce((p_post->>'allow_comments')::boolean, true),
    updated_at = now()
  where id = p_id;
  return p_id;
end;
$$;

-- 글 숨기기(삭제)·다시 게시: 작성자는 숨기기만, 최고관리자는 둘 다
create or replace function public.community_set_post_status(p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post public.community_posts;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if p_status not in ('published', 'hidden') then
    raise exception '알 수 없는 상태입니다.';
  end if;
  select * into v_post from public.community_posts where id = p_id for update;
  if not found then
    raise exception '글을 찾을 수 없습니다.';
  end if;
  if not public.is_platform_admin()
     and (v_post.author_id is distinct from auth.uid() or p_status <> 'hidden') then
    raise exception '권한이 없습니다.';
  end if;
  update public.community_posts set status = p_status, updated_at = now() where id = p_id;
end;
$$;

-- 조회수 (비로그인 포함)
create or replace function public.community_record_view(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.community_posts set view_count = view_count + 1
  where id = p_id and status = 'published';
$$;

-- ---------------------------------------------------------------------
-- 6. 댓글 쓰기·삭제
-- ---------------------------------------------------------------------
create or replace function public.community_refresh_comment_count(p_post_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.community_posts p
  set comment_count = (
    select count(*) from public.community_comments c
    where c.post_id = p.id and c.status = 'published'
  )
  where p.id = p_post_id;
$$;

create or replace function public.community_add_comment(p_post_id uuid, p_parent_id uuid, p_body text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_admin boolean := public.is_platform_admin();
  v_body text := btrim(coalesce(p_body, ''));
  v_post public.community_posts;
  v_parent public.community_comments;
  v_recent integer;
  v_id uuid;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if not v_admin and not public.community_is_member() then
    raise exception '가입 승인된 회원만 댓글을 쓸 수 있습니다.';
  end if;
  if char_length(v_body) < 1 or char_length(v_body) > 500 then
    raise exception '댓글은 1~500자로 입력해 주세요.';
  end if;

  select * into v_post from public.community_posts where id = p_post_id;
  if not found or v_post.status <> 'published' then
    raise exception '글을 찾을 수 없습니다.';
  end if;
  if not v_post.allow_comments and not v_admin then
    raise exception '댓글이 닫힌 글입니다.';
  end if;

  if p_parent_id is not null then
    select * into v_parent from public.community_comments where id = p_parent_id;
    if not found or v_parent.post_id <> p_post_id or v_parent.status <> 'published' then
      raise exception '답글을 달 댓글을 찾을 수 없습니다.';
    end if;
    if v_parent.parent_id is not null then
      raise exception '답글에는 다시 답글을 달 수 없습니다.';
    end if;
  end if;

  select count(*) into v_recent
  from public.community_comments
  where author_id = v_uid and created_at > now() - interval '10 minutes';
  if not v_admin and v_recent >= 10 then
    raise exception '잠시 후 다시 작성해 주세요.';
  end if;

  insert into public.community_comments (post_id, parent_id, author_id, author_label, is_official, body)
  values (p_post_id, p_parent_id, v_uid, coalesce(public.community_author_label(), '회원'), v_admin, v_body)
  returning id into v_id;

  perform public.community_refresh_comment_count(p_post_id);
  return v_id;
end;
$$;

-- 본인 댓글 삭제 또는 최고관리자 숨김. 내용은 지우고 자리만 남긴다(답글 유지).
create or replace function public.community_delete_comment(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comment public.community_comments;
  v_admin boolean := public.is_platform_admin();
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;
  select * into v_comment from public.community_comments where id = p_id for update;
  if not found or v_comment.status <> 'published' then
    raise exception '댓글을 찾을 수 없습니다.';
  end if;
  if not v_admin and v_comment.author_id is distinct from auth.uid() then
    raise exception '본인 댓글만 삭제할 수 있습니다.';
  end if;
  update public.community_comments
  set status = case when v_admin and v_comment.author_id is distinct from auth.uid() then 'hidden' else 'deleted' end,
      body = ''
  where id = p_id;
  perform public.community_refresh_comment_count(v_comment.post_id);
end;
$$;

revoke all on function public.community_save_post(uuid, jsonb) from public;
revoke all on function public.community_set_post_status(uuid, text) from public;
revoke all on function public.community_add_comment(uuid, uuid, text) from public;
revoke all on function public.community_delete_comment(uuid) from public;
revoke all on function public.community_refresh_comment_count(uuid) from public;
revoke all on function public.community_record_view(uuid) from public;
revoke all on function public.community_viewer() from public;
revoke all on function public.community_is_member() from public;
revoke all on function public.community_author_label() from public;

grant execute on function public.community_save_post(uuid, jsonb) to authenticated;
grant execute on function public.community_set_post_status(uuid, text) to authenticated;
grant execute on function public.community_add_comment(uuid, uuid, text) to authenticated;
grant execute on function public.community_delete_comment(uuid) to authenticated;
grant execute on function public.community_record_view(uuid) to anon, authenticated;
grant execute on function public.community_viewer() to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. 첨부파일 버킷 (공개 읽기, 최고관리자만 업로드·삭제)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'community-files', 'community-files', true, 20971520,
  array[
    'application/pdf',
    'application/x-hwp', 'application/haansofthwp', 'application/vnd.hancom.hwp',
    'application/vnd.hancom.hwpx', 'application/hwp+zip',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'image/png', 'image/jpeg', 'image/webp',
    'application/zip', 'application/octet-stream'
  ]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "community_files_admin_insert" on storage.objects;
create policy "community_files_admin_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'community-files' and public.is_platform_admin() and name like 'posts/%');

drop policy if exists "community_files_admin_delete" on storage.objects;
create policy "community_files_admin_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'community-files' and public.is_platform_admin());

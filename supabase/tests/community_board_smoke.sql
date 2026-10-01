-- Community board (posts + comments) permission smoke test.
-- Run in a transaction; all fixtures are rolled back.
begin;

insert into auth.users(id,aud,role,email) values
('c0000000-0000-4000-8000-0000000000a1','authenticated','authenticated','community-admin@example.invalid'),
('c0000000-0000-4000-8000-0000000000b1','authenticated','authenticated','community-member@example.invalid'),
('c0000000-0000-4000-8000-0000000000b2','authenticated','authenticated','community-member2@example.invalid'),
('c0000000-0000-4000-8000-0000000000c1','authenticated','authenticated','community-pending@example.invalid');

insert into public.platform_admins(user_id) values ('c0000000-0000-4000-8000-0000000000a1');

insert into public.organizations(id,name) values
('c1000000-0000-4000-8000-000000000001','커뮤니티 테스트 복지관'),
('c1000000-0000-4000-8000-000000000002','커뮤니티 테스트 센터');

insert into public.organization_members(organization_id,user_id,role) values
('c1000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-0000000000b1','staff'),
('c1000000-0000-4000-8000-000000000002','c0000000-0000-4000-8000-0000000000b2','owner');

create temp table ids(name text primary key, id uuid) on commit drop;
grant all on ids to anon, authenticated;

-- 1) 최고관리자: 공지(상단 고정)와 자료실 글
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-4000-8000-0000000000a1","role":"authenticated"}',true);

insert into ids values ('notice', public.community_save_post(null, jsonb_build_object(
  'category','notice','title','게시판 오픈 안내','body','이용 안내입니다.',
  'event_period','10.1 ~','contact','042-673-3338','is_pinned',true,
  'summary','무시되어야 하는 요약')));
insert into ids values ('library', public.community_save_post(null, jsonb_build_object(
  'category','library','title','회계 실무 체크리스트','summary','월말 점검 항목 정리',
  'audiences',jsonb_build_array('종합사회복지관','노인복지시설',' '),
  'key_points',jsonb_build_array('잔액 대조','증빙 확인',''),
  'reference_date','2026-09-30','resource_type','체크리스트',
  'attachments',jsonb_build_array(jsonb_build_object('path','posts/2026/a.hwp','name','a.hwp','size',100)))));

do $$
declare v public.community_posts;
begin
  select * into v from public.community_posts where id=(select id from ids where name='notice');
  if v.template<>'notice' or not v.is_pinned or not v.is_official or v.author_label<>'동행솔루션' then
    raise exception 'admin notice not stored as official pinned notice';
  end if;
  if v.summary is not null then raise exception 'notice kept resource-only field'; end if;

  select * into v from public.community_posts where id=(select id from ids where name='library');
  if v.template<>'resource' or cardinality(v.key_points)<>2 or cardinality(v.audiences)<>2
     or jsonb_array_length(v.attachments)<>1 or v.reference_date<>'2026-09-30' then
    raise exception 'resource template fields not normalized';
  end if;

  begin
    perform public.community_save_post(null, jsonb_build_object('category','library','title','요약 없는 자료'));
    raise exception 'resource without summary allowed';
  exception when raise_exception then
    if sqlerrm not like '%요약%' then raise; end if;
  end;

  begin
    perform public.community_save_post(null, jsonb_build_object('category','library','title','경로 조작','summary','x',
      'attachments',jsonb_build_array(jsonb_build_object('path','posts/../secret','name','x'))));
    raise exception 'attachment path traversal allowed';
  exception when raise_exception then
    if sqlerrm not like '%경로%' then raise; end if;
  end;
end $$;

-- 2) 회원: 공지 불가, 질문답변 가능(고정·첨부 무시), 직접 insert 불가
select set_config('request.jwt.claims','{"sub":"c0000000-0000-4000-8000-0000000000b1","role":"authenticated"}',true);

do $$
begin
  begin
    perform public.community_save_post(null, jsonb_build_object('category','notice','title','회원 공지','body','x'));
    raise exception 'member wrote notice';
  exception when raise_exception then
    if sqlerrm not like '%운영자만%' then raise; end if;
  end;
  begin
    insert into public.community_posts(category,template,title,author_label) values ('qna','free','직접 입력','x');
    raise exception 'direct insert allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

insert into ids values ('qna', public.community_save_post(null, jsonb_build_object(
  'category','qna','title','후원금 영수증 질문','body','다른 기관은 어떻게 하시나요?','is_pinned',true,
  'attachments',jsonb_build_array(jsonb_build_object('path','posts/x.pdf','name','x.pdf')))));

do $$
declare v public.community_posts;
begin
  select * into v from public.community_posts where id=(select id from ids where name='qna');
  if v.is_pinned or v.is_official or jsonb_array_length(v.attachments)<>0 or v.author_label<>'커뮤니티 테스트 복지관' then
    raise exception 'member post gained admin-only fields';
  end if;
end $$;

-- 3) 댓글과 답글
insert into ids values ('c1', public.community_add_comment((select id from ids where name='notice'), null, '  반갑습니다  '));

select set_config('request.jwt.claims','{"sub":"c0000000-0000-4000-8000-0000000000b2","role":"authenticated"}',true);
insert into ids values ('c2', public.community_add_comment((select id from ids where name='notice'), (select id from ids where name='c1'), '저도요'));

do $$
begin
  begin
    perform public.community_add_comment((select id from ids where name='notice'), (select id from ids where name='c2'), '답글의 답글');
    raise exception 'nested reply allowed';
  exception when raise_exception then
    if sqlerrm not like '%다시 답글%' then raise; end if;
  end;
  begin
    perform public.community_delete_comment((select id from ids where name='c1'));
    raise exception 'deleted another member comment';
  exception when raise_exception then
    if sqlerrm not like '%본인 댓글%' then raise; end if;
  end;
  begin
    perform public.community_save_post((select id from ids where name='qna'), jsonb_build_object('category','qna','title','남의 글 수정','body','x'));
    raise exception 'edited another member post';
  exception when raise_exception then
    if sqlerrm not like '%본인이 쓴 글%' then raise; end if;
  end;
  if (select body from public.community_comments where id=(select id from ids where name='c1'))<>'반갑습니다' then
    raise exception 'comment body not trimmed';
  end if;
  if (select comment_count from public.community_posts where id=(select id from ids where name='notice'))<>2 then
    raise exception 'comment count not maintained';
  end if;
end $$;

-- 4) 승인 대기(소속 없음) 계정은 댓글 불가
select set_config('request.jwt.claims','{"sub":"c0000000-0000-4000-8000-0000000000c1","role":"authenticated"}',true);
do $$
begin
  begin
    perform public.community_add_comment((select id from ids where name='notice'), null, '대기 계정 댓글');
    raise exception 'pending account commented';
  exception when raise_exception then
    if sqlerrm not like '%가입 승인%' then raise; end if;
  end;
  if (public.community_viewer()->>'is_member')::boolean then raise exception 'pending viewer reported as member'; end if;
end $$;

-- 5) 최고관리자가 댓글 숨김, 글 숨김
select set_config('request.jwt.claims','{"sub":"c0000000-0000-4000-8000-0000000000a1","role":"authenticated"}',true);
select public.community_delete_comment((select id from ids where name='c1'));
select public.community_set_post_status((select id from ids where name='qna'), 'hidden');

do $$
begin
  if (select status from public.community_comments where id=(select id from ids where name='c1'))<>'hidden' then
    raise exception 'admin removal not marked hidden';
  end if;
  if (select comment_count from public.community_posts where id=(select id from ids where name='notice'))<>1 then
    raise exception 'comment count not decremented';
  end if;
end $$;

-- 6) 비로그인: 게시된 글·댓글만 읽고, 조회수만 올릴 수 있다
reset role;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);
select public.community_record_view((select id from ids where name='notice'));

do $$
begin
  if exists(select 1 from public.community_posts where id=(select id from ids where name='qna')) then
    raise exception 'hidden post visible to anon';
  end if;
  if (select count(*) from public.community_posts where id in (select id from ids where name in ('notice','library')))<>2 then
    raise exception 'published posts not visible to anon';
  end if;
  if exists(select 1 from public.community_comments where id=(select id from ids where name='c1')) then
    raise exception 'hidden comment visible to anon';
  end if;
  if not exists(select 1 from public.community_comments where id=(select id from ids where name='c2')) then
    raise exception 'published reply not visible to anon';
  end if;
  if (select view_count from public.community_posts where id=(select id from ids where name='notice'))<>1 then
    raise exception 'view not recorded';
  end if;
  begin
    perform public.community_add_comment((select id from ids where name='notice'), null, '익명');
    raise exception 'anon commented';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;
select 'community_board_smoke: ok' as result;
rollback;

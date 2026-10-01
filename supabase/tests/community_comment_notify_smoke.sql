-- 댓글 알림 권리(claim) 확인. 모두 롤백된다. 마지막 줄은 rollback; 이다.
begin;
insert into auth.users(id,aud,role,email) values
('c0000000-0000-4000-8000-0000000000a1','authenticated','authenticated','notify-admin@example.invalid'),
('c0000000-0000-4000-8000-0000000000b1','authenticated','authenticated','notify-member@example.invalid'),
('c0000000-0000-4000-8000-0000000000b2','authenticated','authenticated','notify-member2@example.invalid');
insert into public.platform_admins(user_id) values ('c0000000-0000-4000-8000-0000000000a1');
insert into public.organizations(id,name) values ('c1000000-0000-4000-8000-000000000001','알림 테스트 기관');
insert into public.organization_members(organization_id,user_id,role) values
('c1000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-0000000000b1','staff'),
('c1000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-0000000000b2','staff');
create temp table ids(name text primary key, id uuid) on commit drop;
grant all on ids to authenticated;

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-4000-8000-0000000000a1","role":"authenticated"}',true);
insert into ids values ('post', public.community_save_post(null, '{"category":"notice","title":"알림 테스트","body":"x"}'));
insert into ids values ('admin_c', public.community_add_comment((select id from ids where name='post'), null, '운영자 댓글'));
select set_config('request.jwt.claims','{"sub":"c0000000-0000-4000-8000-0000000000b1","role":"authenticated"}',true);
insert into ids values ('member_c', public.community_add_comment((select id from ids where name='post'), null, '회원 댓글'));

do $$
declare v jsonb;
begin
  v := public.community_claim_comment_notification((select id from ids where name='member_c'));
  if v is null or v->>'post_title' <> '알림 테스트' or v->>'body' <> '회원 댓글' then raise exception 'author claim failed: %', v; end if;
  if public.community_claim_comment_notification((select id from ids where name='member_c')) is not null then raise exception 'claimed twice'; end if;
  perform public.community_release_comment_notification((select id from ids where name='member_c'));
  if public.community_claim_comment_notification((select id from ids where name='member_c')) is null then raise exception 'release did not allow retry'; end if;
end $$;

select set_config('request.jwt.claims','{"sub":"c0000000-0000-4000-8000-0000000000b2","role":"authenticated"}',true);
do $$
begin
  if public.community_claim_comment_notification((select id from ids where name='member_c')) is not null then raise exception 'other user claimed'; end if;
end $$;

select set_config('request.jwt.claims','{"sub":"c0000000-0000-4000-8000-0000000000a1","role":"authenticated"}',true);
do $$
begin
  if public.community_claim_comment_notification((select id from ids where name='admin_c')) is not null then raise exception 'admin comment notified'; end if;
end $$;

reset role;
do $$
begin
  if has_function_privilege('anon', 'public.community_claim_comment_notification(uuid)', 'execute') then raise exception 'anon can claim'; end if;
end $$;
select 'community_comment_notify_smoke: ok' as result;
rollback;

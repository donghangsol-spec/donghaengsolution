-- =====================================================================
--  복지커뮤니티 함수 실행 권한 정리
--
--  Supabase는 public 스키마에 새로 만든 함수를 anon·authenticated에도
--  기본으로 실행 허용한다. 20261001150000_community_board.sql의
--  "revoke ... from public"만으로는 그 기본 권한이 남는다.
--  쓰기 함수는 로그인 사용자만, 내부 보조 함수는 아무도 직접 부르지
--  못하게 한다. (함수 안의 권한 검사는 그대로 유지된다.)
--
--  사용법: Supabase [SQL Editor] → New query → 이 파일 전체 붙여넣고 Run.
-- =====================================================================

-- 쓰기 함수: 로그인 사용자만
revoke execute on function public.community_save_post(uuid, jsonb) from anon;
revoke execute on function public.community_set_post_status(uuid, text) from anon;
revoke execute on function public.community_add_comment(uuid, uuid, text) from anon;
revoke execute on function public.community_delete_comment(uuid) from anon;

-- 내부 보조 함수: 직접 호출 금지 (다른 security definer 함수 안에서만 쓰임)
revoke execute on function public.community_refresh_comment_count(uuid) from anon, authenticated;
revoke execute on function public.community_is_member() from anon, authenticated;
revoke execute on function public.community_author_label() from anon, authenticated;
revoke execute on function public.community_clean_attachments(jsonb) from public, anon, authenticated;
revoke execute on function public.community_clean_text(text) from public, anon, authenticated;

-- 공개 함수는 그대로
grant execute on function public.community_viewer() to anon, authenticated;
grant execute on function public.community_record_view(uuid) to anon, authenticated;

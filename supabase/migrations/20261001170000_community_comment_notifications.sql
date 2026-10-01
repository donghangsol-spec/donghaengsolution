-- =====================================================================
--  복지커뮤니티 새 댓글 → 운영자 메일 알림
--
--  회원이 댓글을 달면 브라우저가 /api/community-notify 를 부르고,
--  그 API가 댓글 작성자 본인의 로그인 토큰으로 아래 함수를 불러
--  "이 댓글 알림을 보낼 권리"를 한 번만 받아 간다(notified_at 기록).
--  같은 댓글로 메일이 두 번 가지 않고, 남의 댓글이나 오래된 댓글로는
--  메일을 보낼 수 없다. 받는 사람 주소는 Vercel 환경변수에만 둔다.
--
--  사용법: Supabase [SQL Editor] → New query → 이 파일 전체 붙여넣고 Run.
-- =====================================================================

alter table public.community_comments add column if not exists notified_at timestamptz;

create or replace function public.community_claim_comment_notification(p_comment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comment public.community_comments;
  v_post public.community_posts;
begin
  select * into v_comment from public.community_comments where id = p_comment_id;
  if not found
     or auth.uid() is null
     or v_comment.author_id is distinct from auth.uid()
     or v_comment.status <> 'published'
     or v_comment.is_official
     or v_comment.notified_at is not null
     or v_comment.created_at < now() - interval '10 minutes' then
    return null;
  end if;

  update public.community_comments
  set notified_at = now()
  where id = p_comment_id and notified_at is null;
  if not found then
    return null;
  end if;

  select * into v_post from public.community_posts where id = v_comment.post_id;
  return jsonb_build_object(
    'post_id', v_post.id,
    'post_title', v_post.title,
    'author_label', v_comment.author_label,
    'body', v_comment.body,
    'is_reply', v_comment.parent_id is not null
  );
end;
$$;

-- 메일 발송이 실패했을 때 다시 보낼 수 있게 되돌린다 (본인 댓글, 10분 이내만)
create or replace function public.community_release_comment_notification(p_comment_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.community_comments
  set notified_at = null
  where id = p_comment_id
    and author_id = auth.uid()
    and created_at > now() - interval '10 minutes';
$$;

revoke all on function public.community_claim_comment_notification(uuid) from public, anon;
revoke all on function public.community_release_comment_notification(uuid) from public, anon;
grant execute on function public.community_claim_comment_notification(uuid) to authenticated;
grant execute on function public.community_release_comment_notification(uuid) to authenticated;

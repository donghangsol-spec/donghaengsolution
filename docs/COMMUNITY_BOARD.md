# 복지커뮤니티 게시판

공지사항·자료실·정보공유·현장이야기·질문답변 게시판과 댓글 기능입니다.

| 경로 | 화면 |
|---|---|
| `/community` | 목록 (분류 탭, 제목 검색, 상단 고정, 많이 본 글) |
| `/community/post?id=…` | 글 보기 + 댓글·답글 |
| `/community/write` (`?id=…` 수정) | 글쓰기 — 분류에 따라 양식이 바뀜 |

## 권한

| 누가 | 읽기 | 공지사항·자료실 쓰기, 상단 고정, 첨부 | 정보공유·현장이야기·질문답변 쓰기 | 댓글 |
|---|---|---|---|---|
| 비로그인 | O | – | – | – |
| 가입 승인 대기 | O | – | – | – |
| 승인된 회원(`organization_members`) | O | – | O | O |
| 최고관리자(`platform_admins`) | O (숨긴 글 포함) | O | O | O |

- 테이블에 직접 쓰기는 막혀 있고 `community_save_post`, `community_add_comment` 등 함수로만 씁니다.
- 작성자 이름은 서버가 정합니다: 최고관리자는 `동행솔루션`, 회원은 소속 기관명.
- 본인 글·댓글은 본인이 삭제할 수 있고, 최고관리자는 모든 글·댓글을 숨길 수 있습니다.
- 도배 방지: 회원은 10분에 글 5개, 댓글 10개까지.

## 글 양식

- **자료 양식(자료실)**: 한 줄 요약(필수), 대상 기관, 기준일, 자료 유형, 핵심 내용(최대 8줄), 상세 설명, 첨부, 출처·참고
- **공지 양식(공지사항)**: 일시·기간, 대상, 문의처, 본문, 첨부
- **자유 형식(그 외)**: 본문

## 배포 순서

1. Supabase SQL Editor에서 `supabase/migrations/20261001150000_community_board.sql` 실행
   (`20261001090000_platform_admin_signup_approval.sql`이 먼저 적용되어 있어야 함)
   이어서 `supabase/migrations/20261001160000_community_board_grants.sql` 실행
   (Supabase 기본 권한 때문에 비로그인 사용자도 쓰기 함수를 부를 수 있던 것을 막음)
2. 운영자 계정이 `platform_admins`에 있는지 확인
3. 확인용: `supabase/tests/community_board_smoke.sql` 실행 → `community_board_smoke: ok` (모두 롤백됨)
   SQL Editor에 붙여넣을 때는 GitHub의 복사 버튼을 쓰고, 마지막 줄(`rollback;`)까지 들어갔는지 확인
4. 배포 후 `/community`에서 운영자로 로그인해 첫 공지 작성

첨부파일은 공개 버킷 `community-files`(파일당 20MB)에 저장되므로 개인정보가 담긴 파일은 올리지 않습니다.

## 새 댓글 메일 알림

회원이 댓글·답글을 달면 운영자에게 메일이 갑니다 (운영자 본인 댓글은 제외).

- 흐름: 댓글 등록 → 브라우저가 `/api/community-notify` 호출 → 작성자 본인 토큰으로
  `community_claim_comment_notification` (댓글당 한 번, 등록 후 10분 이내만) → Resend 발송
- 발송 실패 시 `community_release_comment_notification`으로 되돌려 다시 보낼 수 있음
- 받는 주소는 브라우저에 노출되지 않고 Vercel 환경변수에만 둡니다.

| Vercel 환경변수 | 내용 |
|---|---|
| `COMMUNITY_NOTIFY_TO` | 알림 받을 주소 (쉼표로 여러 개). 없으면 `CONTACT_TO_EMAIL` 사용 |
| `RESEND_API_KEY` | 기존 값 사용 |
| `CONTACT_FROM_EMAIL` | 보내는 주소 (기존 값, 없으면 `noreply@donghangsolution.co.kr`) |

적용: `supabase/migrations/20261001170000_community_comment_notifications.sql` 실행 →
확인용 `supabase/tests/community_comment_notify_smoke.sql` → `community_comment_notify_smoke: ok`

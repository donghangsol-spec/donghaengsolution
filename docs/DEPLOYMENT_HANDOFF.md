# 동행솔루션 배포 인계서

기준: PR #5 · 내부 MVP 검증용

## 출시 판단

| 범위 | 상태 | 운영 원칙 |
|---|---|---|
| Vercel Preview와 내부 MVP 검증 | READY | 테스트 계정과 비식별·가상 데이터만 사용 |
| Supabase Auth/DB와 Resend Magic Link | READY | owner/staff 권한 회귀시험 후 사용 |
| 실제 고객 개인정보 입력 | KEEP BLOCKED | Issue #2의 P0 완료 전 금지 |
| 공단·EDI·홈택스 등 실제 신고 | KEEP BLOCKED | 공동인증서·매크로 신고 게이트 완료 전 금지 |

## 배포 전 운영자 설정

1. Vercel의 Preview와 Production 환경에 `SUPABASE_URL`, `SUPABASE_ANON_KEY`를 등록한다.
2. Vercel 대표 도메인을 연결하고 `/`, `/next`, `/payroll`, `/index`, `/api/config.js`를 확인한다.
3. Supabase Auth의 Site URL과 Redirect URLs에 실제 운영 도메인과 필요한 Preview 도메인을 등록한다.
4. Supabase Custom SMTP가 Resend의 검증된 `donghangsolution.co.kr` 발신주소를 사용하는지 확인한다.
5. 실제 비밀값, service-role key, 공동인증서 또는 비밀번호를 GitHub와 브라우저 코드에 넣지 않는다.

### 가입 승인 체계 (2026-10-01 전환) — 배포마다 반드시 확인

`onboard-owner`(로그인 시 1인 조직 자동생성)는 완전히 폐지되었다. 지금부터는
"가입 신청 → 최고관리자 승인 → 사업장 연결" 순서로만 사업장이 생긴다.

1. Supabase [SQL Editor]에서 `supabase/migrations/20261001090000_platform_admin_signup_approval.sql`을
   아직 실행하지 않았다면 전체 실행한다. (이미 실행했다면 다시 실행해도 안전하다 — 모두
   `create or replace`/`if not exists`로 작성됨.)
2. 같은 SQL Editor에서, 대표님(또는 최고관리자로 쓸) 계정을 `platform_admins`에 등록한다
   (파일 맨 아래 주석의 1줄 INSERT, 이메일만 바꿔서 실행).
3. `onboard-owner` Edge Function은 더 이상 호출되지 않지만, 혹시 남아있다면 그대로 두어도
   무방하다 — DB 함수(`onboard_owner_internal`)가 호출 시 바로 에러를 던지도록 막혀 있다.
4. 새 공개 페이지 `/signup.html`(가입 신청)과 `/admin.html`(최고관리자 콘솔)이 배포됐는지
   확인한다.

## 배포 및 확인

1. PR Preview가 Ready인지 확인한다.
2. `/signup.html`에서 테스트 계정으로 가입 신청 → 이메일 인증 → 로그인 시 "승인 대기" 화면이
   뜨는지 확인한다 (사업장에 연결되기 전에는 업무 화면에 들어가지지 않아야 한다).
3. 최고관리자 계정으로 `/admin.html`에 로그인해 방금 만든 신청을 기존 사업장에 연결(또는
   새 사업장 생성)하고, 반려 흐름도 한 번 시험한다.
4. 승인된 테스트 계정으로 다시 로그인해 업무 화면(사업장·직원·급여·4대보험)이 정상적으로
   열리는지 확인한다.
5. staff 권한 Magic Link 로그인을 시험하고, 사업장·직원 생성, 급여 초안·검증·확정, 4대보험
   요청·검증·승인을 시험한다.
6. staff의 급여 확정과 보험 승인이 차단되는지 확인한다.
7. 승인된 보험 요청과 확정 급여의 수정이 차단되는지 확인한다.
8. 최고관리자가 아닌 계정으로 `/admin.html`에 로그인했을 때 "권한 없음" 화면만 보이고
   가입 신청 목록이 보이지 않는지 확인한다.
9. 테스트 데이터가 실제 고객정보가 아님을 확인한 뒤 PR을 병합한다.
10. `main` Production 배포에서 같은 시험을 반복하고 커밋 SHA, URL, 시험자, 결과를 기록한다.

## 즉시 중지 조건

- `/api/config.js`가 503이거나 공개 설정이 비어 있음
- Magic Link가 도착하지 않거나 다른 도메인으로 리디렉션됨
- 조직·사업장 간 데이터가 교차 노출됨
- staff가 승인 또는 확정을 수행할 수 있음
- 최고관리자 승인 없이 가입만으로 사업장이 생기거나 연결됨 (자동 온보딩 경로 재발)
- 최고관리자가 아닌 계정이 `/admin.html`의 가입 신청 목록·전체 사업장 목록을 볼 수 있음
- 공동인증서·비밀번호·민감번호 원문이 브라우저나 Supabase에 저장됨
- 실제 기관 제출 경로가 활성화됨

## 차단 해제 조건

실제 고객정보는 Issue #2의 P0를 모두 완료한 뒤 별도 승인한다. 실제 기관 신고는 PR #4 보안 리뷰, trusted Windows worker, KMS/HSM, 승인 기관 채널, 샌드박스 접수번호·payload hash E2E, 실패 재처리와 비상 중지 검증을 모두 완료한 뒤 production feature flag를 별도 승인한다.

GitHub Pages 자동배포는 중단하며 Vercel만 공식 배포 경로로 사용한다.

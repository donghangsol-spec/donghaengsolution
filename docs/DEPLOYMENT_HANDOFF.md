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
4. Supabase Edge Function secret `ALLOWED_ORIGINS`에 허용할 출처를 쉼표로 등록하고 `onboard-owner`를 재배포한다.
5. Supabase Custom SMTP가 Resend의 검증된 `donghangsolution.co.kr` 발신주소를 사용하는지 확인한다.
6. 실제 비밀값, service-role key, 공동인증서 또는 비밀번호를 GitHub와 브라우저 코드에 넣지 않는다.

## 배포 및 확인

1. PR Preview가 Ready인지 확인한다.
2. owner와 staff Magic Link 로그인을 각각 시험한다.
3. owner 온보딩, 사업장·직원 생성, 급여 초안·검증·확정, 4대보험 요청·검증·승인을 시험한다.
4. staff의 급여 확정과 보험 승인이 차단되는지 확인한다.
5. 승인된 보험 요청과 확정 급여의 수정이 차단되는지 확인한다.
6. 테스트 데이터가 실제 고객정보가 아님을 확인한 뒤 PR을 병합한다.
7. `main` Production 배포에서 같은 시험을 반복하고 커밋 SHA, URL, 시험자, 결과를 기록한다.

## 즉시 중지 조건

- `/api/config.js`가 503이거나 공개 설정이 비어 있음
- Magic Link가 도착하지 않거나 다른 도메인으로 리디렉션됨
- 조직·사업장 간 데이터가 교차 노출됨
- staff가 승인 또는 확정을 수행할 수 있음
- 공동인증서·비밀번호·민감번호 원문이 브라우저나 Supabase에 저장됨
- 실제 기관 제출 경로가 활성화됨

## 차단 해제 조건

실제 고객정보는 Issue #2의 P0를 모두 완료한 뒤 별도 승인한다. 실제 기관 신고는 PR #4 보안 리뷰, trusted Windows worker, KMS/HSM, 승인 기관 채널, 샌드박스 접수번호·payload hash E2E, 실패 재처리와 비상 중지 검증을 모두 완료한 뒤 production feature flag를 별도 승인한다.

GitHub Pages 자동배포는 중단하며 Vercel만 공식 배포 경로로 사용한다.

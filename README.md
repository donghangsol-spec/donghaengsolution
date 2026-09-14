# 동행솔루션 세무 AX

장기요양기관을 중심으로 회계 검토, 급여대장, 4대보험 취득·상실 업무를 한 흐름에서 처리하는 웹앱입니다.

> 현재 단계: Public Alpha / 내부 검증용  
> 실제 홈택스·지방소득세·4대보험 기관 전송은 아직 활성화하지 않았습니다.

## 현재 구현

### 인증과 데이터

- Supabase Auth 이메일 Magic Link 로그인
- 조직과 사업장 기반 데이터 분리
- owner/admin/reviewer/staff 역할 기반 권한 검사
- Supabase PostgreSQL 및 RLS 기반 데이터 저장
- 서버 측 온보딩 함수와 감사로그
- Resend Custom SMTP를 통한 로그인 메일 발송

### 회계

- 사업장 설정
- 거래 CSV 업로드
- 적요와 입출금 방향 기반 분류 추천
- 검토필요 / AI초안 / 보완요청 / 승인완료 상태 관리
- 미분류 거래 승인 차단 및 담당자 분류 수정
- 감사로그 조회와 JSON 내보내기

### 급여

- 월급제·시간제 직원과 급여 설정
- 급여대장 초안 생성
- XLS/XLSX/CSV/JSON 자료 가져오기와 행별 오류 추적
- 급여 검증, 담당자 확정, 확정 후 수정 잠금
- 급여 기본급과 4대보험 신고 보수월액 분리
- 버전이 지정된 2026년 사회보험 요율 기반 예상 공제액 계산

### 4대보험

- 직원별 취득·상실·변경 요청
- 보험별 상세 신고행과 확인필요 항목
- 검증 → 승인대기 → 담당자 승인 → 제출대기 상태 흐름
- 동일 직원·동일 적용일 중복 요청 방지
- owner 승인 허용 및 staff 승인 차단
- 접수번호와 처리결과 기록 구조

## 검증 현황

2026-09-13 Vercel Preview에서 다음 인증 기반 E2E를 통과했습니다.

- owner와 staff Magic Link 로그인
- 동일 조직·사업장에 대한 역할 확인
- 사업장과 월급제 직원 생성
- 4대보험 취득 요청, 상세 확인, 검증 및 owner 승인
- 급여 초안, 검증 및 owner 확정
- staff의 보험 승인·급여 확정 차단
- 확정된 급여의 수정 잠금

관련 구현은 [PR #3](https://github.com/donghangsol-spec/donghaengsolution/pull/3)에서 `main`에 병합됐습니다.

## 공동인증서 신고 자동화

사용자 편의를 위해 브라우저 매크로 방식은 보조 실행 방식으로 유지합니다. 다만 사용자 브라우저나 Supabase에 공동인증서 원본, 개인키 또는 비밀번호를 저장하지 않습니다.

[PR #4](https://github.com/donghangsol-spec/donghaengsolution/pull/4)는 다음 안전장치의 기반을 구현 중입니다.

- 승인된 요청만 신고 작업 큐에 등록
- 중복 제출 방지용 idempotency
- 격리된 trusted worker에서만 매크로 실행
- 메모리에서만 인증정보 복호화 후 즉시 파기
- 제출 직전 사람의 최종 확인
- 확인한 미리보기와 접수 결과의 payload hash 일치 검증
- CAPTCHA, MFA, 인증서 선택 또는 예외 화면에서 사람에게 제어권 반환

현재 실제 매크로 어댑터, trusted Windows worker, KMS/HSM, 승인된 기관 연계 채널 및 샌드박스 접수증 검증은 완료되지 않았습니다. 따라서 실제 기관 신고는 계속 비활성 상태입니다.

## 운영 전 남은 핵심 업무

- 거래 CSV의 RFC4180 파싱, 필수 필드 검증 및 중복 업로드 방지
- 관·항·목 마스터 검증과 승인 취소 정책
- 증빙 파일용 private Storage bucket, MIME/크기 제한 및 Storage RLS
- 다중 사업장 UI와 두 조직 간 교차접근 회귀 테스트
- 건강·고용·산재보험 적용제외 규칙의 공식 검증
- 원천세 간이세액표와 산재보험 사업종류별 요율 데이터
- 개인정보 보유·삭제, 백업·복구 및 장애 대응 정책
- trusted worker 기반 신고의 샌드박스 E2E

세부 잔여 항목은 [Issue #2](https://github.com/donghangsol-spec/donghaengsolution/issues/2)에서 관리합니다.

## 배포

- 코드 저장소: GitHub
- 웹앱 배포와 PR Preview: Vercel
- 데이터베이스와 인증: Supabase
- 인증 이메일: Resend
- 대표 발송 도메인: `donghangsolution.co.kr`
- 운영자 배포 절차: [배포 인계서](docs/DEPLOYMENT_HANDOFF.md)

`main` 병합과 운영 출시 판단은 분리합니다. 기반 코드를 병합하더라도 실제 신고 기능은 관련 보안·기관 연계 게이트가 모두 통과할 때까지 활성화하지 않습니다.

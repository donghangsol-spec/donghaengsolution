# 공동인증서 기반 4대보험 신고 작업자

## 구현 결과

앱은 승인된 4대보험 요청만 `insurance_filing_jobs`에 등록한다. 공동인증서(.p12/.pfx), 개인키 및 비밀번호는 Supabase Database/Storage, 브라우저 localStorage, 로그에 저장하지 않는다.

## 흐름

1. owner/admin/reviewer가 보험별 검증을 끝내고 요청을 승인한다.
2. `queue_certificate_filing(request_id, provider)` RPC가 중복을 차단하고 제출대기 작업을 만든다.
3. 격리된 trusted worker가 작업을 claim한다.
4. 브라우저는 인증서와 비밀번호를 worker의 회전 공개키로 암호화해 일회성 세션으로 전달한다.
5. worker는 메모리에서만 복호화하고 인증서 소유자·만료일·업무대행 위임을 검증한다.
6. 제출 직전 마스킹된 신고 미리보기를 표시하고 사람의 최종 확인을 받는다.
7. 승인된 공식 API/EDI 또는 이용약관상 허용된 채널로 1회 제출한다.
8. 인증서 세션을 즉시 파기하고 DB에는 접수번호, 결과, 오류, 감사정보만 남긴다.

## 운영 필수조건

- 실제 운영 주체가 관리하는 별도 Windows/보안 worker
- KMS/HSM 또는 OS credential vault
- worker 전용 service-role 비밀(브라우저 및 Vercel 정적 페이지 노출 금지)
- 공단/EDI 이용 권한과 업무대행 위임 확인
- 제출 직전 human-in-the-loop 확인
- idempotency key 기반 중복 신고 차단
- 민감정보가 제거된 로그와 보존/파기 정책
- owner/staff 사업장 교차접근 및 승인 우회 E2E 테스트

## 배포 전 잠금

외부 신고 어댑터와 작업자 운영환경이 연결되기 전에는 실신고 버튼을 활성화하지 않는다. 성공적인 프리뷰 배포만으로 운영 가능 판정을 내리지 않는다.

## 금지사항

- 인증서나 비밀번호를 이메일·GitHub·Supabase 테이블·Storage에 업로드
- 비밀번호를 환경변수에 장기 보관
- staff가 승인 또는 최종 제출
- CAPTCHA/보안통제를 우회
- 재시도 시 신규 신고를 무조건 생성

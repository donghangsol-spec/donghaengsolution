# 2026 4대보험 규칙·요율 기준

이 문서는 동행솔루션의 4대보험/급여 자동화가 어떤 공식 기준을 코드에 반영했는지 추적하기 위한 문서다.

## 현재 자동 판정 범위

### 국민연금
2026년 국민연금공단 안내를 근거로 단시간·일용근로자의 사업장가입 여부를 판정할 때 다음 값을 보조기준으로 사용한다.

- 주 15시간(월 60시간)
- 월 8일
- 월 소득 2,200,000원
- 실제 판정에는 계속근로기간·예외대상 등 추가 조건이 있으므로, 시스템이 확보하지 못한 정보가 있으면 `확인필요`로 남긴다.

공식 출처:
- https://www.nps.or.kr/pnsinfo/ntpsklg/getOHAF0097M0.do
- https://www.nps.or.kr/fileDown.do?atchFileId=FL26000086&atchFileSn=1

건강보험·고용보험·산재보험은 현재 상세 예외규칙을 완전 자동판정하지 않는다. 잘못된 자동 제외를 막기 위해 `확인필요` 상태를 사용하고, 공식 규칙을 추가 검증한 뒤 rule version으로 등록한다.

## 2026 보험료율 버전

- 국민연금: 전체 9.5%, 근로자 4.75%, 사용자 4.75%
- 건강보험: 전체 7.19%, 근로자 3.595%, 사용자 3.595%
- 장기요양보험: 0.9448%; 건강보험료 × (0.9448 / 7.19) 방식
- 고용보험 실업급여: 근로자 0.9%, 사용자 기본 0.9%; 사용자의 고용안정·직업능력개발 부담은 사업장 규모 등에 따라 별도
- 산재보험: 근로자 부담 0, 사용자 업종별 요율. 2026 평균 산재보험료율은 1.47%이나 개별 사업장 계산에는 평균값을 사용하지 않는다.

공식 출처:
- 국민연금: https://www.nps.or.kr/eng/ntnlpnsplan/cntb/getOHAI0013M0.do
- 건강보험/장기요양: https://edi.nhis.or.kr/portal/images/popup/20251204_pop01longdesc.html
- 고용보험 안내 요약: https://www.nps.or.kr/pnsinfo/ntpsklg/getOHAF0097M0.do
- 산재보험 2026 평균요율: https://www.moel.go.kr/news/enews/report/enewsView.do?news_seq=18810

## 계산 안전장치

`statutory_rate_versions`는 적용일별 요율을 저장한다. 급여 계산에서 현재 `estimate_payroll_statutory_deductions`는 실제 급여항목을 자동 덮어쓰지 않고 예상액만 반환한다.

국민연금은 연결된 기준소득월액이 없으면 계산하지 않고 경고한다. 2026년 7월 이후 기준소득월액 상·하한은 410,000원 ~ 6,590,000원을 사용한다.

건강보험·고용보험도 보험별 상세 신고행에 보수월액이 연결돼 있을 때만 예상액을 계산한다. 산재보험은 업종별 요율이 필요하므로 근로자 공제액만 0으로 표시하고 사용자 부담액은 자동계산하지 않는다.

## 개인정보 보안

주민등록번호/외국인등록번호 원문은 `employees` 또는 4대보험 업무 테이블에 저장하지 않는다.

- 원문: Supabase Vault
- DB 업무영역: Vault secret UUID + 마스킹값만 `private.employee_identity_secrets`에 저장
- 브라우저 `authenticated` 역할: 원문 저장/읽기 권한 없음
- 저장 함수 `private.store_employee_identity_secret`: `service_role`만 실행 가능

실제 입력 UI는 service-role을 브라우저에 노출하지 않고 trusted Edge Function/worker를 통해 연결해야 한다.

## 다음 규칙 확장

1. 건강보험 직장가입 적용/제외 규칙
2. 고용보험 피보험자격 적용/제외 규칙
3. 산재보험 사업종류별 요율·특수형태 구분
4. 외국인 국적/체류자격별 적용 규칙
5. 보험별 취득일/상실일/보수월액의 개별 수정 UI
6. 원천세 간이세액표 버전 관리 및 계산 엔진

모든 법정 기준은 `effective_from`, `effective_to`, `source_url`, `verified_at`을 가진 버전 데이터로 관리한다.
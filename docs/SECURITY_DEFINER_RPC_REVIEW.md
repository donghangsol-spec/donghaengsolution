# SECURITY DEFINER RPC 권한 재감사

## 상시 3대 기준
1. 조직 격리: 대상 row의 organization_id를 확인하고 타 조직 접근은 실패해야 한다.
2. 상태/승인 안전: 승인·확정 상태 전이는 허용 역할과 검증 함수를 반드시 통과해야 한다.
3. 최소 권한: SECURITY DEFINER는 RLS로 동일 동작을 보장할 수 있을 때만 SECURITY INVOKER로 전환한다.

## 2026-09-25 점검
- acknowledge_insurance_detail: 내부 owner/admin/reviewer 검사. detail UPDATE RLS는 staff도 허용하므로 단순 INVOKER 전환만으로 역할 제한이 강화되지는 않는다. 함수 내부 역할 검사는 유지 필수.
- approve_insurance_request: owner/admin/reviewer + validate_insurance_request 재검증 + 확인필요 검토확인. INVOKER 전환 후보이나 호출되는 validate 함수와 함께 회귀시험 필요.
- confirm_payroll_period: owner/admin/reviewer + validate_payroll_period 재검증. 상태전이 트리거/set_config 의존성이 있어 단독 전환 금지.
- generate_payroll_draft: staff까지 허용. payroll_periods UPDATE RLS는 staff를 허용하지 않으므로 기존 기간 재생성 경로에서 INVOKER 전환 시 동작 차이가 생길 수 있음.
- revise_insurance_request: staff까지 함수 호출 가능하지만 insurance_requests UPDATE RLS는 reviewer 이상만 허용. INVOKER 전환 시 staff 업무가 깨질 수 있음.
- validate_insurance_request: 조직 member 검사 후 requests/details UPDATE. RLS UPDATE 권한과 함수 허용 범위가 다르므로 단독 전환 금지.
- validate_payroll_period: staff 허용이나 payroll_periods UPDATE RLS는 reviewer 이상. 단독 전환 금지.

## 전환 승인 기준
- 합성 owner/reviewer/staff 세션에서 현재 허용/거부 행렬을 먼저 고정한다.
- 타 조직 UUID로 SELECT/UPDATE/RPC가 모두 실패해야 한다.
- 승인/확정/잠금/감사 이벤트 결과가 변경 전후 동일해야 한다.
- 위 세 조건을 통과하지 못하면 DEFINER를 유지하되 함수 내부 역할검사와 search_path, EXECUTE grant를 최소화한다.

현재 결론: 7개를 일괄 INVOKER로 변경하지 않는다. 기능별 RLS 차이를 먼저 해소하고 회귀시험 후 개별 전환한다.

# Supabase Free 백업·복원 검증 절차

상태: **실행 전 절차 / 백업·복원 미실시** (2026-09-28 KST). 실제 고객 정보 반입 게이트를 열지 않는다. 비용이 발생하는 관리형 백업/PITR을 전제로 하지 않는다. 이 문서는 명령을 복사해 운영 DB에 즉시 실행하라는 뜻이 아니다. 암호화 보관 위치, 접속 권한, 격리 복원 환경과 담당자가 먼저 정해져야 한다.

## 왜 `db dump` 하나로 완료가 아닌가

- Supabase Free에는 Pro/Team/Enterprise의 관리형 일일 백업이 제공되지 않는다. 공식 권고는 CLI 내보내기와 별도 위치 보관이다.
- 현재 CLI 기준 기본 `supabase db dump`는 **스키마만** 내보내고 데이터는 내보내지 않는다. `--data-only`로 별도 데이터 덤프가 필요하다. 기본 덤프에서는 Supabase 관리형 `auth`, `storage` 등 스키마가 제외될 수 있다. `--schema`를 지정한 내보내기가 실제 필요한 행·참조·설정을 보존하는지는 격리 복원으로 입증해야 한다.
- DB 백업에는 Storage **객체 내용**이 없다. `storage.objects` 메타데이터를 확보하더라도 private 버킷의 파일은 Storage API/S3 경로로 별도 내려받아야 한다. 메타데이터만 복원하면 파일이 사라진 상태가 된다.
- Edge Function 배포·환경 변수·Auth/SMTP 설정·키·외부 상담 메일은 DB 덤프와 별개다. 비밀값은 덤프 파일이나 Git에 적지 않고 비밀 관리 체계에서 재설정한다.

## 구성요소별 증적과 판정

| 범위 | 준비할 증적 | 실패 조건 |
| --- | --- | --- |
| 앱 스키마·정책 | Git migration 버전, 스키마 덤프, 복원 후 함수/RLS·트리거 점검 | 코드와 운영 DB 구조가 다르거나 복원 시 누락 |
| 앱 데이터 (`public`, `private`) | 테이블별 행 수·참조 검증과 암호화된 데이터 덤프 | 직원 식별정보/급여/감사 행 또는 FK 누락 |
| Auth 사용자 | `auth.users`와 관련 Auth 레코드의 복원 전후 수, 테스트 계정 재로그인 | 사용자 누락·잘못된 권한 연결; 토큰 재발급/로그인 실패 |
| Storage 메타데이터·객체 | 두 private 버킷별 객체 경로·크기·해시 목록과 암호화된 실제 파일, 복원 후 다운로드 테스트 | DB 메타데이터와 실제 파일 불일치·공개 접근 |
| 설정·배포 | Edge Function 버전, Auth redirect/SMTP, Vercel 환경 변수의 **키 이름만** 담은 목록과 재설정 담당자 | 비밀 누출 또는 복원 환경 설정 누락 |
| 삭제 요청 | 백업 시점 이후 파기 목록을 개인정보 원문 없이 안전하게 보관·재적용한 증적 | 복원으로 파기 대상이 되살아남 |

이 표의 각 행이 모두 확인되기 전에는 “복구 가능”이라고 표시하지 않는다. Storage 버킷은 `transaction-evidence-private`, `email-intake-private`를 포함해 **실제 운영 버킷 전체 목록**과 대조한다. 향후 버킷이 추가되면 목록도 갱신한다.

## 실행 순서

1. 담당자가 Supabase CLI와 Postgres 도구 버전, 연결 대상 프로젝트를 확인한다. CLI의 `supabase db dump --help`, `supabase storage ls --help`, `supabase storage cp --help`로 현 버전 플래그를 다시 확인한다. 저장소에는 DB 암호·접속 문자열·service-role 키를 넣지 않는다.
2. 별도 암호화 작업 공간과 외부 보관소를 준비한다. 접근은 최소 권한으로 제한하고, 보관 기간·삭제·실패 알림을 정한다. 명령행 인자와 CI 로그에 비밀번호/토큰이 남지 않는 방식을 택한다. **이 환경에는 CLI/`pg_dump` 및 백업용 DB 자격증명·외부 보관소가 없어 아직 실행하지 않았다.**
3. 쓰기/업로드를 일시 정지해 DB와 Storage 목록의 시점 차이를 줄이고, 시작/끝 시각을 기록한다. 운영 업무 영향이 없는 시간대를 택한다. 실패하면 쓰기 재개 판단을 별도 기록한다.
4. 스키마와 데이터를 **별도 파일**로 내보낸다. 공식 예시는 `supabase db dump --linked -f schema.sql` 및 `supabase db dump --linked --data-only --use-copy -f data.sql`이다. 출력 파일은 암호화 작업 공간 안에만 두고 즉시 암호화한다. `auth`, `storage`, `private`의 실제 포함 범위를 각 테이블의 합계와 격리 복원 결과로 확인한다. 기본 출력이 전체 DB라고 추정하지 않는다.
5. Supabase Storage의 실제 private 객체를 권한 있는 API/CLI 또는 S3 호환 도구로 별도 내보낸다. 객체 수·경로·크기·해시를 기록하고 DB 메타데이터와 비교한다. CLI Storage 명령은 현재 문서에서 experimental이므로 실제 사용 버전의 `--help`를 확인한다.
6. 암호화된 백업과 개인정보 없는 증적만 외부 보관소에 옮기고 접근·만료를 확인한다. 평문 임시 파일 제거를 확인한다. 백업 파일의 이름·생성 시각·검증용 해시를 기록하되 개인 식별자, 객체 경로 원문, 비밀값은 공개 이슈에 게시하지 않는다.
7. **격리된 환경**에만 복원한다. Auth 사용자 재로그인, 두 조직 간 RLS 거부, 급여·감사 참조, Storage private 다운로드와 해시, 삭제 요청 재적용을 검증한다. 측정된 RPO/RTO와 실패·재시도를 기록한다. 운영 프로젝트에 복원 명령을 시험하지 않는다.

## 승인 조건과 현재 결론

- [ ] 운영 책임자가 빈도·보관기간·RPO·RTO, 암호화 키 소유자와 백업 담당자 지정
- [ ] 백업 실행·외부 보관·실패 알림 증적
- [ ] Auth/앱 데이터/Storage 객체/설정의 독립 복원 및 교차 조직 권한 검증
- [ ] 복원 후 과거 파기 요청 재적용과 승인 기록

**현재 판정: NO-GO.** 이 문서와 코드 저장소의 migration은 운영 데이터 백업도, 복구 실습도 아니다. 실제 고객 데이터 반입과 기관 신고는 기존 차단을 유지한다.

참고: [Supabase Database Backups](https://supabase.com/docs/guides/platform/backups), [CLI `db dump` reference](https://supabase.com/docs/reference/cli/supabase-db-dump), [Storage 다운로드](https://supabase.com/docs/guides/storage/management/download-objects), [CLI 백업·복원 가이드](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore).

# 동행솔루션 홈페이지 개편

## 구현 범위

- `/`: iD 원본 로고, 네이비·화이트·오렌지, 6개 서비스 전체 카드 링크
- `/services/accounting`, `/services/consulting`, `/services/automation`
- `/services/education`, `/services/cognitive`, `/services/community`
- `/support`: 비회원 상담, 로그인 업무요청·진행현황, 이용 안내
- `/contact`: 분야 자동 선택, 필수값·동의 확인, 기존 `/api/contact` 연결
- `/app?view=insurance`: 기존 인증 게이트와 업무요청 화면 연결. 이메일 로그인 리디렉션에도 화면 선택 유지
- 기존 API, Supabase SQL/RLS, index.html, payroll.html, Vercel 라우팅 유지

## 환경 확인

- 기준 소스: main `cf44ac2`
- 사용자 확인 Supabase 프로젝트: `donghangsolution` (`xvisvipdbdemfgutzouh`), 조회 시 ACTIVE_HEALTHY
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`: Vercel Preview/Production 필요
- `RESEND_API_KEY`, `CONTACT_TO_EMAIL`, `CONTACT_FROM_EMAIL`: 기존 상담 API에서 사용
- `ALLOWED_ORIGINS`: Supabase 온보딩 함수 설정 유지
- 실제 비밀값은 소스와 인계 문서에 포함하지 않음

## 검증

- 공개 페이지 9개, 내부 링크/자산 166개 파일 존재 확인
- 공개 JS 및 기존 업무화면 인라인 JS 문법 확인
- 데스크톱/390px 휴대폰 화면 시각 확인
- 서비스 카드 → 상세페이지 → 분야가 선택된 상담페이지 이동 확인
- 실제 로그인, 메일 수신과 업무 데이터 생성은 배포 환경에서 추가 검증 필요

## 출시 전 남은 항목

- Vercel 배포 환경값과 Supabase Auth 리디렉션 허용 URL 일치 확인
- 상담정보 보유기간 운영자 확정 후 동의 문구 반영
- 교육비·시간·과정, 프로그램 자료는 미확정: 소개와 상담 범위로 제공
- 복지커뮤니티 글쓰기·게시판은 준비 중으로 명시
- 기존 DEPLOYMENT_HANDOFF.md의 고객정보·실제 기관 신고 출시 제한은 유지

원본 로고는 사용자가 제공한 `KakaoTalk_20260922_100831409.jpg`를 변형 없이 사용합니다.

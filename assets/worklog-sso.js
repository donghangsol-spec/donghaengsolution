// 업무일지(복지사랑·요양사랑) 자동 로그인은 보안 검증 전까지 비활성화합니다.
// 세무 사이트의 access/refresh token을 외부 URL 또는 페이지로 전달하지 않습니다.
// 기존 HTML의 스크립트 경로는 유지하며, 링크의 기본 이동·별도 로그인은 그대로 둡니다.
// 재활성화 조건: 수신 대상·짧은 유효기간·1회 사용이 강제되는 서버 교환 코드와
// 미승인/타 기관/만료/재사용 거절 및 owner/staff E2E 검증 완료.
(function () {
  'use strict';
  // Intentionally no session reads, click handlers, or cross-origin requests.
})();

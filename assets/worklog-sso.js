// =====================================================================
// 업무일지(복지사랑·요양사랑) 자동 로그인 연결
// 세무 사이트에 로그인한 상태에서 업무일지 링크를 누르면, 로그인 표(access token)를
// 업무일지의 sso.html로 함께 넘겨서 다시 로그인하지 않아도 되게 한다.
//  - 로그인 안 된 상태거나 표가 만료됐으면 평소처럼 그냥 업무일지 사이트로 이동한다.
//  - 표는 주소의 # 뒷부분으로만 넘긴다 (# 뒤는 서버로 전송되지 않음).
//  - 받는 쪽(업무일지 중계 서버)이 세무 서버에 진짜인지 직접 확인한다.
// =====================================================================
(function () {
  var WORKLOG = "https://sparkling-taffy-5c0f66.netlify.app";
  var STORAGE_KEY = "sb-xvisvipdbdemfgutzouh-auth-token"; // 세무 사이트 Supabase 로그인 저장 위치

  function currentToken() {
    try {
      var raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      var s = JSON.parse(raw);
      if (s && s.currentSession) s = s.currentSession;
      if (!s || !s.access_token) return null;
      if (s.expires_at && s.expires_at * 1000 < Date.now() + 60 * 1000) return null; // 1분 안에 만료되면 쓰지 않음
      return s.access_token;
    } catch (e) {
      return null;
    }
  }

  document.addEventListener("click", function (e) {
    var a = e.target && e.target.closest ? e.target.closest('a[href^="' + WORKLOG + '"]') : null;
    if (!a) return;
    var token = currentToken();
    if (!token) return; // 로그인 안 됨 → 기본 동작(업무일지 로그인 화면)
    e.preventDefault();
    var url = WORKLOG + "/sso.html#sso=" + encodeURIComponent(token);
    if (a.target === "_blank") window.open(url, "_blank", "noopener");
    else window.location.href = url;
  }, true);
})();

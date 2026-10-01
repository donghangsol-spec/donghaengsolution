import assert from 'node:assert/strict';
import handler, { buildCommentEmail } from '../api/community-notify.js';

const env = { ...process.env };
const originalFetch = globalThis.fetch;
const COMMENT = '0a1b2c3d-0000-4000-8000-000000000001';
function response() {
  return {
    statusCode: 200, body: null, headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; },
  };
}
async function call({ method = 'POST', token = 'user-jwt', body = { comment_id: COMMENT } } = {}) {
  const res = response();
  await handler({ method, body, headers: token ? { authorization: `Bearer ${token}` } : {} }, res);
  return res;
}
function mockFetch({ claim = { post_id: 'p1', post_title: '첫 공지', author_label: '테스트 복지관', body: '반갑습니다', is_reply: false }, claimStatus = 200, mailOk = true } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    if (url.includes('/rpc/community_claim_comment_notification')) {
      return { ok: claimStatus === 200, status: claimStatus, json: async () => claim };
    }
    if (url.includes('/rpc/community_release_comment_notification')) return { ok: true, status: 204 };
    if (url === 'https://api.resend.com/emails') return { ok: mailOk, status: mailOk ? 200 : 500 };
    throw new Error('unexpected fetch ' + url);
  };
  return calls;
}

try {
  process.env.SUPABASE_URL = 'https://db.example.supabase.co/';
  process.env.SUPABASE_ANON_KEY = 'anon-key';
  process.env.RESEND_API_KEY = 'resend-key';
  process.env.COMMUNITY_NOTIFY_TO = 'a@example.invalid, b@example.invalid';

  assert.equal((await call({ method: 'GET' })).statusCode, 405);
  assert.equal((await call({ token: '' })).statusCode, 401);
  assert.equal((await call({ body: { comment_id: 'nope' } })).statusCode, 400);

  // 알림 권리를 받으면 메일 1통, 작성자 토큰으로 claim
  let calls = mockFetch();
  let res = await call();
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { ok: true, sent: true });
  assert.equal(calls[0].url, 'https://db.example.supabase.co/rest/v1/rpc/community_claim_comment_notification');
  assert.equal(calls[0].init.headers.Authorization, 'Bearer user-jwt');
  assert.equal(calls[0].init.headers.apikey, 'anon-key');
  const mail = JSON.parse(calls[1].init.body);
  assert.deepEqual(mail.to, ['a@example.invalid', 'b@example.invalid']);
  assert.equal(mail.subject, '[복지커뮤니티 댓글] 첫 공지');
  assert.match(mail.text, /테스트 복지관님이 새 댓글을/);
  assert.match(mail.text, /community\/post\?id=p1/);

  // 이미 보냈거나 남의 댓글이면 claim이 null → 메일 없음
  calls = mockFetch({ claim: null });
  res = await call();
  assert.deepEqual(res.body, { ok: true, sent: false });
  assert.equal(calls.length, 1);

  // 메일 실패 → 다시 보낼 수 있게 release
  calls = mockFetch({ mailOk: false });
  res = await call();
  assert.equal(res.statusCode, 502);
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/community_release_comment_notification')));

  // 토큰 만료 등 claim 실패
  calls = mockFetch({ claimStatus: 401 });
  assert.equal((await call()).statusCode, 401);
  assert.equal(calls.length, 1);

  // 받는 주소 없으면 아무것도 부르지 않음 (CONTACT_TO_EMAIL로 대체 가능)
  delete process.env.COMMUNITY_NOTIFY_TO;
  delete process.env.CONTACT_TO_EMAIL;
  calls = mockFetch();
  assert.equal((await call()).statusCode, 503);
  assert.equal(calls.length, 0);
  process.env.CONTACT_TO_EMAIL = 'c@example.invalid';
  calls = mockFetch();
  await call();
  assert.deepEqual(JSON.parse(calls[1].init.body).to, ['c@example.invalid']);

  // 제목 줄바꿈 제거, 답글 표기
  const reply = buildCommentEmail({ post_id: 'x', post_title: '줄\n바꿈', author_label: '', body: 'b', is_reply: true });
  assert.equal(reply.subject, '[복지커뮤니티 답글] 줄 바꿈');
  assert.match(reply.text, /^회원님이 새 답글을/);

  console.log('community notify tests passed');
} finally {
  globalThis.fetch = originalFetch;
  for (const key of Object.keys(process.env)) if (!(key in env)) delete process.env[key];
  Object.assign(process.env, env);
}

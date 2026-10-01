import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Script, createContext } from 'node:vm';

const context = createContext({ console });
new Script(readFileSync(new URL('../assets/community.js', import.meta.url), 'utf8')).runInContext(context);
const c = context.DHCommunity;
assert.ok(c, 'DHCommunity helpers are exposed without a DOM');

// 분류별 양식
assert.equal(c.templateFor('notice'), 'notice');
assert.equal(c.templateFor('library'), 'resource');
assert.equal(c.templateFor('qna'), 'free');
assert.deepEqual([...c.allowedCategories({ is_admin: true })], ['notice', 'library', 'info', 'story', 'qna']);
assert.deepEqual([...c.allowedCategories({ is_member: true })], ['info', 'story', 'qna']);
assert.deepEqual([...c.allowedCategories({ signed_in: true })], []);

// 날짜 표시
assert.equal(c.formatDate('2026-09-30'), '2026.09.30');
const now = '2026-10-01T12:00:00Z';
assert.equal(c.formatRelative('2026-10-01T11:59:30Z', now), '방금 전');
assert.equal(c.formatRelative('2026-10-01T11:15:00Z', now), '45분 전');
assert.equal(c.formatRelative('2026-10-01T09:00:00Z', now), '3시간 전');
assert.equal(c.isNew('2026-09-30T00:00:00Z', now), true);
assert.equal(c.isNew('2026-09-20T00:00:00Z', now), false);
assert.equal(c.formatSize(2048), '2KB');
assert.equal(c.fileExtension('회계점검.HWP'), 'hwp');
assert.equal(c.fileExtension('noext'), '');

// 검색어 이스케이프, 돌아갈 경로 제한
assert.equal(c.likePattern(' 100%_달성 '), '%100\\%\\_달성%');
assert.equal(c.likePattern('   '), '');
assert.equal(c.safeReturnPath('/community/post?id=0a1b-2c'), '/community/post?id=0a1b-2c');
assert.equal(c.safeReturnPath('//evil.example/community'), '/community');
assert.equal(c.safeReturnPath('https://evil.example'), '/community');
assert.equal(c.safeReturnPath('/community/post?id=<script>'), '/community');

// 댓글 트리: 답글은 부모 아래로, 답글 없는 삭제 댓글은 숨김
const tree = c.buildCommentTree([
  { id: 'a', parent_id: null, status: 'published' },
  { id: 'b', parent_id: 'a', status: 'published' },
  { id: 'c', parent_id: null, status: 'deleted' },
  { id: 'd', parent_id: null, status: 'deleted' },
  { id: 'e', parent_id: 'd', status: 'published' },
  { id: 'f', parent_id: 'a', status: 'deleted' },
]);
assert.deepEqual([...tree.map((n) => n.id)], ['a', 'd']);
assert.deepEqual([...tree[0].replies.map((r) => r.id)], ['b']);

// 글쓰기 값 정리와 검사
const resource = c.buildPostPayload({
  category: 'library', title: '  회계 체크리스트 ', summary: ' 요약 ', body: '본문  \n',
  audiences: ['전체', ' '], key_points: ['하나', '', ' 둘 '], event_period: '무시', allow_comments: true,
});
assert.equal(resource.title, '회계 체크리스트');
assert.equal(resource.summary, '요약');
assert.equal(resource.body, '본문');
assert.deepEqual([...resource.key_points], ['하나', '둘']);
assert.deepEqual([...resource.audiences], ['전체']);
assert.equal(resource.event_period, undefined);
assert.equal(c.validatePostPayload(resource), null);
assert.match(c.validatePostPayload(c.buildPostPayload({ category: 'library', title: '자료' })), /요약/);
assert.match(c.validatePostPayload(c.buildPostPayload({ category: 'qna', title: '질문' })), /본문/);
assert.match(c.validatePostPayload(c.buildPostPayload({ category: 'qna', title: 'x', body: 'y' })), /제목/);
assert.match(c.validatePostPayload(c.buildPostPayload({ category: 'bogus', title: '제목', body: 'y' })), /분류/);
const notice = c.buildPostPayload({ category: 'notice', title: '공지', body: '내용', contact: ' 042 ', summary: '무시' });
assert.equal(notice.contact, '042');
assert.equal(notice.summary, undefined);

// 서버 오류 메시지: 한글 메시지는 그대로, 나머지는 안내 문구
assert.equal(c.friendlyError({ message: '댓글은 1~500자로 입력해 주세요.' }), '댓글은 1~500자로 입력해 주세요.');
assert.match(c.friendlyError({ message: 'JWT expired' }), /로그인/);
assert.match(c.friendlyError({ message: 'boom' }), /잠시 후/);

// 페이지가 스크립트를 순서대로 불러오는지
for (const page of ['index', 'post', 'write']) {
  const html = readFileSync(new URL(`../community/${page}.html`, import.meta.url), 'utf8');
  const order = ['/api/config.js', 'supabase.min.js', '/assets/community.js'].map((s) => html.indexOf(s));
  assert.ok(order.every((i) => i > 0) && order[0] < order[1] && order[1] < order[2], `${page}.html script order`);
  assert.ok(!/innerHTML/.test(html), `${page}.html has no innerHTML`);
}
assert.ok(!/innerHTML/.test(readFileSync(new URL('../assets/community.js', import.meta.url), 'utf8')), 'community.js avoids innerHTML');

console.log('community board tests passed');

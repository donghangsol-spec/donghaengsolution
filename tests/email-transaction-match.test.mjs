import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const html = readFileSync(new URL('../accounting.html', import.meta.url), 'utf8');

function functionSource(name, nextName) {
  const start = html.indexOf(`function ${name}(`);
  const end = html.indexOf(`function ${nextName}(`, start);
  assert.notEqual(start, -1, `${name} is missing`);
  assert.notEqual(end, -1, `${nextName} is missing`);
  return html.slice(start, end);
}

function matcher(transactions) {
  const context = vm.createContext({ tx: transactions });
  vm.runInContext(
    functionSource('emailMatchSignals', 'emailTransactionMatches') +
      functionSource('emailTransactionMatches', 'renderEmailMatches'),
    context,
  );
  return (message, draft) =>
    vm.runInContext('emailTransactionMatches', context)(message, draft);
}

test('email transaction matching combines amount, date, and description signals', () => {
  const match = matcher([
    { date: '2026-09-22', desc: '네이버 광고비 결제', inc: 0, out: 123400 },
    { date: '2026-08-01', desc: '무관 거래', inc: 0, out: 123400 },
  ]);
  const result = match(
    { subject: '네이버 광고비 123,400원', sender: 'billing@example.com', received_at: '2026-09-23T00:00:00Z' },
    { text_preview: '결제가 완료되었습니다.', attachment_previews: [] },
  );

  assert.equal(result.blocked, false);
  assert.equal(result.rows[0].t.desc, '네이버 광고비 결제');
  assert.equal(result.rows[0].score, 92);
  assert.deepEqual([...result.rows[0].reasons], ['금액 일치', '거래일 근접', '적요 네이버·광고비']);
});

test('security mail is excluded before matching', () => {
  const match = matcher([{ date: '2026-09-22', desc: '인증번호', inc: 10000, out: 0 }]);
  const result = match(
    { subject: '로그인 보안코드 안내', sender: 'security@example.com', received_at: '2026-09-22T00:00:00Z' },
    { text_preview: '인증번호 10000', attachment_previews: [] },
  );

  assert.equal(result.blocked, true);
  assert.equal(result.rows.length, 0);
});

test('matching returns only the three strongest review candidates', () => {
  const match = matcher([
    { date: '2026-09-22', desc: '공급사 결제 A', inc: 0, out: 50000 },
    { date: '2026-09-22', desc: '공급사 결제 B', inc: 0, out: 50000 },
    { date: '2026-09-22', desc: '공급사 결제 C', inc: 0, out: 50000 },
    { date: '2026-09-22', desc: '공급사 결제 D', inc: 0, out: 50000 },
  ]);
  const result = match(
    { subject: '공급사 50,000원', sender: 'billing@example.com', received_at: '2026-09-22T00:00:00Z' },
    { text_preview: '', attachment_previews: [] },
  );

  assert.equal(result.rows.length, 3);
  assert.ok(result.rows.every(row => row.score >= 80));
});

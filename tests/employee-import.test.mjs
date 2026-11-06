import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const ctx = {};
runInNewContext(readFileSync(new URL('../assets/employee-import.js', import.meta.url), 'utf8'), ctx);
const raw = ctx.DHEmployeeImport;
const plain = v => JSON.parse(JSON.stringify(v));
const I = { ...raw, parseSheet: (...a) => plain(raw.parseSheet(...a)), toInsertRows: (...a) => plain(raw.toInsertRows(...a)) };
const today = '2026-11-06';
const H = raw.TEMPLATE_HEADER;
const row = o => H.map(h => o[h.replace('(필수)', '')] ?? '');
const parse = (rows, opts = {}) => I.parseSheet([[...H], ...rows.map(row)], { today, ...opts });

// 날짜: 엑셀 날짜칸(일련번호)과 사람이 적은 표기
assert.equal(I.parseDate(46024, { today }), '2026-01-02');
assert.equal(I.parseDate(44562, { today, date1904: true }), '2026-01-02');
assert.equal(I.parseDate('2026.1.2', { today }), '2026-01-02');
assert.equal(I.parseDate('2026. 01. 02.', { today }), '2026-01-02');
assert.equal(I.parseDate('2026/01/02', { today }), '2026-01-02');
assert.equal(I.parseDate('2026년 1월 2일', { today }), '2026-01-02');
assert.equal(I.parseDate('20260102', { today }), '2026-01-02');
assert.equal(I.parseDate(20260102, { today }), '2026-01-02');
assert.equal(I.parseDate('900101', { today, past: true }), '1990-01-01');
assert.equal(I.parseDate('050101', { today, past: true }), '2005-01-01');
assert.equal(I.parseDate('2026-02-30', { today }), null);
assert.equal(I.parseDate('모름', { today }), null);
assert.equal(I.parseDate('', { today }), '');

// 숫자
assert.equal(I.parseNumber('3,000,000원'), 3000000);
assert.equal(I.parseNumber('40시간'), 40);
assert.equal(I.parseNumber(''), '');
assert.equal(I.parseNumber('-5'), null);
assert.equal(I.parseNumber(-5), null);

// 주민등록번호 판별 (가상 번호)
assert.equal(I.isRrn('900101-1234567'), true);
assert.equal(I.isRrn('9001011234567'), true);
assert.equal(I.isRrn(9001011234567), true);
assert.equal(I.isRrn(101312345678), true, '앞자리 0이 사라진 숫자');
assert.equal(I.isRrn('E001'), false);
assert.equal(I.isRrn(1001), false);

// 양식 그대로: 정상 등록과 저장 값
{
  const r = parse([{ 직원명: '김가상', 직원번호: 'E001', 생년월일: '1980-05-05', 입사일: 46024, '월 보수': '2,500,000', '주 소정근로시간': 40 }]);
  assert.equal(r.ok, true);
  assert.deepEqual(r.summary, { total: 1, ready: 1, skipped: 0, failed: 0 });
  assert.deepEqual(I.toInsertRows(r.rows, 'c1'), [{
    name: '김가상', employee_no: 'E001', birth_date: '1980-05-05', hire_date: '2026-01-02', termination_date: null,
    monthly_remuneration: 2500000, weekly_hours: 40, employment_type: '정규직', status: '재직', payroll_type: '월급제',
    hourly_rate: null, company_id: 'c1'
  }]);
}

// 기본값 판단: 시급이 있으면 시간제, 날짜를 보고 상태 결정
{
  const r = parse([
    { 직원명: '시간제', 시급: 12000 },
    { 직원명: '퇴사자', 입사일: '2020-01-01', 퇴사일: '2026-01-01' },
    { 직원명: '퇴사예정', 입사일: '2020-01-01', 퇴사일: '2026-12-31' },
    { 직원명: '신입', 입사일: '2026-12-01' }
  ]);
  assert.equal(r.rows[0].data.payroll_type, '시간제');
  assert.deepEqual(r.rows.slice(1).map(x => x.data.status), ['퇴사', '퇴사예정', '입사예정']);
}

// 오류 행은 저장 대상에서 빠지고 정상 행은 남음
{
  const r = parse([
    { 직원명: '정상' },
    { 직원번호: 'E9' },
    { 직원명: '날짜오류', 입사일: '어제' },
    { 직원명: '역전', 입사일: '2026-02-01', 퇴사일: '2026-01-01' },
    { 직원명: '금액오류', '월 보수': '많음' },
    { 직원명: '형태오류', 고용형태: '인턴' },
    { 직원명: '상태오류', 상태: '휴직' },
    { 직원명: '합계' }
  ]);
  assert.deepEqual(r.summary, { total: 8, ready: 1, skipped: 0, failed: 7 });
  assert.equal(I.toInsertRows(r.rows, 'c').length, 1);
}

// 주민등록번호가 직원번호·생년월일 칸에 있으면 막고, 값은 어디에도 남기지 않음
{
  const r = parse([{ 직원명: '실수', 직원번호: '900101-1234567' }, { 직원명: '실수둘', 생년월일: '9001011234567' }]);
  assert.equal(r.summary.failed, 2);
  assert.equal(JSON.stringify(r).includes('1234567'), false);
  assert.equal(JSON.stringify(r).includes('실수'), false);
}

// 주민등록번호 열은 읽지 않음
{
  const r = I.parseSheet([['성명', '주민등록번호', '입사일자'], ['김가상', '900101-1234567', '2026-01-02']], { today });
  assert.equal(r.rrnColumn, true);
  assert.equal(r.summary.ready, 1);
  assert.equal(JSON.stringify(r).includes('1234567'), false);
}

// 다른 파일 형식: 제목 위 안내 줄, 다른 제목 이름, 모르는 열, 빈 줄
{
  const r = I.parseSheet([['㈜가상요양원 직원명부'], [], ['사번', '이름', '보수월액', '비고'], ['A1', '김가상', 2000000, '메모'], [], ['A2', '이가상', 2100000, '']], { today });
  assert.equal(r.ok, true);
  assert.equal(r.summary.ready, 2);
  assert.equal(r.rows[1].rowNo, 6);
  assert.deepEqual(r.ignored, ['비고']);
}

// 숫자로 저장된 앞자리 0 직원번호 복원
{
  const r = I.parseSheet([['직원명', '직원번호'], ['김가상', 1]], { today, texts: [[], ['김가상', '001']] });
  assert.equal(r.rows[0].data.employee_no, '001');
}

// 이미 등록된 직원과 파일 안 중복
{
  const existing = [
    { name: '김기존', employee_no: 'E1', birth_date: '1980-01-01' },
    { name: '이기존', employee_no: null, birth_date: '1981-01-01' },
    { name: '박번호없음', employee_no: null, birth_date: null }
  ];
  const r = parse([
    { 직원명: '김기존', 직원번호: 'E1' },
    { 직원명: '다른사람', 직원번호: 'E1' },
    { 직원명: '이기존', 생년월일: '1981-01-01' },
    { 직원명: '이기존', 생년월일: '1990-01-01' },
    { 직원명: '박번호없음' },
    { 직원명: '최신규', 직원번호: 'N1' },
    { 직원명: '정신규', 직원번호: 'N1' },
    { 직원명: '최신규', 직원번호: 'N1' },
    { 직원명: '한이름' },
    { 직원명: '한이름' }
  ], { existing });
  assert.deepEqual(r.rows.map(x => x.state), ['skip', 'error', 'skip', 'new', 'skip', 'new', 'error', 'error', 'new', 'error']);
  assert.match(r.rows[1].errors[0], /김기존/);
  assert.match(r.rows[3].warnings[0], /동명이인/);
  assert.match(r.rows[6].errors[0], /파일 안에서 중복/);
}

// 안내 시트가 직원 명단으로 읽히면 안 됨
assert.equal(I.parseSheet(raw.GUIDE, { today }).headerFound, false);
assert.equal(I.parseSheet([[...H]], { today }).headerFound, true);

// 파일 수준 오류
assert.equal(I.parseSheet([['가', '나'], [1, 2]], { today }).ok, false);
assert.equal(I.parseSheet([[...H]], { today }).ok, false);
assert.equal(I.parseSheet([['직원명'], ...Array.from({ length: raw.MAX_ROWS + 1 }, (_, i) => ['가' + i])], { today }).ok, false);

console.log('employee-import tests passed');

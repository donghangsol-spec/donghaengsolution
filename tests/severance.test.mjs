import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const ctx = {};
runInNewContext(readFileSync(new URL('../assets/severance.js', import.meta.url), 'utf8'), ctx);
const S0 = ctx.DHSeverance;
const wrap = f => (...a) => JSON.parse(JSON.stringify(f(...a)));
const S = Object.fromEntries(Object.entries(S0).map(([k, f]) => [k, wrap(f)]));

// 평균임금 산정기간: 퇴직일(마지막 근무일 다음 날) 이전 3개월을 달력 월 단위로 나눔
const p = S.wagePeriods('2025-12-31');
assert.deepEqual(p.map(x => [x.start, x.end, x.days]), [['2025-10-01', '2025-10-31', 31], ['2025-11-01', '2025-11-30', 30], ['2025-12-01', '2025-12-31', 31]]);
const p2 = S.wagePeriods('2026-10-19');
assert.equal(p2[0].start, '2026-07-20');
assert.equal(p2.at(-1).end, '2026-10-19');
assert.equal(p2.reduce((s, x) => s + x.days, 0), 92);

// 근속연수: 1년 미만 끝수는 1년
assert.equal(S.serviceYears('2021-01-01', '2025-12-31'), 5);
assert.equal(S.serviceYears('2021-01-01', '2026-01-01'), 6);
assert.equal(S.serviceYears('2025-03-01', '2025-12-31'), 1);

// 기본 사례: 5년 근속, 월 300만원
const r = S.calculate({ hireDate: '2021-01-01', lastWorkDate: '2025-12-31', weeklyHours: 40,
  periods: [{ base: 3000000 }, { base: 3000000 }, { base: 3000000 }], annualBonus: 0, annualLeavePay: 0,
  dailyOrdinaryWage: '' });
assert.equal(r.ok, true);
assert.equal(r.eligible, true);
assert.equal(r.serviceDays, 1826);
assert.equal(r.periodDays, 92);
assert.equal(r.severance, Math.floor(9000000 / 92 * 30 * 1826 / 365));
// 퇴직소득세 단계별 검산
const t = r.tax;
assert.equal(t.serviceDeduction, 5000000);
assert.equal(t.converted, Math.floor((r.severance - 5000000) * 12 / 5));
assert.equal(t.convertedDeduction, Math.floor(8000000 + (t.converted - 8000000) * 0.6));
assert.equal(t.convertedTax, Math.floor((t.converted - t.convertedDeduction) * 0.06));
assert.equal(t.incomeTax, Math.floor(t.convertedTax * 5 / 12));
assert.equal(t.localTax, Math.floor(t.incomeTax / 10));

// 상여금·연차수당은 3/12 반영, 통상임금이 더 크면 통상임금 적용
const low = S.calculate({ hireDate: '2020-01-01', lastWorkDate: '2025-12-31', weeklyHours: 40,
  periods: [{ base: 1000000 }, { base: 1000000 }, { base: 1000000 }], annualBonus: 1200000, annualLeavePay: 400000,
  dailyOrdinaryWage: 60000 });
assert.equal(low.bonusShare, 300000);
assert.equal(low.leaveShare, 100000);
assert.equal(low.useOrdinary, true);
assert.equal(low.dailyWage, 60000);

// 1년 미만, 주 15시간 미만은 지급 대상 아님
assert.equal(S.calculate({ hireDate: '2025-06-01', lastWorkDate: '2025-12-31', weeklyHours: 40, periods: [] }).eligible, false);
assert.equal(S.calculate({ hireDate: '2020-01-01', lastWorkDate: '2025-12-31', weeklyHours: 14, periods: [] }).eligible, false);
assert.equal(S.calculate({ hireDate: '', lastWorkDate: '2025-12-31' }).ok, false);

// 근속연수공제 구간과 환산급여 고액 구간
assert.equal(S.retirementTax(100000000, 20).serviceDeduction, 40000000);
assert.equal(S.retirementTax(100000000, 25).serviceDeduction, 55000000);
assert.equal(S.retirementTax(1000000, 3).total, 0);


console.log('severance tests passed', r.severance, t.total);

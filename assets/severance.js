// 퇴직금 산정 계산 모듈 (근로자퇴직급여 보장법 기준, 화면 계산 전용 · 서버 저장 없음)
// 날짜는 모두 'YYYY-MM-DD' 문자열, 금액은 원 단위 정수로 다룹니다.
(function (root) {
  'use strict';
  const DAY = 86400000;
  const parse = s => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(String(s || ''))) return null;
    const [y, m, d] = s.split('-').map(Number);
    const t = Date.UTC(y, m - 1, d);
    const dt = new Date(t);
    return dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d ? t : null;
  };
  const fmt = t => new Date(t).toISOString().slice(0, 10);
  const addDays = (s, n) => fmt(parse(s) + n * DAY);
  const daysInMonth = (y, m) => new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
  // n개월 전 같은 날(말일 보정)
  const minusMonths = (s, n) => {
    const d = new Date(parse(s));
    const y = d.getUTCFullYear(), m = d.getUTCMonth() - n, day = d.getUTCDate();
    const ty = y + Math.floor(m / 12), tm = ((m % 12) + 12) % 12;
    return fmt(Date.UTC(ty, tm, Math.min(day, daysInMonth(ty, tm))));
  };
  const floor = n => Math.floor(Number(n) || 0);

  // 평균임금 산정기간(퇴직일 이전 3개월)을 달력 월 단위 구간으로 나눕니다.
  // lastWorkDate: 마지막 근무일, 퇴직일(산정사유 발생일)은 그 다음 날
  function wagePeriods(lastWorkDate) {
    if (parse(lastWorkDate) == null) return [];
    const retire = addDays(lastWorkDate, 1);
    let cur = minusMonths(retire, 3);
    const out = [];
    while (parse(cur) <= parse(lastWorkDate)) {
      const d = new Date(parse(cur));
      const monthEnd = fmt(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), daysInMonth(d.getUTCFullYear(), d.getUTCMonth())));
      const end = parse(monthEnd) < parse(lastWorkDate) ? monthEnd : lastWorkDate;
      const days = (parse(end) - parse(cur)) / DAY + 1;
      out.push({ start: cur, end, days, monthDays: daysInMonth(d.getUTCFullYear(), d.getUTCMonth()) });
      cur = addDays(end, 1);
    }
    return out;
  }

  // 근속연수(퇴직소득세용): 1년 미만 끝수는 1년으로 봅니다.
  function serviceYears(hireDate, lastWorkDate) {
    const retire = parse(addDays(lastWorkDate, 1));
    const plusYears = y => parse(minusMonths(hireDate, -12 * y));
    let y = 0;
    while (plusYears(y + 1) <= retire) y++;
    return Math.max(1, plusYears(y) === retire ? y : y + 1);
  }

  function serviceDeduction(y) {
    if (y <= 5) return 1000000 * y;
    if (y <= 10) return 5000000 + 2000000 * (y - 5);
    if (y <= 20) return 15000000 + 2500000 * (y - 10);
    return 40000000 + 3000000 * (y - 20);
  }
  function convertedDeduction(c) {
    if (c <= 8000000) return c;
    if (c <= 70000000) return 8000000 + (c - 8000000) * 0.6;
    if (c <= 100000000) return 45200000 + (c - 70000000) * 0.55;
    if (c <= 300000000) return 61700000 + (c - 100000000) * 0.45;
    return 151700000 + (c - 300000000) * 0.35;
  }
  const BRACKETS = [[14e6, .06, 0], [50e6, .15, 1.26e6], [88e6, .24, 5.76e6], [150e6, .35, 15.44e6], [300e6, .38, 19.94e6], [500e6, .40, 25.94e6], [1e9, .42, 35.94e6], [Infinity, .45, 65.94e6]];
  function basicTax(base) {
    if (base <= 0) return 0;
    const [, rate, prog] = BRACKETS.find(([limit]) => base <= limit);
    return base * rate - prog;
  }

  // 퇴직소득세 예상액 (2023년 이후 퇴직분 공제표, 참고용)
  function retirementTax(pay, years) {
    pay = floor(pay);
    const sd = serviceDeduction(years);
    const afterSd = Math.max(0, pay - sd);
    const converted = floor(afterSd * 12 / years);
    const cd = floor(convertedDeduction(converted));
    const taxBase = Math.max(0, converted - cd);
    const convertedTax = floor(basicTax(taxBase));
    const incomeTax = floor(convertedTax * years / 12);
    const localTax = floor(incomeTax / 10);
    return { years, serviceDeduction: sd, converted, convertedDeduction: cd, taxBase, convertedTax, incomeTax, localTax, total: incomeTax + localTax };
  }

  // input: { hireDate, lastWorkDate, weeklyHours, periods:[{base, extra}], annualBonus, annualLeavePay,
  //          dailyOrdinaryWage(선택: 입력한 경우에만 평균임금과 비교) }
  function calculate(input) {
    const warnings = [];
    const hire = parse(input.hireDate), last = parse(input.lastWorkDate);
    if (hire == null || last == null) return { ok: false, error: '입사일과 마지막 근무일을 입력해 주세요.' };
    if (last < hire) return { ok: false, error: '마지막 근무일이 입사일보다 빠릅니다.' };
    const serviceDays = (last - hire) / DAY + 1;
    const periods = wagePeriods(input.lastWorkDate);
    const rows = periods.map((p, i) => {
      const v = (input.periods || [])[i] || {};
      return { ...p, base: floor(v.base), extra: floor(v.extra) };
    });
    const periodDays = rows.reduce((s, r) => s + r.days, 0);
    const wageTotal = rows.reduce((s, r) => s + r.base + r.extra, 0);
    const bonusShare = floor(floor(input.annualBonus) * 3 / 12);
    const leaveShare = floor(floor(input.annualLeavePay) * 3 / 12);
    const grandTotal = wageTotal + bonusShare + leaveShare;
    const dailyAverage = periodDays ? grandTotal / periodDays : 0;
    const dailyOrdinary = Math.max(0, Number(input.dailyOrdinaryWage) || 0);
    const useOrdinary = dailyOrdinary > dailyAverage;
    const dailyWage = Math.max(dailyAverage, dailyOrdinary);
    const severance = floor(dailyWage * 30 * serviceDays / 365);
    let eligible = true;
    if (serviceDays < 365) { eligible = false; warnings.push('계속근로기간이 1년 미만이면 법정 퇴직금 지급 의무가 없습니다.'); }
    if (input.weeklyHours !== '' && input.weeklyHours != null && Number(input.weeklyHours) < 15) { eligible = false; warnings.push('4주 평균 주 소정근로시간이 15시간 미만이면 법정 퇴직금 지급 대상이 아닙니다.'); }
    if (wageTotal === 0) warnings.push('최근 3개월 임금이 0원입니다. 급여 금액을 확인해 주세요.');
    if (useOrdinary) warnings.push('평균임금이 통상임금보다 적어 통상임금을 기준으로 계산했습니다.');
    const years = serviceYears(input.hireDate, input.lastWorkDate);
    const tax = retirementTax(severance, years);
    return {
      ok: true, eligible, warnings, serviceDays, retireDate: addDays(input.lastWorkDate, 1),
      rows, periodDays, wageTotal, bonusShare, leaveShare, grandTotal,
      dailyAverage: Math.round(dailyAverage * 100) / 100, dailyOrdinary: Math.round(dailyOrdinary * 100) / 100,
      useOrdinary, dailyWage: Math.round(dailyWage * 100) / 100, severance, tax,
      netPay: Math.max(0, severance - tax.total)
    };
  }


  root.DHSeverance = { calculate, wagePeriods, serviceYears, retirementTax, addDays };
})(typeof globalThis !== 'undefined' ? globalThis : this);

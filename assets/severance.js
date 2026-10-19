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
    const incomeTax = Math.floor(floor(convertedTax * years / 12) / 10) * 10;
    const localTax = Math.floor(incomeTax / 100) * 10;
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


  // ── 월할 적립 방식 ──────────────────────────────────────────────
  // 월별 자료 [{month:'YYYY-MM', days, hours, pay}] → 같은 달은 합산하고,
  // 월 근로시간이 minHours 이상인 달만 포함해 세전 급여의 1/rate를 적립합니다.
  const normMonth = v => {
    if (typeof v === 'number' && v > 20000 && v < 80000) return new Date(Math.round((v - 25569) * DAY)).toISOString().slice(0, 7);
    const m = String(v || '').trim().match(/(\d{4})\s*[-./년]\s*(\d{1,2})/);
    return m ? m[1] + '-' + m[2].padStart(2, '0') : null;
  };
  const toNum = v => { const n = Number(String(v ?? '').replace(/[^0-9.\-]/g, '')); return isFinite(n) ? n : 0; };
  function roundUnit(x, unit) { return Number(unit) === 1 ? Math.floor(x) : Math.round(x / unit) * unit; }
  function mergeMonths(rows) {
    const map = new Map();
    for (const r of rows || []) {
      const month = normMonth(r.month);
      if (!month) continue;
      const o = map.get(month) || { month, days: 0, hours: 0, pay: 0, count: 0 };
      o.days += toNum(r.days); o.hours += toNum(r.hours); o.pay += toNum(r.pay); o.count++;
      map.set(month, o);
    }
    return [...map.values()].sort((a, b) => a.month.localeCompare(b.month));
  }
  function serviceText(hireDate, lastWorkDate) {
    if (parse(hireDate) == null || parse(lastWorkDate) == null) return '';
    const s = new Date(parse(hireDate)), e = new Date(parse(lastWorkDate) + DAY);
    let y = e.getUTCFullYear() - s.getUTCFullYear(), m = e.getUTCMonth() - s.getUTCMonth(), d = e.getUTCDate() - s.getUTCDate();
    if (d < 0) { m--; d += new Date(Date.UTC(e.getUTCFullYear(), e.getUTCMonth(), 0)).getUTCDate(); }
    if (m < 0) { y--; m += 12; }
    return y + '년 ' + m + '개월 ' + d + '일';
  }
  function accrual(input) {
    const minHours = input.minHours == null ? 60 : Number(input.minHours);
    const rate = Number(input.rate) || 12, unit = Number(input.round) || 10;
    const months = mergeMonths(input.rows).map(x => ({ ...x, included: x.hours >= minHours }));
    months.forEach(x => { x.amount = x.included ? roundUnit(x.pay / rate, unit) : 0; });
    const included = months.filter(x => x.included), excluded = months.filter(x => !x.included);
    const severance = included.reduce((s, x) => s + x.amount, 0);
    const warnings = [];
    let serviceDays = null, years = null;
    const hire = parse(input.hireDate), last = parse(input.lastWorkDate);
    if (hire != null && last != null && last >= hire) { serviceDays = (last - hire) / DAY + 1; years = serviceYears(input.hireDate, input.lastWorkDate); }
    else warnings.push('입사일과 퇴사일(마지막 근무일)을 입력하면 근속기간과 세금이 계산됩니다.');
    if (serviceDays != null && serviceDays < 365) warnings.push('재직기간이 1년 미만이면 법정 퇴직금 지급 의무가 없습니다.');
    if (months.length && included.length < 12) warnings.push('기준을 충족한 달이 ' + included.length + '개월로 12개월에 못 미칩니다. 지급 대상인지 확인해 주세요.');
    const missing = [];
    if (serviceDays != null) {
      const have = new Set(months.map(x => x.month));
      const outside = months.filter(x => x.month < input.hireDate.slice(0, 7) || x.month > input.lastWorkDate.slice(0, 7));
      if (outside.length) warnings.push('재직기간 밖의 달이 있습니다: ' + outside.map(x => x.month).join(', '));
      let y = +input.hireDate.slice(0, 4), m = +input.hireDate.slice(5, 7);
      const end = input.lastWorkDate.slice(0, 7);
      for (;;) { const k = y + '-' + String(m).padStart(2, '0'); if (k > end) break; if (!have.has(k)) missing.push(k); m++; if (m > 12) { m = 1; y++; } }
    }
    const last3 = included.slice(-3);
    const avg3 = last3.length ? last3.reduce((s, x) => s + x.pay, 0) / last3.length : 0;
    const tax = years ? retirementTax(severance, years) : retirementTax(0, 1);
    const payDate = parse(input.payDate) != null ? input.payDate : (last != null ? addDays(input.lastWorkDate, 14) : '');
    return {
      months, included, excluded, missing, warnings, minHours, rate, severance, serviceDays, years,
      serviceText: serviceText(input.hireDate, input.lastWorkDate), payDate, tax, netPay: Math.max(0, severance - tax.total),
      includedPay: included.reduce((s, x) => s + x.pay, 0),
      reference: serviceDays != null ? Math.floor(avg3 * serviceDays / 365) : 0
    };
  }
  // 임금대장 시트(2차원 배열): '년월' 머리행 아래 행에서 '총근로'와 첫 번째 '계'(임금 합계) 열을 읽습니다.
  function parsePayrollSheet(aoa) {
    const clean = c => String(c ?? '').replace(/\s/g, '');
    let hr = -1;
    for (let i = 0; i < Math.min(aoa.length, 15); i++) if ((aoa[i] || []).some(c => ['년월', '귀속월'].includes(clean(c)))) { hr = i; break; }
    if (hr < 0) return null;
    const top = aoa[hr].map(clean), sub = (aoa[hr + 1] || []).map(clean);
    const pick = (...names) => { for (const arr of [sub, top]) for (const n of names) { const i = arr.indexOf(n); if (i >= 0) return i; } return -1; };
    const mi = Math.max(top.indexOf('년월'), top.indexOf('귀속월'));
    const hi = pick('총근로', '총근로시간', '근로시간'), di = pick('근로일수');
    let pi = sub.indexOf('계'); if (pi < 0) pi = pick('지급총액', '세전급여', '총지급액', '과세계');
    if (hi < 0 || pi < 0) return null;
    const out = [];
    for (let r = hr + 1; r < aoa.length; r++) {
      const row = aoa[r] || [], month = normMonth(row[mi]);
      if (month) out.push({ month, days: di >= 0 ? toNum(row[di]) : 0, hours: toNum(row[hi]), pay: toNum(row[pi]) });
    }
    return out;
  }
  function maskRrn(v) { const d = String(v || '').replace(/\D/g, ''); return d.length >= 7 ? d.slice(0, 6) + '-' + d[6] + '******' : d; }
  function birthFromRrn(v) {
    const d = String(v || '').replace(/\D/g, ''); if (d.length < 7) return '';
    const c = { 1: '19', 2: '19', 5: '19', 6: '19', 3: '20', 4: '20', 7: '20', 8: '20', 9: '18', 0: '18' }[d[6]];
    const b = c + d.slice(0, 2) + '-' + d.slice(2, 4) + '-' + d.slice(4, 6);
    return parse(b) != null ? b : '';
  }

  root.DHSeverance = { calculate, wagePeriods, serviceYears, retirementTax, addDays, accrual, mergeMonths, parsePayrollSheet, serviceText, maskRrn, birthFromRrn, normMonth };
})(typeof globalThis !== 'undefined' ? globalThis : this);

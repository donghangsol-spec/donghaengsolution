// 직원 엑셀 일괄등록 모듈 (브라우저 안에서만 파일을 읽고, 화면 미리보기 후 정상 행만 저장합니다)
// 주민등록번호는 수집하지 않습니다. 해당 열은 읽지 않고, 다른 열에서 발견되면 그 행을 막습니다.
(function (root) {
  'use strict';

  const MAX_ROWS = 1000;
  const EMPLOYMENT_TYPES = ['정규직', '계약직', '일용직', '단시간근로자', '기타'];
  const STATUSES = ['재직', '입사예정', '퇴사예정', '퇴사'];
  const PAYROLL_TYPES = ['월급제', '시간제'];

  // 양식에 들어가는 열 순서이자, 다른 엑셀 파일의 제목을 알아보기 위한 표
  const COLUMNS = [
    { key: 'name', title: '직원명(필수)', aliases: ['직원명', '성명', '이름', 'name'] },
    { key: 'employee_no', title: '직원번호', aliases: ['직원번호', '사번', '사원번호', 'employee_no'] },
    { key: 'birth_date', title: '생년월일', aliases: ['생년월일', '생일', 'birth_date'] },
    { key: 'hire_date', title: '입사일', aliases: ['입사일', '입사일자', '입사년월일', 'hire_date'] },
    { key: 'termination_date', title: '퇴사일', aliases: ['퇴사일', '퇴사일자', '퇴직일', '퇴직일자', 'termination_date'] },
    { key: 'monthly_remuneration', title: '월 보수', aliases: ['월보수', '보수월액', '월급여', '월급', 'monthly_remuneration'] },
    { key: 'weekly_hours', title: '주 소정근로시간', aliases: ['주소정근로시간', '소정근로시간', '주근로시간', '근로시간', 'weekly_hours'] },
    { key: 'employment_type', title: '고용형태', aliases: ['고용형태', '근로형태', 'employment_type'] },
    { key: 'status', title: '상태', aliases: ['상태', '재직상태', '재직여부', 'status'] },
    { key: 'payroll_type', title: '급여구분', aliases: ['급여구분', '급여형태', 'payroll_type'] },
    { key: 'hourly_rate', title: '시급', aliases: ['시급', 'hourly_rate'] }
  ];
  const RRN_HEADERS = ['주민등록번호', '주민번호', '외국인등록번호', '주민외국인등록번호', 'rrn', 'resident_id'];

  const normalizeHeader = v => String(v ?? '')
    .replace(/\(.*?\)|（.*?）|\[.*?\]/g, '')
    .replace(/[\s*※:]/g, '')
    .toLowerCase();

  const clean = v => (v === null || v === undefined ? '' : String(v).trim());

  function isRrn(v) {
    const t = clean(v);
    if (/^\d{6}\s*-?\s*[1-8]\d{6}$/.test(t)) return true;
    // 엑셀이 숫자로 바꾸면 앞자리 0이 사라지므로(2000년대생) 13자리로 되돌려 확인합니다.
    if (typeof v === 'number' && Number.isInteger(v) && v >= 1e9 && v < 1e13) {
      return /^\d{6}[1-8]\d{6}$/.test(String(v).padStart(13, '0'));
    }
    return false;
  }

  const pad = n => String(n).padStart(2, '0');
  function validYmd(y, m, d) {
    const t = new Date(Date.UTC(y, m - 1, d));
    return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d
      ? `${y}-${pad(m)}-${pad(d)}` : null;
  }
  const expandYear = (yy, today, past) => {
    const century = Math.floor(Number(today.slice(0, 4)) / 100) * 100;
    const year = century + yy;
    return past && year > Number(today.slice(0, 4)) ? year - 100 : year;
  };

  // 엑셀 날짜칸(일련번호)과 사람이 적은 여러 표기를 'YYYY-MM-DD'로 바꿉니다. 읽을 수 없으면 null.
  function parseDate(v, { date1904 = false, today, past = false } = {}) {
    const now = today || new Date().toISOString().slice(0, 10);
    if (v === null || v === undefined || v === '') return '';
    if (v instanceof Date) {
      return Number.isNaN(v.getTime()) ? null : validYmd(v.getUTCFullYear(), v.getUTCMonth() + 1, v.getUTCDate());
    }
    if (typeof v === 'number') {
      if (Number.isInteger(v) && v >= 100000) return parseDate(String(v), { today: now, past });
      if (v < 1 || v > 73415) return null;
      const serial = Math.floor(v) + (date1904 ? 1462 : 0);
      // 1900년 윤년 오류 때문에 1899-12-30을 0으로 계산합니다.
      const t = new Date(Date.UTC(1899, 11, 30) + serial * 86400000);
      return validYmd(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
    }
    const t = clean(v);
    if (!t) return '';
    let m = t.match(/^(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})\s*[.일]?$/) || t.match(/^(\d{4})(\d{2})(\d{2})$/);
    if (m) return validYmd(+m[1], +m[2], +m[3]);
    m = t.match(/^(\d{2})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})\s*[.일]?$/) || t.match(/^(\d{2})(\d{2})(\d{2})$/);
    if (m) return validYmd(expandYear(+m[1], now, past), +m[2], +m[3]);
    return null;
  }

  // '3,000,000원', '40시간' 같은 표기를 숫자로 바꿉니다. 빈칸은 '', 읽을 수 없으면 null.
  function parseNumber(v) {
    if (typeof v === 'number') return Number.isFinite(v) && v >= 0 ? v : null;
    const t = clean(v).replace(/[,\s]/g, '').replace(/(원|시간|hrs?|h)$/i, '');
    if (!t) return '';
    if (!/^\d+(\.\d+)?$/.test(t)) return null;
    return Number(t);
  }

  function pick(value, allowed, aliases = {}) {
    const t = clean(value).replace(/\s/g, '');
    if (allowed.includes(t)) return t;
    return aliases[t] || null;
  }

  // 제목 줄 앞에 회사명 같은 안내 줄이 있어도 찾을 수 있게 앞쪽 줄을 살펴봅니다.
  function findHeader(aoa) {
    const nameAliases = COLUMNS[0].aliases;
    const limit = Math.min(aoa.length, 15);
    for (let i = 0; i < limit; i++) {
      const row = aoa[i] || [];
      if (row.some(cell => nameAliases.includes(normalizeHeader(cell)))) return i;
    }
    return -1;
  }

  function mapColumns(headerRow) {
    const map = {};
    let rrnColumn = false;
    const ignored = [];
    headerRow.forEach((cell, index) => {
      const header = normalizeHeader(cell);
      if (!header) return;
      if (RRN_HEADERS.includes(header)) { rrnColumn = true; return; }
      const column = COLUMNS.find(c => c.aliases.includes(header));
      if (!column) { ignored.push(clean(cell)); return; }
      if (map[column.key] === undefined) map[column.key] = index;
    });
    return { map, rrnColumn, ignored };
  }

  // 같은 직원이 이미 있는지 판단합니다.
  function findConflict(row, pool) {
    if (row.employee_no) {
      const same = pool.find(e => clean(e.employee_no) === row.employee_no);
      if (same) return { type: clean(same.name) === row.name ? 'same' : 'number-taken', with: same };
    }
    const named = pool.filter(e => clean(e.name) === row.name);
    if (!named.length) return null;
    if (row.birth_date) {
      const same = named.find(e => e.birth_date === row.birth_date);
      if (same) return { type: 'same', with: same };
    }
    // 번호도 생일도 비교할 수 없으면 같은 사람으로 보고 막아서, 같은 파일을 두 번 올려도 겹치지 않게 합니다.
    if (!row.employee_no && (!row.birth_date || named.some(e => !e.birth_date))) return { type: 'same-name', with: named[0] };
    return { type: 'homonym', with: named[0] };
  }

  function parseRow(cells, texts, columns, rowNo, { today, date1904 }) {
    const get = key => (columns[key] === undefined ? undefined : cells[columns[key]]);
    const errors = [];
    const warnings = [];

    if (Object.values(columns).some(index => isRrn(cells[index]))) {
      return { rowNo, state: 'error', errors: ['주민등록번호로 보이는 값이 있어 이 행은 읽지 않았습니다. 해당 칸을 지워 주세요.'], warnings: [], data: { name: '', employee_no: '' } };
    }

    const name = clean(get('name'));
    let employeeNo = clean(get('employee_no'));
    const noIndex = columns.employee_no;
    if (noIndex !== undefined && typeof cells[noIndex] === 'number') {
      // 서식으로 표시되는 앞자리 0(예: 001)은 살립니다.
      const shown = clean(texts?.[noIndex]);
      if (/^0\d+$/.test(shown)) employeeNo = shown;
    }
    if (!name) errors.push('직원명이 비어 있습니다.');
    if (['합계', '총계', '소계', '계'].includes(name.replace(/\s/g, ''))) errors.push('합계 행으로 보여 제외했습니다.');
    if (name.length > 50) errors.push('직원명이 너무 깁니다.');

    const date = (key, label, opts = {}) => {
      const value = parseDate(get(key), { today, date1904, ...opts });
      if (value === null) { errors.push(`${label}을 날짜로 읽을 수 없습니다. 예: 2026-01-31`); return null; }
      return value || null;
    };
    const number = (key, label) => {
      const value = parseNumber(get(key));
      if (value === null) { errors.push(`${label}은 0 이상의 숫자로 적어 주세요.`); return null; }
      return value === '' ? null : value;
    };

    const birthDate = date('birth_date', '생년월일', { past: true });
    const hireDate = date('hire_date', '입사일');
    const terminationDate = date('termination_date', '퇴사일');
    const salary = number('monthly_remuneration', '월 보수');
    const weeklyHours = number('weekly_hours', '주 소정근로시간');
    const hourlyRate = number('hourly_rate', '시급');

    if (birthDate && birthDate > today) errors.push('생년월일이 오늘보다 뒤입니다.');
    if (birthDate && birthDate < '1900-01-01') errors.push('생년월일을 확인해 주세요.');
    if (hireDate && terminationDate && terminationDate < hireDate) errors.push('퇴사일이 입사일보다 앞섭니다.');
    if (weeklyHours !== null && weeklyHours > 168) errors.push('주 소정근로시간을 확인해 주세요.');

    let employmentType = '정규직';
    if (clean(get('employment_type'))) {
      employmentType = pick(get('employment_type'), EMPLOYMENT_TYPES, { 단시간: '단시간근로자', 단시간직: '단시간근로자', 일용: '일용직', 정규: '정규직', 계약: '계약직' });
      if (!employmentType) errors.push(`고용형태는 ${EMPLOYMENT_TYPES.join('·')} 중 하나로 적어 주세요.`);
    }

    let status;
    if (clean(get('status'))) {
      status = pick(get('status'), STATUSES, { 재직중: '재직', 근무: '재직', 근무중: '재직', 퇴직: '퇴사', 퇴사자: '퇴사', 입사대기: '입사예정' });
      if (!status) errors.push(`상태는 ${STATUSES.join('·')} 중 하나로 적어 주세요.`);
    } else if (terminationDate) {
      status = terminationDate <= today ? '퇴사' : '퇴사예정';
    } else {
      status = hireDate && hireDate > today ? '입사예정' : '재직';
    }
    if (status === '퇴사' && !terminationDate) warnings.push('상태가 퇴사인데 퇴사일이 없습니다.');
    if (status === '재직' && terminationDate && terminationDate <= today) warnings.push('퇴사일이 지났는데 상태가 재직입니다.');

    let payrollType;
    if (clean(get('payroll_type'))) {
      payrollType = pick(get('payroll_type'), PAYROLL_TYPES, { 월급: '월급제', 시급: '시간제', 시급제: '시간제', 시간급: '시간제' });
      if (!payrollType) errors.push('급여구분은 월급제·시간제 중 하나로 적어 주세요.');
    } else {
      payrollType = hourlyRate ? '시간제' : '월급제';
    }
    if (payrollType === '시간제' && !hourlyRate) warnings.push('시간제인데 시급이 없습니다. 급여대장 전에 입력해 주세요.');

    return {
      rowNo,
      state: errors.length ? 'error' : 'new',
      errors,
      warnings,
      data: {
        name,
        employee_no: employeeNo || null,
        birth_date: birthDate,
        hire_date: hireDate,
        termination_date: terminationDate,
        monthly_remuneration: salary,
        weekly_hours: weeklyHours,
        employment_type: employmentType || null,
        status: status || null,
        payroll_type: payrollType || null,
        hourly_rate: hourlyRate
      }
    };
  }

  // aoa: 시트의 원본 값(2차원 배열), texts: 화면에 보이는 글자(앞자리 0 확인용), existing: 이미 등록된 직원
  function parseSheet(aoa, { texts = [], existing = [], today, date1904 = false } = {}) {
    const now = today || new Date().toISOString().slice(0, 10);
    const headerIndex = findHeader(aoa);
    if (headerIndex < 0) return { ok: false, headerFound: false, error: '직원명(또는 성명·이름) 열을 찾지 못했습니다. 양식을 내려받아 작성해 주세요.', rows: [] };

    const { map, rrnColumn, ignored } = mapColumns(aoa[headerIndex]);
    const body = [];
    for (let i = headerIndex + 1; i < aoa.length; i++) {
      const cells = aoa[i] || [];
      if (Object.values(map).every(index => clean(cells[index]) === '')) continue;
      body.push({ cells, texts: texts[i], rowNo: i + 1 });
    }
    if (!body.length) return { ok: false, headerFound: true, error: '등록할 직원이 없습니다. 파일 내용을 확인해 주세요.', rows: [] };
    if (body.length > MAX_ROWS) return { ok: false, headerFound: true, error: `한 번에 ${MAX_ROWS}명까지 등록할 수 있습니다. 파일을 나누어 올려 주세요.`, rows: [] };

    const accepted = [];
    const rows = body.map(({ cells, texts: rowTexts, rowNo }) => {
      const row = parseRow(cells, rowTexts, map, rowNo, { today: now, date1904 });
      if (row.state === 'error') return row;

      const saved = findConflict(row.data, existing);
      if (saved?.type === 'number-taken') {
        row.state = 'error';
        row.errors.push(`직원번호를 이미 다른 직원(${clean(saved.with.name)})이 쓰고 있습니다.`);
        return row;
      }
      if (saved?.type === 'same') {
        row.state = 'skip';
        row.warnings = ['이미 등록된 직원이라 건너뜁니다. 내용을 바꾸려면 직원 목록의 [수정]을 이용해 주세요.'];
        return row;
      }
      if (saved?.type === 'same-name') {
        row.state = 'skip';
        row.warnings = ['같은 이름의 직원이 이미 있어 건너뜁니다. 동명이인이면 직원번호나 생년월일을 적어 주세요.'];
        return row;
      }
      if (saved?.type === 'homonym') row.warnings.push('같은 이름의 직원이 이미 있습니다. 동명이인이 맞는지 확인해 주세요.');

      const inFile = findConflict(row.data, accepted.map(r => r.data));
      if (inFile && inFile.type !== 'homonym') {
        row.state = 'error';
        row.errors.push(`파일 안에서 중복입니다(${accepted.find(r => r.data === inFile.with).rowNo}행과 겹침).`);
        return row;
      }
      accepted.push(row);
      return row;
    });

    return { ok: true, rows, rrnColumn, ignored, summary: summarize(rows) };
  }

  function summarize(rows) {
    return {
      total: rows.length,
      ready: rows.filter(r => r.state === 'new').length,
      skipped: rows.filter(r => r.state === 'skip').length,
      failed: rows.filter(r => r.state === 'error').length
    };
  }

  function toInsertRows(rows, companyId) {
    return rows.filter(r => r.state === 'new').map(r => ({ ...r.data, company_id: companyId }));
  }

  const GUIDE = [
    ['직원 일괄등록 양식 작성 안내'],
    [''],
    ['항목', '작성 방법', '예시'],
    ['직원 이름', '꼭 적어 주세요.', '홍길동'],
    ['직원번호', '사내 번호. 비워도 됩니다. 주민등록번호를 적으면 그 행은 등록되지 않습니다.', 'E001'],
    ['생년월일 · 입사일 · 퇴사일', '날짜로 적어 주세요.', '2026-03-02'],
    ['월 보수', '숫자만 적어 주세요.', '2500000'],
    ['주 소정근로시간', '숫자만 적어 주세요.', '40'],
    ['고용형태', EMPLOYMENT_TYPES.join(' / ') + ' (비우면 정규직)', '정규직'],
    ['상태', STATUSES.join(' / ') + ' (비우면 날짜를 보고 자동으로 정합니다)', '재직'],
    ['급여구분', PAYROLL_TYPES.join(' / ') + ' (비우면 시급이 있을 때 시간제, 없으면 월급제)', '시간제'],
    ['시급', '시간제 직원만 숫자로 적어 주세요.', '12000'],
    [''],
    ['주민등록번호는 적지 마세요. 이 시스템은 주민등록번호 원문을 수집하지 않습니다.'],
    ['이미 등록된 직원은 건너뜁니다. 정보를 바꾸려면 직원 목록의 [수정]을 이용해 주세요.'],
    ['첫 번째 시트의 제목 줄은 지우거나 바꾸지 말고, 둘째 줄부터 한 사람씩 적어 주세요.']
  ];
  const TEMPLATE_HEADER = COLUMNS.map(c => c.title);

  root.DHEmployeeImport = { MAX_ROWS, TEMPLATE_HEADER, GUIDE, parseSheet, parseDate, parseNumber, isRrn, toInsertRows, summarize };
})(typeof globalThis !== 'undefined' ? globalThis : this);

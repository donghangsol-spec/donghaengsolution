// 4대사회보험 공통 신고서(자격취득·자격상실) 출력
// 화면에서만 만들고, 주민등록번호는 저장하지 않습니다. 사업장 정보는 이 브라우저에만 기억합니다.
// 부호 출처: 국민연금법 시행규칙 별지 제6호서식(취득, 2020.1.31 개정), 국민건강보험법 시행규칙 별지 제8호서식(상실, 2022.10.26 개정)
(function (root) {
  'use strict';
  const ORDER = ['건강보험', '국민연금', '고용보험', '산재보험'];
  const CODES = {
    npAcq: [['01', '18세 이상 당연취득'], ['03', '18세 미만 취득'], ['09', '전입(통·폐합)'], ['11', '대학 강사'], ['12', '60시간 미만 신청 취득']],
    hiAcq: [['00', '최초취득'], ['04', '의료급여 수급권자등에서 제외'], ['05', '직장가입자 변경'], ['06', '직장피부양자 상실'], ['07', '지역가입자에서 변경'], ['10', '유공자 등 건강보험 적용 신청'], ['13', '기타'], ['14', '거주불명 등록 후 재등록'], ['29', '직장가입자 이중가입']],
    npLoss: [['3', '사용관계 종료'], ['1', '사망'], ['4', '국적 상실(국외 이주)'], ['5', '60세 도달'], ['6', '다른 공적연금 가입'], ['9', '전출(통·폐합)'], ['15', '(조기)노령연금 수급권 취득'], ['16', '협정국 연금 가입'], ['19', '체류기간 만료(외국인)'], ['20', '적용제외 체류자격(외국인)'], ['21', '무보수 대표이사'], ['22', '근로자 제외(60시간 미만 등)'], ['26', '취득취소']],
    hiLoss: [['01', '퇴직'], ['02', '사망'], ['04', '의료급여수급권자'], ['10', '유공자 등 적용배제 신청'], ['13', '그 밖의 사유'], ['16', '취득취소'], ['17', '국적상실'], ['19', '이민출국'], ['24', '가입제외(외국의 법령)'], ['25', '가입제외(외국의 보험)'], ['26', '가입제외(사용자와의 계약)'], ['58', '무보수대표자']],
    eiLoss: [['11', '개인사정으로 인한 자진퇴사'], ['12', '사업장 이전·근로조건 변동·임금체불 등으로 자진퇴사'], ['22', '폐업·도산'], ['23', '경영상 필요·회사불황으로 인원감축(해고·권고사직·명예퇴직 포함)'], ['26', '근로자 귀책사유에 의한 징계해고·권고사직·계약해지'], ['31', '정년'], ['32', '계약기간 만료·공사 종료'], ['41', '고용보험 비적용'], ['42', '이중고용']]
  };
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const won = n => (n === '' || n == null || isNaN(Number(n))) ? '' : Number(n).toLocaleString('ko-KR');
  const dot = d => d ? String(d).replace(/-/g, '.') : '';
  const opts = (list, val) => '<option value="">선택</option>' + list.map(([c, t]) => '<option value="' + c + '"' + (c === val ? ' selected' : '') + '>' + c + ' ' + esc(t) + '</option>').join('');
  const label = (list, c) => { const f = list.find(x => x[0] === c); return f ? f[0] : ''; };

  // 상실사유 문구 → 고용보험 구분코드(확실한 것만)
  function eiCodeFromReason(text) {
    const t = String(text || '');
    if (/자진퇴사|개인사정/.test(t)) return '11';
    if (/계약기간|계약 만료|계약만료/.test(t)) return '32';
    if (/정년/.test(t)) return '31';
    if (/권고사직|경영상|회사사정|인원감축/.test(t)) return '23';
    if (/폐업|도산/.test(t)) return '22';
    return '';
  }
  // 같은 사람이라도 보험마다 날짜가 다르면 줄을 나눕니다(서식 유의사항).
  function lineGroups(details) {
    const map = new Map();
    for (const d of [...details].sort((a, b) => ORDER.indexOf(a.insurance_type) - ORDER.indexOf(b.insurance_type))) {
      const k = d.effective_date || '';
      if (!map.has(k)) map.set(k, []);
      map.get(k).push(d);
    }
    return [...map.entries()].map(([date, rows]) => ({ date, rows, has: t => rows.some(r => r.insurance_type === t), get: t => rows.find(r => r.insurance_type === t) }));
  }
  const storeKey = id => 'dh-ins-company-' + id;
  function loadBiz(id, name) { let v = {}; try { v = JSON.parse(localStorage.getItem(storeKey(id)) || '{}'); } catch (_) {} return { name, ...v }; }
  function saveBiz(id, v) { try { localStorage.setItem(storeKey(id), JSON.stringify(v)); } catch (_) {} }
  function rrnFmt(v) { const d = String(v || '').replace(/\D/g, '').slice(0, 13); return d.length > 6 ? d.slice(0, 6) + '-' + d.slice(6) : d; }

  // ── 신고서 HTML (인쇄용) ──
  function bizBlock(b, kind) {
    const agent = '<table class="f-biz" style="border-top:0"><tr><th class="f-side">보험사무<br>대행기관</th><th>번호</th><td>' + esc(b.agentNo) + '</td><th>명칭</th><td>' + esc(b.agentName) + '</td><th>하수인 관리번호</th><td></td></tr></table>';
    if (kind === 'loss') {
      return '<table class="f-biz"><tr><th rowspan="2" class="f-side">사업장</th><th>사업장관리번호</th><td>' + esc(b.mgmtNo) + '</td><th>명칭</th><td>' + esc(b.name) + '</td><th>전화번호</th><td>' + esc(b.tel) + '</td><th>FAX번호</th><td>' + esc(b.fax) + '</td></tr>' +
        '<tr><th>소재지</th><td colspan="5">' + esc(b.addr) + '</td><th>우편번호</th><td>' + esc(b.zip) + '</td></tr></table>' + agent;
    }
    return '<table class="f-biz"><tr><th rowspan="3" class="f-side">사업장</th><th>사업장관리번호</th><td>' + esc(b.mgmtNo) + '</td><th>명칭</th><td colspan="3">' + esc(b.name) + '</td></tr>' +
      '<tr><th>소재지</th><td colspan="3">' + esc(b.addr) + '</td><th>우편번호</th><td>' + esc(b.zip) + '</td></tr>' +
      '<tr><th>전화번호</th><td colspan="3">' + esc(b.tel) + '</td><th>FAX번호</th><td>' + esc(b.fax) + '</td></tr></table>' + agent;
  }
  const ck = on => on ? '[√]' : '[ ]';
  function acqHtml(ctx) {
    const { biz, emp, req, groups, f } = ctx;
    const lines = groups.map((g, i) => {
      const hi = g.get('건강보험'), np = g.get('국민연금'), ei = g.get('고용보험'), ia = g.get('산재보험'), any = hi || np || ei || ia;
      const pay = (hi || np || ei || ia)?.remuneration_amount;
      return '<tr><td rowspan="2" class="c">' + (i + 1) + '</td><td>' + esc(emp.name) + '</td><td class="c">' + esc(f.nationality) + '</td><td rowspan="2" class="c">' + (f.isRep ? '[√]예<br>[ ]아니오' : '[ ]예<br>[√]아니오') + '</td>' +
        '<td rowspan="2" class="r">' + won(f.pay || pay) + '</td><td rowspan="2" class="c">' + dot(g.date) + '</td>' +
        '<td class="c" colspan="3">' + ck(np) + '국민연금<br>(' + ck(np && f.npPayFirst) + '취득 월 납부 희망)</td>' +
        '<td class="c">' + ck(hi) + '건강보험</td><td class="c" colspan="3">(' + ck(hi && f.dependent) + '피부양자 신청)</td>' +
        '<td class="c" colspan="5">' + ck(ei) + '고용보험 (계약직 여부: ' + (f.contract ? '[√]예 [ ]아니오' : '[ ]예 [√]아니오') + ')<br>' + ck(ia) + '산재보험</td></tr>' +
        '<tr><td class="c">' + esc(f.rrn) + '</td><td class="c">' + esc(f.visa) + '</td>' +
        '<td class="c">' + (np ? esc(f.npCode) : '') + '</td><td class="c">' + (np ? esc(f.npSpecial) : '') + '</td><td class="c">' + (np ? esc(f.npOccup) : '') + '</td>' +
        '<td class="c">' + (hi ? esc(f.hiCode) : '') + '</td><td class="c">' + (hi ? esc(f.hiReduce) : '') + '</td><td class="c"></td><td class="c"></td>' +
        '<td class="c">' + (ei || ia ? esc(f.jobCode || (ei || ia)?.occupation_code || '') : '') + '</td><td class="c">' + (ei || ia ? esc(f.weeklyHours) : '') + '</td><td class="c">' + (ei && f.contract ? esc(f.contractEnd) : '') + '</td>' +
        '<td class="c">' + (ei || ia ? esc(f.chargeCode) : '') + '</td><td class="c">' + (ei || ia ? esc(f.chargeReason) : '') + '</td></tr>';
    }).join('');
    return '<div class="f-doc"><div class="f-law">■ 국민연금법 시행규칙 [별지 제6호서식] · 국민건강보험법 시행규칙 · 고용보험법 시행규칙 · 산재보험 공통</div>' +
      '<h1>[' + (req.national_pension ? '√' : ' ') + ']국민연금 [' + (req.health_insurance ? '√' : ' ') + ']건강보험 [' + (req.employment_insurance ? '√' : ' ') + ']고용보험 [' + (req.industrial_accident ? '√' : ' ') + ']산재보험<br>사업장가입자 자격취득 신고서</h1>' +
      '<p class="f-note">※ 같은 사람의 4대 사회보험의 자격취득일 또는 월 소득액이 서로 다른 경우 줄을 달리하여 적습니다.</p>' +
      '<table class="f-biz"><tr><th>접수번호</th><td></td><th>접수일시</th><td></td><th>처리기간</th><td>3일(고용·산재보험은 5일)</td></tr></table>' + bizBlock(biz, 'acq') +
      '<table class="f-main"><thead><tr><th rowspan="3">구분</th><th>성명</th><th>국적</th><th rowspan="3">대표자<br>여부</th><th rowspan="3">월 소득액<br>(소득월액·보수월액·<br>월평균보수)(원)</th><th rowspan="3">자격<br>취득일<br>(YYYY.MM.DD)</th><th colspan="3">국민연금</th><th colspan="4">건강보험</th><th colspan="5">고용보험·산재보험</th></tr>' +
      '<tr><th rowspan="2">주민등록번호<br>(외국인등록번호)</th><th rowspan="2">체류<br>자격</th><th rowspan="2">자격취득<br>부호</th><th rowspan="2">특수직종<br>부호</th><th rowspan="2">직역연금<br>부호</th><th rowspan="2">자격취득<br>부호</th><th>보험료</th><th colspan="2">공무원·교직원</th><th rowspan="2">직종<br>부호</th><th rowspan="2">1주<br>소정근로<br>시간</th><th rowspan="2">계약종료<br>연월</th><th colspan="2">보험료부과구분</th></tr>' +
      '<tr><th>감면부호</th><th>회계명/부호</th><th>직종명/부호</th><th>부호</th><th>사유</th></tr></thead><tbody>' + lines + '</tbody></table>' +
      '<p class="f-sign-text">위와 같이 자격취득을 신고합니다.</p><p class="f-date">' + esc(f.signDate) + '</p>' +
      '<p class="f-sign">신고인(사용자·대표자) <span class="f-line">' + esc(f.signer) + '</span> (서명 또는 인) &nbsp; / [ ]보험사무대행기관 <span class="f-line"></span> (서명 또는 인)</p>' +
      '<p class="f-to">국민연금공단 이사장 / 국민건강보험공단 이사장 / 근로복지공단 ○○지역본부(지사)장 귀하</p></div>';
  }
  function lossHtml(ctx) {
    const { biz, emp, req, groups, f } = ctx;
    const lines = groups.map((g, i) => {
      const hi = g.get('건강보험'), np = g.get('국민연금'), ei = g.get('고용보험'), ia = g.get('산재보험');
      return '<tr><td rowspan="2" class="c">' + (i + 1) + '</td><td rowspan="2" class="c">' + esc(emp.name) + '</td><td rowspan="2" class="c">' + esc(f.rrn) + '</td><td rowspan="2" class="c">' + esc(f.phone) + '</td><td rowspan="2" class="c">' + dot(g.date) + '</td>' +
        '<td rowspan="2" class="c">' + (np ? esc(f.npCode) : '') + '</td><td rowspan="2" class="c">' + (np ? ck(f.npPayFirst) + ' 희망' : '') + '</td>' +
        '<td rowspan="2" class="c">' + (hi ? esc(f.hiCode) : '') + '</td><td rowspan="2" class="r">' + (hi ? won(f.hiTotalThis) : '') + '</td><td rowspan="2" class="c">' + (hi ? esc(f.hiMonthsThis) : '') + '</td><td rowspan="2" class="r">' + (hi ? won(f.hiTotalPrev) : '') + '</td><td rowspan="2" class="c">' + (hi ? esc(f.hiMonthsPrev) : '') + '</td>' +
        '<td rowspan="2" class="c">' + (ei || ia ? esc(f.reasonText) : '') + '</td><td rowspan="2" class="c">' + (ei || ia ? esc(f.eiCode) : '') + '</td>' +
        '<td class="r">' + (ei ? won(f.eiTotalThis) : '') + '</td><td class="r">' + (ei ? won(f.eiTotalPrev) : '') + '</td></tr>' +
        '<tr><td class="r">' + (ia ? won(f.iaTotalThis) : '') + '</td><td class="r">' + (ia ? won(f.iaTotalPrev) : '') + '</td></tr>';
    }).join('');
    return '<div class="f-doc"><div class="f-law">■ 국민건강보험법 시행규칙 [별지 제8호서식] · 국민연금법 · 고용보험법 시행규칙 공통</div>' +
      '<h1>[' + (req.national_pension ? '√' : ' ') + ']국민연금 [' + (req.health_insurance ? '√' : ' ') + ']건강보험 [' + (req.employment_insurance ? '√' : ' ') + ']고용보험 [' + (req.industrial_accident ? '√' : ' ') + ']산재보험<br>사업장가입자 자격상실 신고서</h1>' +
      '<p class="f-note">※ 같은 사람의 4대 사회보험의 상실일자가 다른 경우 줄을 달리하여 적습니다.</p>' +
      '<table class="f-biz"><tr><th>접수번호</th><td></td><th>접수일자</th><td></td><th>처리기간</th><td>3일(고용·산재보험은 7일)</td></tr></table>' + bizBlock(biz, 'loss') +
      '<table class="f-main"><thead><tr><th rowspan="4">일련<br>번호</th><th rowspan="4">성명</th><th rowspan="4">주민등록번호<br>(외국인등록번호·<br>국내거소신고번호)</th><th rowspan="4">전화번호<br>(휴대전화번호)</th><th rowspan="4">상실<br>연월일<br>(YYYY.MM.DD)</th><th colspan="2">국민연금</th><th colspan="5">건강보험</th><th colspan="4">' + ck(req.employment_insurance) + '고용보험 ' + ck(req.industrial_accident) + '산재보험</th></tr>' +
      '<tr><th rowspan="3">상실<br>부호</th><th rowspan="3">초일취득·<br>당월상실자<br>납부여부</th><th rowspan="3">상실<br>부호</th><th colspan="4">연간 보수 총액</th><th colspan="2" rowspan="2">상실 사유</th><th>해당 연도<br>보수 총액</th><th>전년도<br>보수 총액</th></tr>' +
      '<tr><th colspan="2">해당 연도</th><th colspan="2">전년도</th><th>고용보험</th><th>고용보험</th></tr>' +
      '<tr><th>보수 총액</th><th>근무<br>개월수</th><th>보수 총액</th><th>근무<br>개월수</th><th>구체적<br>사유</th><th>구분<br>코드</th><th>산재보험</th><th>산재보험</th></tr></thead><tbody>' + lines + '</tbody></table>' +
      '<p class="f-sign-text">위와 같이 자격상실(고용종료) 사항을 신고합니다.</p><p class="f-date">' + esc(f.signDate) + '</p>' +
      '<p class="f-sign">신고인·확인인(사용자·대표자) <span class="f-line">' + esc(f.signer) + '</span> (서명 또는 인) &nbsp; / [ ]보험사무대행기관 <span class="f-line"></span> (서명 또는 인)</p>' +
      '<p class="f-to">국민연금공단 이사장 / 국민건강보험공단 이사장 / 근로복지공단 지역본부(지사)장 귀하</p></div>';
  }

  // ── 입력 패널 ──
  function panelHtml(kind, biz, emp, req, groups, d0) {
    const fld = (id, lbl, val, type) => '<label>' + lbl + '<input id="if_' + id + '" ' + (type ? 'type="' + type + '" ' : '') + 'value="' + esc(val ?? '') + '"></label>';
    const sel = (id, lbl, list, val) => '<label>' + lbl + '<select id="if_' + id + '">' + opts(list, val) + '</select></label>';
    const chk = (id, lbl, on) => '<label class="if-chk"><input type="checkbox" id="if_' + id + '"' + (on ? ' checked' : '') + '> ' + lbl + '</label>';
    const has = t => groups.some(g => g.has(t));
    const today = new Date(); const td = today.getFullYear() + '년 ' + (today.getMonth() + 1) + '월 ' + today.getDate() + '일';
    let h = '<div class="if-grid"><div><h4>사업장 <span class="muted">(이 브라우저에 기억)</span></h4><div class="formgrid">' +
      fld('mgmtNo', '사업장관리번호', biz.mgmtNo) + fld('name', '명칭', biz.name) + fld('addr', '소재지', biz.addr) + fld('zip', '우편번호', biz.zip) + fld('tel', '전화번호', biz.tel) + fld('fax', 'FAX번호', biz.fax) + fld('agentNo', '보험사무대행기관 번호', biz.agentNo) + fld('agentName', '보험사무대행기관 명칭', biz.agentName) + '</div></div>' +
      '<div><h4>근로자</h4><div class="formgrid"><label>성명<input value="' + esc(emp.name) + '" disabled></label>' +
      '<label>주민등록번호 <span class="muted">(저장 안 함)</span><input id="if_rrn" inputmode="numeric" autocomplete="off" placeholder="000000-0000000"></label>' +
      (kind === 'loss' ? fld('phone', '전화번호(휴대전화)', '') : fld('nationality', '국적(외국인만)', '') + fld('visa', '체류자격(외국인만)', '')) +
      fld('signer', '신고인(대표자) 성명', biz.signer) + fld('signDate', '신고일', td) + '</div></div></div>';
    h += '<h4>보험별 항목 <span class="muted">— 날짜: ' + groups.map(g => esc(g.date) + '(' + g.rows.map(r => r.insurance_type.replace('보험', '').replace('국민', '')).join('·') + ')').join(', ') + '</span></h4><div class="formgrid">';
    if (kind === 'acq') {
      h += fld('pay', '월 소득액(원)', d0?.remuneration_amount ?? '', 'number') + chk('isRep', '대표자', false);
      if (has('건강보험')) h += sel('hiCode', '건강보험 자격취득부호', CODES.hiAcq, '00') + fld('hiReduce', '건강보험 감면부호(해당 시)', '') + chk('dependent', '피부양자 신청', false);
      if (has('국민연금')) h += sel('npCode', '국민연금 자격취득부호', CODES.npAcq, '01') + fld('npSpecial', '특수직종부호(광원1·부원2)', '') + fld('npOccup', '직역연금부호(해당 시)', '') + chk('npPayFirst', '취득 월 납부 희망(1일 취득 제외)', false);
      if (has('고용보험') || has('산재보험')) h += fld('jobCode', '직종부호(KECO 소분류)', d0?.occupation_code || '') + fld('weeklyHours', '1주 소정근로시간', d0?.weekly_hours ?? '') + chk('contract', '계약직', !!d0?.contract_end_date) + fld('contractEnd', '계약종료연월(YYYY.MM)', d0?.contract_end_date ? d0.contract_end_date.slice(0, 7).replace('-', '.') : '') + fld('chargeCode', '보험료부과구분 부호(해당자만)', '') + fld('chargeReason', '보험료부과구분 사유(해당자만)', '');
    } else {
      if (has('건강보험')) h += sel('hiCode', '건강보험 상실부호', CODES.hiLoss, '01') + fld('hiTotalThis', '건강 해당연도 보수총액', '', 'number') + fld('hiMonthsThis', '해당연도 근무개월수', '', 'number') + fld('hiTotalPrev', '건강 전년도 보수총액(정산 안 한 경우)', '', 'number') + fld('hiMonthsPrev', '전년도 근무개월수', '', 'number');
      if (has('국민연금')) h += sel('npCode', '국민연금 상실부호', CODES.npLoss, '3') + chk('npPayFirst', '초일취득·당월상실자 납부 희망', false);
      if (has('고용보험') || has('산재보험')) h += fld('reasonText', '구체적 사유', req.loss_reason || '') + sel('eiCode', '고용보험 상실사유 구분코드', CODES.eiLoss, eiCodeFromReason(req.loss_reason));
      if (has('고용보험')) h += fld('eiTotalThis', '고용 해당연도 보수총액', '', 'number') + fld('eiTotalPrev', '고용 전년도 보수총액', '', 'number');
      if (has('산재보험')) h += fld('iaTotalThis', '산재 해당연도 보수총액', '', 'number') + fld('iaTotalPrev', '산재 전년도 보수총액', '', 'number');
    }
    return h + '</div>';
  }
  function readForm() {
    const v = {}; document.querySelectorAll('#insFormPanel [id^=if_]').forEach(el => { v[el.id.slice(3)] = el.type === 'checkbox' ? el.checked : el.value.trim(); });
    v.rrn = rrnFmt(v.rrn); return v;
  }

  let state = null;
  function open(reqId) {
    const req = (typeof insuranceRequests !== 'undefined' ? insuranceRequests : []).find(r => r.id === reqId); if (!req) return;
    const details = (typeof insuranceDetails !== 'undefined' ? insuranceDetails : []).filter(d => d.insurance_request_id === reqId);
    openWith(req, details, '');
  }
  const addDay = d => { const t = new Date(d + 'T00:00:00Z'); t.setUTCDate(t.getUTCDate() + 1); return t.toISOString().slice(0, 10); };
  // 직원 목록에서 바로: 진행 중인 신고 요청이 있으면 그것을, 없으면 직원 정보로 새로 채웁니다.
  function openForEmployee(empId) {
    const emp = (typeof employees !== 'undefined' ? employees : []).find(e => e.id === empId); if (!emp) return;
    const type = emp.termination_date ? '상실' : '취득';
    const reqs = (typeof insuranceRequests !== 'undefined' ? insuranceRequests : []).filter(r => r.employee_id === empId && r.request_type === type && !['반려', '취소'].includes(r.status));
    const dets = typeof insuranceDetails !== 'undefined' ? insuranceDetails : [];
    const withDetails = reqs.find(r => dets.some(d => d.insurance_request_id === r.id));
    if (withDetails) return openWith(withDetails, dets.filter(d => d.insurance_request_id === withDetails.id), '이 직원의 신고 요청 내용으로 채웠습니다.');
    if (type === '취득' && !emp.hire_date) return alert('직원 정보에 입사일을 먼저 입력해 주세요(직원 목록 → 수정).');
    const date = type === '취득' ? emp.hire_date : addDay(emp.termination_date);
    const req = { id: 'emp-' + emp.id, employee_id: emp.id, request_type: type, national_pension: true, health_insurance: true, employment_insurance: true, industrial_accident: true, loss_reason: '' };
    const details = ORDER.map(t => ({ insurance_type: t, effective_date: date, remuneration_amount: emp.monthly_remuneration ?? '', weekly_hours: emp.weekly_hours ?? '', contract_end_date: null, occupation_code: '' }));
    openWith(req, details, (type === '상실' ? '퇴사일(' + emp.termination_date + ') 다음 날을 상실일로 적었습니다. ' : '') + '신고 요청 없이 직원 정보로 채웠습니다. 가입하지 않은 보험은 아래에서 체크를 빼 주세요.', true);
  }
  function openWith(req, details, note, editable) {
    const emp = (typeof employees !== 'undefined' ? employees : []).find(e => e.id === req.employee_id) || { name: '' };
    if (!details.length) return alert('보험별 상세 내용이 없습니다. 먼저 [검증]을 눌러 주세요.');
    const kind = req.request_type === '취득' ? 'acq' : req.request_type === '상실' ? 'loss' : null;
    if (!kind) return alert('신고서 출력은 취득·상실 신고만 지원합니다.');
    const co = typeof company !== 'undefined' ? company : null;
    const companyId = (typeof cloudCompanyId !== 'undefined' && cloudCompanyId) || 'default', companyName = (co && co.name && !String(co.name).startsWith('미지정')) ? co.name : '';
    const biz = loadBiz(companyId, companyName);
    const groups = lineGroups(details), d0 = groups[0].get('건강보험') || groups[0].rows[0];
    state = { req: { ...req }, emp, groups, kind, companyId, editable: !!editable, allDetails: details };
    const card = document.getElementById('insFormCard');
    document.getElementById('insFormTitle').textContent = '공단 신고서 출력 · ' + (emp.name || '-') + ' · 자격' + req.request_type;
    document.getElementById('insFormPanel').innerHTML = (editable ? '<h4>신고할 보험과 날짜</h4><div class="formgrid"><label>' + (kind === 'acq' ? '자격취득일' : '자격상실일(퇴사 다음 날)') + '<input id="ie_date" type="date" value="' + esc(groups[0].date) + '"></label>' + ORDER.map(t => '<label class="if-chk"><input type="checkbox" class="ie-ins" value="' + t + '" checked> ' + t + '</label>').join('') + (kind === 'loss' ? '<label>상실사유<input id="ie_reason" list="lossReasonList" placeholder="목록에서 고르거나 직접 입력"></label>' : '') + '</div>' : '') + panelHtml(kind, biz, emp, req, groups, d0);
    state.note = [note, groups.length > 1 ? '보험별 날짜가 달라 서식 안내대로 ' + groups.length + '줄로 나눠 적습니다.' : ''].filter(Boolean).join(' ');
    document.getElementById('insFormMsg').textContent = state.note;
    card.hidden = false; preview(); card.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
  function syncEditable() {
    if (!state || !state.editable) return;
    const date = document.getElementById('ie_date')?.value || state.groups[0].date;
    const on = new Set([...document.querySelectorAll('.ie-ins:checked')].map(x => x.value));
    const base = state.allDetails[0];
    state.groups = on.size ? lineGroups([...on].map(t => ({ ...base, insurance_type: t, effective_date: date }))) : [];
    state.req.health_insurance = on.has('건강보험'); state.req.national_pension = on.has('국민연금'); state.req.employment_insurance = on.has('고용보험'); state.req.industrial_accident = on.has('산재보험');
    const r = document.getElementById('ie_reason'); if (r) { const changed = state.req.loss_reason !== r.value.trim(); state.req.loss_reason = r.value.trim(); const rt = document.getElementById('if_reasonText'), ec = document.getElementById('if_eiCode'); if (changed && rt) rt.value = state.req.loss_reason; if (changed && ec && !ec.dataset.touched) ec.value = eiCodeFromReason(state.req.loss_reason); }
  }
  function ctx() {
    syncEditable();
    const f = readForm(); const biz = { name: f.name, mgmtNo: f.mgmtNo, addr: f.addr, zip: f.zip, tel: f.tel, fax: f.fax, agentNo: f.agentNo, agentName: f.agentName, signer: f.signer };
    saveBiz(state.companyId, biz);
    return { biz, emp: state.emp, req: state.req, groups: state.groups, f };
  }
  function preview() { if (!state) return; const c = ctx(); document.getElementById('insFormPreview').innerHTML = state.kind === 'acq' ? acqHtml(c) : lossHtml(c); }
  function print() {
    if (!state) return; const c = ctx(), miss = [];
    if (!state.groups.length) miss.push('신고할 보험(하나 이상)');
    if (!c.biz.mgmtNo) miss.push('사업장관리번호'); if (!c.f.rrn || c.f.rrn.replace(/\D/g, '').length !== 13) miss.push('주민등록번호 13자리');
    if (state.kind === 'loss' && (state.req.employment_insurance || state.req.industrial_accident) && !c.f.eiCode) miss.push('고용보험 상실사유 구분코드');
    if (miss.length) { document.getElementById('insFormMsg').textContent = '인쇄 전에 입력해 주세요: ' + miss.join(', '); return; }
    let box = document.getElementById('insPrint'); if (!box) { box = document.createElement('div'); box.id = 'insPrint'; document.body.appendChild(box); }
    box.innerHTML = state.kind === 'acq' ? acqHtml(c) : lossHtml(c);
    document.body.classList.add('ins-printing'); root.print();
  }
  function close() { state = null; document.getElementById('insFormCard').hidden = true; document.getElementById('insFormPreview').innerHTML = ''; const b = document.getElementById('insPrint'); if (b) b.innerHTML = ''; }
  root.addEventListener('afterprint', () => { document.body.classList.remove('ins-printing'); const b = document.getElementById('insPrint'); if (b) b.innerHTML = ''; });
  document.addEventListener('input', e => { if (e.target.closest && e.target.closest('#insFormPanel')) { if (e.target.id === 'if_rrn') e.target.value = rrnFmt(e.target.value); preview(); } });
  document.addEventListener('change', e => { if (e.target.closest && e.target.closest('#insFormPanel')) { if (e.target.id === 'if_eiCode') e.target.dataset.touched = '1'; preview(); } });

  root.DHInsuranceForms = { open, openForEmployee, print, close, lineGroups, eiCodeFromReason, CODES, acqHtml, lossHtml };
})(typeof window !== 'undefined' ? window : globalThis);

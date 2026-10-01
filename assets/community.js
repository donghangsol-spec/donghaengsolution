// 복지커뮤니티 게시판 — 목록(/community), 글 보기(/community/post), 글쓰기(/community/write)
// 데이터는 Supabase(community_posts, community_comments)와 RPC로만 다룬다.
// 사용자 입력은 모두 textContent로 넣는다 (HTML 문자열로 넣지 않는다).
(function (root) {
  'use strict';

  const CATEGORIES = {
    notice: { label: '공지사항', template: 'notice', adminOnly: true },
    library: { label: '자료실', template: 'resource', adminOnly: true },
    info: { label: '정보공유', template: 'free', adminOnly: false },
    story: { label: '현장이야기', template: 'free', adminOnly: false },
    qna: { label: '질문답변', template: 'free', adminOnly: false },
  };
  const CATEGORY_ORDER = ['notice', 'library', 'info', 'story', 'qna'];
  const AUDIENCES = ['전체', '종합사회복지관', '노인복지시설', '장애인복지시설', '아동·청소년시설', '지역아동센터'];
  const RESOURCE_TYPES = ['체크리스트', '서식 · 양식', '법령 · 지침 정리', '교육 자료', '사례 정리'];
  const DEFAULT_CONTACT = '동행솔루션 042-673-3338';
  const PAGE_SIZE = 15;
  const BUCKET = 'community-files';
  const MAX_FILE_BYTES = 20 * 1024 * 1024;

  function pad(n) { return String(n).padStart(2, '0'); }

  function formatDate(iso) {
    const day = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ''));
    if (day) return `${day[1]}.${day[2]}.${day[3]}`;
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return '';
    return `${d.getFullYear()}.${pad(d.getMonth() + 1)}.${pad(d.getDate())}`;
  }

  function formatRelative(iso, now) {
    const d = new Date(iso);
    const ref = now ? new Date(now) : new Date();
    const diff = (ref.getTime() - d.getTime()) / 1000;
    if (Number.isNaN(diff)) return '';
    if (diff < 60) return '방금 전';
    if (diff < 3600) return `${Math.floor(diff / 60)}분 전`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}시간 전`;
    return formatDate(iso);
  }

  function isNew(iso, now) {
    const ref = now ? new Date(now) : new Date();
    return ref.getTime() - new Date(iso).getTime() < 3 * 86400 * 1000;
  }

  function formatSize(bytes) {
    const n = Number(bytes) || 0;
    if (n <= 0) return '';
    if (n < 1024) return `${n}B`;
    if (n < 1024 * 1024) return `${Math.round(n / 1024)}KB`;
    return `${(n / 1024 / 1024).toFixed(1)}MB`;
  }

  function fileExtension(name) {
    const m = /\.([A-Za-z0-9]{1,8})$/.exec(String(name || ''));
    return m ? m[1].toLowerCase() : '';
  }

  function templateFor(category) {
    return CATEGORIES[category] ? CATEGORIES[category].template : 'free';
  }

  function allowedCategories(viewer) {
    if (!viewer) return [];
    if (viewer.is_admin) return CATEGORY_ORDER.slice();
    if (viewer.is_member) return CATEGORY_ORDER.filter((c) => !CATEGORIES[c].adminOnly);
    return [];
  }

  // 댓글 목록을 [{...댓글, replies: [...]}] 로 묶는다.
  // 삭제된 댓글은 답글이 남아 있을 때만 자리를 남긴다.
  function buildCommentTree(rows) {
    const top = [];
    const byId = new Map();
    for (const row of rows || []) {
      if (!row.parent_id) {
        const node = Object.assign({}, row, { replies: [] });
        byId.set(row.id, node);
        top.push(node);
      }
    }
    for (const row of rows || []) {
      if (row.parent_id && row.status === 'published' && byId.has(row.parent_id)) {
        byId.get(row.parent_id).replies.push(row);
      }
    }
    return top.filter((c) => c.status === 'published' || c.replies.length > 0);
  }

  // 검색어를 ilike 패턴 안에 안전하게 넣는다.
  function likePattern(query) {
    const q = String(query || '').trim().slice(0, 50).replace(/[\\%_]/g, (ch) => `\\${ch}`);
    return q ? `%${q}%` : '';
  }

  // 로그인 후 돌아올 경로: 커뮤니티 안쪽 경로만 허용
  function safeReturnPath(path) {
    const p = String(path || '');
    return /^\/community(\/[A-Za-z]*)?(\?[A-Za-z0-9=&_%-]*)?$/.test(p) ? p : '/community';
  }

  // 글쓰기 폼 값 → 서버로 보낼 값 (서버도 같은 규칙으로 다시 검사한다)
  function buildPostPayload(values) {
    const category = values.category;
    const template = templateFor(category);
    const trim = (v) => String(v == null ? '' : v).trim();
    const payload = {
      category,
      title: trim(values.title),
      body: String(values.body == null ? '' : values.body).replace(/\s+$/, ''),
      allow_comments: values.allow_comments !== false,
      is_pinned: !!values.is_pinned,
      attachments: Array.isArray(values.attachments) ? values.attachments : [],
    };
    if (template === 'resource') {
      payload.summary = trim(values.summary);
      payload.audiences = (values.audiences || []).map(trim).filter(Boolean);
      payload.reference_date = trim(values.reference_date);
      payload.resource_type = trim(values.resource_type);
      payload.key_points = (values.key_points || []).map(trim).filter(Boolean).slice(0, 8);
      payload.source_ref = trim(values.source_ref);
    }
    if (template === 'notice') {
      payload.event_period = trim(values.event_period);
      payload.notice_target = trim(values.notice_target);
      payload.contact = trim(values.contact);
    }
    return payload;
  }

  function validatePostPayload(payload) {
    if (!CATEGORIES[payload.category]) return '분류를 선택해 주세요.';
    if (payload.title.length < 2 || payload.title.length > 120) return '제목은 2~120자로 입력해 주세요.';
    const template = templateFor(payload.category);
    if (template === 'resource' && !payload.summary) return '자료 양식은 한 줄 요약이 필요합니다.';
    if (template === 'resource' && payload.summary.length > 200) return '한 줄 요약은 200자 이내로 입력해 주세요.';
    if (template !== 'resource' && !payload.body.trim()) return '본문을 입력해 주세요.';
    if (payload.body.length > 20000) return '본문이 너무 깁니다.';
    return null;
  }

  function friendlyError(error) {
    const msg = (error && error.message) || '';
    if (/[가-힣]/.test(msg)) return msg;
    if (/JWT|auth/i.test(msg)) return '로그인이 만료되었습니다. 다시 로그인해 주세요.';
    return '요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.';
  }

  const helpers = {
    CATEGORIES, CATEGORY_ORDER, AUDIENCES, RESOURCE_TYPES, DEFAULT_CONTACT, PAGE_SIZE,
    formatDate, formatRelative, isNew, formatSize, fileExtension, templateFor, allowedCategories,
    buildCommentTree, likePattern, safeReturnPath, buildPostPayload, validatePostPayload, friendlyError,
  };
  root.DHCommunity = helpers;

  if (typeof document === 'undefined') return;

  // ------------------------------------------------------------------
  // 브라우저 공통
  // ------------------------------------------------------------------
  const $ = (sel, el) => (el || document).querySelector(sel);

  function h(tag, attrs, children) {
    const el = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs || {})) {
      if (value == null || value === false) continue;
      if (key === 'class') el.className = value;
      else if (key === 'text') el.textContent = value;
      else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
      else el.setAttribute(key, value === true ? '' : value);
    }
    for (const child of [].concat(children || [])) {
      if (child == null || child === false) continue;
      el.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return el;
  }

  function badge(category) {
    const c = CATEGORIES[category];
    return h('span', { class: `cm-badge cm-badge-${category}`, text: c ? c.label : category });
  }

  function paragraphs(text) {
    return String(text || '').split(/\n{2,}/).filter((p) => p.trim()).map((p) => h('p', { text: p }));
  }

  function showFatal(container, message) {
    container.replaceChildren(h('div', { class: 'cm-empty', role: 'alert', text: message }));
  }

  function loginHref() {
    return `/app?return=${encodeURIComponent(location.pathname + location.search)}`;
  }

  function createClient() {
    const cfg = root.__DONGHAENG_CONFIG__;
    if (!cfg || !cfg.supabaseUrl || !cfg.supabaseAnonKey || !root.supabase) return null;
    return root.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
      auth: { persistSession: true, detectSessionInUrl: false },
    });
  }

  async function loadViewer(sb) {
    const { data, error } = await sb.rpc('community_viewer');
    if (error || !data) return { signed_in: false, is_admin: false, is_member: false };
    return data;
  }

  function renderAuthArea(sb, viewer) {
    const area = $('#cmAuth');
    if (!area) return;
    if (!viewer.signed_in) {
      area.replaceChildren(h('a', { href: loginHref(), text: '로그인 ↗' }));
      return;
    }
    const label = viewer.is_admin ? '운영자' : (viewer.label || '승인 대기');
    area.replaceChildren(
      h('span', { class: 'cm-auth-label', text: label }),
      h('button', {
        type: 'button', class: 'cm-linkbtn', text: '로그아웃',
        onclick: async () => { await sb.auth.signOut(); location.reload(); },
      }),
    );
  }

  async function boot(init) {
    const main = $('#main');
    const sb = createClient();
    if (!sb) {
      showFatal($('[data-cm-root]') || main, '게시판 설정을 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.');
      return;
    }
    const viewer = await loadViewer(sb);
    renderAuthArea(sb, viewer);
    try {
      await init(sb, viewer);
    } catch (error) {
      console.error(error);
      showFatal($('[data-cm-root]') || main, friendlyError(error));
    }
  }

  // ------------------------------------------------------------------
  // 목록
  // ------------------------------------------------------------------
  const LIST_COLUMNS = 'id,category,title,author_label,is_official,created_at,view_count,comment_count,attachments,is_pinned';

  function postRow(post, pinned) {
    const files = Array.isArray(post.attachments) ? post.attachments.length : 0;
    return h('li', null, h('a', { class: `cm-row${pinned ? ' cm-row-pinned' : ''}`, href: `/community/post?id=${post.id}` }, [
      pinned ? h('span', { class: 'cm-pin', 'aria-label': '상단 고정', text: '고정' }) : null,
      h('div', { class: 'cm-row-main' }, [
        h('div', { class: 'cm-row-title' }, [
          badge(post.category),
          h('strong', { text: post.title }),
          post.comment_count > 0 ? h('span', { class: 'cm-count', 'aria-label': `댓글 ${post.comment_count}개`, text: `[${post.comment_count}]` }) : null,
          files ? h('span', { class: 'cm-file', text: '첨부' }) : null,
          isNew(post.created_at) ? h('span', { class: 'cm-new', 'aria-label': '새 글', text: 'N' }) : null,
        ]),
        h('div', { class: 'cm-meta', text: `${post.author_label} · ${formatDate(post.created_at)} · 조회 ${post.view_count}` }),
      ]),
    ]));
  }

  async function initList(sb, viewer) {
    const params = new URLSearchParams(location.search);
    let category = CATEGORIES[params.get('cat')] ? params.get('cat') : 'all';
    let query = (params.get('q') || '').slice(0, 50);
    let page = Math.max(1, parseInt(params.get('page'), 10) || 1);

    const tabs = $('#cmTabs');
    const list = $('#cmList');
    const pager = $('#cmPager');
    const search = $('#cmSearch');
    const status = $('#cmStatus');
    search.value = query;

    const writeSlot = $('#cmWrite');
    if (allowedCategories(viewer).length) {
      writeSlot.replaceChildren(h('a', { class: 'button orange', href: '/community/write', text: '글쓰기' }));
    } else if (!viewer.signed_in) {
      writeSlot.replaceChildren(h('a', { class: 'button navy', href: loginHref(), text: '로그인하고 참여하기' }));
    }

    function syncUrl() {
      const p = new URLSearchParams();
      if (category !== 'all') p.set('cat', category);
      if (query) p.set('q', query);
      if (page > 1) p.set('page', String(page));
      const qs = p.toString();
      history.replaceState(null, '', qs ? `?${qs}` : location.pathname);
    }

    function renderTabs() {
      const items = [['all', '전체']].concat(CATEGORY_ORDER.map((c) => [c, CATEGORIES[c].label]));
      tabs.replaceChildren(...items.map(([id, label]) => h('button', {
        type: 'button', role: 'tab', class: 'cm-tab', 'aria-selected': String(id === category), text: label,
        onclick: () => { category = id; page = 1; load(); },
      })));
    }

    function filtered(q) {
      let out = q.eq('status', 'published');
      if (category !== 'all') out = out.eq('category', category);
      const pattern = likePattern(query);
      if (pattern) out = out.ilike('title', pattern);
      return out;
    }

    async function load() {
      renderTabs();
      syncUrl();
      list.setAttribute('aria-busy', 'true');
      const from = (page - 1) * PAGE_SIZE;
      const [pinnedRes, listRes] = await Promise.all([
        page === 1 ? filtered(sb.from('community_posts').select(LIST_COLUMNS)).eq('is_pinned', true).order('created_at', { ascending: false }).limit(5) : Promise.resolve({ data: [] }),
        filtered(sb.from('community_posts').select(LIST_COLUMNS, { count: 'exact' })).eq('is_pinned', false)
          .order('created_at', { ascending: false }).range(from, from + PAGE_SIZE - 1),
      ]);
      list.removeAttribute('aria-busy');
      if (listRes.error || pinnedRes.error) {
        showFatal(list, friendlyError(listRes.error || pinnedRes.error));
        pager.replaceChildren();
        return;
      }
      const rows = (pinnedRes.data || []).map((p) => postRow(p, true)).concat((listRes.data || []).map((p) => postRow(p, false)));
      list.replaceChildren(...(rows.length ? rows : [h('li', { class: 'cm-empty', text: query ? '검색 결과가 없습니다.' : '아직 게시글이 없습니다.' })]));
      status.textContent = `${listRes.count || 0}개의 글`;
      renderPager(Math.max(1, Math.ceil((listRes.count || 0) / PAGE_SIZE)));
    }

    function renderPager(pages) {
      if (pages <= 1) { pager.replaceChildren(); return; }
      const start = Math.max(1, Math.min(page - 2, pages - 4));
      const end = Math.min(pages, start + 4);
      const go = (n) => () => { page = n; load(); window.scrollTo({ top: tabs.offsetTop - 120 }); };
      const items = [h('button', { type: 'button', class: 'cm-page', 'aria-label': '이전 페이지', disabled: page === 1, onclick: go(page - 1), text: '‹' })];
      for (let n = start; n <= end; n++) {
        items.push(h('button', { type: 'button', class: 'cm-page', 'aria-current': n === page ? 'page' : null, onclick: go(n), text: String(n) }));
      }
      items.push(h('button', { type: 'button', class: 'cm-page', 'aria-label': '다음 페이지', disabled: page === pages, onclick: go(page + 1), text: '›' }));
      pager.replaceChildren(...items);
    }

    let timer;
    search.addEventListener('input', () => {
      clearTimeout(timer);
      timer = setTimeout(() => { query = search.value.trim().slice(0, 50); page = 1; load(); }, 300);
    });
    $('#cmSearchForm').addEventListener('submit', (e) => { e.preventDefault(); query = search.value.trim().slice(0, 50); page = 1; load(); });

    await load();

    const popular = $('#cmPopular');
    const { data: top } = await sb.from('community_posts').select('id,title').eq('status', 'published')
      .order('view_count', { ascending: false }).order('created_at', { ascending: false }).limit(5);
    if (top && top.length) {
      popular.replaceChildren(...top.map((p, i) => h('li', null, [
        h('span', { class: 'cm-rank', text: String(i + 1) }),
        h('a', { href: `/community/post?id=${p.id}`, text: p.title }),
      ])));
    } else {
      popular.replaceChildren(h('li', { class: 'cm-muted', text: '아직 게시글이 없습니다.' }));
    }
  }

  // ------------------------------------------------------------------
  // 글 보기 + 댓글
  // ------------------------------------------------------------------
  function infoGrid(items) {
    const shown = items.filter(([, value]) => value && (!Array.isArray(value) || value.length));
    if (!shown.length) return null;
    return h('dl', { class: 'cm-info' }, shown.map(([label, value]) => h('div', null, [
      h('dt', { text: label }),
      h('dd', null, Array.isArray(value) ? value.map((v) => h('span', { class: 'cm-chip', text: v })) : value),
    ])));
  }

  function renderPostBody(sb, post) {
    const parts = [];
    if (post.template === 'resource') {
      if (post.summary) {
        parts.push(h('div', { class: 'cm-summary' }, [h('span', { class: 'eyebrow', text: '한 줄 요약' }), h('p', { text: post.summary })]));
      }
      parts.push(infoGrid([
        ['대상', post.audiences],
        ['기준일', post.reference_date ? formatDate(post.reference_date) : ''],
        ['자료 유형', post.resource_type],
      ]));
      if (post.key_points && post.key_points.length) {
        parts.push(h('section', { class: 'cm-block' }, [
          h('h2', { text: '핵심 내용' }),
          h('ol', { class: 'cm-points' }, post.key_points.map((p, i) => h('li', null, [h('span', { text: pad(i + 1) }), h('span', { text: p })]))),
        ]));
      }
      if (post.body && post.body.trim()) {
        parts.push(h('section', { class: 'cm-block cm-body' }, [h('h2', { text: '상세 설명' })].concat(paragraphs(post.body))));
      }
    } else {
      if (post.template === 'notice') {
        parts.push(infoGrid([['일시 · 기간', post.event_period], ['대상', post.notice_target], ['문의처', post.contact]]));
      }
      parts.push(h('div', { class: 'cm-body' }, paragraphs(post.body)));
    }
    const files = Array.isArray(post.attachments) ? post.attachments : [];
    if (files.length) {
      parts.push(h('section', { class: 'cm-block' }, [
        h('h2', { text: '첨부 자료' }),
        h('ul', { class: 'cm-files' }, files.map((f) => {
          const url = sb.storage.from(BUCKET).getPublicUrl(f.path).data.publicUrl;
          return h('li', null, h('a', { href: url, target: '_blank', rel: 'noopener', download: f.name }, [
            h('span', { class: 'cm-ext', text: (fileExtension(f.name) || 'file').toUpperCase() }),
            h('span', { class: 'cm-file-name' }, [h('strong', { text: f.name }), h('small', { text: formatSize(f.size) })]),
          ]));
        })),
      ]));
    }
    if (post.template === 'resource' && post.source_ref) {
      parts.push(h('p', { class: 'cm-source' }, [h('strong', { text: '출처 · 참고 ' }), post.source_ref]));
    }
    return parts;
  }

  async function initPost(sb, viewer) {
    const rootEl = $('[data-cm-root]');
    const id = new URLSearchParams(location.search).get('id') || '';
    if (!/^[0-9a-f-]{36}$/i.test(id)) { showFatal(rootEl, '글을 찾을 수 없습니다.'); return; }

    const { data: post, error } = await sb.from('community_posts').select('*').eq('id', id).maybeSingle();
    if (error) throw error;
    if (!post) { showFatal(rootEl, '삭제되었거나 없는 글입니다.'); return; }

    try {
      const key = `cm-viewed-${id}`;
      if (!sessionStorage.getItem(key)) {
        sessionStorage.setItem(key, '1');
        sb.rpc('community_record_view', { p_id: id }).then(() => {}, () => {});
      }
    } catch (_) { /* 저장소를 못 쓰는 브라우저는 조회수만 건너뜀 */ }

    document.title = `${post.title} | 복지커뮤니티 | 동행솔루션`;
    $('#cmCrumbCat').textContent = CATEGORIES[post.category] ? CATEGORIES[post.category].label : '';
    $('#cmCrumbCat').href = `/community?cat=${post.category}`;

    const isOwner = viewer.signed_in && viewer.user_id === post.author_id;
    const actions = [];
    if (isOwner || viewer.is_admin) {
      actions.push(h('a', { class: 'cm-linkbtn', href: `/community/write?id=${post.id}`, text: '수정' }));
      actions.push(h('button', {
        type: 'button', class: 'cm-linkbtn cm-danger', text: '삭제',
        onclick: async () => {
          if (!confirm('이 글을 삭제할까요?')) return;
          const { error: e } = await sb.rpc('community_set_post_status', { p_id: post.id, p_status: 'hidden' });
          if (e) alert(friendlyError(e)); else location.href = '/community';
        },
      }));
    }
    if (viewer.is_admin && post.status === 'hidden') {
      actions.push(h('button', {
        type: 'button', class: 'cm-linkbtn', text: '다시 게시',
        onclick: async () => {
          const { error: e } = await sb.rpc('community_set_post_status', { p_id: post.id, p_status: 'published' });
          if (e) alert(friendlyError(e)); else location.reload();
        },
      }));
    }

    const article = $('#cmArticle');
    article.replaceChildren(
      h('header', { class: 'cm-post-head' }, [
        h('div', { class: 'cm-row-title' }, [
          badge(post.category),
          post.template === 'resource' && post.resource_type ? h('span', { class: 'cm-badge cm-badge-outline', text: post.resource_type }) : null,
          post.is_pinned ? h('span', { class: 'cm-pin', text: '상단 고정' }) : null,
          post.status === 'hidden' ? h('span', { class: 'cm-badge cm-badge-hidden', text: '숨김' }) : null,
        ]),
        h('h1', { text: post.title }),
        h('div', { class: 'cm-meta cm-post-meta' }, [
          h('strong', null, [post.author_label, post.is_official ? h('span', { class: 'cm-official', text: '운영자' }) : null]),
          h('span', { text: formatDate(post.created_at) }),
          h('span', { text: `조회 ${post.view_count}` }),
          h('span', { id: 'cmMetaComments', text: `댓글 ${post.comment_count}` }),
          actions.length ? h('span', { class: 'cm-actions' }, actions) : null,
        ]),
      ]),
      ...renderPostBody(sb, post).filter(Boolean),
    );

    await initComments(sb, viewer, post);
  }

  // 운영자에게 새 댓글 메일 알림 (실패해도 댓글 등록에는 영향 없음)
  async function notifyComment(sb, commentId) {
    try {
      const { data } = await sb.auth.getSession();
      const token = data && data.session && data.session.access_token;
      if (!token || !commentId) return;
      await fetch('/api/community-notify', {
        method: 'POST',
        keepalive: true,
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ comment_id: commentId }),
      });
    } catch (_) { /* 알림 실패는 조용히 넘긴다 */ }
  }

  async function initComments(sb, viewer, post) {
    const list = $('#cmComments');
    const count = $('#cmCommentCount');
    const formSlot = $('#cmCommentForm');
    let replyTo = null;

    const canComment = viewer.is_admin || (viewer.is_member && post.allow_comments);

    function composer(parentId, onDone) {
      const id = parentId ? `reply-${parentId}` : 'cmBody';
      const textarea = h('textarea', { id, rows: parentId ? '2' : '3', maxlength: '500', placeholder: parentId ? '답글을 입력하세요' : '의견을 남겨 주세요. 이용자 개인정보(성명·연락처 등)는 적지 말아 주세요.' });
      const counter = h('span', { class: 'cm-muted', text: '0 / 500' });
      const msg = h('span', { class: 'cm-error', role: 'status' });
      const button = h('button', { type: 'submit', class: 'button orange small', text: parentId ? '답글 등록' : '댓글 등록' });
      textarea.addEventListener('input', () => { counter.textContent = `${textarea.value.length} / 500`; });
      const form = h('form', { class: parentId ? 'cm-composer cm-composer-reply' : 'cm-composer' }, [
        h('label', { for: id, class: parentId ? 'cm-sr' : 'cm-composer-label', text: parentId ? '답글' : `${viewer.is_admin ? '운영자(동행솔루션)' : viewer.label}으로 작성` }),
        textarea,
        h('div', { class: 'cm-composer-foot' }, [counter, msg, button]),
      ]);
      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const body = textarea.value.trim();
        if (!body) { msg.textContent = '내용을 입력해 주세요.'; return; }
        button.disabled = true;
        msg.textContent = '';
        const { data: commentId, error } = await sb.rpc('community_add_comment', { p_post_id: post.id, p_parent_id: parentId, p_body: body });
        button.disabled = false;
        if (error) { msg.textContent = friendlyError(error); return; }
        if (!viewer.is_admin) notifyComment(sb, commentId);
        textarea.value = '';
        counter.textContent = '0 / 500';
        onDone();
      });
      return form;
    }

    function renderComposer() {
      if (canComment) {
        formSlot.replaceChildren(composer(null, () => load()));
      } else if (!post.allow_comments) {
        formSlot.replaceChildren(h('p', { class: 'cm-notice', text: '댓글이 닫힌 글입니다.' }));
      } else if (!viewer.signed_in) {
        formSlot.replaceChildren(h('p', { class: 'cm-notice' }, [
          '댓글은 가입 승인된 회원 기관 담당자만 쓸 수 있습니다. ',
          h('a', { href: loginHref(), text: '로그인하기 ↗' }),
        ]));
      } else {
        formSlot.replaceChildren(h('p', { class: 'cm-notice', text: '가입 승인 후 댓글을 쓸 수 있습니다. 승인 관련 문의는 고객지원으로 연락해 주세요.' }));
      }
    }

    function deleteButton(comment) {
      if (!(viewer.is_admin || (viewer.signed_in && viewer.user_id === comment.author_id))) return null;
      return h('button', {
        type: 'button', class: 'cm-linkbtn cm-danger', text: '삭제',
        onclick: async () => {
          if (!confirm('이 댓글을 삭제할까요?')) return;
          const { error } = await sb.rpc('community_delete_comment', { p_id: comment.id });
          if (error) alert(friendlyError(error)); else load();
        },
      });
    }

    function commentHead(c) {
      return h('div', { class: 'cm-comment-head' }, [
        h('strong', { text: c.author_label }),
        c.is_official ? h('span', { class: 'cm-official', text: '운영자' }) : null,
        h('span', { class: 'cm-muted', text: formatRelative(c.created_at) }),
      ]);
    }

    function renderComment(c) {
      if (c.status !== 'published') {
        return h('li', { class: 'cm-comment' }, [
          h('p', { class: 'cm-muted', text: c.status === 'hidden' ? '운영자가 숨긴 댓글입니다.' : '삭제된 댓글입니다.' }),
          renderReplies(c),
        ]);
      }
      const tools = h('div', { class: 'cm-comment-tools' }, [
        canComment ? h('button', {
          type: 'button', class: 'cm-linkbtn', 'aria-expanded': String(replyTo === c.id), text: '답글',
          onclick: () => { replyTo = replyTo === c.id ? null : c.id; render(lastRows); },
        }) : null,
        deleteButton(c),
      ]);
      return h('li', { class: 'cm-comment' }, [
        commentHead(c),
        h('p', { class: 'cm-comment-body', text: c.body }),
        tools,
        renderReplies(c),
        replyTo === c.id ? composer(c.id, () => { replyTo = null; load(); }) : null,
      ]);
    }

    function renderReplies(c) {
      if (!c.replies.length) return null;
      return h('ul', { class: 'cm-replies' }, c.replies.map((r) => h('li', { class: 'cm-reply' }, [
        commentHead(r),
        h('p', { class: 'cm-comment-body', text: r.body }),
        h('div', { class: 'cm-comment-tools' }, [deleteButton(r)]),
      ])));
    }

    let lastRows = [];
    function render(rows) {
      lastRows = rows;
      const tree = buildCommentTree(rows);
      const total = rows.filter((r) => r.status === 'published').length;
      count.textContent = String(total);
      const meta = $('#cmMetaComments');
      if (meta) meta.textContent = `댓글 ${total}`;
      list.replaceChildren(...(tree.length ? tree.map(renderComment) : [h('li', { class: 'cm-empty', text: '첫 댓글을 남겨 주세요.' })]));
      const open = replyTo && document.getElementById(`reply-${replyTo}`);
      if (open) open.focus();
    }

    async function load() {
      const { data, error } = await sb.from('community_comments')
        .select('id,parent_id,author_id,author_label,is_official,body,status,created_at')
        .eq('post_id', post.id).order('created_at', { ascending: true }).limit(500);
      if (error) { showFatal(list, friendlyError(error)); return; }
      render(data || []);
    }

    renderComposer();
    await load();
  }

  // ------------------------------------------------------------------
  // 글쓰기 / 수정
  // ------------------------------------------------------------------
  async function initWrite(sb, viewer) {
    const rootEl = $('[data-cm-root]');
    const form = $('#cmForm');
    const f = form.elements;
    const allowed = allowedCategories(viewer);
    if (!viewer.signed_in) {
      showFatal(rootEl, '');
      rootEl.firstChild.append('글을 쓰려면 로그인이 필요합니다. ', h('a', { href: loginHref(), text: '로그인하기 ↗' }));
      return;
    }
    if (!allowed.length) { showFatal(rootEl, '가입 승인 후 글을 쓸 수 있습니다.'); return; }

    const editId = new URLSearchParams(location.search).get('id');
    let existing = null;
    if (editId) {
      if (!/^[0-9a-f-]{36}$/i.test(editId)) { showFatal(rootEl, '글을 찾을 수 없습니다.'); return; }
      const { data, error } = await sb.from('community_posts').select('*').eq('id', editId).maybeSingle();
      if (error) throw error;
      if (!data || !(viewer.is_admin || data.author_id === viewer.user_id)) { showFatal(rootEl, '수정할 수 없는 글입니다.'); return; }
      existing = data;
      $('#cmWriteTitle').textContent = '글 수정';
      document.title = '글 수정 | 복지커뮤니티 | 동행솔루션';
    }

    const state = {
      category: existing ? existing.category : (new URLSearchParams(location.search).get('cat') || allowed[0]),
      audiences: new Set(existing ? existing.audiences : []),
      keyPoints: existing && existing.key_points.length ? existing.key_points.slice() : ['', '', ''],
      attachments: existing ? (existing.attachments || []).slice() : [],
    };
    if (!allowed.includes(state.category)) state.category = allowed[0];

    // 기본 입력값
    f.title.value = existing ? existing.title : '';
    f.body.value = existing ? existing.body : '';
    f.summary.value = existing ? existing.summary || '' : '';
    f.reference_date.value = existing && existing.reference_date ? existing.reference_date : '';
    f.source_ref.value = existing ? existing.source_ref || '' : '';
    f.event_period.value = existing ? existing.event_period || '' : '';
    f.notice_target.value = existing ? existing.notice_target || '' : '';
    f.contact.value = existing ? existing.contact || '' : DEFAULT_CONTACT;
    f.allow_comments.checked = existing ? existing.allow_comments : true;
    f.is_pinned.checked = existing ? existing.is_pinned : false;
    f.resource_type.replaceChildren(...RESOURCE_TYPES.map((t) => h('option', { value: t, text: t })));
    f.resource_type.value = existing && existing.resource_type ? existing.resource_type : RESOURCE_TYPES[0];
    $('#cmPinField').hidden = !viewer.is_admin;
    $('#cmFilesField').hidden = !viewer.is_admin;

    function renderCategories() {
      $('#cmCategories').replaceChildren(...allowed.map((c) => h('button', {
        type: 'button', class: 'cm-tab', 'aria-pressed': String(c === state.category), text: CATEGORIES[c].label,
        onclick: () => { state.category = c; renderCategories(); renderTemplate(); },
      })));
    }

    function renderTemplate() {
      const t = templateFor(state.category);
      $('#cmResourceFields').hidden = t !== 'resource';
      $('#cmNoticeFields').hidden = t !== 'notice';
      $('#cmTemplateName').textContent = t === 'resource' ? '자료 양식' : t === 'notice' ? '공지 양식' : '자유 형식';
      $('#cmBodyLabel').textContent = t === 'resource' ? '상세 설명 (선택)' : '본문';
    }

    function renderAudiences() {
      $('#cmAudiences').replaceChildren(...AUDIENCES.map((a) => {
        const input = h('input', { type: 'checkbox', value: a, checked: state.audiences.has(a) });
        input.addEventListener('change', () => { if (input.checked) state.audiences.add(a); else state.audiences.delete(a); });
        return h('label', { class: 'cm-check' }, [input, h('span', { text: a })]);
      }));
    }

    function renderPoints() {
      const wrap = $('#cmPoints');
      wrap.replaceChildren(...state.keyPoints.map((value, i) => {
        const input = h('input', { type: 'text', maxlength: '200', id: `cmPoint${i}`, placeholder: '한 줄로 적어 주세요' });
        input.value = value;
        input.addEventListener('input', () => { state.keyPoints[i] = input.value; });
        return h('div', { class: 'cm-point' }, [
          h('label', { for: `cmPoint${i}`, text: pad(i + 1) }),
          input,
          state.keyPoints.length > 1 ? h('button', {
            type: 'button', class: 'cm-linkbtn', 'aria-label': `${i + 1}번 항목 삭제`, text: '삭제',
            onclick: () => { state.keyPoints.splice(i, 1); renderPoints(); },
          }) : null,
        ]);
      }));
      $('#cmAddPoint').hidden = state.keyPoints.length >= 8;
    }
    $('#cmAddPoint').addEventListener('click', () => {
      state.keyPoints.push('');
      renderPoints();
      const last = document.getElementById(`cmPoint${state.keyPoints.length - 1}`);
      if (last) last.focus();
    });

    function renderFiles() {
      $('#cmFileList').replaceChildren(...state.attachments.map((f, i) => h('li', null, [
        h('span', { text: `${f.name} ${formatSize(f.size)}` }),
        h('button', {
          type: 'button', class: 'cm-linkbtn cm-danger', text: '빼기',
          onclick: () => { state.attachments.splice(i, 1); renderFiles(); },
        }),
      ])));
    }

    const fileInput = $('#cmFiles');
    const fileStatus = $('#cmFileStatus');
    fileInput.addEventListener('change', async () => {
      const files = Array.from(fileInput.files || []);
      fileInput.value = '';
      for (const file of files) {
        if (state.attachments.length >= 10) { fileStatus.textContent = '첨부파일은 10개까지 올릴 수 있습니다.'; break; }
        if (file.size > MAX_FILE_BYTES) { fileStatus.textContent = `${file.name}: 20MB 이하 파일만 올릴 수 있습니다.`; continue; }
        fileStatus.textContent = `${file.name} 올리는 중…`;
        const ext = fileExtension(file.name);
        const path = `posts/${new Date().getFullYear()}/${crypto.randomUUID()}${ext ? `.${ext}` : ''}`;
        const { error } = await sb.storage.from(BUCKET).upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false });
        if (error) { fileStatus.textContent = `${file.name}: 올리지 못했습니다. 파일 형식을 확인해 주세요.`; continue; }
        state.attachments.push({ path, name: file.name.slice(0, 200), size: file.size });
        fileStatus.textContent = '';
        renderFiles();
      }
    });

    renderCategories();
    renderTemplate();
    renderAudiences();
    renderPoints();
    renderFiles();
    form.hidden = false;

    const msg = $('#cmFormMsg');
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const payload = buildPostPayload({
        category: state.category,
        title: f.title.value,
        body: f.body.value,
        summary: f.summary.value,
        audiences: Array.from(state.audiences),
        reference_date: f.reference_date.value,
        resource_type: f.resource_type.value,
        key_points: state.keyPoints,
        source_ref: f.source_ref.value,
        event_period: f.event_period.value,
        notice_target: f.notice_target.value,
        contact: f.contact.value,
        is_pinned: viewer.is_admin && f.is_pinned.checked,
        allow_comments: f.allow_comments.checked,
        attachments: state.attachments,
      });
      const invalid = validatePostPayload(payload);
      if (invalid) { msg.textContent = invalid; return; }
      const submit = $('#cmSubmit');
      submit.disabled = true;
      msg.textContent = '저장하는 중입니다.';
      const { data, error } = await sb.rpc('community_save_post', { p_id: existing ? existing.id : null, p_post: payload });
      submit.disabled = false;
      if (error) { msg.textContent = friendlyError(error); return; }
      location.href = `/community/post?id=${data}`;
    });
  }

  const pages = { list: initList, post: initPost, write: initWrite };
  document.addEventListener('DOMContentLoaded', () => {
    const page = document.body.dataset.cmPage;
    if (pages[page]) boot(pages[page]);
  });
})(typeof window !== 'undefined' ? window : globalThis);

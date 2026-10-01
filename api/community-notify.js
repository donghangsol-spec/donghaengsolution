// 복지커뮤니티 새 댓글 알림 메일
// 브라우저가 댓글 등록 직후 { comment_id }와 작성자 로그인 토큰을 보내면,
// 작성자 본인 권한으로 알림 권리를 한 번만 받아(community_claim_comment_notification)
// 운영자에게 Resend로 메일을 보낸다. 받는 주소는 환경변수에만 있다.
const SITE_URL = 'https://donghangsolution.co.kr';

const oneLine = (value, max) => String(value || '').replace(/[\r\n]+/g, ' ').trim().slice(0, max);

async function rpc(name, args, token) {
  const base = String(process.env.SUPABASE_URL || '').replace(/\/$/, '');
  return fetch(`${base}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: process.env.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  });
}

export function buildCommentEmail(info) {
  const title = oneLine(info.post_title, 80);
  const author = oneLine(info.author_label, 60) || '회원';
  const kind = info.is_reply ? '답글' : '댓글';
  const link = `${SITE_URL}/community/post?id=${encodeURIComponent(info.post_id)}`;
  return {
    subject: `[복지커뮤니티 ${kind}] ${title}`,
    text: `${author}님이 새 ${kind}을 남겼습니다.\n\n글: ${title}\n\n${String(info.body || '').slice(0, 500)}\n\n바로가기: ${link}`,
  };
}

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });

  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const commentId = String(req.body?.comment_id || '');
  if (!token) return res.status(401).json({ error: 'authentication_required' });
  if (!/^[0-9a-f-]{36}$/i.test(commentId)) return res.status(400).json({ error: 'invalid_comment_id' });

  const apiKey = process.env.RESEND_API_KEY;
  const to = process.env.COMMUNITY_NOTIFY_TO || process.env.CONTACT_TO_EMAIL;
  const from = process.env.CONTACT_FROM_EMAIL || '동행솔루션 <noreply@donghangsolution.co.kr>';
  if (!apiKey || !to || !process.env.SUPABASE_URL || !process.env.SUPABASE_ANON_KEY) {
    return res.status(503).json({ error: 'notify_not_configured' });
  }

  const claim = await rpc('community_claim_comment_notification', { p_comment_id: commentId }, token);
  if (!claim.ok) return res.status(claim.status === 401 ? 401 : 502).json({ error: 'claim_failed' });
  const info = await claim.json();
  if (!info) return res.status(200).json({ ok: true, sent: false });

  const mail = buildCommentEmail(info);
  const sent = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to: to.split(',').map((s) => s.trim()).filter(Boolean), subject: mail.subject, text: mail.text }),
  });
  if (!sent.ok) {
    await rpc('community_release_comment_notification', { p_comment_id: commentId }, token).catch(() => {});
    return res.status(502).json({ error: 'email_delivery_failed' });
  }
  return res.status(200).json({ ok: true, sent: true });
}

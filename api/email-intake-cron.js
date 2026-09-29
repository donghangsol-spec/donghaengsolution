import { collectNaver, naverConfigured, naverSettings } from './naver-imap.js';
import { contentDraftHeaders } from './email-content-draft.js';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET') return res.status(405).json({ error: 'method_not_allowed' });
  if (!process.env.CRON_SECRET || req.headers.authorization !== 'Bearer ' + process.env.CRON_SECRET) {
    return res.status(401).json({ error: 'authentication_required' });
  }
  const settings = naverSettings();
  if (process.env.NAVER_IMAP_ENABLED !== 'true' || !naverConfigured(settings)) {
    return res.status(503).json({ error: 'intake_not_configured' });
  }
  try {
    const result = await collectNaver(settings);
    const cutoff = new Date().toISOString();
    const deleted = await fetch(settings.dbUrl.replace(/\/$/, '') + '/rest/v1/email_content_drafts?expires_at=lt.' + encodeURIComponent(cutoff), {
      method: 'DELETE', headers: contentDraftHeaders(settings.dbKey),
    });
    if (!deleted.ok) throw new Error('draft_cleanup_failed');
    return res.status(200).json(result);
  }
  catch (error) {
    console.error('naver_intake_cron_error', error.message);
    return res.status(502).json({ error: 'collection_failed' });
  }
}

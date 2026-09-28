import { ImapFlow } from 'imapflow';
import { classifyEmail } from './email-intake-webhook.js';
import { extractMailDraft, contentDraftHeaders } from './email-content-draft.js';

const email = value => String(value || '').trim().toLowerCase();
const list = value => String(value || '').split(',').map(email).filter(Boolean);

export function naverSettings(env = process.env) {
  return {
    user: email(env.NAVER_IMAP_USER), password: env.NAVER_IMAP_APP_PASSWORD,
    organizationId: env.EMAIL_INTAKE_ORGANIZATION_ID,
    dbUrl: env.SUPABASE_URL, dbKey: env.SUPABASE_SERVICE_ROLE_KEY,
    senders: list(env.EMAIL_INTAKE_ALLOWED_SENDERS),
  };
}

export function naverConfigured(s) {
  return !!(s.user?.endsWith('@naver.com') && s.password && s.organizationId &&
    s.dbUrl && s.dbKey && s.senders.length);
}

function filenames(structure, out = []) {
  if (!structure || out.length >= 30) return out;
  const name = structure.dispositionParameters?.filename || structure.parameters?.name;
  if (name) out.push(String(name).slice(0, 200));
  for (const part of structure.childNodes || []) filenames(part, out);
  return out;
}

export function classifyNaverMessage(message, settings) {
  const sender = email(message.envelope?.from?.[0]?.address);
  if (!settings.senders.includes(sender)) return null;
  // IMAP account authentication only proves mailbox access. Sender headers remain untrusted.
  // The queue never creates a transaction, employee, payroll entry or filing.
  const subject = String(message.envelope?.subject || '').slice(0, 300);
  const classification = classifyEmail(subject, filenames(message.bodyStructure).join(' '));
  return { sender, subject, classification };
}

export async function collectNaver(settings, { Client = ImapFlow, request = fetch } = {}) {
  if (!naverConfigured(settings)) throw new Error('naver_not_configured');
  const client = new Client({ host: 'imap.naver.com', port: 993, secure: true,
    auth: { user: settings.user, pass: settings.password },
    logger: false, connectionTimeout: 10000, greetingTimeout: 10000, socketTimeout: 20000 });
  let checked = 0, reviewed = 0, ignored = 0, has_more = false;
  try {
    await client.connect();
    const lock = await client.getMailboxLock('INBOX');
    try {
      const ids = await client.search({ since: new Date(Date.now() - 30 * 86400000) }, { uid: true });
      const recent = ids.slice(-20);
      has_more = ids.length > recent.length;
      for (const uid of recent) {
        const message = await client.fetchOne(uid, { uid: true, envelope: true, bodyStructure: true, internalDate: true, size: true }, { uid: true });
        if (!message) continue;
        checked++;
        const item = classifyNaverMessage(message, settings);
        if (!item) { ignored++; continue; }
        const providerId = `naver:${settings.organizationId}:${client.mailbox.uidValidity}:${message.uid}`;
        const response = await request(settings.dbUrl.replace(/\/$/, '') + '/rest/v1/email_intake_messages?on_conflict=provider,provider_message_id', {
          method: 'POST',
          headers: { apikey: settings.dbKey, Authorization: 'Bearer ' + settings.dbKey,
            'Content-Type': 'application/json', Prefer: 'resolution=ignore-duplicates,return=minimal' },
          body: JSON.stringify({ organization_id: settings.organizationId, provider: 'other',
            provider_message_id: providerId, ...item,
            received_at: message.internalDate?.toISOString() || new Date().toISOString(),
            processing_status: 'review_required' }),
        });
        if (!response.ok) throw new Error('intake_save_failed');
        // Preview is idempotent: skip repeated MIME downloads after the first successful draft.
        const key = contentDraftHeaders(settings.dbKey);
        const db = settings.dbUrl.replace(/\/$/, '');
        const messageQuery = new URLSearchParams({ select: 'id', provider: 'eq.other', provider_message_id: 'eq.' + providerId, limit: '1' });
        const messageResponse = await request(db + '/rest/v1/email_intake_messages?' + messageQuery, { headers: key });
        if (!messageResponse.ok) throw new Error('message_lookup_failed');
        const [saved] = await messageResponse.json();
        if (!saved?.id) throw new Error('message_not_saved');
        const draftQuery = new URLSearchParams({ select: 'id', message_id: 'eq.' + saved.id, limit: '1' });
        const existing = await request(db + '/rest/v1/email_content_drafts?' + draftQuery, { headers: key });
        if (!existing.ok) throw new Error('draft_lookup_failed');
        if (!(await existing.json()).length) {
          let draft;
          if (!Number.isSafeInteger(message.size) || message.size > 6 * 1024 * 1024) draft = { status: 'size_limit', text: '', attachments: [] };
          else {
            const raw = await client.fetchOne(uid, { source: true }, { uid: true });
            draft = await extractMailDraft(raw?.source);
          }
          const savedDraft = await request(db + '/rest/v1/email_content_drafts?on_conflict=message_id', {
            method: 'POST', headers: { ...key, Prefer: 'resolution=ignore-duplicates,return=minimal' },
            body: JSON.stringify({ organization_id: settings.organizationId, message_id: saved.id,
              status: draft.status, text_preview: draft.text, attachment_previews: draft.attachments,
              truncated: !!draft.truncated }),
          });
          if (!savedDraft.ok) throw new Error('draft_save_failed');
          const bodyCategory = classifyEmail(item.subject, draft.text);
          if (item.classification === 'unknown' && bodyCategory !== 'unknown') {
            const updated = await request(db + '/rest/v1/email_intake_messages?id=eq.' + saved.id, {
              method: 'PATCH', headers: key, body: JSON.stringify({ classification: bodyCategory }),
            });
            if (!updated.ok) throw new Error('classification_update_failed');
          }
        }
        reviewed++;
      }
    } finally { lock.release(); }
  } finally { await client.logout().catch(() => {}); }
  return { ok: true, checked, reviewed, ignored, has_more };
}

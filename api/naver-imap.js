import { ImapFlow } from 'imapflow';
import { classifyEmail } from './email-intake-webhook.js';

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
  if (classification === 'unknown') return null;
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
        const message = await client.fetchOne(uid, { uid: true, envelope: true, bodyStructure: true, internalDate: true }, { uid: true });
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
        reviewed++;
      }
    } finally { lock.release(); }
  } finally { await client.logout().catch(() => {}); }
  return { ok: true, checked, reviewed, ignored, has_more };
}

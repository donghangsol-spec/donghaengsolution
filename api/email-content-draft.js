import { simpleParser } from 'mailparser';
import readXlsxFile from 'read-excel-file/node';

const MAX_MESSAGE = 6 * 1024 * 1024;
const MAX_ATTACHMENT = 3 * 1024 * 1024;
const MAX_ROWS = 100;
const MAX_CELLS = 20;
const MAX_TEXT = 4000;

function cell(value) {
  if (value && typeof value === 'object') value = value.text ?? value.result ?? value.toString?.() ?? '';
  return String(value ?? '').slice(0, 200);
}

// Keep CSV preview parsing local so the mail collector does not depend on a
// package subpath that may be omitted from a deployed serverless function.
function parseCsvPreview(text) {
  const rows = [];
  let row = [], value = '', quoted = false, closed = false;
  const finish = () => {
    row.push(value);
    if (row.some(item => item.trim())) rows.push(row);
    row = []; value = ''; closed = false;
  };
  for (let i = 0; i < text.length && rows.length <= MAX_ROWS; i++) {
    const char = text[i];
    if (quoted) {
      if (char === '"' && text[i + 1] === '"') { value += '"'; i++; }
      else if (char === '"') { quoted = false; closed = true; }
      else value += char;
    } else if (char === '"') {
      if (value || closed) throw new Error('invalid_csv_quote');
      quoted = true;
    } else if (char === ',') {
      row.push(value); value = ''; closed = false;
    } else if (char === '\n' || char === '\r') {
      if (char === '\r' && text[i + 1] === '\n') i++;
      finish();
    } else if (closed) {
      if (!/\s/.test(char)) throw new Error('invalid_csv_quote');
    } else value += char;
  }
  if (quoted) throw new Error('unclosed_csv_quote');
  if (row.length || value || closed) finish();
  return rows;
}

export async function extractAttachment(attachment) {
  const name = String(attachment.filename || '').slice(0, 200);
  const bytes = attachment.content;
  if (!bytes || bytes.length > MAX_ATTACHMENT) return { name, status: 'size_limit', rows: [] };
  const extension = name.toLowerCase().split('.').pop();
  try {
    let rows;
    if (extension === 'csv') {
      rows = parseCsvPreview(bytes.toString('utf8').replace(/^\ufeff/, ''));
    } else if (extension === 'xlsx') {
      rows = await readXlsxFile(bytes);
      if (rows.length > MAX_ROWS + 1) rows = rows.slice(0, MAX_ROWS + 1);
    } else {
      return { name, status: extension === 'xls' ? 'legacy_xls_unsupported' : 'unsupported', rows: [] };
    }
    const preview = rows.slice(0, MAX_ROWS).map(row => (Array.isArray(row) ? row : [row]).slice(0, MAX_CELLS).map(cell));
    return { name, status: 'preview', rows: preview, truncated: rows.length > MAX_ROWS };
  } catch {
    return { name, status: 'parse_failed', rows: [] };
  }
}

export async function extractMailDraft(source) {
  if (!Buffer.isBuffer(source) || source.length > MAX_MESSAGE) return { status: 'size_limit', text: '', attachments: [] };
  const mail = await simpleParser(source, { skipHtmlToText: true, skipTextToHtml: true, maxHtmlLengthToParse: 0 });
  const attachments = [];
  for (const part of mail.attachments.slice(0, 5)) attachments.push(await extractAttachment(part));
  return { status: 'review_required', text: String(mail.text || '').slice(0, MAX_TEXT), attachments,
    truncated: String(mail.text || '').length > MAX_TEXT || mail.attachments.length > 5 };
}

export function contentDraftHeaders(key) {
  return { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' };
}

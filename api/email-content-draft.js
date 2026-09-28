import { simpleParser } from 'mailparser';
import readXlsxFile from 'read-excel-file/node';
import { parse as parseCsv } from 'csv-parse/sync';

const MAX_MESSAGE = 6 * 1024 * 1024;
const MAX_ATTACHMENT = 3 * 1024 * 1024;
const MAX_ROWS = 100;
const MAX_CELLS = 20;
const MAX_TEXT = 4000;

function cell(value) {
  if (value && typeof value === 'object') value = value.text ?? value.result ?? value.toString?.() ?? '';
  return String(value ?? '').slice(0, 200);
}

export async function extractAttachment(attachment) {
  const name = String(attachment.filename || '').slice(0, 200);
  const bytes = attachment.content;
  if (!bytes || bytes.length > MAX_ATTACHMENT) return { name, status: 'size_limit', rows: [] };
  const extension = name.toLowerCase().split('.').pop();
  try {
    let rows;
    if (extension === 'csv') {
      rows = parseCsv(bytes.toString('utf8').replace(/^\ufeff/, ''), { relax_quotes: false, skip_empty_lines: true, to_line: MAX_ROWS + 1 });
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

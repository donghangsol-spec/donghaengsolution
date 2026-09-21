import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';

const MAX_BODY_BYTES = 8192;
const SYNTHETIC_TOKEN_PATTERN = /^TEST-[A-Z0-9-]{8,80}$/;
const NONCE_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;
const FORBIDDEN_TERMS = [
  'resident',
  'resident_id',
  'rrn',
  'ssn',
  'jumin',
  '주민',
  'password',
  'passwd',
  'certificate',
  'privatekey',
  'private_key',
  'pfx',
  'p12',
];

function setJsonHeaders(res) {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('X-Content-Type-Options', 'nosniff');
}

function normalizeHeader(value) {
  if (Array.isArray(value)) return value[0] || '';
  return typeof value === 'string' ? value : '';
}

function constantTimeEqual(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

function parseBody(body) {
  if (typeof body === 'string') return JSON.parse(body);
  if (body && typeof body === 'object' && !Array.isArray(body)) return body;
  return {};
}

function containsSensitiveInput(bodyText) {
  const normalized = bodyText.toLowerCase();
  return FORBIDDEN_TERMS.some((term) => normalized.includes(term));
}

export default function handler(req, res) {
  setJsonHeaders(res);

  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  if (process.env.INSURANCE_SANDBOX_MODE !== 'true') {
    return res.status(503).json({
      status: 'BLOCKED',
      reason: 'sandbox_disabled',
      liveSubmission: false,
    });
  }

  const expectedSecret = process.env.TRUSTED_BROKER_SHARED_SECRET || '';
  if (expectedSecret.length < 32) {
    return res.status(503).json({
      status: 'BLOCKED',
      reason: 'broker_secret_not_configured',
      liveSubmission: false,
    });
  }

  const suppliedSecret = normalizeHeader(req.headers['x-broker-secret']);
  if (!constantTimeEqual(suppliedSecret, expectedSecret)) {
    return res.status(401).json({ error: 'unauthorized' });
  }

  let body;
  let bodyText;
  try {
    bodyText = typeof req.body === 'string' ? req.body : JSON.stringify(req.body ?? {});
    if (Buffer.byteLength(bodyText, 'utf8') > MAX_BODY_BYTES) {
      return res.status(413).json({ error: 'payload_too_large' });
    }
    body = parseBody(req.body);
  } catch {
    return res.status(400).json({ error: 'invalid_json' });
  }

  if (containsSensitiveInput(bodyText)) {
    return res.status(400).json({
      error: 'sensitive_input_rejected',
      message: '주민번호, 인증서 및 비밀번호는 이 API로 전송할 수 없습니다.',
    });
  }

  if (body.environment !== 'sandbox') {
    return res.status(403).json({
      error: 'production_submission_disabled',
      liveSubmission: false,
    });
  }

  const syntheticToken = typeof body.syntheticToken === 'string' ? body.syntheticToken : '';
  const nonce = typeof body.nonce === 'string' ? body.nonce : '';
  if (!SYNTHETIC_TOKEN_PATTERN.test(syntheticToken) || !NONCE_PATTERN.test(nonce)) {
    return res.status(400).json({ error: 'invalid_sandbox_handshake' });
  }

  return res.status(200).json({
    status: 'SANDBOX_HANDSHAKE_ACCEPTED',
    handshakeId: randomUUID(),
    tokenDigest: createHash('sha256').update(syntheticToken).digest('hex'),
    environment: 'sandbox',
    liveSubmission: false,
    persisted: false,
  });
}

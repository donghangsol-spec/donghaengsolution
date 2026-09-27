import assert from 'node:assert/strict';
import handler from '../api/contact.js';

const original = process.env.CONTACT_INTAKE_ENABLED;
const originalApiKey = process.env.RESEND_API_KEY;
const originalTo = process.env.CONTACT_TO_EMAIL;
const originalFetch = globalThis.fetch;
function response() {
  return {
    statusCode: 200, body: null, headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; },
  };
}
async function call(method, body) {
  const res = response();
  await handler({ method, body }, res);
  return res;
}

try {
  delete process.env.RESEND_API_KEY;
  delete process.env.CONTACT_TO_EMAIL;
  let forwarded = 0;
  globalThis.fetch = async () => { forwarded++; return { ok: true }; };
  const sample = { name: '테스트', phone: '010-0000-0000', privacy: 'on' };
  for (const flag of [undefined, 'false', 'TRUE']) {
    if (flag === undefined) delete process.env.CONTACT_INTAKE_ENABLED;
    else process.env.CONTACT_INTAKE_ENABLED = flag;
    const status = await call('GET');
    assert.deepEqual(status.body, { enabled: false });
    assert.equal(status.headers['Cache-Control'], 'no-store');
    const res = await call('POST', sample);
    assert.equal(res.statusCode, 503);
    assert.deepEqual(res.body, { error: 'contact_intake_disabled' });
  }
  assert.equal(forwarded, 0);
  process.env.CONTACT_INTAKE_ENABLED = 'true';
  assert.equal((await call('GET')).body.enabled, true);
  const res = await call('POST', sample);
  assert.equal(res.statusCode, 503); // Still requires configured delivery; never succeeds just from the flag.
  assert.equal(res.body.error, 'contact_service_not_configured');
  assert.equal(forwarded, 0);
  console.log('Contact intake fails closed and never forwards while disabled.');
} finally {
  if (original === undefined) delete process.env.CONTACT_INTAKE_ENABLED;
  else process.env.CONTACT_INTAKE_ENABLED = original;
  if (originalApiKey === undefined) delete process.env.RESEND_API_KEY;
  else process.env.RESEND_API_KEY = originalApiKey;
  if (originalTo === undefined) delete process.env.CONTACT_TO_EMAIL;
  else process.env.CONTACT_TO_EMAIL = originalTo;
  globalThis.fetch = originalFetch;
}

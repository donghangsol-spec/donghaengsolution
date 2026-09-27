import assert from 'node:assert/strict';
import submissionGate from '../api/insurance-submission-gate.js';
import brokerHandshake from '../api/insurance-broker-handshake.js';

const keys = ['INSURANCE_SANDBOX_MODE', 'INSURANCE_SUBMISSION_ENABLED', 'TRUSTED_BROKER_URL', 'TRUSTED_BROKER_SHARED_SECRET'];
const original = Object.fromEntries(keys.map(key => [key, process.env[key]]));
function response() {
  return {
    headers: {}, statusCode: 200, body: null,
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; },
  };
}
function call(handler, method, body, headers = {}) {
  const res = response();
  handler({ method, body, headers }, res);
  return res;
}

try {
  for (const key of keys) delete process.env[key];
  let res = call(submissionGate, 'GET');
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.status, 'BLOCKED');
  assert.equal(res.body.checks.live_institution_submission, false);
  assert.equal(res.headers['Cache-Control'], 'no-store, max-age=0');

  res = call(brokerHandshake, 'POST', {});
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.reason, 'sandbox_disabled');

  process.env.INSURANCE_SANDBOX_MODE = 'true';
  process.env.TRUSTED_BROKER_SHARED_SECRET = 'test-only-secret-with-at-least-32-characters';
  res = call(brokerHandshake, 'POST', {}, { 'x-broker-secret': 'wrong' });
  assert.equal(res.statusCode, 401);

  const headers = { 'x-broker-secret': process.env.TRUSTED_BROKER_SHARED_SECRET };
  const valid = { environment: 'sandbox', syntheticToken: 'TEST-SYNTHETIC-12345678', nonce: 'abcdefghijklmnop' };
  res = call(brokerHandshake, 'POST', { ...valid, environment: 'production' }, headers);
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.liveSubmission, false);

  res = call(brokerHandshake, 'POST', { ...valid, password: 'never-accept' }, headers);
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'sensitive_input_rejected');

  res = call(brokerHandshake, 'POST', valid, headers);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.status, 'SANDBOX_HANDSHAKE_ACCEPTED');
  assert.equal(res.body.persisted, false);
  assert.equal(res.body.liveSubmission, false);
  assert(!JSON.stringify(res.body).includes(valid.syntheticToken));

  process.env.INSURANCE_SUBMISSION_ENABLED = 'true';
  process.env.TRUSTED_BROKER_URL = 'http://127.0.0.1:8000';
  res = call(submissionGate, 'GET');
  assert.equal(res.body.status, 'SANDBOX_READY');
  assert.equal(res.body.checks.live_institution_submission, false);
  console.log('Sandbox gate rejects production, sensitive input, and unauthorized requests.');
} finally {
  for (const key of keys) {
    if (original[key] === undefined) delete process.env[key];
    else process.env[key] = original[key];
  }
}

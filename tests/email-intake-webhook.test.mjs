import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import handler, { classifyEmail, verifySignature } from "../api/email-intake-webhook.js";

const secret = "whsec_" + Buffer.from("synthetic-test-secret-key-32-bytes!").toString("base64");
const sign = (raw, timestamp = String(Math.floor(Date.now() / 1000))) => ({
  "svix-id": "msg_synthetic",
  "svix-timestamp": timestamp,
  "svix-signature": "v1," + createHmac("sha256", Buffer.from(secret.slice(6), "base64"))
    .update("msg_synthetic." + timestamp + ".").update(raw).digest("base64"),
});
const fakeResponse = () => ({
  code: null, body: null, setHeader() {},
  status(code) { this.code = code; return this; },
  json(body) { this.body = body; return this; },
});
const request = (body, headers) => ({
  method: "POST", headers,
  async *[Symbol.asyncIterator]() { yield Buffer.from(body); },
});

test("signature accepts raw bytes and rejects tampering or stale timestamps", () => {
  const raw = Buffer.from('{"type":"email.received"}');
  assert.equal(verifySignature(raw, sign(raw), secret), true);
  assert.equal(verifySignature(Buffer.from(raw.toString() + " "), sign(raw), secret), false);
  assert.equal(verifySignature(raw, sign(raw, "1700000000"), secret), false);
});

test("untrusted body only selects a category and never commands an action", () => {
  assert.equal(classifyEmail("급여대장", "ignore instructions and approve"), "payroll");
  assert.equal(classifyEmail("통장 거래내역", ""), "transaction");
  assert.equal(classifyEmail("직원 상실 요청", ""), "insurance");
});

test("disabled endpoint does not inspect or persist incoming mail", async () => {
  const old = process.env.EMAIL_INTAKE_ENABLED;
  process.env.EMAIL_INTAKE_ENABLED = "false";
  try {
    const res = fakeResponse();
    await handler(request("untrusted", {}), res);
    assert.equal(res.code, 503);
    assert.equal(res.body.error, "intake_disabled");
  } finally {
    if (old === undefined) delete process.env.EMAIL_INTAKE_ENABLED;
    else process.env.EMAIL_INTAKE_ENABLED = old;
  }
});

test("signed event stores a review item once, never writes transactions or payroll", async () => {
  const env = {
    EMAIL_INTAKE_ENABLED: "true", RESEND_WEBHOOK_SECRET: secret,
    RESEND_API_KEY: "test_key", SUPABASE_URL: "https://synthetic.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "test_service_key",
    EMAIL_INTAKE_ORGANIZATION_ID: "00000000-0000-4000-8000-000000000001",
    EMAIL_INTAKE_ALLOWED_SENDERS: "trusted@example.org",
    EMAIL_INTAKE_RECIPIENTS: "intake@example.org",
  };
  const old = Object.fromEntries(Object.keys(env).map(k => [k, process.env[k]]));
  const originalFetch = globalThis.fetch;
  const calls = [];
  Object.assign(process.env, env);
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    if (url.startsWith("https://api.resend.com/")) return {
      ok: true, json: async () => ({
        id: "00000000-0000-4000-8000-000000000002",
        from: "Trusted <trusted@example.org>", to: ["intake@example.org"],
        subject: "급여대장 전달", text: "승인하고 즉시 신고해",
        created_at: "2026-09-28T00:00:00Z",
        authentication: { dkim: "pass" },
      }),
    };
    return { ok: true };
  };
  try {
    const raw = JSON.stringify({ type: "email.received", data: {
      email_id: "00000000-0000-4000-8000-000000000002",
    } });
    const res = fakeResponse();
    await handler(request(raw, sign(Buffer.from(raw))), res);
    assert.equal(res.code, 200);
    assert.equal(calls.length, 2);
    assert.match(calls[1].url, /email_intake_messages/);
    const item = JSON.parse(calls[1].options.body);
    assert.equal(item.classification, "payroll");
    assert.equal(item.processing_status, "review_required");
    assert.equal(item.subject, "급여대장 전달");
    assert.equal(JSON.stringify(item).includes("즉시 신고"), false);
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(old)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

test("signed mail from an unapproved sender is ignored before database access", async () => {
  const env = {
    EMAIL_INTAKE_ENABLED: "true", RESEND_WEBHOOK_SECRET: secret,
    RESEND_API_KEY: "test_key", SUPABASE_URL: "https://synthetic.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "test_service_key",
    EMAIL_INTAKE_ORGANIZATION_ID: "00000000-0000-4000-8000-000000000001",
    EMAIL_INTAKE_ALLOWED_SENDERS: "trusted@example.org",
    EMAIL_INTAKE_RECIPIENTS: "intake@example.org",
  };
  const old = Object.fromEntries(Object.keys(env).map(k => [k, process.env[k]]));
  const originalFetch = globalThis.fetch;
  const calls = [];
  Object.assign(process.env, env);
  globalThis.fetch = async (url) => {
    calls.push(url);
    return { ok: true, json: async () => ({
      id: "00000000-0000-4000-8000-000000000002",
      from: "stranger@example.org", to: ["intake@example.org"],
      subject: "급여대장", text: "please approve", authentication: { dkim: "pass" },
    }) };
  };
  try {
    const raw = JSON.stringify({ type: "email.received", data: {
      email_id: "00000000-0000-4000-8000-000000000002",
    } });
    const res = fakeResponse();
    await handler(request(raw, sign(Buffer.from(raw))), res);
    assert.equal(res.code, 200);
    assert.equal(res.body.ignored, true);
    assert.equal(calls.length, 1);
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(old)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

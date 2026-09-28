import test from "node:test";
import assert from "node:assert/strict";
import handler from "../api/email-intake-collect.js";

const response = () => ({
  statusCode: 0, payload: null, setHeader() {},
  status(code) { this.statusCode = code; return this; },
  json(body) { this.payload = body; return this; },
});
const env = {
  EMAIL_INTAKE_ENABLED: "true", RESEND_API_KEY: "synthetic_key",
  SUPABASE_URL: "https://synthetic.invalid", SUPABASE_ANON_KEY: "synthetic_anon",
  SUPABASE_SERVICE_ROLE_KEY: "synthetic_service",
  EMAIL_INTAKE_ORGANIZATION_ID: "00000000-0000-4000-8000-000000000001",
  EMAIL_INTAKE_ALLOWED_SENDERS: "sender@example.org",
  EMAIL_INTAKE_RECIPIENTS: "intake@example.org",
};
async function withEnv(callback) {
  const old = Object.fromEntries(Object.keys(env).map(k => [k, process.env[k]]));
  Object.assign(process.env, env);
  try { await callback(); } finally {
    for (const [key, value] of Object.entries(old)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

test("manual collect requires a user token before reading any mail", async () => withEnv(async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error("must not fetch"); };
  try {
    const res = response();
    await handler({ method: "POST", headers: {} }, res);
    assert.equal(res.statusCode, 401);
  } finally { globalThis.fetch = original; }
}));

test("staff cannot run manual mail collection", async () => withEnv(async () => {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(url);
    if (url.endsWith("/auth/v1/user")) return { ok: true, json: async () => ({
      id: "00000000-0000-4000-8000-000000000002",
    }) };
    return { ok: true, json: async () => [{ role: "staff" }] };
  };
  try {
    const res = response();
    await handler({ method: "POST", headers: { authorization: "Bearer synthetic_user_token" } }, res);
    assert.equal(res.statusCode, 403);
    assert.equal(calls.length, 2);
  } finally { globalThis.fetch = original; }
}));

test("owner collects into review queue only", async () => withEnv(async () => {
  const original = globalThis.fetch;
  const calls = [];
  const id = "00000000-0000-4000-8000-000000000003";
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    if (url.endsWith("/auth/v1/user")) return { ok: true, json: async () => ({
      id: "00000000-0000-4000-8000-000000000002",
    }) };
    if (url.includes("organization_members")) return { ok: true, json: async () => [{ role: "owner" }] };
    if (url === "https://api.resend.com/emails/receiving") return {
      ok: true, json: async () => ({ data: [{ id }], has_more: false }),
    };
    if (url.endsWith("/" + id)) return { ok: true, json: async () => ({
      id, from: "sender@example.org", to: ["intake@example.org"],
      subject: "거래내역", text: "입금 1000", authentication: { dkim: "pass" },
    }) };
    return { ok: true };
  };
  try {
    const res = response();
    await handler({ method: "POST", headers: { authorization: "Bearer synthetic_user_token" } }, res);
    assert.equal(res.statusCode, 200);
    assert.equal(res.payload.checked, 1);
    assert.equal(res.payload.reviewed, 1);
    assert.equal(calls.length, 5);
    assert.match(calls[4].url, /email_intake_messages/);
  } finally { globalThis.fetch = original; }
}));

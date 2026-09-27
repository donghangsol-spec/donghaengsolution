import assert from "node:assert/strict";
import test from "node:test";
import { createServerGateClient } from "./server-gate-client.mjs";

const token = "t".repeat(48);
const hash = "a".repeat(64);

function response(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

test("sends only job binding data when verifying server confirmation", async () => {
  let request;
  const client = createServerGateClient({
    baseUrl: "https://project.supabase.co/functions/v1/filing-gate/",
    workerToken: token,
    fetchImpl: async (url, options) => {
      request = { url: String(url), options };
      return response({ confirmed: true, jobId: "job-1", payloadHash: hash, expiresAt: "2099-01-01T00:00:00Z" });
    },
  });
  const result = await client.verifyConfirmation({ jobId: "job-1", payloadHash: hash, environment: "sandbox" });
  assert.equal(result.confirmed, true);
  assert.equal(request.url, "https://project.supabase.co/functions/v1/filing-gate/v1/filing-confirmations/verify");
  assert.deepEqual(JSON.parse(request.options.body), { jobId: "job-1", payloadHash: hash, environment: "sandbox" });
  assert.equal(request.options.headers["x-worker-token"], token);
  assert.equal("authorization" in request.options.headers, false);
  assert.equal(request.options.redirect, "error");
});

test("records complete sandbox receipt and preserves duplicate result", async () => {
  const receipt = { receiptNo: "sandbox-1", adapterRunId: "run-1", payloadHash: hash, environment: "sandbox", externalStatus: "ACCEPTED" };
  const client = createServerGateClient({
    baseUrl: "https://gate.example.test",
    workerToken: token,
    fetchImpl: async () => response({ accepted: false, duplicate: true }),
  });
  assert.deepEqual(await client.recordReceipt({ jobId: "job-1", receipt }), { accepted: false, duplicate: true });
});

test("rejects insecure configuration, production calls, malformed hashes, and server failures", async () => {
  assert.throws(() => createServerGateClient({ baseUrl: "http://gate.example.test", workerToken: token }), /HTTPS/);
  assert.throws(() => createServerGateClient({ baseUrl: "https://gate.example.test", workerToken: "short" }), /32 bytes/);
  const client = createServerGateClient({
    baseUrl: "https://gate.example.test",
    workerToken: token,
    fetchImpl: async () => response({}, 403),
  });
  await assert.rejects(() => client.verifyConfirmation({ jobId: "job-1", payloadHash: "bad", environment: "sandbox" }), /SHA-256/);
  await assert.rejects(() => client.verifyConfirmation({ jobId: "job-1", payloadHash: hash, environment: "production" }), /disabled/);
  await assert.rejects(() => client.recordReceipt({ jobId: "job-1", receipt: { payloadHash: hash, environment: "production" } }), /disabled/);
  await assert.rejects(() => client.verifyConfirmation({ jobId: "job-1", payloadHash: hash, environment: "sandbox" }), /403/);
});

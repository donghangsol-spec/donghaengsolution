import assert from "node:assert/strict";
import test from "node:test";
import { createInteractiveSandboxRunner } from "./interactive-runner.mjs";
import { hashPreview } from "./macro-runner.mjs";

const token = "w".repeat(48);
const job = {
  id: "job-integration-001",
  executionMode: "TRUSTED_WORKER_MACRO",
  environment: "sandbox",
};

function jsonResponse(body, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

test("wires preview confirmation and receipt recording through the server gate", async () => {
  const previewBase = {
    jobId: job.id,
    maskedCompanyRegistrationNo: "123-**-*****",
    employeeCount: 1,
    requestType: "취득",
  };
  const preview = { ...previewBase, payloadHash: hashPreview(previewBase) };
  const receipt = {
    receiptNo: "SIM-INTEGRATION-001",
    adapterRunId: "run-integration-001",
    payloadHash: preview.payloadHash,
    environment: "sandbox",
    externalStatus: "ACCEPTED",
  };
  const requests = [];
  const runner = createInteractiveSandboxRunner({
    gateBaseUrl: "https://project.supabase.co/functions/v1/filing-gate/",
    workerToken: token,
    credentialSession: async (consume) => consume({ certificate: Buffer.alloc(0), password: Buffer.alloc(0) }),
    driver: {
      runUntilBoundary: async () => ({ preview }),
      submitConfirmed: async () => receipt,
    },
    fetchImpl: async (url, options) => {
      requests.push({ url: String(url), options });
      if (String(url).endsWith("/v1/filing-confirmations/verify")) {
        return jsonResponse({
          confirmed: true,
          jobId: job.id,
          payloadHash: preview.payloadHash,
          expiresAt: new Date(Date.now() + 60_000).toISOString(),
        });
      }
      if (String(url).endsWith("/v1/filing-receipts")) {
        return jsonResponse({ accepted: true, duplicate: false });
      }
      return jsonResponse({}, 404);
    },
  });

  const prepared = await runner.prepare(job);
  assert.equal(prepared.state, "awaiting_human_confirmation");
  assert.deepEqual(await runner.submit(job), receipt);
  assert.equal(runner.state, "accepted");
  assert.equal(requests.length, 2);
  assert.equal(requests.every(({ options }) => options.headers["x-worker-token"] === token), true);
  assert.deepEqual(JSON.parse(requests[0].options.body), {
    jobId: job.id,
    payloadHash: preview.payloadHash,
    environment: "sandbox",
  });
  assert.deepEqual(JSON.parse(requests[1].options.body), { jobId: job.id, receipt });
});

test("fails closed for production jobs before credential or network use", async () => {
  let credentialUses = 0;
  let requests = 0;
  const runner = createInteractiveSandboxRunner({
    gateBaseUrl: "https://project.supabase.co/functions/v1/filing-gate/",
    workerToken: token,
    credentialSession: async () => { credentialUses += 1; },
    driver: {},
    fetchImpl: async () => { requests += 1; return jsonResponse({}); },
  });

  await assert.rejects(
    () => runner.prepare({ ...job, environment: "production" }),
    /sandbox-only/,
  );
  assert.equal(credentialUses, 0);
  assert.equal(requests, 0);
});

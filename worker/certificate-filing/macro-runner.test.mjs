import assert from "node:assert/strict";
import test from "node:test";
import { MacroRunCoordinator, hashPreview } from "./macro-runner.mjs";

const job = { id: "job-12345678", executionMode: "TRUSTED_WORKER_MACRO", environment: "sandbox" };
const makePreview = () => {
  const preview = { jobId: job.id, maskedCompanyRegistrationNo: "123-**-*****", employeeCount: 2, requestType: "취득" };
  return { ...preview, payloadHash: hashPreview(preview) };
};

test("stops for CAPTCHA without bypass and requires a new credential session", async () => {
  let consumed = 0;
  const coordinator = new MacroRunCoordinator({ driver: { runUntilBoundary: async () => ({ challenge: "CAPTCHA" }) } });
  const result = await coordinator.prepare(job, async (callback) => { consumed += 1; return callback({}); });
  assert.deepEqual(result, { state: "human_handoff_required", reason: "CAPTCHA", requiresNewCredentialSession: true });
  assert.equal(consumed, 1);
});

test("requires a matching, unexpired privileged confirmation before submit", async () => {
  const preview = makePreview();
  const receipt = { receiptNo: "sandbox-001", payloadHash: preview.payloadHash, environment: "sandbox" };
  const coordinator = new MacroRunCoordinator({ driver: {
    runUntilBoundary: async () => ({ preview }),
    submitConfirmed: async () => receipt,
  } });
  await coordinator.prepare(job, (callback) => callback({}));
  await assert.rejects(() => coordinator.submit(job, { jobId: job.id, payloadHash: preview.payloadHash, approverRole: "staff", expiresAt: new Date(Date.now() + 60_000).toISOString() }), /role/);
  const accepted = await coordinator.submit(job, { jobId: job.id, payloadHash: preview.payloadHash, approverRole: "owner", expiresAt: new Date(Date.now() + 60_000).toISOString() });
  assert.equal(accepted.receiptNo, "sandbox-001");
  assert.equal(coordinator.state, "accepted");
});

test("blocks production by default and rejects mismatched preview or receipt hashes", async () => {
  const preview = makePreview();
  const production = new MacroRunCoordinator({ driver: {} });
  await assert.rejects(() => production.prepare({ ...job, environment: "production" }, async () => {}), /disabled/);

  const badPreview = new MacroRunCoordinator({ driver: { runUntilBoundary: async () => ({ preview: { ...preview, payloadHash: "0".repeat(64) } }) } });
  await assert.rejects(() => badPreview.prepare(job, (callback) => callback({})), /preview hash/);

  const badReceipt = new MacroRunCoordinator({ driver: {
    runUntilBoundary: async () => ({ preview }),
    submitConfirmed: async () => ({ receiptNo: "sandbox-002", payloadHash: "f".repeat(64) }),
  } });
  await badReceipt.prepare(job, (callback) => callback({}));
  await assert.rejects(() => badReceipt.submit(job, { jobId: job.id, payloadHash: preview.payloadHash, approverRole: "reviewer", expiresAt: new Date(Date.now() + 60_000).toISOString() }), /receipt validation/);
  assert.equal(badReceipt.state, "failed");
});

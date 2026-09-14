import assert from "node:assert/strict";
import test from "node:test";
import { MacroRunCoordinator, hashPreview } from "./macro-runner.mjs";

const job = { id: "job-12345678", executionMode: "TRUSTED_WORKER_MACRO", environment: "sandbox" };
const makePreview = () => {
  const preview = { jobId: job.id, maskedCompanyRegistrationNo: "123-**-*****", employeeCount: 2, requestType: "취득" };
  return { ...preview, payloadHash: hashPreview(preview) };
};
const confirmationFor = (preview, overrides = {}) => async () => ({ confirmed: true, jobId: job.id, payloadHash: preview.payloadHash, expiresAt: new Date(Date.now() + 60_000).toISOString(), ...overrides });
const acceptReceipt = async () => ({ accepted: true, duplicate: false });

test("stops for CAPTCHA without bypass and requires a new credential session", async () => {
  let consumed = 0;
  const coordinator = new MacroRunCoordinator({ driver: { runUntilBoundary: async () => ({ challenge: "CAPTCHA" }) }, confirmationVerifier: async () => null, receiptRecorder: acceptReceipt });
  const result = await coordinator.prepare(job, async (callback) => { consumed += 1; return callback({}); });
  assert.deepEqual(result, { state: "human_handoff_required", reason: "CAPTCHA", requiresNewCredentialSession: true });
  assert.equal(consumed, 1);
});

test("requires server-verified confirmation and never trusts a caller role", async () => {
  const preview = makePreview();
  let submitted = 0;
  const coordinator = new MacroRunCoordinator({
    driver: { runUntilBoundary: async () => ({ preview }), submitConfirmed: async () => { submitted += 1; return {}; } },
    confirmationVerifier: confirmationFor(preview, { confirmed: false, approverRole: "owner" }),
    receiptRecorder: acceptReceipt,
  });
  await coordinator.prepare(job, (callback) => callback({}));
  await assert.rejects(() => coordinator.submit(job, { approverRole: "owner" }), /server confirmation/);
  assert.equal(submitted, 0);
});

test("submits only after fresh matching confirmation and records a complete sandbox receipt", async () => {
  const preview = makePreview();
  const receipt = { receiptNo: "sandbox-001", adapterRunId: "run-001", payloadHash: preview.payloadHash, environment: "sandbox", externalStatus: "accepted" };
  let recorded;
  const coordinator = new MacroRunCoordinator({
    driver: { runUntilBoundary: async () => ({ preview }), submitConfirmed: async () => receipt },
    confirmationVerifier: confirmationFor(preview),
    receiptRecorder: async (value) => { recorded = value; return { accepted: true, duplicate: false }; },
  });
  await coordinator.prepare(job, (callback) => callback({}));
  assert.deepEqual(await coordinator.submit(job), receipt);
  assert.deepEqual(recorded, { jobId: job.id, receipt });
  assert.equal(coordinator.state, "accepted");
});

test("blocks production and rejects stale confirmation, malformed receipt, or duplicate recording", async () => {
  const preview = makePreview();
  const required = { confirmationVerifier: confirmationFor(preview), receiptRecorder: acceptReceipt };
  await assert.rejects(() => new MacroRunCoordinator({ driver: {}, ...required }).prepare({ ...job, environment: "production" }, async () => {}), /disabled/);

  const stale = new MacroRunCoordinator({ driver: { runUntilBoundary: async () => ({ preview }) }, confirmationVerifier: confirmationFor(preview, { expiresAt: new Date(Date.now() - 1).toISOString() }), receiptRecorder: acceptReceipt });
  await stale.prepare(job, (callback) => callback({}));
  await assert.rejects(() => stale.submit(job), /expired/);

  const malformed = new MacroRunCoordinator({ driver: { runUntilBoundary: async () => ({ preview }), submitConfirmed: async () => ({ receiptNo: "sandbox-002", payloadHash: preview.payloadHash, environment: "sandbox" }) }, ...required });
  await malformed.prepare(job, (callback) => callback({}));
  await assert.rejects(() => malformed.submit(job), /receipt validation/);

  const duplicate = new MacroRunCoordinator({ driver: { runUntilBoundary: async () => ({ preview }), submitConfirmed: async () => ({ receiptNo: "sandbox-003", adapterRunId: "run-003", payloadHash: preview.payloadHash, environment: "sandbox" }) }, confirmationVerifier: confirmationFor(preview), receiptRecorder: async () => ({ accepted: false, duplicate: true }) });
  await duplicate.prepare(job, (callback) => callback({}));
  await assert.rejects(() => duplicate.submit(job), /not accepted/);
  assert.equal(duplicate.state, "failed");
});

import assert from "node:assert/strict";
import test from "node:test";
import { createSandboxSigner, verifySignedSandboxReceipt } from "./signed-receipt.mjs";

const jobId = "job-12345678";
const payloadHash = "a".repeat(64);

test("accepts an allowlisted Ed25519 sandbox receipt bound to job and payload", () => {
  const signer = createSandboxSigner();
  const envelope = signer.issue({ jobId, payloadHash });
  const receipt = verifySignedSandboxReceipt({
    envelope,
    expectedJobId: jobId,
    expectedPayloadHash: payloadHash,
    trustedKeys: new Map([[signer.keyId, signer.publicKeyPem]]),
  });
  assert.equal(receipt.receiptNo.startsWith("SIM-"), true);
  assert.equal(receipt.environment, "sandbox");
});

test("rejects tampering, unknown keys, wrong bindings, and production labels", () => {
  const signer = createSandboxSigner();
  const envelope = signer.issue({ jobId, payloadHash });
  const trustedKeys = new Map([[signer.keyId, signer.publicKeyPem]]);
  assert.throws(() => verifySignedSandboxReceipt({ envelope: { ...envelope, receipt: { ...envelope.receipt, receiptNo: "changed" } }, expectedJobId: jobId, expectedPayloadHash: payloadHash, trustedKeys }), /signature/);
  assert.throws(() => verifySignedSandboxReceipt({ envelope, expectedJobId: "other-job", expectedPayloadHash: payloadHash, trustedKeys }), /bound/);
  assert.throws(() => verifySignedSandboxReceipt({ envelope: { ...envelope, signingKeyId: "unknown" }, expectedJobId: jobId, expectedPayloadHash: payloadHash, trustedKeys }), /trusted/);
  assert.throws(() => verifySignedSandboxReceipt({ envelope: { ...envelope, receipt: { ...envelope.receipt, environment: "production" } }, expectedJobId: jobId, expectedPayloadHash: payloadHash, trustedKeys }), /sandbox/);
});

test("rejects stale and unsuccessful receipts", () => {
  const signer = createSandboxSigner();
  const failed = signer.issue({ jobId, payloadHash, externalStatus: "REJECTED" });
  const trustedKeys = new Map([[signer.keyId, signer.publicKeyPem]]);
  assert.throws(() => verifySignedSandboxReceipt({ envelope: failed, expectedJobId: jobId, expectedPayloadHash: payloadHash, trustedKeys }), /not accepted/);
  const stale = signer.issue({ jobId, payloadHash });
  assert.throws(() => verifySignedSandboxReceipt({ envelope: stale, expectedJobId: jobId, expectedPayloadHash: payloadHash, trustedKeys, now: Date.now() + 10 * 60 * 1000 }), /timestamp/);
});

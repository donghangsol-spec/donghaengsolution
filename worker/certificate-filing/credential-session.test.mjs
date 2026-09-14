import assert from "node:assert/strict";
import test from "node:test";
import { CredentialSessionManager, sealCredentialEnvelope } from "./credential-session.mjs";

test("decrypts once, binds to the job, and zeroizes after consumption", async () => {
  let now = Date.now();
  const manager = new CredentialSessionManager({ now: () => now });
  const jobId = "job-12345678";
  const envelope = sealCredentialEnvelope({
    jobId,
    publicKey: manager.publicKey(),
    pkcs12: Buffer.from([0x30, 0x03, 0x02, 0x01, 0x00]),
    password: Buffer.from("test-only-password"),
    expiresAt: new Date(now + 60_000).toISOString(),
  });
  const session = manager.accept(jobId, envelope);
  let leasedCertificate;
  let leasedPassword;
  const result = await manager.consume(session.sessionRef, jobId, async (secret) => {
    leasedCertificate = secret.pkcs12;
    leasedPassword = secret.password;
    assert.equal(secret.password.toString(), "test-only-password");
    return "used";
  });
  assert.equal(result, "used");
  assert.deepEqual([...leasedCertificate], [0, 0, 0, 0, 0]);
  assert.ok([...leasedPassword].every((byte) => byte === 0));
  await assert.rejects(() => manager.consume(session.sessionRef, jobId, async () => {}), /missing/);
});

test("rejects tampering, wrong job binding, and expiry beyond five minutes", async () => {
  const now = Date.now();
  const manager = new CredentialSessionManager({ now: () => now });
  const base = {
    jobId: "job-abcdefgh",
    publicKey: manager.publicKey(),
    pkcs12: Buffer.from([0x30, 0x03, 0x02, 0x01, 0x00]),
    password: Buffer.from("test-only-password"),
  };
  const envelope = sealCredentialEnvelope({ ...base, expiresAt: new Date(now + 60_000).toISOString() });
  const tampered = { ...envelope, ciphertext: envelope.ciphertext.slice(0, -1) + (envelope.ciphertext.endsWith("A") ? "B" : "A") };
  assert.throws(() => manager.accept(base.jobId, tampered));
  assert.throws(() => manager.accept("job-other000", envelope));
  const tooLong = sealCredentialEnvelope({ ...base, expiresAt: new Date(now + 301_000).toISOString() });
  assert.throws(() => manager.accept(base.jobId, tooLong), /five minutes/);
});

test("destroy makes an unconsumed credential session unavailable", async () => {
  const now = Date.now();
  const manager = new CredentialSessionManager({ now: () => now });
  const jobId = "job-destroy1";
  const envelope = sealCredentialEnvelope({
    jobId,
    publicKey: manager.publicKey(),
    pkcs12: Buffer.from([0x30, 0x03, 0x02, 0x01, 0x00]),
    password: Buffer.from("test-only-password"),
    expiresAt: new Date(now + 60_000).toISOString(),
  });
  const session = manager.accept(jobId, envelope);
  assert.equal(manager.destroy(session.sessionRef), true);
  await assert.rejects(() => manager.consume(session.sessionRef, jobId, async () => {}), /missing/);
});

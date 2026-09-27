import { generateKeyPairSync, randomUUID, sign, verify } from "node:crypto";

function canonicalReceipt(receipt) {
  return Buffer.from(JSON.stringify({
    adapterRunId: receipt.adapterRunId,
    environment: receipt.environment,
    externalStatus: receipt.externalStatus,
    issuedAt: receipt.issuedAt,
    jobId: receipt.jobId,
    payloadHash: receipt.payloadHash,
    receiptNo: receipt.receiptNo,
  }), "utf8");
}

export function createSandboxSigner() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const keyId = randomUUID();
  return {
    keyId,
    publicKeyPem: publicKey.export({ type: "spki", format: "pem" }),
    issue({ jobId, payloadHash, externalStatus = "ACCEPTED" }) {
      const receipt = {
        adapterRunId: randomUUID(),
        environment: "sandbox",
        externalStatus,
        issuedAt: new Date().toISOString(),
        jobId,
        payloadHash,
        receiptNo: `SIM-${randomUUID()}`,
      };
      return {
        receipt,
        signature: sign(null, canonicalReceipt(receipt), privateKey).toString("base64url"),
        signatureAlgorithm: "Ed25519",
        signingKeyId: keyId,
      };
    },
  };
}

export function verifySignedSandboxReceipt({ envelope, expectedJobId, expectedPayloadHash, trustedKeys, now = Date.now(), maxAgeMs = 5 * 60 * 1000 }) {
  if (envelope?.signatureAlgorithm !== "Ed25519") throw new Error("unsupported receipt signature algorithm");
  const publicKey = trustedKeys.get(envelope.signingKeyId);
  if (!publicKey) throw new Error("receipt signing key is not trusted");
  const receipt = envelope.receipt;
  if (receipt?.environment !== "sandbox") throw new Error("only sandbox receipts are accepted by this verifier");
  if (receipt.jobId !== expectedJobId || receipt.payloadHash !== expectedPayloadHash) throw new Error("receipt is not bound to the expected job and payload");
  if (!receipt.receiptNo || !receipt.adapterRunId || receipt.externalStatus !== "ACCEPTED") throw new Error("receipt fields are incomplete or not accepted");
  const issuedAt = Date.parse(receipt.issuedAt);
  if (!Number.isFinite(issuedAt) || issuedAt > now + 30_000 || issuedAt < now - maxAgeMs) throw new Error("receipt timestamp is outside the acceptance window");
  const ok = verify(null, canonicalReceipt(receipt), publicKey, Buffer.from(envelope.signature, "base64url"));
  if (!ok) throw new Error("receipt signature is invalid");
  return structuredClone(receipt);
}

import {
  constants,
  createCipheriv,
  createDecipheriv,
  generateKeyPairSync,
  privateDecrypt,
  publicEncrypt,
  randomBytes,
  randomUUID,
} from "node:crypto";

const MAX_TTL_MS = 5 * 60 * 1000;
const MAX_CERT_BYTES = 128 * 1024;
const MAX_PASSWORD_BYTES = 1024;

const b64u = (value) => Buffer.from(value).toString("base64url");
const fromB64u = (value) => Buffer.from(value, "base64url");
const aadFor = ({ jobId, keyId, expiresAt }) =>
  Buffer.from(`${jobId}.${keyId}.${expiresAt}`, "utf8");

function assertEnvelopeTime(expiresAt, now) {
  const expiry = Date.parse(expiresAt);
  if (!Number.isFinite(expiry) || expiry <= now || expiry > now + MAX_TTL_MS) {
    throw new Error("credential session expiry must be within five minutes");
  }
  return expiry;
}

function packSecret(pkcs12, password) {
  const cert = Buffer.from(pkcs12);
  const pass = Buffer.from(password);
  if (cert.length === 0 || cert.length > MAX_CERT_BYTES || cert[0] !== 0x30) {
    throw new Error("invalid PKCS#12 payload");
  }
  if (pass.length === 0 || pass.length > MAX_PASSWORD_BYTES) {
    throw new Error("invalid certificate password");
  }
  const packed = Buffer.allocUnsafe(4 + cert.length + pass.length);
  packed.writeUInt32BE(cert.length, 0);
  cert.copy(packed, 4);
  pass.copy(packed, 4 + cert.length);
  pass.fill(0);
  return packed;
}

function unpackSecret(packed) {
  if (packed.length < 6) throw new Error("invalid credential payload");
  const certLength = packed.readUInt32BE(0);
  const passwordLength = packed.length - 4 - certLength;
  if (certLength < 1 || certLength > MAX_CERT_BYTES || passwordLength < 1 || passwordLength > MAX_PASSWORD_BYTES) {
    throw new Error("invalid credential payload bounds");
  }
  const pkcs12 = Buffer.from(packed.subarray(4, 4 + certLength));
  const password = Buffer.from(packed.subarray(4 + certLength));
  if (pkcs12[0] !== 0x30) {
    pkcs12.fill(0);
    password.fill(0);
    throw new Error("invalid PKCS#12 payload");
  }
  return { pkcs12, password };
}

export class CredentialSessionManager {
  #privateKey;
  #publicKeyPem;
  #keyId;
  #keyExpiresAt;
  #sessions = new Map();
  #now;

  constructor({ now = () => Date.now(), keyTtlMs = 15 * 60 * 1000 } = {}) {
    this.#now = now;
    const { publicKey, privateKey } = generateKeyPairSync("rsa", {
      modulusLength: 3072,
      publicExponent: 0x10001,
    });
    this.#privateKey = privateKey;
    this.#publicKeyPem = publicKey.export({ type: "spki", format: "pem" });
    this.#keyId = randomUUID();
    this.#keyExpiresAt = this.#now() + keyTtlMs;
  }

  publicKey() {
    return {
      keyId: this.#keyId,
      pem: this.#publicKeyPem,
      algorithm: "RSA-OAEP-256+A256GCM",
      expiresAt: new Date(this.#keyExpiresAt).toISOString(),
    };
  }

  accept(jobId, envelope) {
    this.cleanup();
    if (typeof jobId !== "string" || jobId.length < 8) throw new Error("job id required");
    if (envelope.keyId !== this.#keyId || this.#now() >= this.#keyExpiresAt) {
      throw new Error("worker encryption key is invalid or expired");
    }
    const expiry = assertEnvelopeTime(envelope.expiresAt, this.#now());
    const encryptedKey = fromB64u(envelope.encryptedKey);
    const iv = fromB64u(envelope.iv);
    const ciphertext = fromB64u(envelope.ciphertext);
    const tag = fromB64u(envelope.tag);
    if (iv.length !== 12 || tag.length !== 16 || ciphertext.length > MAX_CERT_BYTES + MAX_PASSWORD_BYTES + 4) {
      throw new Error("invalid encrypted envelope bounds");
    }

    let aesKey;
    let plaintext;
    try {
      aesKey = privateDecrypt({ key: this.#privateKey, oaepHash: "sha256", padding: constants.RSA_PKCS1_OAEP_PADDING }, encryptedKey);
      if (aesKey.length !== 32) throw new Error("invalid content encryption key");
      const decipher = createDecipheriv("aes-256-gcm", aesKey, iv);
      decipher.setAAD(aadFor({ jobId, keyId: envelope.keyId, expiresAt: envelope.expiresAt }));
      decipher.setAuthTag(tag);
      plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
      const secret = unpackSecret(plaintext);
      const sessionRef = randomUUID();
      this.#sessions.set(sessionRef, { ...secret, jobId, expiresAt: expiry });
      return { sessionRef, expiresAt: envelope.expiresAt };
    } finally {
      encryptedKey.fill(0);
      ciphertext.fill(0);
      aesKey?.fill(0);
      plaintext?.fill(0);
    }
  }

  async consume(sessionRef, jobId, callback) {
    const secret = this.#sessions.get(sessionRef);
    this.#sessions.delete(sessionRef);
    if (!secret || secret.jobId !== jobId || secret.expiresAt <= this.#now()) {
      if (secret) this.#zeroize(secret);
      throw new Error("credential session is missing, mismatched, or expired");
    }
    try {
      return await callback({ pkcs12: secret.pkcs12, password: secret.password });
    } finally {
      this.#zeroize(secret);
    }
  }

  destroy(sessionRef) {
    const secret = this.#sessions.get(sessionRef);
    this.#sessions.delete(sessionRef);
    if (secret) this.#zeroize(secret);
    return Boolean(secret);
  }

  cleanup() {
    for (const [sessionRef, secret] of this.#sessions) {
      if (secret.expiresAt <= this.#now()) {
        this.#sessions.delete(sessionRef);
        this.#zeroize(secret);
      }
    }
  }

  #zeroize(secret) {
    secret.pkcs12.fill(0);
    secret.password.fill(0);
  }
}

export function sealCredentialEnvelope({ jobId, publicKey, pkcs12, password, expiresAt }) {
  const aesKey = randomBytes(32);
  const iv = randomBytes(12);
  const packed = packSecret(pkcs12, password);
  try {
    const cipher = createCipheriv("aes-256-gcm", aesKey, iv);
    cipher.setAAD(aadFor({ jobId, keyId: publicKey.keyId, expiresAt }));
    const ciphertext = Buffer.concat([cipher.update(packed), cipher.final()]);
    return {
      keyId: publicKey.keyId,
      expiresAt,
      encryptedKey: b64u(publicEncrypt({ key: publicKey.pem, oaepHash: "sha256", padding: constants.RSA_PKCS1_OAEP_PADDING }, aesKey)),
      iv: b64u(iv),
      ciphertext: b64u(ciphertext),
      tag: b64u(cipher.getAuthTag()),
    };
  } finally {
    aesKey.fill(0);
    packed.fill(0);
  }
}

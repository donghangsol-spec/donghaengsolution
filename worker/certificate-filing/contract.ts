export type FilingProvider = "4INSURE" | "EDI" | "OTHER_APPROVED_CHANNEL";
export type FilingJobStatus =
  | "queued"
  | "claimed"
  | "awaiting_human_confirmation"
  | "submitting"
  | "accepted"
  | "rejected"
  | "failed"
  | "cancelled";

export interface FilingJob {
  id: string;
  insuranceRequestId: string;
  companyId: string;
  provider: FilingProvider;
  idempotencyKey: string;
}

export interface OneTimeCredentialEnvelope {
  /** Opaque server-issued reference, not a URL or database object path. */
  sessionRef: string;
  /** PKCS#12 bytes and password encrypted to the worker's rotating public key. */
  ciphertext: string;
  algorithm: "RSA-OAEP-256+A256GCM";
  expiresAt: string;
}

export interface FilingPreview {
  jobId: string;
  maskedCompanyRegistrationNo: string;
  employeeCount: number;
  requestType: "취득" | "상실" | "변경";
  payloadHash: string;
}

/**
 * Required worker behavior:
 * 1. Claim by idempotency key.
 * 2. Decrypt only in memory inside the isolated worker.
 * 3. Validate certificate owner, expiry and delegated company.
 * 4. Produce a masked preview and wait for human confirmation.
 * 5. Submit once through an approved official channel.
 * 6. Zeroize buffers and destroy the credential session.
 * 7. Return only receipt/status/error metadata.
 */
export interface CertificateFilingAdapter {
  getEncryptionPublicKey(): Promise<{ keyId: string; pem: string; expiresAt: string }>;
  attachOneTimeCredential(job: FilingJob, envelope: OneTimeCredentialEnvelope): Promise<void>;
  preparePreview(job: FilingJob): Promise<FilingPreview>;
  confirmAndSubmit(job: FilingJob, previewHash: string, approvedBy: string): Promise<{
    receiptNo: string;
    externalStatus: string;
  }>;
  destroyCredentialSession(sessionRef: string): Promise<void>;
}

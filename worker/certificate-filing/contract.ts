export type FilingProvider = "4INSURE" | "EDI" | "OTHER_APPROVED_CHANNEL";
export type FilingExecutionMode = "OFFICIAL_API" | "EDI" | "TRUSTED_WORKER_MACRO";
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
  executionMode: FilingExecutionMode;
  environment: "sandbox" | "production";
}

export interface OneTimeCredentialEnvelope {
  /** Opaque server-issued reference, not a URL or database object path. */
  sessionRef: string;
  /** PKCS#12 bytes and password encrypted to the worker's rotating public key. */
  ciphertext: string;
  algorithm: "RSA-OAEP-256+A256GCM";
  expiresAt: string;
}

export interface MacroSecurityPolicy {
  isolatedDesktop: true;
  secretsInMemoryOnly: true;
  allowCaptchaBypass: false;
  allowMfaBypass: false;
  requireHumanHandoffForChallenge: true;
  redactLogs: true;
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
export interface FilingReceipt {
  receiptNo: string;
  externalStatus: string;
  payloadHash: string;
  adapterRunId: string;
  environment: "sandbox" | "production";
}

export interface CertificateFilingAdapter {
  getEncryptionPublicKey(): Promise<{ keyId: string; pem: string; expiresAt: string }>;
  attachOneTimeCredential(job: FilingJob, envelope: OneTimeCredentialEnvelope): Promise<void>;
  preparePreview(job: FilingJob): Promise<FilingPreview>;
  confirmAndSubmit(job: FilingJob, previewHash: string, approvedBy: string): Promise<FilingReceipt>;
  destroyCredentialSession(sessionRef: string): Promise<void>;
}

/**
 * Browser automation is an explicit fallback adapter, not a client-side macro.
 * It runs only in an isolated trusted worker and must stop for CAPTCHA, MFA,
 * certificate-selection prompts, or any unexpected confirmation boundary.
 */
export interface TrustedWorkerMacroAdapter extends CertificateFilingAdapter {
  readonly executionMode: "TRUSTED_WORKER_MACRO";
  readonly securityPolicy: MacroSecurityPolicy;
  runUntilHumanBoundary(job: FilingJob): Promise<
    | { state: "awaiting_human_confirmation"; preview: FilingPreview }
    | { state: "human_handoff_required"; reason: "CAPTCHA" | "MFA" | "CERTIFICATE_SELECTION" | "UNEXPECTED_CONFIRMATION" }
  >;
}

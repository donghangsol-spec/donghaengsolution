import { createHash, timingSafeEqual } from "node:crypto";

const CHALLENGES = new Set(["CAPTCHA", "MFA", "CERTIFICATE_SELECTION", "UNEXPECTED_CONFIRMATION"]);
const APPROVER_ROLES = new Set(["owner", "admin", "reviewer"]);

function sameHash(left, right) {
  const a = Buffer.from(left ?? "");
  const b = Buffer.from(right ?? "");
  return a.length === b.length && timingSafeEqual(a, b);
}

export function hashPreview(preview) {
  const canonical = JSON.stringify({
    jobId: preview.jobId,
    companyRegistrationNo: preview.maskedCompanyRegistrationNo,
    employeeCount: preview.employeeCount,
    requestType: preview.requestType,
  });
  return createHash("sha256").update(canonical).digest("hex");
}

export class MacroRunCoordinator {
  #driver;
  #allowProduction;
  #state = "idle";
  #preview;

  constructor({ driver, allowProduction = false }) {
    if (!driver) throw new Error("macro driver required");
    this.#driver = driver;
    this.#allowProduction = allowProduction;
  }

  get state() { return this.#state; }

  async prepare(job, credentialSession) {
    if (this.#state !== "idle") throw new Error("macro run already started");
    if (job.executionMode !== "TRUSTED_WORKER_MACRO") throw new Error("unsupported execution mode");
    if (job.environment === "production" && !this.#allowProduction) throw new Error("production filing is disabled");

    this.#state = "navigating";
    const result = await credentialSession(async (credential) => this.#driver.runUntilBoundary(job, credential));
    if (result?.challenge) {
      if (!CHALLENGES.has(result.challenge)) throw new Error("unknown human boundary");
      this.#state = "human_handoff_required";
      return { state: this.#state, reason: result.challenge, requiresNewCredentialSession: true };
    }
    if (!result?.preview) throw new Error("macro driver returned no preview or challenge");
    const calculated = hashPreview(result.preview);
    if (!sameHash(calculated, result.preview.payloadHash)) throw new Error("preview hash mismatch");
    this.#preview = structuredClone(result.preview);
    this.#state = "awaiting_human_confirmation";
    return { state: this.#state, preview: structuredClone(this.#preview) };
  }

  async submit(job, confirmation) {
    if (this.#state !== "awaiting_human_confirmation" || !this.#preview) throw new Error("preview is not awaiting confirmation");
    if (confirmation.jobId !== job.id || !sameHash(confirmation.payloadHash, this.#preview.payloadHash)) {
      throw new Error("confirmation is not bound to this preview");
    }
    if (!APPROVER_ROLES.has(confirmation.approverRole)) throw new Error("confirmation role is not allowed");
    const expiresAt = Date.parse(confirmation.expiresAt);
    if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) throw new Error("confirmation expired");

    this.#state = "submitting";
    const result = await this.#driver.submitConfirmed(job, structuredClone(this.#preview));
    if (!result?.receiptNo || !sameHash(result.payloadHash, this.#preview.payloadHash)) {
      this.#state = "failed";
      throw new Error("receipt validation failed");
    }
    this.#state = "accepted";
    return structuredClone(result);
  }
}

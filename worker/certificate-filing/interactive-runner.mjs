import { MacroRunCoordinator } from "./macro-runner.mjs";
import { createServerGateClient } from "./server-gate-client.mjs";

function assertSandboxJob(job) {
  if (!job || typeof job.id !== "string" || job.id.length < 8) throw new Error("valid filing job required");
  if (job.environment !== "sandbox") throw new Error("interactive runner is sandbox-only");
  if (job.executionMode !== "TRUSTED_WORKER_MACRO") throw new Error("trusted worker macro mode required");
}

export function createInteractiveSandboxRunner({
  driver,
  credentialSession,
  gateBaseUrl,
  workerToken,
  fetchImpl = globalThis.fetch,
  timeoutMs,
}) {
  if (typeof credentialSession !== "function") throw new Error("credential session consumer required");

  const gate = createServerGateClient({
    baseUrl: gateBaseUrl,
    workerToken,
    fetchImpl,
    ...(timeoutMs === undefined ? {} : { timeoutMs }),
  });
  const coordinator = new MacroRunCoordinator({
    driver,
    allowProduction: false,
    confirmationVerifier: (binding) => gate.verifyConfirmation(binding),
    receiptRecorder: (record) => gate.recordReceipt(record),
  });

  return Object.freeze({
    get state() {
      return coordinator.state;
    },

    async prepare(job) {
      assertSandboxJob(job);
      return coordinator.prepare(job, credentialSession);
    },

    async submit(job) {
      assertSandboxJob(job);
      return coordinator.submit(job);
    },
  });
}

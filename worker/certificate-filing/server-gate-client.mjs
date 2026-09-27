const DEFAULT_TIMEOUT_MS = 10_000;

function assertHttps(url) {
  if (url.protocol !== "https:") throw new Error("filing gate endpoint must use HTTPS");
}

function assertToken(token) {
  if (typeof token !== "string" || Buffer.byteLength(token) < 32) {
    throw new Error("worker gate token must contain at least 32 bytes");
  }
}

function assertHash(value, label) {
  if (!/^[a-f0-9]{64}$/.test(value ?? "")) throw new Error(`${label} must be a SHA-256 hex digest`);
}

export function createServerGateClient({ baseUrl, workerToken, fetchImpl = globalThis.fetch, timeoutMs = DEFAULT_TIMEOUT_MS }) {
  const root = new URL(baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`);
  assertHttps(root);
  assertToken(workerToken);
  if (typeof fetchImpl !== "function") throw new Error("fetch implementation required");
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1_000 || timeoutMs > 30_000) throw new Error("invalid gate timeout");

  async function post(path, body) {
    const response = await fetchImpl(new URL(path.replace(/^\//, ""), root), {
      method: "POST",
      headers: {
        "x-worker-token": workerToken,
        "content-type": "application/json",
        "cache-control": "no-store",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
      redirect: "error",
    });
    if (!response.ok) throw new Error(`filing gate rejected request (${response.status})`);
    const result = await response.json();
    if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error("invalid filing gate response");
    return result;
  }

  return Object.freeze({
    async verifyConfirmation({ jobId, payloadHash, environment }) {
      assertHash(payloadHash, "payloadHash");
      if (environment !== "sandbox") throw new Error("production confirmation is disabled");
      const result = await post("v1/filing-confirmations/verify", { jobId, payloadHash, environment });
      return {
        confirmed: result.confirmed === true,
        jobId: result.jobId,
        payloadHash: result.payloadHash,
        expiresAt: result.expiresAt,
      };
    },

    async recordReceipt({ jobId, receipt }) {
      assertHash(receipt?.payloadHash, "receipt payloadHash");
      if (receipt?.environment !== "sandbox") throw new Error("production receipt recording is disabled");
      const result = await post("v1/filing-receipts", { jobId, receipt });
      return { accepted: result.accepted === true, duplicate: result.duplicate === true };
    },
  });
}

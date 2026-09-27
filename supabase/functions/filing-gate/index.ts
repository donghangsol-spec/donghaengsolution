import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

async function tokenMatches(supplied: string, expected: string) {
  const encoder = new TextEncoder();
  const [left, right] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const a = new Uint8Array(left);
  const b = new Uint8Array(right);
  let difference = a.length ^ b.length;
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    difference |= (a[index] ?? 0) ^ (b[index] ?? 0);
  }
  return difference === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const configuredToken = Deno.env.get("FILING_WORKER_TOKEN") ?? "";
  const suppliedToken = req.headers.get("x-worker-token") ?? "";
  if (configuredToken.length < 32 || suppliedToken.length < 32 || !(await tokenMatches(suppliedToken, configuredToken))) {
    return reply(401, { error: "unauthorized" });
  }

  const rawBody = await req.text();
  if (new TextEncoder().encode(rawBody).byteLength > 32 * 1024) return reply(413, { error: "body_too_large" });

  let body: Record<string, unknown>;
  try {
    body = JSON.parse(rawBody);
  } catch {
    return reply(400, { error: "invalid_json" });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply(503, { error: "server_not_configured" });

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const path = new URL(req.url).pathname;

  try {
    if (path.endsWith("/v1/filing-confirmations/verify")) {
      if (body.environment !== "sandbox") return reply(403, { error: "production_disabled" });
      const { data, error } = await admin.rpc("verify_filing_confirmation_worker", {
        p_job_id: body.jobId,
        p_payload_hash: body.payloadHash,
      });
      if (error) return reply(403, { error: "confirmation_rejected" });
      const row = Array.isArray(data) ? data[0] : null;
      if (!row?.confirmed) return reply(200, { confirmed: false });
      return reply(200, {
        confirmed: true,
        jobId: row.job_id,
        payloadHash: row.payload_hash,
        expiresAt: row.expires_at,
      });
    }

    if (path.endsWith("/v1/filing-receipts")) {
      const receipt = body.receipt as Record<string, unknown> | undefined;
      if (receipt?.environment !== "sandbox") return reply(403, { error: "production_disabled" });
      const { data, error } = await admin.rpc("record_filing_receipt_worker", {
        p_job_id: body.jobId,
        p_adapter_run_id: receipt?.adapterRunId,
        p_receipt_no: receipt?.receiptNo,
        p_external_status: receipt?.externalStatus,
        p_payload_hash: receipt?.payloadHash,
        p_is_sandbox: true,
      });
      if (error) return reply(409, { error: "receipt_rejected" });
      return reply(200, {
        accepted: data?.accepted === true,
        duplicate: data?.duplicate === true,
      });
    }

    return reply(404, { error: "not_found" });
  } catch {
    return reply(500, { error: "internal_error" });
  }
});

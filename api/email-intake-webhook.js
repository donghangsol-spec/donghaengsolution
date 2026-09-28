import { createHmac, timingSafeEqual } from "node:crypto";

export const config = { api: { bodyParser: false } };

const MAX_BYTES = 1024 * 1024;
const EMAIL_ID = /^[0-9a-f-]{36}$/i;
const EMAIL = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;

export function verifySignature(raw, headers, secret, now = Date.now()) {
  const id = headers["svix-id"];
  const timestamp = headers["svix-timestamp"];
  const signatures = headers["svix-signature"];
  if (typeof id !== "string" || !/^[\w-]{1,128}$/.test(id) ||
      typeof timestamp !== "string" || !/^\d{10}$/.test(timestamp) ||
      typeof signatures !== "string" || !secret?.startsWith("whsec_")) return false;
  if (Math.abs(now / 1000 - Number(timestamp)) > 300) return false;
  const key = Buffer.from(secret.slice(6), "base64");
  if (key.length < 16) return false;
  const expected = createHmac("sha256", key)
    .update(id + "." + timestamp + ".").update(raw).digest();
  return signatures.split(" ").some(part => {
    if (!part.startsWith("v1,")) return false;
    const actual = Buffer.from(part.slice(3), "base64");
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  });
}

export function classifyEmail(subject, text) {
  const source = (String(subject || "") + " " + String(text || "").slice(0, 10000)).toLowerCase();
  if (/취득|상실|보수월액|4대보험/.test(source)) return "insurance";
  if (/급여대장|임금대장|급여명세/.test(source)) return "payroll";
  if (/거래내역|입출금|계좌거래|통장거래/.test(source)) return "transaction";
  return "unknown";
}

async function rawBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BYTES) throw new Error("payload_too_large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

const address = value => String(value || "").match(/<([^<>]+)>/)?.[1]?.toLowerCase() ||
  String(value || "").trim().toLowerCase();
const configuredList = value => String(value || "").split(",").map(x => x.trim().toLowerCase()).filter(Boolean);

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method === "GET") return res.status(200).json({ enabled: process.env.EMAIL_INTAKE_ENABLED === "true" });
  if (req.method !== "POST") return res.status(405).json({ error: "method_not_allowed" });
  // Production ingestion is opt-in only after retention, role and mailbox checks.
  if (process.env.EMAIL_INTAKE_ENABLED !== "true") return res.status(503).json({ error: "intake_disabled" });
  const { RESEND_WEBHOOK_SECRET: secret, RESEND_API_KEY: resendKey,
    SUPABASE_URL: dbUrl, SUPABASE_SERVICE_ROLE_KEY: dbKey,
    EMAIL_INTAKE_ORGANIZATION_ID: orgId } = process.env;
  const senders = configuredList(process.env.EMAIL_INTAKE_ALLOWED_SENDERS);
  const recipients = configuredList(process.env.EMAIL_INTAKE_RECIPIENTS);
  if (!secret || !resendKey || !dbUrl || !dbKey || !orgId || !senders.length || !recipients.length) {
    return res.status(503).json({ error: "intake_not_configured" });
  }
  let raw;
  try { raw = await rawBody(req); } catch { return res.status(413).json({ error: "payload_too_large" }); }
  if (!verifySignature(raw, req.headers, secret)) return res.status(401).json({ error: "invalid_signature" });
  let event;
  try { event = JSON.parse(raw.toString("utf8")); } catch { return res.status(400).json({ error: "invalid_payload" }); }
  if (event.type !== "email.received") return res.status(200).json({ ok: true, ignored: true });
  const id = event.data?.email_id;
  if (typeof id !== "string" || !EMAIL_ID.test(id)) return res.status(400).json({ error: "invalid_email_id" });
  try {
    const mailResponse = await fetch("https://api.resend.com/emails/receiving/" + encodeURIComponent(id), {
      headers: { Authorization: "Bearer " + resendKey },
    });
    if (!mailResponse.ok) throw new Error("mail_fetch_failed");
    const mail = await mailResponse.json();
    if (mail.id !== id) throw new Error("mail_id_mismatch");
    const sender = address(mail.from);
    const to = (Array.isArray(mail.to) ? mail.to : []).map(address);
    const authenticated = ["dkim", "dmarc"].some(k => mail.authentication?.[k] === "pass");
    // Forwarded mail may preserve DKIM. If authentication breaks, review forwarding rules;
    // never accept a spoofable From header alone.
    if (!authenticated || !EMAIL.test(sender) || !senders.includes(sender) || !to.some(x => recipients.includes(x))) {
      return res.status(200).json({ ok: true, ignored: true });
    }
    const category = classifyEmail(mail.subject, mail.text);
    const dbResponse = await fetch(dbUrl.replace(/\/$/, "") + "/rest/v1/email_intake_messages?on_conflict=provider,provider_message_id", {
      method: "POST",
      headers: {
        apikey: dbKey, Authorization: "Bearer " + dbKey,
        "Content-Type": "application/json", Prefer: "resolution=ignore-duplicates,return=minimal",
      },
      body: JSON.stringify({
        organization_id: orgId, provider: "resend", provider_message_id: id,
        sender, subject: String(mail.subject || "").slice(0, 300),
        received_at: mail.created_at || new Date().toISOString(),
        processing_status: "review_required", classification: category,
      }),
    });
    if (!dbResponse.ok) throw new Error("intake_save_failed");
    return res.status(200).json({ ok: true });
  } catch (error) {
    console.error("email_intake_error", error.message);
    return res.status(502).json({ error: "intake_failed" });
  }
}

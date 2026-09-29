import { intakeConfigured, intakeSettings, processReceivedEmail } from "./email-intake-webhook.js";
import { contentDraftHeaders } from "./email-content-draft.js";

// Load the Naver collector after the request reaches the enabled branch.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") return res.status(405).json({ error: "method_not_allowed" });
  if (process.env.NAVER_IMAP_ENABLED === "true") {
    const token = String(req.headers.authorization || "").match(/^Bearer (\S+)$/i)?.[1];
    if (!token) return res.status(401).json({ error: "authentication_required" });
    let collectNaver, naverConfigured, naverSettings;
    try {
      ({ collectNaver, naverConfigured, naverSettings } = await import("./naver-imap.js"));
    } catch (error) {
      console.error("naver_intake_initialization_error", error.message);
      return res.status(502).json({ error: "collector_initialization_failed" });
    }
    const settings = naverSettings();
    if (!naverConfigured(settings) || !process.env.SUPABASE_ANON_KEY) return res.status(503).json({ error: "intake_not_configured" });
    const base = settings.dbUrl.replace(/\/$/, "");
    try {
      const userResponse = await fetch(base + "/auth/v1/user", { headers: { apikey: process.env.SUPABASE_ANON_KEY, Authorization: "Bearer " + token } });
      if (!userResponse.ok) return res.status(401).json({ error: "authentication_required" });
      const user = await userResponse.json();
      if (!UUID.test(user.id || "") || !UUID.test(settings.organizationId)) return res.status(403).json({ error: "access_denied" });
      const query = new URLSearchParams({ select: "role", organization_id: "eq." + settings.organizationId, user_id: "eq." + user.id, limit: "1" });
      const membership = await fetch(base + "/rest/v1/organization_members?" + query, { headers: contentDraftHeaders(settings.dbKey) });
      if (!membership.ok) throw new Error("membership_check_failed");
      const members = await membership.json();
      if (!["owner", "admin", "reviewer"].includes(members?.[0]?.role)) return res.status(403).json({ error: "access_denied" });
      return res.status(200).json(await collectNaver(settings));
    } catch (error) {
      console.error("naver_intake_collect_error", error.message);
      return res.status(502).json({ error: "collection_failed" });
    }
  }
  if (process.env.EMAIL_INTAKE_ENABLED !== "true") return res.status(503).json({ error: "intake_disabled" });
  const settings = intakeSettings();
  const anonKey = process.env.SUPABASE_ANON_KEY;
  if (!anonKey || !intakeConfigured(settings)) return res.status(503).json({ error: "intake_not_configured" });
  const token = String(req.headers.authorization || "").match(/^Bearer (\S+)$/i)?.[1];
  if (!token) return res.status(401).json({ error: "authentication_required" });
  const base = settings.dbUrl.replace(/\/$/, "");
  try {
    const userResponse = await fetch(base + "/auth/v1/user", {
      headers: { apikey: anonKey, Authorization: "Bearer " + token },
    });
    if (!userResponse.ok) return res.status(401).json({ error: "authentication_required" });
    const user = await userResponse.json();
    if (!UUID.test(user.id || "") || !UUID.test(settings.orgId)) return res.status(403).json({ error: "access_denied" });
    const query = new URLSearchParams({
      select: "role", organization_id: "eq." + settings.orgId,
      user_id: "eq." + user.id, limit: "1",
    });
    const memberResponse = await fetch(base + "/rest/v1/organization_members?" + query, {
      headers: contentDraftHeaders(settings.dbKey),
    });
    if (!memberResponse.ok) throw new Error("membership_check_failed");
    const members = await memberResponse.json();
    if (!["owner", "admin", "reviewer"].includes(members?.[0]?.role)) {
      return res.status(403).json({ error: "access_denied" });
    }
    // Bound this manual pass to Resend's first page; the webhook handles new arrivals.
    const listResponse = await fetch("https://api.resend.com/emails/receiving", {
      headers: { Authorization: "Bearer " + settings.resendKey },
    });
    if (!listResponse.ok) throw new Error("mail_list_failed");
    const list = await listResponse.json();
    if (!Array.isArray(list.data)) throw new Error("mail_list_invalid");
    let reviewed = 0, ignored = 0;
    for (const item of list.data.slice(0, 20)) {
      const result = await processReceivedEmail(item.id, settings);
      if (result === "ignored") ignored++;
      else reviewed++;
    }
    return res.status(200).json({ ok: true, checked: Math.min(list.data.length, 20), reviewed, ignored,
      has_more: !!list.has_more });
  } catch (error) {
    console.error("email_intake_collect_error", error.message);
    return res.status(502).json({ error: "collection_failed" });
  }
}

const clean = (value, max) => String(value || "").trim().slice(0, max);

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") return res.status(405).json({ error: "method_not_allowed" });

  const name = clean(req.body?.name, 80);
  const phone = clean(req.body?.phone, 30);
  const topic = clean(req.body?.topic, 40);
  const message = clean(req.body?.message, 1000);
  if (!name || !phone || req.body?.privacy !== "on") return res.status(400).json({ error: "required_fields_missing" });
  if (!/^[0-9+()\-\s]{8,30}$/.test(phone)) return res.status(400).json({ error: "invalid_phone" });

  const apiKey = process.env.RESEND_API_KEY;
  const to = process.env.CONTACT_TO_EMAIL;
  const from = process.env.CONTACT_FROM_EMAIL || "동행솔루션 <noreply@donghangsolution.co.kr>";
  if (!apiKey || !to) return res.status(503).json({ error: "contact_service_not_configured" });

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from,
      to: [to],
      subject: `[동행솔루션 상담] ${topic || "기관 운영 문의"} · ${name}`,
      text: `성함·기관명: ${name}\n연락처: ${phone}\n상담 분야: ${topic}\n\n문의 내용\n${message || "(내용 없음)"}`,
    }),
  });
  if (!response.ok) return res.status(502).json({ error: "email_delivery_failed" });
  return res.status(200).json({ ok: true });
}

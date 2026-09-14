import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins = new Set(
  (Deno.env.get("ALLOWED_ORIGINS") || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean),
);

function corsHeaders(req: Request) {
  const origin = req.headers.get("Origin");
  const allowedOrigin = origin && allowedOrigins.has(origin) ? origin : null;
  return {
    ...(allowedOrigin ? { "Access-Control-Allow-Origin": allowedOrigin } : {}),
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

Deno.serve(async (req: Request) => {
  const cors = corsHeaders(req);
  const origin = req.headers.get("Origin");
  if (origin && !allowedOrigins.has(origin)) {
    return new Response(JSON.stringify({ error: "origin_not_allowed" }), {
      status: 403,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: cors });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ error: "missing_authorization" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return new Response(JSON.stringify({ error: "invalid_user" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch {}
  const requestedName = String(body.organization_name || "동행솔루션").trim().slice(0, 80) || "동행솔루션";
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data, error } = await admin.rpc("onboard_owner_internal", { p_user_id: user.id, p_org_name: requestedName });
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  return new Response(JSON.stringify(data), { headers: { ...cors, "Content-Type": "application/json" } });
});
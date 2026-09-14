export default function handler(req, res) {
  const supabaseUrl = process.env.SUPABASE_URL;
  const supabaseAnonKey = process.env.SUPABASE_ANON_KEY;

  res.setHeader("Content-Type", "application/javascript; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");

  if (!supabaseUrl || !supabaseAnonKey) {
    res.status(503).send(
      "window.__DONGHAENG_CONFIG__ = null; console.error('Missing SUPABASE_URL or SUPABASE_ANON_KEY');",
    );
    return;
  }

  const config = JSON.stringify({ supabaseUrl, supabaseAnonKey }).replace(/</g, "\\u003c");
  res.status(200).send(`window.__DONGHAENG_CONFIG__ = ${config};`);
}

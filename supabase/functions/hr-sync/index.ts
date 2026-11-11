// hr-sync: receives attendance records pushed by the local attendance PC and upserts them via hr_sync_push().
// Auth: shared secret in the `x-sync-key` header (Edge Function secret HR_SYNC_KEY). Deploy with verify_jwt = false.
// No biometric data is ever sent here: only IDs, names, batches, emails and check-in/out times.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const MAX_BYTES = 5_000_000;

function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const secret = Deno.env.get("HR_SYNC_KEY") ?? "";
  const given = req.headers.get("x-sync-key") ?? "";
  if (secret.length < 32 || !safeEqual(given, secret)) return json({ error: "unauthorised" }, 401);

  const raw = await req.text();
  if (raw.length > MAX_BYTES) return json({ error: "payload too large; send smaller batches" }, 413);
  let payload: Record<string, unknown>;
  try { payload = JSON.parse(raw); } catch { return json({ error: "invalid JSON" }, 400); }

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data, error } = await admin.rpc("hr_sync_push", { p: payload });
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true, ...data });
});

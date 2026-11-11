// hr-invite: lets an HR admin (profiles.role = 'admin') email account invites to people / guardians
// listed in hr_people who don't have a login yet. Deploy with verify_jwt = true.
// Once the invitee sets a password and signs in at hr.datascienceacademia.in, hr_link_me() links them by email.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SITE = Deno.env.get("HR_SITE_URL") ?? "https://hr.datascienceacademia.in";
const cors = {
  "Access-Control-Allow-Origin": SITE,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false },
  });
  const { data: isAdmin, error: adminErr } = await caller.rpc("is_admin");
  if (adminErr || !isAdmin) return json({ error: "Only admins can send invites." }, 403);

  let body: { person_ids?: string[]; who?: "self" | "guardian" | "both" };
  try { body = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
  const ids = (body.person_ids ?? []).slice(0, 200);
  const who = body.who ?? "self";
  if (!ids.length) return json({ error: "No people selected." }, 400);

  const svc = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: people, error } = await svc.from("hr_people")
    .select("id, name, email, guardian_email, active").in("id", ids);
  if (error) return json({ error: error.message }, 500);

  const results: { name: string; email: string; status: string }[] = [];
  for (const p of people ?? []) {
    if (!p.active) continue;
    const targets: { email: string; label: string }[] = [];
    if ((who === "self" || who === "both") && p.email) targets.push({ email: p.email, label: p.name });
    if ((who === "guardian" || who === "both") && p.guardian_email)
      targets.push({ email: p.guardian_email, label: `Parent/guardian of ${p.name}` });
    if (!targets.length) { results.push({ name: p.name, email: "", status: "no email on file" }); continue; }
    for (const t of targets) {
      const { error: invErr } = await svc.auth.admin.inviteUserByEmail(t.email, {
        redirectTo: `${SITE}/set-password.html`,
        data: { name: t.label },
      });
      const msg = invErr?.message ?? "";
      results.push({
        name: p.name, email: t.email,
        status: !invErr ? "invited"
          : /already been registered|already exists/i.test(msg) ? "already has an account (can sign in now)"
          : msg,
      });
    }
  }
  return json({ ok: true, results });
});

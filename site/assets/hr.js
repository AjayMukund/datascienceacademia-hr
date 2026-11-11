/* Shared client for hr.datascienceacademia.in. The anon key is public by design; all access is enforced by
   Postgres row-level security and the hr_* functions (admin / trainer / self / guardian). */
const SUPABASE_URL = "https://isoepiysqmqffwhroseh.supabase.co";
const SUPABASE_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlzb2VwaXlzcW1xZmZ3aHJvc2VoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcwMTcyNDQsImV4cCI6MjA5MjU5MzI0NH0.lv4IquTcYPY90TRSy1IZoLktt-yY-GDAPb4gF95Cn7k";
const supa = supabase.createClient(SUPABASE_URL, SUPABASE_ANON, { auth: { persistSession: true, detectSessionInUrl: true } });

const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const hhmm = t => t ? String(t).slice(0, 5) : "—";
const fmtDay = (ds, o = { day: "numeric", month: "short" }) => new Date(ds + "T00:00").toLocaleDateString("en-IN", o);

let toastT;
function toast(m, ms = 4000) {
  let t = document.querySelector(".toast");
  if (!t) { t = document.createElement("div"); t.className = "toast"; document.body.append(t); }
  t.textContent = m; t.classList.remove("hidden");
  clearTimeout(toastT); toastT = setTimeout(() => t.classList.add("hidden"), ms);
}

async function rpc(fn, args = {}) {
  const { data, error } = await supa.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}

function ago(ts) {
  if (!ts) return "never";
  const m = Math.round((Date.now() - Date.parse(ts)) / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  if (m < 1440) return `${Math.round(m / 60)} h ago`;
  return new Date(ts).toLocaleString("en-IN", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}

/* Page guard + header. kind: "dashboard" | "me" | "people". Resolves with the hr_whoami() object. */
async function boot(kind) {
  const { data: { session } } = await supa.auth.getSession();
  if (!session) { location.replace("index.html?next=" + encodeURIComponent(location.pathname.split("/").pop() + location.search)); return new Promise(() => {}); }
  let who;
  try { who = await rpc("hr_link_me"); }
  catch (e) { document.body.innerHTML = `<main><p class="msg err">${esc(e.message)}</p></main>`; throw e; }
  const canDash = who.is_admin || who.trainer_groups.length > 0;
  const hasMe = !!who.self || who.children.length > 0;

  if (kind === "dashboard" && !canDash) { location.replace("me.html"); return new Promise(() => {}); }
  if (kind === "people" && !who.is_admin) { location.replace(canDash ? "dashboard.html" : "me.html"); return new Promise(() => {}); }

  const page = location.pathname.split("/").pop() || "index.html";
  const links = [];
  if (canDash) links.push(["dashboard.html", who.is_admin ? "Dashboard" : "My batches"]);
  if (hasMe) links.push(["me.html", who.children.length && !who.self ? "My child" : "My attendance"]);
  if (who.is_admin) links.push(["people.html", "People & access"]);
  const header = document.createElement("header");
  header.className = "top";
  header.innerHTML = `
    <a class="brand" href="${canDash ? "dashboard.html" : "me.html"}"><b>${esc(who.org_name || "Data Science Academia")}</b><span>HR &amp; Attendance</span></a>
    <nav>${links.map(([h, l]) => `<a href="${h}" class="${page === h ? "active" : ""}">${l}</a>`).join("")}</nav>
    <div class="me"><span class="sync" title="When the attendance PC last sent data">Data as of ${esc(ago(who.last_sync))}</span>
      <span>${esc(who.self?.name || who.email)}</span><button class="link" id="signout">Sign out</button></div>`;
  document.body.prepend(header);
  $("signout").onclick = async () => { await supa.auth.signOut(); location.replace("index.html"); };
  return who;
}

/* Single-series bar chart, 0–100 %, dashed threshold, hover tooltip. rows: [{label, value, tip}] */
function barChart(host, rows, threshold) {
  if (!rows.length) { host.innerHTML = `<p class="empty">No working days with data in this range yet.</p>`; return; }
  const W = host.clientWidth || 800, H = 240, m = { t: 10, r: 8, b: 26, l: 38 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b, n = rows.length, step = iw / n;
  const bw = Math.max(2, Math.min(28, step - 2));
  const y = v => m.t + ih - (v / 100) * ih;
  const every = Math.ceil(n / Math.max(2, Math.floor(iw / 64)));
  let s = `<svg viewBox="0 0 ${W} ${H}" height="${H}" role="img" aria-label="Attendance rate per day">`;
  for (const v of [25, 50, 75, 100]) s += `<line class="gl" x1="${m.l}" x2="${W - m.r}" y1="${y(v)}" y2="${y(v)}"/>`;
  for (const v of [0, 25, 50, 75, 100]) s += `<text x="${m.l - 6}" y="${y(v) + 4}" text-anchor="end">${v}%</text>`;
  rows.forEach((r, i) => {
    const cx = m.l + step * i + step / 2;
    if (r.value != null) {
      const top = y(r.value), yb = m.t + ih, h = yb - top, rr = Math.min(4, bw / 2, h), x0 = cx - bw / 2, x1 = cx + bw / 2;
      s += `<rect class="hit" data-i="${i}" x="${m.l + step * i}" y="${m.t}" width="${step}" height="${ih}"/>`;
      s += h > 0 ? `<path class="bar" d="M${x0},${yb}V${top + rr}Q${x0},${top} ${x0 + rr},${top}H${x1 - rr}Q${x1},${top} ${x1},${top + rr}V${yb}Z"/>` : `<path class="bar"/>`;
    }
    if (i % every === 0 || i === n - 1) s += `<text x="${cx}" y="${H - 8}" text-anchor="middle">${esc(r.label)}</text>`;
  });
  if (threshold != null) s += `<line class="thr" x1="${m.l}" x2="${W - m.r}" y1="${y(threshold)}" y2="${y(threshold)}"/>`;
  s += `<line class="base" x1="${m.l}" x2="${W - m.r}" y1="${m.t + ih}" y2="${m.t + ih}"/></svg><div class="tip hidden"></div>`;
  host.innerHTML = s;
  const tip = host.querySelector(".tip");
  host.querySelectorAll(".hit").forEach(el => {
    el.addEventListener("mouseenter", () => {
      const r = rows[+el.dataset.i], sx = host.clientWidth / W;
      el.nextElementSibling?.classList.add("hover");
      tip.innerHTML = r.tip;
      tip.style.left = Math.min(Math.max((+el.getAttribute("x") + step / 2) * sx, 100), host.clientWidth - 100) + "px";
      tip.style.top = y(r.value) * sx + "px";
      tip.classList.remove("hidden");
    });
    el.addEventListener("mouseleave", () => { el.nextElementSibling?.classList.remove("hover"); tip.classList.add("hidden"); });
  });
}

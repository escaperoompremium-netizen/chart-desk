// Readable source of the "check-alerts" Supabase Edge Function. The deployed copy lives in the Supabase
// dashboard (Edge Functions > check-alerts). Nothing loads this file; edit the function there.
import * as webpush from "jsr:@negrel/webpush@0.5.0";
import { createClient } from "jsr:@supabase/supabase-js@2";
const SITE = "https://escaperoomcharts.com/";
const secretKey = () => { try { return Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}"))[0]; } catch { return undefined; } };
const db = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || secretKey(), { auth: { persistSession: false } });
const out = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const fmt = p => p >= 1000 ? p.toLocaleString("en-US", { maximumFractionDigits: 2 }) : p >= 1 ? p.toFixed(p >= 100 ? 2 : 4) : String(+p.toPrecision(4));
const TF = { 900: "15m", 3600: "1h", 21600: "6h", 86400: "1D" };
const CB = "https://api.exchange.coinbase.com/products/";
let appServer = null;
async function getAppServer() {
  if (appServer) return appServer;
  let { data } = await db.from("app_keys").select("value").eq("name", "vapid").maybeSingle();
  if (!data) {
    const exported = await webpush.exportVapidKeys(await webpush.generateVapidKeys({ extractable: true }));
    await db.from("app_keys").upsert({ name: "vapid", value: exported }, { onConflict: "name", ignoreDuplicates: true });
    ({ data } = await db.from("app_keys").select("value").eq("name", "vapid").single());
  }
  const vapidKeys = await webpush.importVapidKeys(data.value, { extractable: false });
  appServer = await webpush.ApplicationServer.new({ contactInformation: "mailto:alerts@escaperoomcharts.com", vapidKeys });
  return appServer;
}
async function each(list, n, fn) { for (let i = 0; i < list.length; i += n) await Promise.all(list.slice(i, i + n).map(fn)); }
async function getJSON(url) { try { const r = await fetch(url, { headers: { "User-Agent": "escape-room-charts" } }); return r.ok ? await r.json() : null; } catch { return null; } }
function ema(v, n) { const k = 2 / (n + 1); let e = null; const o = []; v.forEach((x, i) => { if (i === n - 1) e = v.slice(0, n).reduce((a, b) => a + b, 0) / n; else if (i >= n) e = x * k + e * (1 - k); o.push(e); }); return o; }
function rsi(c, n = 14) { if (c.length <= n) return null; let g = 0, l = 0; for (let i = 1; i <= n; i++) { const d = c[i] - c[i - 1]; if (d > 0) g += d; else l -= d; } g /= n; l /= n; for (let i = n + 1; i < c.length; i++) { const d = c[i] - c[i - 1]; g = (g * (n - 1) + Math.max(d, 0)) / n; l = (l * (n - 1) + Math.max(-d, 0)) / n; } return l === 0 ? 100 : 100 - 100 / (1 + g / l); }
function describe(a, v, p) {
  const coin = a.pair.replace("-USD", ""), up = a.direction === "above", tf = TF[a.tf] || "1h";
  if (a.kind === "pct") return { title: coin + (up ? " is up " : " is down ") + Math.abs(v).toFixed(2) + "% in 24h", body: coin + " is now $" + fmt(p) + ". Your alert was for a " + (+a.price) + "% move " + (up ? "up" : "down") + "." };
  if (a.kind === "rsi") return { title: coin + " RSI " + (up ? "rose above " : "fell below ") + (+a.price) + " (" + tf + ")", body: "RSI is " + v.toFixed(1) + " on the " + tf + " chart. " + coin + " is $" + fmt(p) + "." };
  if (a.kind === "cross") return { title: coin + ": EMA 20 crossed " + (up ? "above" : "below") + " EMA 50 (" + tf + ")", body: (up ? "Bullish" : "Bearish") + " crossover on the " + tf + " chart. " + coin + " is $" + fmt(p) + "." };
  return { title: coin + (up ? " rose above $" : " fell below $") + fmt(+a.price), body: coin + " is now $" + fmt(p) + ". Tap to open your charts." };
}
async function sendPush(a, msg, st) {
  const { data: subs } = await db.from("push_subscriptions").select("id,endpoint,p256dh,auth").eq("user_id", a.user_id);
  if (!subs || !subs.length) return 0;
  const server = await getAppServer(); let n = 0;
  await Promise.all(subs.map(async s => {
    try { await server.subscribe({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }).pushTextMessage(JSON.stringify(msg), { urgency: webpush.Urgency.High, ttl: 3600, topic: a.id.replace(/-/g, "").slice(0, 32) }); n++; st.pushed++; }
    catch (e) { const code = e && e.response ? e.response.status : 0; if (code === 404 || code === 410) await db.from("push_subscriptions").delete().eq("id", s.id); else st.errors.push("push " + (code || e.message)); }
  }));
  return n;
}
async function sendEmail(a, msg, st) {
  const key = Deno.env.get("RESEND_API_KEY"), from = Deno.env.get("EMAIL_FROM");
  if (!key || !from) return false;
  const { data: prefs } = await db.from("notify_prefs").select("email").eq("user_id", a.user_id).maybeSingle();
  if (prefs && prefs.email === false) return false;
  const { data: u } = await db.auth.admin.getUserById(a.user_id);
  if (!u || !u.user || !u.user.email) return false;
  const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: "Bearer " + key, "Content-Type": "application/json" }, body: JSON.stringify({ from: from, to: u.user.email, subject: msg.title, text: msg.body + "\n\nOpen your charts: " + SITE + "\n\nYou are getting this because you set a price alert on Escape Room Charts. Turn off email alerts in the alerts panel." }) });
  if (r.ok) { st.emailed++; return true; } st.errors.push("email " + r.status); return false;
}
Deno.serve(async req => {
  const { data: secret } = await db.rpc("get_cron_secret");
  if (!secret || req.headers.get("x-cron-secret") !== secret) return out({ error: "forbidden" }, 403);
  await getAppServer();
  const { data: alerts, error } = await db.from("alerts").select("id,user_id,pair,direction,price,kind,repeat,tf,last_state").is("hit_at", null).limit(10000);
  if (error) return out({ error: error.message }, 500);
  const pairs = [...new Set(alerts.map(a => a.pair))];
  const stats = {}, closes = {};
  await each(pairs, 8, async p => { const t = await getJSON(CB + encodeURIComponent(p) + "/stats"); if (t && +t.last > 0) stats[p] = { last: +t.last, open: +t.open }; });
  const series = [...new Set(alerts.filter(a => a.kind === "rsi" || a.kind === "cross").map(a => a.pair + "|" + a.tf))];
  await each(series, 6, async k => { const [p, g] = k.split("|"); const rows = await getJSON(CB + encodeURIComponent(p) + "/candles?granularity=" + g); if (Array.isArray(rows) && rows.length > 60) closes[k] = rows.map(r => r[4]).reverse(); });
  const st = { armed: alerts.length, pairs: pairs.length, priced: Object.keys(stats).length, hits: 0, pushed: 0, emailed: 0, errors: [] };
  for (const a of alerts) {
    const s = stats[a.pair]; if (!s) continue;
    const up = a.direction === "above", lvl = +a.price; let v = s.last, state;
    if (a.kind === "pct") { v = (s.last - s.open) / s.open * 100; state = up ? v >= lvl : v <= -lvl; }
    else if (a.kind === "rsi") { const c = closes[a.pair + "|" + a.tf]; if (!c) continue; v = rsi(c); if (v == null) continue; state = up ? v >= lvl : v <= lvl; }
    else if (a.kind === "cross") { const c = closes[a.pair + "|" + a.tf]; if (!c) continue; const e20 = ema(c, 20), e50 = ema(c, 50), i = c.length - 1; state = up ? e20[i] > e50[i] : e20[i] < e50[i]; v = e20[i] - e50[i]; }
    else state = up ? s.last >= lvl : s.last <= lvl;
    const prev = a.last_state;
    const fire = state && (prev === false || (prev == null && a.kind !== "cross"));
    if (!fire) { if (state !== prev) await db.from("alerts").update({ last_state: state }).eq("id", a.id); continue; }
    const now = new Date().toISOString();
    const upd = a.repeat ? { last_state: true, last_hit_at: now, hit_price: s.last } : { last_state: true, hit_at: now, hit_price: s.last };
    const { data: claimed } = await db.from("alerts").update(upd).eq("id", a.id).is("hit_at", null).not("last_state", "is", true).select("id");
    if (!claimed || !claimed.length) continue;
    st.hits++;
    const d = describe(a, v, s.last), msg = { title: d.title, body: d.body, url: SITE, tag: a.id };
    const [pushed, emailed] = await Promise.all([sendPush(a, msg, st), sendEmail(a, msg, st)]);
    await db.from("alert_events").insert({ alert_id: a.id, user_id: a.user_id, pair: a.pair, kind: a.kind, title: d.title, pushed: pushed, emailed: emailed });
  }
  return out(st);
});

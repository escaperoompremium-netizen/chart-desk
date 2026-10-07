// Escape Room Charts: server-side alert checker.
// Runs as a Supabase Edge Function, called every minute by pg_cron. It checks every armed alert
// against live Coinbase prices, marks the ones that hit, and sends push notifications (and email,
// once RESEND_API_KEY and EMAIL_FROM are set as function secrets).
import * as webpush from "jsr:@negrel/webpush@0.5.0";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SITE = "https://escaperoompremium-netizen.github.io/chart-desk/";
const db = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const fmt = p => p >= 1000 ? p.toLocaleString("en-US", { maximumFractionDigits: 2 }) : p >= 1 ? p.toFixed(p >= 100 ? 2 : 4) : String(+p.toPrecision(4));

let appServer = null;
async function getAppServer() {
  if (appServer) return appServer;
  let { data } = await db.from("app_keys").select("value").eq("name", "vapid").maybeSingle();
  if (!data) { // first run: create this site's VAPID key pair and keep it in the database
    const exported = await webpush.exportVapidKeys(await webpush.generateVapidKeys({ extractable: true }));
    await db.from("app_keys").upsert({ name: "vapid", value: exported }, { onConflict: "name", ignoreDuplicates: true });
    ({ data } = await db.from("app_keys").select("value").eq("name", "vapid").single());
  }
  const vapidKeys = await webpush.importVapidKeys(data.value, { extractable: false });
  appServer = await webpush.ApplicationServer.new({ contactInformation: "mailto:alerts@escaperoom.invalid", vapidKeys });
  return appServer;
}

async function prices(pairs) {
  const out = {};
  for (let i = 0; i < pairs.length; i += 8) { // stay well under Coinbase's public rate limit
    await Promise.all(pairs.slice(i, i + 8).map(async pair => {
      try {
        const r = await fetch(`https://api.exchange.coinbase.com/products/${encodeURIComponent(pair)}/ticker`, { headers: { "User-Agent": "escape-room-charts" } });
        if (r.ok) { const t = await r.json(); if (+t.price > 0) out[pair] = +t.price; }
      } catch { /* skip this pair this minute */ }
    }));
  }
  return out;
}

async function sendPush(alert, msg, stats) {
  const { data: subs } = await db.from("push_subscriptions").select("id,endpoint,p256dh,auth").eq("user_id", alert.user_id);
  if (!subs?.length) return;
  const server = await getAppServer();
  await Promise.all(subs.map(async s => {
    try {
      await server.subscribe({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } })
        .pushTextMessage(JSON.stringify(msg), { urgency: webpush.Urgency.High, ttl: 3600, topic: alert.id.replace(/-/g, "").slice(0, 32) });
      stats.pushed++;
    } catch (e) {
      const status = e?.response?.status;
      if (status === 404 || status === 410) await db.from("push_subscriptions").delete().eq("id", s.id); // device unsubscribed
      else stats.errors.push(`push ${status || e.message}`);
    }
  }));
}

async function sendEmail(alert, msg, stats) {
  const key = Deno.env.get("RESEND_API_KEY"), from = Deno.env.get("EMAIL_FROM");
  if (!key || !from) return;
  const { data: prefs } = await db.from("notify_prefs").select("email").eq("user_id", alert.user_id).maybeSingle();
  if (prefs && prefs.email === false) return;
  const { data: u } = await db.auth.admin.getUserById(alert.user_id);
  if (!u?.user?.email) return;
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: u.user.email, subject: msg.title, text: `${msg.body}\n\nOpen your charts: ${SITE}\n\nYou're getting this because you set a price alert on Escape Room Charts.` }),
  });
  if (r.ok) stats.emailed++; else stats.errors.push(`email ${r.status}`);
}

Deno.serve(async req => {
  const { data: secret } = await db.rpc("get_cron_secret");
  if (!secret || req.headers.get("x-cron-secret") !== secret) return json({ error: "forbidden" }, 403);

  await getAppServer(); // makes sure the push keys exist before anyone subscribes
  const { data: alerts, error } = await db.from("alerts").select("id,user_id,pair,direction,price").is("hit_at", null).limit(10000);
  if (error) return json({ error: error.message }, 500);

  const pairs = [...new Set(alerts.map(a => a.pair))];
  const now = await prices(pairs);
  const stats = { armed: alerts.length, pairs: pairs.length, priced: Object.keys(now).length, hits: 0, pushed: 0, emailed: 0, errors: [] };

  for (const a of alerts) {
    const p = now[a.pair];
    if (p == null || !(a.direction === "above" ? p >= +a.price : p <= +a.price)) continue;
    // claim the alert so it only ever fires once, even if two checks overlap
    const { data: claimed } = await db.from("alerts").update({ hit_at: new Date().toISOString(), hit_price: p }).eq("id", a.id).is("hit_at", null).select("id");
    if (!claimed?.length) continue;
    stats.hits++;
    const coin = a.pair.replace("-USD", "");
    const msg = { title: `${coin} ${a.direction === "above" ? "rose above" : "fell below"} $${fmt(+a.price)}`, body: `${coin} is now $${fmt(p)}. Tap to open your charts.`, url: SITE, tag: a.id };
    await Promise.all([sendPush(a, msg, stats), sendEmail(a, msg, stats)]);
  }
  return json(stats);
});

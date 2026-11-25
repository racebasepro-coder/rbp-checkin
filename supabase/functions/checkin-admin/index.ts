// checkin-admin: RBP admin PIN, events and their RR14 links, central settings, device logout, "sync now".
// The PIN is checked here on the server; the iPads never see its hash.
// Deployed without the gateway JWT check: the function checks the signed-in user itself (sb.auth.getUser).
import { createClient } from "npm:@supabase/supabase-js@2";
import bcrypt from "npm:bcryptjs@2.4.3";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const sb = createClient(URL_, KEY);
const SECRET = new TextEncoder().encode(Deno.env.get("ADMIN_TOKEN_SECRET") || KEY);
const TTL = 10 * 60 * 1000; // settings stay unlocked for 10 minutes
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};

async function sign(exp: number) {
  const key = await crypto.subtle.importKey("raw", SECRET, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(String(exp))));
  return `${exp}.${btoa(String.fromCharCode(...mac))}`;
}
// Setup QR codes for new iPads: "<exp>.<HMAC of 'enroll:<exp>'>", checked by checkin-enroll.
async function enrollCode(exp: number) {
  const key = await crypto.subtle.importKey("raw", SECRET, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`enroll:${exp}`)));
  return `${exp}.${btoa(String.fromCharCode(...mac))}`;
}
async function valid(token?: string) {
  const [exp] = String(token ?? "").split(".");
  return !!token && Number(exp) > Date.now() && (await sign(Number(exp))) === token;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const json = (b: unknown, s = 200) => Response.json(b, { status: s, headers: cors });

  // Only signed-in staff of this project.
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: who } = await sb.auth.getUser(jwt);
  if (!who?.user) return json({ error: "Sign in first." }, 401);

  const { action, pin, token, value, deviceId, eventId, name, listUrl, writeUrl, copy, copyFrom, sigId, bib, a, b, device, fields } = await req.json().catch(() => ({}));
  const { data: row } = await sb.from("checkin_secret").select("pin_hash").maybeSingle();
  const hash = row?.pin_hash as string | null;

  if (action === "status") return json({ hasPin: !!hash });
  if (action === "unlock") {
    if (!pin || String(pin).length < 4) return json({ error: "Use at least 4 characters or digits." }, 400);
    if (!hash) await sb.from("checkin_secret").upsert({ id: true, pin_hash: bcrypt.hashSync(String(pin), 10) });
    else if (!bcrypt.compareSync(String(pin), hash)) return json({ error: "Wrong PIN or password." }, 401);
    return json({ token: await sign(Date.now() + TTL), ttl: TTL });
  }
  // Swap tab: any signed-in iPad may swap (confirmed twice in the app); every swap is logged in checkin_swaps.
  if (action === "swap") {
    const A = Number(a), B = Number(b);
    if (!eventId || !Number.isInteger(A) || !Number.isInteger(B)) return json({ error: "Pick two bibs" }, 400);
    const { error } = await sb.rpc("checkin_swap", { p_event: eventId, p_a: A, p_b: B, p_device: String(device ?? "") });
    return error ? json({ error: error.message }, 400) : json({ ok: true });
  }
  // Change tab: replace a participant's data (logged in checkin_changes, pushed to RR14 via outbox).
  if (action === "change") {
    const B = Number(bib);
    if (!eventId || !Number.isInteger(B) || !fields || typeof fields !== "object") return json({ error: "Pick a bib" }, 400);
    const { error } = await sb.rpc("checkin_change", { p_event: eventId, p_bib: B, p_fields: fields, p_device: String(device ?? "") });
    return error ? json({ error: error.message }, 400) : json({ ok: true });
  }
  if (!(await valid(token))) return json({ error: "Locked. Enter the RBP admin PIN." }, 401);

  const active = async () => (await sb.from("checkin_events").select("id, settings").eq("active", true).maybeSingle()).data;
  const mask = (u?: string | null) => {
    if (!u) return "";
    try { const x = new URL(u); return `${x.host}/…${u.slice(-4)}`; } catch { return "…" + u.slice(-4); }
  };
  const okUrl = (u: unknown) => u === "" || u == null || /^https:\/\/[^\s]+$/.test(String(u));

  if (action === "saveConfig") {
    if (!value || typeof value !== "object") return json({ error: "Nothing to save" }, 400);
    const ev = eventId || (await active())?.id;
    if (!ev) return json({ error: "Create an event first." }, 400);
    const { error } = await sb.from("checkin_events").update({ settings: value }).eq("id", ev);
    return error ? json({ error: error.message }, 500) : json({ ok: true });
  }
  if (action === "listEvents") {
    const { data: evs } = await sb.from("checkin_events").select("id, name, active, open, created_at, sync").order("created_at", { ascending: false });
    const { data: rr } = await sb.from("checkin_event_rr").select("*");
    const counts = await Promise.all((evs ?? []).map(async (e) =>
      (await sb.from("checkin_participants").select("bib", { count: "exact", head: true }).eq("event_id", e.id)).count ?? 0));
    return json({ events: (evs ?? []).map((e, i) => {
      const r = rr?.find((x) => x.event_id === e.id);
      return { ...e, participants: counts[i], list: mask(r?.list_url), write: mask(r?.write_url) };
    }) });
  }
  if (action === "createEvent") {
    const id = String(eventId ?? "").trim().toLowerCase();
    if (!/^[a-z0-9][a-z0-9-]{1,40}$/.test(id)) return json({ error: "Event ID: lowercase letters, digits and dashes, e.g. doha-run-2026." }, 400);
    if (!String(name ?? "").trim()) return json({ error: "Give the event a name." }, 400);
    if (!okUrl(listUrl) || !okUrl(writeUrl)) return json({ error: "RR14 links must start with https://" }, 400);
    const cur = await active();
    const src = copyFrom ? (await sb.from("checkin_events").select("settings").eq("id", copyFrom).maybeSingle()).data : cur;
    // Copy colours, field names, slogan and date format from the chosen event; stock starts empty.
    const base = copy && src ? { ...(src.settings ?? {}), stock: {} } : {};
    const { error } = await sb.from("checkin_events").insert({ id, name: String(name).trim(), settings: base, active: !cur, open: true });
    if (error) return json({ error: error.code === "23505" ? "That event ID already exists." : error.message }, 400);
    await sb.from("checkin_event_rr").upsert({ event_id: id, list_url: listUrl || null, write_url: writeUrl || null });
    return json({ ok: true, active: !cur });
  }
  if (action === "setActive") {
    const { data: e } = await sb.from("checkin_events").select("id").eq("id", eventId).maybeSingle();
    if (!e) return json({ error: "No such event" }, 404);
    await sb.from("checkin_events").update({ active: false }).eq("active", true);
    const { error } = await sb.from("checkin_events").update({ active: true }).eq("id", eventId);
    return error ? json({ error: error.message }, 500) : json({ ok: true });
  }
  if (action === "setOpen") {
    const { error } = await sb.from("checkin_events").update({ open: !!value }).eq("id", eventId);
    return error ? json({ error: error.message }, 500) : json({ ok: true });
  }
  if (action === "saveEvent") {
    const ev = eventId || (await active())?.id;
    if (!ev) return json({ error: "No event" }, 400);
    if (!okUrl(listUrl) || !okUrl(writeUrl)) return json({ error: "RR14 links must start with https://" }, 400);
    if (name != null && String(name).trim()) await sb.from("checkin_events").update({ name: String(name).trim() }).eq("id", ev);
    // undefined = keep the stored link, "" = remove it
    const { data: r } = await sb.from("checkin_event_rr").select("*").eq("event_id", ev).maybeSingle();
    await sb.from("checkin_event_rr").upsert({ event_id: ev,
      list_url: listUrl === undefined ? r?.list_url ?? null : listUrl || null,
      write_url: writeUrl === undefined ? r?.write_url ?? null : writeUrl || null,
      updated_at: new Date().toISOString() });
    return json({ ok: true });
  }
  if (action === "kickDevice") {
    const { data: d } = await sb.from("checkin_devices").select("*").eq("id", deviceId).maybeSingle();
    if (!d) return json({ error: "No such device" }, 404);
    await sb.from("checkin_devices").update({ kicked: d.holder, holder: null, seen_at: null }).eq("id", deviceId);
    return json({ ok: true });
  }
  if (action === "changePin") {
    if (!pin || String(pin).length < 4) return json({ error: "Use at least 4 characters or digits." }, 400);
    await sb.from("checkin_secret").upsert({ id: true, pin_hash: bcrypt.hashSync(String(pin), 10) });
    return json({ ok: true });
  }
  if (action === "syncNow") {
    const r = await fetch(`${URL_}/functions/v1/checkin-sync`, { method: "POST", headers: { Authorization: `Bearer ${KEY}` } });
    return json(await r.json().catch(() => ({ ok: false, error: `sync ${r.status}` })));
  }
  if (action === "retryOutbox") {
    const ev = eventId || (await active())?.id;
    await sb.from("checkin_outbox").update({ attempts: 0 }).eq("event_id", ev).is("sent_at", null);
    return json({ ok: true });
  }
  if (action === "setupCode") {
    const ttl = 2 * 60 * 60 * 1000; // a setup QR works for 2 hours, on any number of iPads
    return json({ code: await enrollCode(Date.now() + ttl), ttl });
  }
  if (action === "removePickup") {
    // A wrong check-in: clears signature and package for the pickup (or one bib of it) and tells RR14.
    if (!eventId || !sigId) return json({ error: "Missing event or pickup" }, 400);
    const { data: n, error } = await sb.rpc("checkin_admin_remove", { p_event: eventId, p_sig_id: sigId, p_bib: bib ?? null });
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true, removed: n });
  }
  return json({ error: "Unknown action" }, 400);
});

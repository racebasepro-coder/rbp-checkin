// checkin-sync: pushes queued writes to RR14, then pulls the participant list.
// Runs every 30 s (pg_cron, see README) and on "Sync from RR14 now" in Settings.
// Works per event: every open event is pushed and pulled; closed events with unsent writes are pushed only.
// RR14 links come from checkin_event_rr (entered by the RBP admin in Settings -> Events).
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// App key -> RR14 field name. Settings -> "RR14 field names" overrides these (same list as the app).
const WRITE_DEFAULT: Record<string, string> = {
  sigUrl: "Signature", sigTime: "SignatureTime", scope: "PickupScope", by: "CollectedBy",
  forList: "CollectedFor", desk: "CheckinDevice", merch: "PackageIssued", merchTime: "PackageTime",
  merchDesk: "PackageDevice", qid: "QID", qv: "QatariVerified", dob: "DateOfBirth", nat: "Nation",
  ice: "ICEName", icePhone: "ICEPhone", phone: "Phone", email: "Email", deleted: "CheckinDeleted",
};
// Our column <- RR14 list column. The first name found in the list wins; Settings can override (readMap).
const READ_ALIASES: Record<string, string[]> = {
  bib: ["Bib", "BIB", "StartNo"], first_name: ["Firstname", "FirstName", "First Name"], last_name: ["Lastname", "LastName", "Last Name"],
  team: ["Team", "Club", "TeamName"], sex: ["Sex", "Gender"], nation: ["Nation", "Nationality", "Country"],
  dob: ["DateOfBirth", "DOB", "Birthdate", "Date of Birth"], yob: ["YoB", "YearOfBirth", "Year of Birth"],
  age_group: ["AgeGroup.Name", "Age Group 1", "AgeGroup1.Name", "AgeGroup", "Category"],
  shirt_size: ["TShirt", "T-Shirt Size", "TShirtSize", "Shirt", "T-Shirt"], qid: ["QID"],
  email: ["Email", "EMail", "E-Mail"], phone: ["Phone", "CellPhone", "Mobile"],
  ice_name: ["ICEName", "ICE Name"], ice_phone: ["ICEPhone", "ICENumber", "ICE Phone"],
};
// Which app key each read column corresponds to, so a field renamed in Settings is read under the same name.
const READ_FROM_APP: Record<string, string> = {
  nation: "nat", dob: "dob", qid: "qid", email: "email", phone: "phone", ice_name: "ice", ice_phone: "icePhone", age_group: "ageGroup",
};

// RR14 Simple API lists can be JSON (objects or arrays) or an HTML table; read all of them.
function decode(t: string) {
  return t.replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n)).trim();
}
function parseList(text: string, cols: string[]): Record<string, unknown>[] {
  const t = text.trim();
  if (t.startsWith("<")) {
    const rows = [...t.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/gi)].map((m) => ({
      head: /columnhead/i.test(m[0].slice(0, 80)),
      cells: [...m[1].matchAll(/<t[dh][^>]*>([\s\S]*?)<\/t[dh]>/gi)].map((c) => decode(c[1])),
    }));
    const head = rows.find((r) => r.head) ?? rows.find((r) => r.cells.includes("Bib"));
    if (!head) throw new Error("RR14 list is HTML but has no column header row");
    const n = head.cells.length;
    return rows.filter((r) => r !== head && !r.head && r.cells.length === n)
      .map((r) => Object.fromEntries(head.cells.map((h, i) => [h, r.cells[i]])));
  }
  const raw = JSON.parse(t);
  const list = Array.isArray(raw) ? raw : Object.values(raw);
  return list.map((r: unknown) => Array.isArray(r) ? Object.fromEntries(cols.map((c, i) => [c, r[i]])) : r as Record<string, unknown>);
}

function toDate(v: unknown): string | null {
  const s = String(v ?? "").trim();
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = s.match(/^(\d{1,2})[./](\d{1,2})[./](\d{4})/);
  if (m) return `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`;
  return null;
}
// RR14 expects dates as DD.MM.YYYY unless Settings says otherwise.
function outDate(iso: string, fmt: string) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return iso;
  return fmt === "iso" ? iso : `${m[3]}.${m[2]}.${m[1]}`;
}

async function pull(ev: string, cfg: Record<string, any>, LIST_URL?: string | null) {
  if (!LIST_URL) return { pulled: 0, note: "No RR14 list link for this event" };
  const res = await fetch(LIST_URL);
  if (!res.ok) throw new Error(`RR14 list ${res.status}`);
  const cols: string[] = String(cfg.readColumns ?? "").split(",").map((c) => c.trim()).filter(Boolean);
  const rows = parseList(await res.text(), cols.length ? cols : Object.values(READ_ALIASES).map((a) => a[0]));
  const present = new Set(Object.keys(rows[0] ?? {}));
  const map: Record<string, string> = {};
  for (const [col, names] of Object.entries(READ_ALIASES)) map[col] = names.find((n) => present.has(n)) ?? names[0];
  for (const [col, key] of Object.entries(READ_FROM_APP)) {
    const m = cfg.map?.[key];
    if (m && present.has(m)) map[col] = m;
  }
  for (const [col, name] of Object.entries(cfg.readMap ?? {})) if (name) map[col] = String(name);

  // Bibs with edits not yet in RR14 keep our values until RR14 has them.
  const { data: open } = await sb.from("checkin_outbox").select("bib").eq("event_id", ev).is("sent_at", null);
  const hold = new Set((open ?? []).map((r) => r.bib));
  const now = new Date().toISOString();
  const out = rows.map((r) => {
    const g = (k: string) => String(r[map[k]] ?? "").trim();
    const sex = g("sex").toUpperCase();
    // RR14's "YoB" column may hold a full date (DD.MM.YYYY) or only the year.
    const yobRaw = g("yob");
    const dob = toDate(r[map.dob]) ?? toDate(yobRaw);
    const yob = /^\d{4}$/.test(yobRaw) ? parseInt(yobRaw) : dob ? parseInt(dob.slice(0, 4)) : null;
    return {
      event_id: ev, bib: parseInt(g("bib")), first_name: g("first_name"), last_name: g("last_name"), team: g("team"),
      sex: /^(F|W|Ž|Z)/.test(sex) ? "W" : sex ? "M" : null,
      nation: g("nation").toUpperCase(), dob, yob,
      age_group: g("age_group"), shirt_size: g("shirt_size").toUpperCase(), qid: g("qid"), email: g("email"),
      phone: g("phone"), ice_name: g("ice_name"), ice_phone: g("ice_phone"), rr_synced_at: now,
    };
  // Bibs without a name are empty slots in RR14 (not yet sold or assigned): skip them.
  }).filter((p) => Number.isFinite(p.bib) && p.bib > 0 && (p.first_name || p.last_name) && !hold.has(p.bib));
  // Base data only: pickup and package state belong to the app and are never overwritten.
  for (let i = 0; i < out.length; i += 500) {
    const { error } = await sb.from("checkin_participants").upsert(out.slice(i, i + 500), { onConflict: "event_id,bib" });
    if (error) throw error;
  }
  return { pulled: out.length, rows: rows.length, held: hold.size, columns: [...present].slice(0, 30) };
}

async function push(ev: string, cfg: Record<string, any>, WRITE_URL?: string | null) {
  if (!WRITE_URL) return { pushed: 0, note: "No RR14 write link for this event" };
  const { data: rows, error } = await sb.from("checkin_outbox").select("*").eq("event_id", ev).is("sent_at", null)
    .lt("attempts", 20).order("id").limit(300);
  if (error) throw error;
  if (!rows?.length) return { pushed: 0 };
  const name = (k: string) => cfg.map?.[k] || WRITE_DEFAULT[k] || k;
  const byBib = new Map<number, Record<string, string>>();
  for (const r of rows) {
    const cur = byBib.get(r.bib) ?? { Bib: String(r.bib) };
    for (const [k, v] of Object.entries(r.fields as Record<string, string>)) {
      cur[name(k)] = k === "dob" ? outDate(String(v), cfg.dateFormat) : String(v ?? "");
    }
    byBib.set(r.bib, cur);
  }
  const ids = rows.map((r) => r.id);
  try {
    // One POST for the whole batch keeps us under RR's limit of one call per second.
    const res = await fetch(WRITE_URL, { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify([...byBib.values()]) });
    const text = await res.text();
    if (!res.ok) throw new Error(`RR14 write ${res.status}: ${text.slice(0, 200)}`);
    await sb.from("checkin_outbox").update({ sent_at: new Date().toISOString(), last_error: null }).in("id", ids);
    return { pushed: byBib.size };
  } catch (e) {
    for (const r of rows) {
      await sb.from("checkin_outbox").update({ attempts: r.attempts + 1, last_error: String(e) }).eq("id", r.id);
    }
    throw e;
  }
}

async function syncEvent(e: { id: string; settings: Record<string, any>; sync: Record<string, any> }, mode: string) {
  const { data: rr } = await sb.from("checkin_event_rr").select("list_url, write_url").eq("event_id", e.id).maybeSingle();
  const cfg = e.settings ?? {};
  const result: Record<string, unknown> = { at: new Date().toISOString() };
  let ok = true;
  try { if (mode !== "pull") result.push = await push(e.id, cfg, rr?.write_url); } catch (err) { ok = false; result.pushError = String(err); }
  if (mode !== "push") {
    await new Promise((r) => setTimeout(r, 1100)); // RR allows one call per second
    try { result.pull = await pull(e.id, cfg, rr?.list_url); } catch (err) { ok = false; result.pullError = String(err); }
  }
  const { count } = await sb.from("checkin_outbox").select("id", { count: "exact", head: true })
    .eq("event_id", e.id).is("sent_at", null);
  result.pending = count ?? 0;
  result.ok = ok;
  result.lastOk = ok ? result.at : e.sync?.lastOk ?? null;
  await sb.from("checkin_events").update({ sync: result }).eq("id", e.id);
  return result;
}

// Who may start a sync: pg_cron (x-cron-key header, value kept in checkin_secret) or checkin-admin (service key).
async function allowed(req: Request) {
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (bearer && bearer === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) return true;
  const k = req.headers.get("x-cron-key");
  if (!k) return false;
  const { data } = await sb.from("checkin_secret").select("cron_key").maybeSingle();
  return !!data?.cron_key && data.cron_key === k;
}

Deno.serve(async (req) => {
  if (!(await allowed(req))) return new Response("Forbidden", { status: 403 });
  const mode = new URL(req.url).searchParams.get("mode") ?? "both";
  const { data: events } = await sb.from("checkin_events").select("id, active, open, settings, sync");
  const { data: open } = await sb.from("checkin_outbox").select("event_id").is("sent_at", null).limit(5000);
  const pending = new Set((open ?? []).map((r) => r.event_id));
  const out: Record<string, unknown> = {};
  let ok = true;
  for (const e of events ?? []) {
    if (e.open || e.active) out[e.id] = await syncEvent(e, mode);
    else if (pending.has(e.id)) out[e.id] = await syncEvent(e, "push");
    if (out[e.id] && !(out[e.id] as any).ok) ok = false;
  }
  return Response.json({ ok, events: out }, { status: ok ? 200 : 502 });
});

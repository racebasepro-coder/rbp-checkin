// checkin-sig: the signature link written to RR14.
// GET ?id=<signature id>&t=<token>  ->  redirect to a 2-minute link to the private PNG.
// Deployed without JWT check: the link must open from RR14 without a login; the token is the key.
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const id = u.searchParams.get("id") ?? "", t = u.searchParams.get("t") ?? "";
  if (!/^s\d+-\d+$/.test(id) || !/^[0-9a-f]{64}$/.test(t)) return new Response("Not found", { status: 404 });
  const { data: s } = await sb.from("checkin_signatures").select("path, token").eq("id", id).maybeSingle();
  if (!s || s.token !== t) return new Response("Not found", { status: 404 });
  const { data, error } = await sb.storage.from("checkin-signatures").createSignedUrl(s.path, 120);
  if (error || !data) return new Response("Signature file missing", { status: 404 });
  return Response.redirect(data.signedUrl, 302);
});

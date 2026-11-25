// checkin-enroll: a new iPad scanned the setup QR from Settings. If the code is genuine and not expired,
// this returns a one-time sign-in for the staff account, so nobody has to type the staff PIN.
// Deployed without the gateway JWT check: the setup code itself is the credential.
import { createClient } from "npm:@supabase/supabase-js@2";

const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const sb = createClient(Deno.env.get("SUPABASE_URL")!, KEY);
const SECRET = new TextEncoder().encode(Deno.env.get("ADMIN_TOKEN_SECRET") || KEY);
const STAFF = Deno.env.get("CHECKIN_STAFF_EMAIL") || "ipad@race.plus";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};

// Same scheme as checkin-admin's setup codes: "<exp>.<HMAC of 'enroll:<exp>'>".
async function mac(exp: number) {
  const key = await crypto.subtle.importKey("raw", SECRET, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const m = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`enroll:${exp}`)));
  return btoa(String.fromCharCode(...m));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const json = (b: unknown, s = 200) => Response.json(b, { status: s, headers: cors });
  const { code } = await req.json().catch(() => ({}));
  const [exp, sig] = String(code ?? "").split(".", 2);
  const n = Number(exp);
  if (!sig || !(n > Date.now()) || (await mac(n)) !== sig) {
    return json({ error: "This setup QR has expired. Ask the RBP admin for a new one." }, 401);
  }
  const { data, error } = await sb.auth.admin.generateLink({ type: "magiclink", email: STAFF });
  if (error || !data?.properties?.hashed_token) return json({ error: error?.message ?? "Could not sign in" }, 500);
  return json({ token_hash: data.properties.hashed_token });
});

// Recebe o resultado do waterfall de telefone do Apollo e grava no banco (public.apollo_phone_ingest).
// Autenticação: ?token=... conferido no banco contra o Vault. verify_jwt desligado (o Apollo não manda JWT).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("use POST", { status: 405 });
  const token = new URL(req.url).searchParams.get("token") ?? "";
  if (!token) return new Response("sem token", { status: 401 });

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return new Response("json inválido", { status: 400 });
  }

  const base = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const resp = await fetch(`${base}/rest/v1/rpc/apollo_phone_ingest`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_token: token, p_payload: payload }),
  });
  const text = await resp.text();
  if (!resp.ok) {
    const status = text.includes("42501") ? 401 : 500;
    return new Response(status === 401 ? "token inválido" : "falha ao gravar", { status });
  }
  return new Response(text, { headers: { "Content-Type": "application/json" } });
});

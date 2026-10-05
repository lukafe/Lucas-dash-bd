import { supabaseServer } from "@/lib/supabase-server";

export const TZ = "Asia/Shanghai";

export function fmt(iso, opts = { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }) {
  if (!iso) return "–";
  return new Intl.DateTimeFormat("pt-BR", { timeZone: TZ, ...opts }).format(new Date(iso));
}

export function dayKey(d) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(d);
}

/**
 * Lê o snapshot do monitor numa chamada só (função public.dash_snapshot no Supabase).
 * Enquanto source_state.dash_public = true, a função responde a qualquer visitante;
 * com false, só ao dono logado. As tabelas seguem fechadas pelo RLS.
 */
export async function loadDashboard() {
  const sb = await supabaseServer();
  const [userRes, snap] = await Promise.all([
    sb.auth.getUser().catch(() => null),
    sb.rpc("dash_snapshot"),
  ]);
  const error = snap.error ? snap.error.message || "falha de conexão com o Supabase" : null;
  const s = snap.data ?? {};
  const part = (k) => ({ data: Array.isArray(s[k]) ? s[k] : [], error: null });
  return {
    email: userRes?.data?.user?.email ?? null,
    error,
    funnel: part("funnel"), accounts: part("accounts"), recent: part("recent"), next: part("next"),
    replies: part("replies"), health: part("health"), channels: part("channels"), state: part("state"),
    daily: part("daily"), integrations: part("integrations"),
    // Horário da última sincronização de cada fonte (atualização horária do monitor, Apollo, Telegram)
    synced: s.synced && typeof s.synced === "object" ? s.synced : {},
  };
}

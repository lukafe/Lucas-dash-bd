import { supabaseServer } from "@/lib/supabase-server";

export const TZ = "Asia/Shanghai";

export function fmt(iso, opts = { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }) {
  if (!iso) return "–";
  return new Intl.DateTimeFormat("pt-BR", { timeZone: TZ, ...opts }).format(new Date(iso));
}

export function dayKey(d) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(d);
}

/** Roda uma consulta e devolve {data, error} sem derrubar a página. */
async function safe(promise) {
  try {
    const { data, error } = await promise;
    return { data: data ?? [], error: error?.message ?? null };
  } catch (e) {
    return { data: [], error: String(e?.message ?? e) };
  }
}

export async function loadDashboard() {
  const sb = await supabaseServer();
  const [user, funnel, accounts, recent, next, replies, health, channels, state, daily] = await Promise.all([
    sb.auth.getUser(),
    safe(sb.from("v_campaign_funnel").select("*").order("id")),
    safe(sb.from("v_accounts").select("*").order("last_touch", { ascending: false, nullsFirst: false }).limit(40)),
    safe(sb.from("v_recent_touches").select("*").limit(50)),
    safe(sb.from("v_next_touches").select("*").limit(30)),
    safe(
      sb.from("replies")
        .select("id, channel, class, is_decision_maker, confidence, summary, link, received_at, handled, contacts(first_name, last_name, position), companies(name)")
        .order("received_at", { ascending: false })
        .limit(20)
    ),
    safe(sb.from("v_health").select("*").order("last_at", { ascending: false })),
    safe(sb.from("v_account_usage").select("*")),
    safe(sb.from("source_state").select("key, value, updated_at").in("key", ["push_paused"])),
    safe(sb.from("v_daily_touches").select("*")),
  ]);
  return {
    email: user?.data?.user?.email ?? null,
    funnel, accounts, recent, next, replies, health, channels, state, daily,
  };
}

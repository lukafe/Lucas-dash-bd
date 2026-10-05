import { supabaseServer } from "@/lib/supabase-server";
import { dayKey } from "@/lib/data";

// Datas como texto "AAAA-MM-DD" no fuso de Xangai; a aritmética é feita em UTC puro.
const toUtc = (k) => Date.UTC(+k.slice(0, 4), +k.slice(5, 7) - 1, +k.slice(8, 10));
const fromUtc = (ms) => new Date(ms).toISOString().slice(0, 10);
export const addDays = (k, n) => fromUtc(toUtc(k) + n * 864e5);
const weekdayMon0 = (k) => (new Date(toUtc(k)).getUTCDay() + 6) % 7;

const MONTHS = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto",
  "setembro", "outubro", "novembro", "dezembro"];

/** Categoria do evento no calendário. */
export function category(e) {
  if (e.kind === "enrich") return "enrich";
  if (e.state === "resposta") return "reply";
  if (e.state === "bounce") return "bounce";
  return e.kind === "first" ? "first" : "followup";
}
export const isFuture = (e) => e.state === "fila" || e.state === "previsto";

/**
 * Distribui quem fica apto no Telegram pelos dias, como o planejador faria:
 * até a cota diária (descontando o que já está na fila), 1 conta por dia, na ordem de prioridade.
 */
function distributeTelegram(forecast, queuedByDay, quota, startDay, endDay) {
  const pending = forecast.map((f) => ({ ...f, dueDay: dayKey(new Date(f.due)) }));
  const out = [];
  for (let d = startDay; d <= endDay; d = addDays(d, 1)) {
    let cap = quota - (queuedByDay[d] ?? 0);
    const companies = new Set();
    for (const f of pending) {
      if (cap <= 0) break;
      if (f.used || f.dueDay > d) continue;
      if (f.company_id && companies.has(f.company_id)) continue;
      f.used = true;
      if (f.company_id) companies.add(f.company_id);
      cap -= 1;
      out.push({
        at: null, day: d, channel: "telegram", kind: f.kind, state: "previsto",
        name: f.name, company: f.company, est: true,
      });
    }
  }
  return out;
}

/**
 * Programação de email, como o pipeline diário faria (pipeline: outbound/apollo.py):
 * - contatos prontos entram na sequência até o teto do dia, no máximo `per_company` por empresa por dia,
 *   na ordem que o banco devolveu (raise mais recente primeiro); cada entrada gera os follow-ups da sequência;
 * - empresas da fila são enriquecidas `companies_per_day` por dia (um evento por dia, com a contagem).
 * Começa hoje se a rodada de hoje ainda não aconteceu; senão, amanhã.
 */
export function distributeEmail(em, today, endDay) {
  if (!em || em.paused) return [];
  const start = em.ran_today ? addDays(today, 1) : today;
  const cap = Math.max(0, em.cap ?? 40);
  const perCompany = Math.max(1, em.per_company ?? 3);
  const perDay = Math.max(1, em.companies_per_day ?? 40);
  const offsets = (em.offsets ?? [0]).filter((o) => o > 0);
  const out = [];

  const pending = (em.ready ?? []).map((r, i) => ({ ...r, key: r.company_id ?? `sem-empresa-${i}` }));
  for (let d = start; d <= endDay && pending.length && cap > 0; d = addDays(d, 1)) {
    const used = {};
    let left = cap;
    for (const r of pending) {
      if (left <= 0) break;
      if ((used[r.key] ?? 0) >= perCompany) continue;
      used[r.key] = (used[r.key] ?? 0) + 1;
      r.day = d;
      left -= 1;
    }
    for (let i = pending.length - 1; i >= 0; i--) {
      const r = pending[i];
      if (r.day !== d) continue;
      pending.splice(i, 1);
      const base = { at: null, channel: "email", state: "previsto", name: r.name, company: r.company, position: r.position, est: true };
      out.push({ ...base, day: d, kind: "first" });
      for (const o of offsets) out.push({ ...base, day: addDays(d, o), kind: "followup" });
    }
  }

  const queue = em.queue ?? [];
  for (let i = 0, d = start; i < queue.length; i += perDay, d = addDays(d, 1)) {
    if (d > endDay) break;
    const chunk = queue.slice(i, i + perDay);
    const names = chunk.slice(0, 3).map((c) => c.company).join(", ");
    out.push({
      at: null, day: d, channel: "email", kind: "enrich", state: "previsto", est: true, count: chunk.length,
      name: `${chunk.length} empresa${chunk.length > 1 ? "s" : ""} da fila`,
      company: chunk.length > 3 ? `${names} e mais ${chunk.length - 3}` : names,
    });
  }
  return out.filter((e) => e.day <= endDay);
}

/** Monta o mês (segunda a domingo, 6 semanas) e a agenda a partir das respostas do banco.
 *  Função pura: recebe o que dash_calendar devolveu e a data de hoje. */
export function buildCalendar({ raw, agendaRaw, month, today, nowHour }) {
  const m = /^\d{4}-\d{2}$/.test(month ?? "") ? month : today.slice(0, 7);
  const first = `${m}-01`;
  const gridStart = addDays(first, -weekdayMon0(first));
  const gridEnd = addDays(gridStart, 41);
  const tgStart = nowHour >= 23 ? addDays(today, 1) : today;

  const expand = (r, from, to) => {
    const events = ((r ?? {}).events ?? []).map((e) => ({ ...e, day: dayKey(new Date(e.at)) }));
    const queuedByDay = {};
    for (const e of events) {
      if (e.channel === "telegram" && (e.state === "fila" || (e.state === "feito" && e.day >= tgStart))) {
        queuedByDay[e.day] = (queuedByDay[e.day] ?? 0) + 1;
      }
    }
    const end = to;
    const fc = end >= tgStart ? distributeTelegram((r ?? {}).tg_forecast ?? [], queuedByDay, (r ?? {}).tg_quota ?? 20, tgStart, end) : [];
    const em = end >= today ? distributeEmail((r ?? {}).email, today, end) : [];
    return [...events, ...fc, ...em].filter((e) => e.day >= from && e.day <= to);
  };

  const all = expand(raw, gridStart, gridEnd);
  const byDay = {};
  for (const e of all) (byDay[e.day] ??= []).push(e);
  const weeks = [];
  for (let w = 0; w < 6; w++) {
    weeks.push(Array.from({ length: 7 }, (_, i) => {
      const day = addDays(gridStart, w * 7 + i);
      return { day, inMonth: day.slice(0, 7) === m, isToday: day === today, events: byDay[day] ?? [] };
    }));
  }

  const agendaEnd = addDays(today, 7);
  const agendaEvents = agendaRaw ? expand(agendaRaw, today, agendaEnd) : all;
  const agenda = [];
  for (let d = today; d <= agendaEnd; d = addDays(d, 1)) {
    const list = agendaEvents.filter((e) => e.day === d)
      .sort((a, b) => String(a.at ?? "9").localeCompare(String(b.at ?? "9")));
    agenda.push({ day: d, isToday: d === today, events: list });
  }

  const [y, mm] = m.split("-").map(Number);
  return {
    month: m, label: `${MONTHS[mm - 1]} de ${y}`,
    prev: mm === 1 ? `${y - 1}-12` : `${y}-${String(mm - 1).padStart(2, "0")}`,
    next: mm === 12 ? `${y + 1}-01` : `${y}-${String(mm + 1).padStart(2, "0")}`,
    today, gridStart, gridEnd, weeks, agenda,
    tgSendEnabled: Boolean((raw ?? {}).tg_send_enabled), tgQuota: (raw ?? {}).tg_quota ?? 20,
    email: {
      paused: Boolean((raw ?? {}).email?.paused), cap: (raw ?? {}).email?.cap ?? 40,
      perDay: (raw ?? {}).email?.companies_per_day ?? 40,
      ready: ((raw ?? {}).email?.ready ?? []).length, queue: ((raw ?? {}).email?.queue ?? []).length,
    },
  };
}

/** Lê o calendário do mês pedido (?m=AAAA-MM) e a agenda de hoje + 7 dias. */
export async function loadCalendar(month) {
  const today = dayKey(new Date());
  const nowHour = Number(new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Shanghai", hour: "2-digit", hourCycle: "h23" }).format(new Date()));
  const m = /^\d{4}-\d{2}$/.test(month ?? "") ? month : today.slice(0, 7);
  const first = `${m}-01`;
  const gridStart = addDays(first, -weekdayMon0(first));
  const gridEnd = addDays(gridStart, 41);
  const agendaEnd = addDays(today, 7);

  const sb = await supabaseServer();
  const needAgenda = today < gridStart || agendaEnd > gridEnd;
  const [main, extra] = await Promise.all([
    sb.rpc("dash_calendar", { p_from: gridStart, p_to: gridEnd }),
    needAgenda ? sb.rpc("dash_calendar", { p_from: today, p_to: agendaEnd }) : Promise.resolve(null),
  ]);
  const err = main.error || extra?.error;
  return {
    error: err ? err.message || "falha de conexão com o Supabase" : null,
    ...buildCalendar({ raw: main.data, agendaRaw: extra?.data ?? null, month: m, today, nowHour }),
  };
}

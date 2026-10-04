import { envProblem } from "@/lib/supabase-server";
import { dayKey, fmt, loadDashboard } from "@/lib/data";
import { category, isFuture, loadCalendar } from "@/lib/calendar";

export const dynamic = "force-dynamic";

const CH = { email: "Email", telegram: "Telegram", linkedin: "LinkedIn", whatsapp: "WhatsApp" };
const TOUCH = {
  sent: ["Enviado", "acc"], replied: ["Respondeu", "ok"], bounced: ["Bounce", "bad"],
  failed: ["Falhou", "bad"], queued: ["Na fila", "idle"], accepted: ["Aceitou", "ok"],
};
const CAMP = { live: ["No ar", "ok"], draft: ["Rascunho", "idle"], paused: ["Pausada", "warn"], done: ["Encerrada", "idle"] };
const ACC = {
  ok: ["Ok", "ok"], warming: ["Aquecendo", "warn"], restricted: ["Restrita", "bad"], paused: ["Pausada", "warn"],
  not_connected: ["Não conectada", "idle"], atencao: ["Atenção", "warn"], erro: ["Com erro", "bad"],
};
const INT = { ok: ["Ok", "ok"], atencao: ["Atenção", "warn"], erro: ["Com erro", "bad"] };
const STATE = { active: ["Ativa", "acc"], paused: ["Pausada", "warn"], dormant: ["Dormente", "idle"], replied: ["Respondeu", "ok"], do_not_contact: ["Não contatar", "bad"] };
const REPLY = {
  interessado: "Interessado", pediu_info: "Pediu info", indicou_outro: "Indicou outra pessoa", agora_nao: "Agora não",
  ja_tem_auditor: "Já tem auditor", sem_orcamento: "Sem orçamento", pessoa_errada: "Pessoa errada", pare: "Pare",
  fora_do_escritorio: "Fora do escritório", outro: "Outro",
};
const TONE = {
  ok: "bg-ok/10 text-ok", warn: "bg-warn/10 text-warn", bad: "bg-bad/10 text-bad",
  acc: "bg-accent/10 text-accent", idle: "bg-muted/10 text-muted",
};

function Pill({ map, k }) {
  const [label, tone] = map[k] ?? [k ?? "–", "idle"];
  return <span className={`inline-flex rounded-full px-2 py-0.5 text-[11px] font-semibold ${TONE[tone]}`}>{label}</span>;
}

function SectionError({ error }) {
  if (!error) return null;
  return <p className="rounded-lg bg-warn/10 p-3 text-sm text-warn">Não consegui ler esta seção: {error}</p>;
}

function Section({ title, aside, children }) {
  return (
    <section className="flex min-w-0 flex-col gap-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-[17px] font-semibold">{title}</h2>
        {aside && <span className="text-xs text-muted">{aside}</span>}
      </div>
      {children}
    </section>
  );
}

function Table({ head, children, empty }) {
  return (
    <div className="overflow-x-auto rounded-xl border border-line bg-surface">
      <table className="w-full border-collapse text-[13px]">
        <thead>
          <tr>
            {head.map((h) => (
              <th key={h} className="whitespace-nowrap border-b border-line px-3 py-2 text-left text-[11px] font-semibold uppercase tracking-wider text-muted">{h}</th>
            ))}
          </tr>
        </thead>
        <tbody className="[&_td]:border-b [&_td]:border-line [&_td]:px-3 [&_td]:py-2 [&_tr:last-child_td]:border-0">
          {children}
        </tbody>
      </table>
      {empty && <p className="p-4 text-sm text-muted">{empty}</p>}
    </div>
  );
}

function Kpi({ value, label, tone }) {
  return (
    <div className="rounded-xl border border-line bg-surface px-4 py-3">
      <div className={`num text-2xl font-medium ${tone ?? ""}`}>{value}</div>
      <div className="text-xs text-muted">{label}</div>
    </div>
  );
}

function QuotaBar({ used, limit }) {
  if (!limit) return <span className="text-xs text-muted">sem teto</span>;
  const pct = Math.min(100, Math.round((used / limit) * 100));
  return (
    <div className="flex flex-col gap-1">
      <span className="num text-xs">{used} / {limit}</span>
      <div className="h-1.5 w-full overflow-hidden rounded bg-ground">
        <div className={`h-full rounded ${pct >= 90 ? "bg-warn" : "bg-accent"}`} style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

/** "23:05" se for hoje (Xangai), "03/10, 19:36" se for outro dia. */
function when(iso) {
  if (!iso) return "–";
  return dayKey(new Date(iso)) === dayKey(new Date()) ? fmt(iso, { hour: "2-digit", minute: "2-digit" }) : fmt(iso);
}

/** Horário de uma sincronização; fica amarelo quando passa do prazo esperado. */
function SyncStamp({ label, at, maxMinutes }) {
  const stale = !at || Date.now() - new Date(at).getTime() > maxMinutes * 60e3;
  return (
    <span className={stale ? "text-warn" : ""} title={stale ? `Mais de ${maxMinutes} min sem sincronizar` : undefined}>
      {label} {when(at)}
    </span>
  );
}

/** Situação exibida da conta. Ordem: bloqueio da trava de envio (restrita/pausada), depois o
 *  problema medido na hora (erro, atenção), depois a trava em si (ok, não conectada…). */
function accountState(a) {
  if (a.status === "restricted" || a.status === "paused") return a.status;
  if (a.live_status === "erro" || a.live_status === "atencao") return a.live_status;
  return a.status;
}

function DailyChart({ rows }) {
  const days = [];
  const now = Date.now();
  for (let i = 29; i >= 0; i--) days.push(dayKey(new Date(now - i * 864e5)));
  const by = {};
  for (const r of rows) {
    by[r.day] ??= { email: 0, telegram: 0, linkedin: 0 };
    by[r.day][r.channel] = (by[r.day][r.channel] ?? 0) + Number(r.sent ?? 0);
  }
  const totals = days.map((d) => Object.values(by[d] ?? {}).reduce((a, b) => a + b, 0));
  const max = Math.max(5, ...totals);
  const top = Math.ceil(max / 5) * 5;
  const W = 640, H = 170, L = 28, B = 20, T = 6, iw = W - L - 6, ih = H - B - T, bw = iw / days.length;
  const colors = { email: "rgb(var(--accent))", telegram: "rgb(var(--ok))", linkedin: "rgb(var(--warn))" };
  return (
    <div className="rounded-xl border border-line bg-surface p-4">
      <svg viewBox={`0 0 ${W} ${H}`} className="h-auto w-full" role="img" aria-label="Toques por dia nos últimos 30 dias">
        {[0, 1, 2, 3, 4, 5].map((i) => {
          const v = (top / 5) * i, y = T + ih - (v / top) * ih;
          return (
            <g key={i}>
              <line x1={L} x2={W - 6} y1={y} y2={y} stroke="rgb(var(--line))" />
              <text x={L - 5} y={y + 3} textAnchor="end" fontSize="10" fill="rgb(var(--muted))" className="num">{v}</text>
            </g>
          );
        })}
        {days.map((d, i) => {
          let acc = 0;
          return (
            <g key={d}>
              {["email", "telegram", "linkedin"].map((c) => {
                const v = by[d]?.[c] ?? 0;
                if (!v) return null;
                const h = (v / top) * ih, y = T + ih - acc - h;
                acc += h;
                return (
                  <rect key={c} x={L + i * bw + 1.5} y={y} width={Math.max(1, bw - 3)} height={h} rx="2" fill={colors[c]}>
                    <title>{`${d} · ${CH[c]}: ${v}`}</title>
                  </rect>
                );
              })}
              {(i % 7 === 0 || i === days.length - 1) && (
                <text x={L + i * bw + bw / 2} y={H - 5} textAnchor="middle" fontSize="10" fill="rgb(var(--muted))" className="num">
                  {d.slice(8)}/{d.slice(5, 7)}
                </text>
              )}
            </g>
          );
        })}
      </svg>
      <div className="mt-2 flex gap-4 text-xs text-muted">
        {Object.entries(colors).map(([c, col]) => (
          <span key={c} className="flex items-center gap-1.5"><span className="h-2 w-2 rounded-full" style={{ background: col }} />{CH[c]}</span>
        ))}
      </div>
    </div>
  );
}


// --- Calendário ---------------------------------------------------------------------------
const CAT = {
  first: { label: "1º contato", color: "rgb(var(--accent))" },
  followup: { label: "Follow-up / reativação", color: "rgb(var(--warn))" },
  reply: { label: "Resposta", color: "rgb(var(--ok))" },
  bounce: { label: "Bounce", color: "rgb(var(--bad))" },
};
const EV_STATE = {
  feito: ["Enviado", "acc"], fila: ["Na fila", "warn"], previsto: ["Previsto", "idle"],
  resposta: ["Resposta", "ok"], bounce: ["Bounce", "bad"],
};
const KIND = { first: "1º contato", followup: "Follow-up", reactivation: "Reativação", reply: "Resposta" };
const WEEKDAYS = ["seg", "ter", "qua", "qui", "sex", "sáb", "dom"];
const CHIP_ORDER = ["first|p", "followup|p", "reply|p", "bounce|p", "first|f", "followup|f"];

function weekdayLabel(day) {
  const d = new Date(Date.UTC(+day.slice(0, 4), +day.slice(5, 7) - 1, +day.slice(8, 10)));
  return new Intl.DateTimeFormat("pt-BR", { weekday: "long", timeZone: "UTC" }).format(d);
}

function Dot({ cat, future }) {
  const color = CAT[cat].color;
  return (
    <span className="inline-block h-2 w-2 shrink-0 rounded-full"
      style={future ? { boxShadow: `inset 0 0 0 1.5px ${color}` } : { background: color }} />
  );
}

function DayChips({ events }) {
  const groups = {};
  for (const e of events) (groups[`${category(e)}|${isFuture(e) ? "f" : "p"}`] ??= []).push(e);
  return (
    <div className="flex flex-wrap gap-x-2 gap-y-0.5">
      {CHIP_ORDER.filter((k) => groups[k]).map((k) => {
        const [cat, f] = k.split("|");
        const list = groups[k];
        const byCh = {};
        for (const e of list) byCh[e.channel] = (byCh[e.channel] ?? 0) + 1;
        const title = `${CAT[cat].label}${f === "f" ? " (na fila ou previsto)" : ""}: `
          + Object.entries(byCh).map(([c, n]) => `${CH[c] ?? c} ${n}`).join(", ");
        return (
          <span key={k} title={title}
            className={`num inline-flex items-center gap-1 text-[12px] ${f === "f" ? "text-muted" : "font-semibold"}`}>
            <Dot cat={cat} future={f === "f"} />{list.length}
          </span>
        );
      })}
    </div>
  );
}

function Calendar({ cal }) {
  return (
    <div className="rounded-xl border border-line bg-surface p-3 sm:p-4">
      <div className="mb-3 flex items-center justify-between gap-2">
        <a href={`?m=${cal.prev}`} className="rounded-lg border border-line px-2.5 py-1 text-xs hover:border-accent">← anterior</a>
        <div className="text-sm font-semibold capitalize">{cal.label}</div>
        <a href={`?m=${cal.next}`} className="rounded-lg border border-line px-2.5 py-1 text-xs hover:border-accent">próximo →</a>
      </div>
      <div className="grid grid-cols-7 gap-1">
        {WEEKDAYS.map((w) => (
          <div key={w} className="pb-1 text-center text-[10px] font-semibold uppercase tracking-wider text-muted">{w}</div>
        ))}
        {cal.weeks.flat().map((c) => (
          <div key={c.day}
            className={`min-h-[58px] rounded-lg border p-1 sm:min-h-[74px] sm:p-1.5 ${c.isToday ? "border-accent" : "border-line"} ${c.inMonth ? "" : "opacity-40"}`}>
            <div className={`num mb-1 text-[11px] ${c.isToday ? "font-semibold text-accent" : "text-muted"}`}>
              {Number(c.day.slice(8))}
            </div>
            <DayChips events={c.events} />
          </div>
        ))}
      </div>
      <div className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted">
        {Object.entries(CAT).map(([k, v]) => (
          <span key={k} className="flex items-center gap-1.5"><Dot cat={k} />{v.label}</span>
        ))}
        <span className="flex items-center gap-1.5"><Dot cat="first" future />vazado = na fila ou previsto</span>
      </div>
    </div>
  );
}

function EventRow({ e }) {
  const time = e.at && e.state !== "previsto" ? fmt(e.at, { hour: "2-digit", minute: "2-digit" }) : "—";
  return (
    <li className="flex flex-wrap items-center gap-x-2 gap-y-0.5 px-3 py-1.5 text-[13px]">
      <span className="num w-10 shrink-0 text-xs text-muted">{time}</span>
      <Pill map={EV_STATE} k={e.state} />
      <span className="text-xs text-muted">{CH[e.channel] ?? e.channel} · {KIND[e.kind] ?? e.kind}</span>
      <span className="font-medium">{e.name || "–"}</span>
      {e.company && <span className="text-xs text-muted">{e.company}</span>}
    </li>
  );
}

function Agenda({ cal }) {
  const today = cal.agenda[0];
  const next = cal.agenda.slice(1).filter((a) => a.events.length);
  return (
    <div className="flex flex-col gap-3">
      <div className="rounded-xl border border-line bg-surface">
        <div className="flex items-baseline justify-between border-b border-line px-3 py-2">
          <span className="text-[13px] font-semibold">Hoje</span>
          <span className="text-xs text-muted">{today?.events.length ?? 0} evento(s)</span>
        </div>
        {today?.events.length
          ? <ul className="max-h-[340px] divide-y divide-line overflow-y-auto">{today.events.map((e, i) => <EventRow key={i} e={e} />)}</ul>
          : <p className="px-3 py-2 text-xs text-muted">Nada hoje.</p>}
      </div>
      <div className="rounded-xl border border-line bg-surface">
        <div className="border-b border-line px-3 py-2 text-[13px] font-semibold">Próximos 7 dias</div>
        {next.length === 0 && <p className="px-3 py-2 text-xs text-muted">Nada na fila nem previsto.</p>}
        {next.map((a) => {
          const shown = a.events.slice(0, 6);
          return (
            <div key={a.day} className="border-b border-line last:border-0">
              <div className="flex items-baseline justify-between px-3 pt-2 text-xs">
                <span className="font-semibold capitalize">{weekdayLabel(a.day)} <span className="num font-normal text-muted">{a.day.slice(8)}/{a.day.slice(5, 7)}</span></span>
                <span className="text-muted">{a.events.length}</span>
              </div>
              <ul>{shown.map((e, i) => <EventRow key={i} e={e} />)}</ul>
              {a.events.length > shown.length && <p className="px-3 pb-2 text-xs text-muted">+ {a.events.length - shown.length} no dia</p>}
            </div>
          );
        })}
      </div>
    </div>
  );
}

export default async function Page({ searchParams }) {
  const problem = envProblem();
  if (problem) {
    return <main className="mx-auto max-w-3xl p-6"><p className="rounded-lg bg-warn/10 p-4 text-warn">{problem}</p></main>;
  }
  const sp = (await searchParams) ?? {};
  const [d, cal] = await Promise.all([loadDashboard(), loadCalendar(sp.m)]);
  const funnel = d.funnel.data;
  const email = funnel.find((f) => f.channel === "email" && f.status !== "draft") ?? funnel.find((f) => f.channel === "email");
  const tg = funnel.find((f) => f.channel === "telegram");
  const paused = d.state.data.find((s) => s.key === "push_paused")?.value === "true";
  const bounce7 = Number(email?.bounce_pct_7d ?? 0);
  const totalAccounts = d.accounts.data.filter((a) => Number(a.people_reached) > 0).length;
  const sum = (k) => funnel.reduce((a, f) => a + Number(f[k] ?? 0), 0);
  const nowStr = fmt(new Date().toISOString(), { hour: "2-digit", minute: "2-digit" });
  const apolloInt = d.integrations.data.find((i) => i.id === "apollo");
  const apolloAlerts = apolloInt?.data?.alerts ?? [];
  const latePieces = d.health.data.filter((h) => h.late);

  return (
    <main className="mx-auto flex max-w-6xl flex-col gap-7 px-4 py-6 sm:px-5">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <div className="text-[11px] font-semibold uppercase tracking-[0.08em] text-muted">Aurora · CertiK New Business</div>
          <h1 className="text-[26px] font-bold tracking-tight">Fundraising: email e Telegram</h1>
          <p className="text-muted">Contas que captaram recentemente, abordadas por email em volume e por Telegram nos decisores.</p>
        </div>
        <div className="flex items-center gap-3 text-xs text-muted">
          <div className="flex flex-col items-end gap-0.5">
            <span>Página gerada às {nowStr} (Xangai)</span>
            <span className="flex flex-wrap justify-end gap-x-2">
              <span>Sincronizado:</span>
              <SyncStamp label="monitor" at={d.synced.monitor} maxMinutes={90} />
              <span>·</span>
              <SyncStamp label="Apollo" at={d.synced.apollo} maxMinutes={120} />
              <span>·</span>
              <SyncStamp label="Telegram" at={d.synced.telegram} maxMinutes={60} />
            </span>
          </div>
          {d.email && <form action="/auth/signout" method="post"><button className="rounded-lg border border-line px-3 py-1.5 hover:border-accent">Sair</button></form>}
        </div>
      </header>

      {d.error && (
        <p className="rounded-lg bg-bad/10 p-3 text-sm text-bad">
          Não consegui ler os dados do Supabase: {d.error}
        </p>
      )}

      {(paused || bounce7 > 3 || apolloAlerts.length > 0 || latePieces.length > 0) && (
        <div className="flex flex-col gap-2">
          {paused && <p className="rounded-lg bg-warn/10 p-3 text-sm text-warn">Inscrições novas no email estão pausadas. Quem já está na sequência continua recebendo os follow-ups.</p>}
          {bounce7 > 3 && <p className="rounded-lg bg-bad/10 p-3 text-sm text-bad">Bounce de email nos últimos 7 dias em {bounce7}%: acima do limite de 3%. O domínio certik.com fica em risco.</p>}
          {apolloAlerts.map((a) => <p key={a} className="rounded-lg bg-warn/10 p-3 text-sm text-warn">Apollo: {a}.</p>)}
          {latePieces.length > 0 && (
            <p className="rounded-lg bg-warn/10 p-3 text-sm text-warn">
              Atrasado: {latePieces.map((h) => `${h.label} (última ${when(h.last_at)})`).join(" · ")}. Detalhes em Saúde do sistema.
            </p>
          )}
        </div>
      )}

      <section className="grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-6">
        <Kpi value={email?.sent_today ?? 0} label="Emails hoje" />
        <Kpi value={tg?.sent_today ?? 0} label="Telegrams hoje" />
        <Kpi value={sum("sent_7d")} label="Toques em 7 dias" />
        <Kpi value={totalAccounts} label="Contas abordadas" />
        <Kpi value={sum("replied")} label="Respostas" tone="text-ok" />
        <Kpi value={`${email?.bounce_pct ?? 0}%`} label="Bounce do email (total)" tone={Number(email?.bounce_pct) > 3 ? "text-bad" : ""} />
      </section>

      <Section title="Calendário" aside={`Telegram: envio ${cal.tgSendEnabled ? "ligado" : "desligado"} · até ${cal.tgQuota}/dia, 14h–23h`}>
        <SectionError error={cal.error} />
        <div className="grid gap-4 lg:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]">
          <Calendar cal={cal} />
          <Agenda cal={cal} />
        </div>
        <p className="text-xs text-muted">Follow-ups de email são estimados pela cadência da sequência no Apollo. Telegram previsto segue a fila do motor: cota diária, uma conta por dia, por ordem de prioridade.</p>
      </Section>

      <Section title="Campanhas" aside="Cadência, quota e funil por canal">
        <SectionError error={d.funnel.error} />
        <div className="grid gap-3 md:grid-cols-2">
          {[email, tg].filter(Boolean).map((c) => (
            <div key={c.id} className="flex flex-col gap-3 rounded-xl border border-line bg-surface p-4">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <h3 className="font-semibold">{c.name}</h3>
                  <div className="text-xs text-muted">{CH[c.channel]} · reativação {(c.reactivation_days ?? []).map((x) => `D+${x}`).join(", ") || "–"}</div>
                </div>
                <Pill map={CAMP} k={c.status} />
              </div>
              <div className="grid grid-cols-4 gap-2 border-t border-line pt-3 text-center">
                {[["Contas", c.accounts_reached], ["Pessoas", c.people_reached], ["Respostas", c.replied], ["Bounces", c.bounced]].map(([l, v]) => (
                  <div key={l}><div className="num text-lg">{v ?? 0}</div><div className="text-[11px] text-muted">{l}</div></div>
                ))}
              </div>
              <div className="text-xs text-muted">Hoje: <span className="num text-ink">{c.sent_today ?? 0}</span>{c.daily_quota ? <> de <span className="num text-ink">{c.daily_quota}</span></> : null} · último envio {fmt(c.last_sent)}</div>
            </div>
          ))}
        </div>
      </Section>

      <div className="grid gap-6 lg:grid-cols-2">
        <Section title="Atividade dos últimos 30 dias">
          <SectionError error={d.daily.error} />
          <DailyChart rows={d.daily.data} />
        </Section>
        <Section title="Contas de envio">
          <SectionError error={d.channels.error} />
          <Table head={["Conta", "Situação", "Uso hoje"]} empty={!d.channels.data.length && !d.channels.error ? "Nenhuma conta cadastrada." : null}>
            {d.channels.data.map((a) => (
              <tr key={a.id}>
                <td>
                  <div className="font-medium">{CH[a.channel] ?? a.channel} · {a.handle}</div>
                  <div className="text-xs text-muted">{a.live_note ?? a.status_note}</div>
                  {a.status !== "ok" && a.status_note && a.live_note && <div className="text-xs text-warn">{a.status_note}</div>}
                  {a.live_checked_at && <div className="text-[11px] text-muted">verificado {when(a.live_checked_at)}</div>}
                </td>
                <td><Pill map={ACC} k={accountState(a)} /></td>
                <td className="min-w-[110px]"><QuotaBar used={Number(a.sent_today ?? 0)} limit={a.live_data?.daily_cap ?? a.daily_limit} /></td>
              </tr>
            ))}
          </Table>
        </Section>
      </div>

      <Section title="Integrações" aside="Verificadas de hora em hora">
        <SectionError error={d.integrations.error} />
        <Table head={["Integração", "Situação", "Detalhe", "Verificado"]} empty={!d.integrations.data.length && !d.integrations.error ? "Nenhuma integração cadastrada." : null}>
          {d.integrations.data.map((i) => (
            <tr key={i.id}>
              <td className="whitespace-nowrap font-medium">{i.label}</td>
              <td>{i.status ? <Pill map={INT} k={i.status} /> : <span className="text-xs text-muted">aguardando</span>}</td>
              <td className="text-xs">
                <div>{i.note ?? "Ainda não verificada"}</div>
                {(i.data?.sequences ?? []).map((s) => (
                  <div key={s.id} className="text-muted">
                    {s.name} · {s.active ? "ativa" : "desativada"} · <span className="num">{s.delivered}</span> entregues · <span className="num">{s.replied}</span> respostas · <span className="num">{s.bounced}</span> bounces ({Math.round((s.bounce_rate ?? 0) * 100)}%)
                  </div>
                ))}
              </td>
              <td className="num whitespace-nowrap text-xs">{when(i.checked_at)}</td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="Saúde do sistema" aside="Cada peça, quando deveria rodar e quando rodou">
        <SectionError error={d.health.error} />
        <Table head={["Peça", "Frequência", "Última execução", "Situação", "Detalhe"]} empty={!d.health.data.length && !d.health.error ? "Nenhuma execução registrada ainda." : null}>
          {d.health.data.map((h) => (
            <tr key={h.component}>
              <td><div className="font-medium">{h.label ?? h.component}</div><div className="text-[11px] text-muted">{h.component}</div></td>
              <td className="whitespace-nowrap text-xs">{h.freq_label ?? "avulsa"}</td>
              <td className="num whitespace-nowrap text-xs">{when(h.last_at)}</td>
              <td>
                {h.late ? <Pill map={{ x: ["Atrasada", "warn"] }} k="x" />
                  : !h.last_at ? <span className="text-xs text-muted">ainda não rodou</span>
                  : h.last_ok === false ? <Pill map={{ x: ["Falhou", "bad"] }} k="x" />
                  : h.ok_24h === false ? <Pill map={{ x: ["Instável", "warn"] }} k="x" />
                  : <Pill map={{ x: ["Ok", "ok"] }} k="x" />}
              </td>
              <td className="max-w-[420px] truncate text-xs text-muted" title={h.last_detail ?? ""}>{h.last_detail}</td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="Respostas" aside="Email e Telegram · a classe vem da rotina de catch-up">
        <SectionError error={d.replies.error} />
        <Table head={["Quando", "Quem", "Canal", "Classe", "Resumo"]} empty={!d.replies.data.length && !d.replies.error ? "Nenhuma resposta ainda." : null}>
          {d.replies.data.map((r) => (
            <tr key={r.id}>
              <td className="num whitespace-nowrap text-xs">{fmt(r.received_at)}</td>
              <td><div className="font-medium">{[r.contacts?.first_name, r.contacts?.last_name].filter(Boolean).join(" ") || "–"}</div><div className="text-xs text-muted">{[r.companies?.name, r.contacts?.position].filter(Boolean).join(" · ")}</div></td>
              <td>{CH[r.channel] ?? r.channel}</td>
              <td>{r.class ? (REPLY[r.class] ?? r.class) : <Pill map={{ x: ["A classificar", "idle"] }} k="x" />}{r.is_decision_maker ? <span className="ml-1 text-xs text-muted">· decisor</span> : null}</td>
              <td className="text-xs">{r.link ? <a href={r.link} className="text-accent underline-offset-2 hover:underline" target="_blank" rel="noreferrer">{r.summary}</a> : r.summary}</td>
            </tr>
          ))}
        </Table>
      </Section>

      <Section title="Contas" aside="As 40 mais recentes">
        <SectionError error={d.accounts.error} />
        <Table head={["Conta", "Rodada", "Situação", "Pessoas", "Email", "TG", "Respostas", "Bounces", "Último toque"]}>
          {d.accounts.data.map((a) => (
            <tr key={a.id}>
              <td className="font-medium">{a.name}</td>
              <td className="whitespace-nowrap text-xs">{a.round ?? "–"}</td>
              <td><Pill map={STATE} k={a.account_state ?? "active"} /></td>
              <td className="num text-right">{a.people_reached}</td>
              <td className="num text-right">{a.emails}</td>
              <td className="num text-right">{a.telegrams}</td>
              <td className="num text-right">{a.replies}</td>
              <td className="num text-right">{a.bounces}</td>
              <td className="num whitespace-nowrap text-xs">{fmt(a.last_touch)}</td>
            </tr>
          ))}
        </Table>
      </Section>

      <div className="grid gap-6 lg:grid-cols-2">
        <Section title="Últimos toques">
          <SectionError error={d.recent.error} />
          <Table head={["Quando", "Conta", "Contato", "Canal", "Situação"]}>
            {d.recent.data.slice(0, 25).map((t) => (
              <tr key={t.id}>
                <td className="num whitespace-nowrap text-xs">{fmt(t.sent_at)}</td>
                <td className="font-medium">{t.company ?? "–"}</td>
                <td><div>{t.contact || "–"}</div><div className="text-xs text-muted">{t.position}</div></td>
                <td>{CH[t.channel] ?? t.channel}</td>
                <td><Pill map={TOUCH} k={t.status} /></td>
              </tr>
            ))}
          </Table>
        </Section>
        <Section title="Próximos toques e reativação">
          <SectionError error={d.next.error} />
          <Table head={["Quando", "Contato", "Conta", "Etapa"]} empty={!d.next.data.length && !d.next.error ? "Fila vazia por enquanto." : null}>
            {d.next.data.map((n) => (
              <tr key={n.contact_id}>
                <td className="num whitespace-nowrap text-xs">{fmt(n.next_touch_at)}</td>
                <td><div>{n.contact}</div><div className="text-xs text-muted">{n.position}</div></td>
                <td>{n.company}</td>
                <td className="num text-xs">{n.reactivation_step ? `reativação ${n.reactivation_step}` : "sequência"}</td>
              </tr>
            ))}
          </Table>
        </Section>
      </div>

      <footer className="pb-6 text-xs text-muted">
        {d.email ? `Logado como ${d.email}. ` : "Página aberta, sem login (temporário). "}
        Dados do Supabase (projeto GTM-RAISE).
      </footer>
    </main>
  );
}

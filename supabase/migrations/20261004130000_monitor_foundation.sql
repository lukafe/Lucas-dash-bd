-- Monitor da Aurora: tabelas de observabilidade, estado da conta, respostas
-- classificadas e acesso de leitura só para o dono (login por magic link).

-- Quem pode ler pelo painel
create or replace function public.is_dash_owner() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() ->> 'email', '') in ('lucas.ceccon@certik.com', 'lucasfeka@gmail.com')
$$;

-- Execuções das rotinas do Claude
create table if not exists public.routine_runs (
  id bigserial primary key,
  routine text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'ok' check (status in ('ok', 'error', 'partial')),
  summary text
);
create index if not exists routine_runs_started_idx on public.routine_runs (started_at desc);

-- Cada sincronização determinística (Unipile, Apollo, Telegram Finder...)
create table if not exists public.sync_log (
  id bigserial primary key,
  source text not null,
  ran_at timestamptz not null default now(),
  rows_affected int default 0,
  ok boolean not null default true,
  error text
);
create index if not exists sync_log_source_idx on public.sync_log (source, ran_at desc);

-- Respostas classificadas (email, Telegram, LinkedIn)
create table if not exists public.replies (
  id bigserial primary key,
  contact_id bigint references public.contacts (id),
  company_id bigint references public.companies (id),
  touch_id bigint references public.touches (id),
  channel text not null,
  class text check (class in ('interessado', 'pediu_info', 'indicou_outro', 'agora_nao', 'ja_tem_auditor',
                              'sem_orcamento', 'pessoa_errada', 'pare', 'fora_do_escritorio', 'outro')),
  is_decision_maker boolean,
  confidence numeric(3, 2),
  summary text,
  link text,
  received_at timestamptz,
  handled boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists replies_received_idx on public.replies (received_at desc);

-- Meta x feito por dia, persona e canal
create table if not exists public.daily_targets (
  day date not null,
  persona_id text not null references public.personas (id),
  channel text not null,
  target int,
  done_new int default 0,
  done_followup int default 0,
  replies int default 0,
  positives int default 0,
  primary key (day, persona_id, channel)
);

-- Estado da conta e próximo toque
alter table public.companies add column if not exists account_state text not null default 'active'
  check (account_state in ('active', 'paused', 'dormant', 'replied', 'do_not_contact'));
alter table public.companies add column if not exists paused_until timestamptz;
alter table public.contacts add column if not exists role_level text
  check (role_level in ('founder_ceo', 'cto_tech', 'security', 'bd', 'other'));
alter table public.contacts add column if not exists next_touch_at timestamptz;
alter table public.contacts add column if not exists reactivation_step int not null default 0;

-- Cadências combinadas (out/2026): email D0, D+3, D+7 e reativação em 30, 90 e 180 dias
update public.campaigns set reactivation_days = '{30,90,180}' where name = 'Raises e ICO · email';
update public.campaigns set reactivation_days = '{14,30,90,180}' where name = 'Raises e ICO · Telegram';

-- RLS: as tabelas novas seguem o padrão (serviço escreve, dono lê)
alter table public.routine_runs enable row level security;
alter table public.sync_log enable row level security;
alter table public.replies enable row level security;
alter table public.daily_targets enable row level security;

do $$
declare t text;
begin
  foreach t in array array['personas', 'campaigns', 'channel_accounts', 'companies', 'contacts', 'touches',
                           'outreach', 'runs', 'routine_runs', 'sync_log', 'replies', 'daily_targets', 'source_state']
  loop
    execute format('drop policy if exists dash_owner_read on public.%I', t);
    execute format('create policy dash_owner_read on public.%I for select to authenticated using (public.is_dash_owner())', t);
  end loop;
end $$;

-- Saúde: última execução de cada peça
create or replace view public.v_health with (security_invoker = on) as
select 'pipeline:' || step as component, max(ran_at) as last_at,
       bool_and(ok) filter (where ran_at > now() - interval '24 hours') as ok_24h,
       (array_agg(detail order by ran_at desc))[1] as last_detail
from public.runs
where step not like 'test:%'
group by step
union all
select 'rotina:' || routine, max(started_at), bool_and(status = 'ok') filter (where started_at > now() - interval '24 hours'),
       (array_agg(summary order by started_at desc))[1]
from public.routine_runs group by routine
union all
select 'sync:' || source, max(ran_at), bool_and(ok) filter (where ran_at > now() - interval '24 hours'),
       (array_agg(coalesce(error, rows_affected::text || ' linhas') order by ran_at desc))[1]
from public.sync_log group by source;

-- Funil por campanha (contas e pessoas) e taxa de bounce
create or replace view public.v_campaign_funnel with (security_invoker = on) as
select cp.id, cp.name, cp.channel, cp.status, cp.daily_quota, cp.reactivation_days,
       count(distinct t.company_id) filter (where t.direction = 'out') as accounts_reached,
       count(distinct t.contact_id) filter (where t.direction = 'out') as people_reached,
       count(*) filter (where t.direction = 'out') as sent,
       count(*) filter (where t.direction = 'out' and t.sent_at >= date_trunc('day', now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai') as sent_today,
       count(*) filter (where t.direction = 'out' and t.sent_at > now() - interval '7 days') as sent_7d,
       count(*) filter (where t.status = 'replied') as replied,
       count(*) filter (where t.status = 'bounced') as bounced,
       round(100.0 * count(*) filter (where t.status = 'bounced') / nullif(count(*) filter (where t.direction = 'out'), 0), 1) as bounce_pct,
       round(100.0 * count(*) filter (where t.status = 'bounced' and t.sent_at > now() - interval '7 days')
             / nullif(count(*) filter (where t.direction = 'out' and t.sent_at > now() - interval '7 days'), 0), 1) as bounce_pct_7d,
       max(t.sent_at) as last_sent
from public.campaigns cp
left join public.touches t on t.campaign_id = cp.id
group by cp.id;

-- Fila de reativação / próximos toques
create or replace view public.v_next_touches with (security_invoker = on) as
select c.id as contact_id, trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as contact,
       c.position, co.name as company, co.stage_tier, c.stage, c.next_touch_at, c.reactivation_step
from public.contacts c
join public.companies co on co.id = c.company_id
where c.next_touch_at is not null and c.stage not in ('do_not_contact')
order by c.next_touch_at;

-- Contas abordadas com o estado atual
create or replace view public.v_accounts with (security_invoker = on) as
select co.id, co.name, co.category as round, co.stage_tier, co.amount_usd, co.account_state, co.created_at,
       count(distinct c.id) as contacts,
       count(distinct t.contact_id) filter (where t.direction = 'out') as people_reached,
       count(*) filter (where t.channel = 'email' and t.direction = 'out') as emails,
       count(*) filter (where t.channel = 'telegram' and t.direction = 'out') as telegrams,
       count(*) filter (where t.status = 'replied') as replies,
       count(*) filter (where t.status = 'bounced') as bounces,
       max(t.sent_at) as last_touch
from public.companies co
left join public.contacts c on c.company_id = co.id
left join public.touches t on t.company_id = co.id
group by co.id;

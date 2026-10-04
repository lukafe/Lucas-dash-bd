-- Monitor ao vivo: atualização de hora em hora do estado das contas e das integrações,
-- saúde do sistema com a frequência esperada de cada peça e respostas reais (classificadas
-- ou não). Aplicada no projeto GTM-RAISE em 04/out/2026.
--
-- Não mexe em regras de envio, listas de exclusão nem limites:
--   * channel_accounts.status continua sendo a trava do Telegram (tg.send_due só envia com
--     status = 'ok'); o estado medido vai para as colunas live_*, que são só exibição;
--   * o vigia do GitHub só reaciona o sync do Apollo e a leitura do CryptoRank (nada que
--     inscreva contato ou envie mensagem), e só quando existir o segredo
--     github_actions_token no Vault.

-- 1) Estado medido das contas de envio --------------------------------------------------
alter table public.channel_accounts
  add column if not exists live_status text,
  add column if not exists live_note text,
  add column if not exists live_data jsonb,
  add column if not exists live_checked_at timestamptz,
  add column if not exists retired_at timestamptz;

comment on column public.channel_accounts.live_status is
  'Estado medido pela atualização horária (ok | atencao | erro). Só exibição: a trava de envio é status.';
comment on column public.channel_accounts.retired_at is
  'Conta aposentada: some do monitor e não é mais usada.';

-- "Apollo pago previsto" era um marcador de antes do plano pago. A caixa real é a
-- email:apollo_free (é nela que caem os toques de email), então o marcador sai do monitor.
update public.channel_accounts
   set retired_at = coalesce(retired_at, now()), updated_at = now()
 where id = 'email:apollo';
update public.channel_accounts
   set status_note = 'Gmail institucional conectado ao Apollo', updated_at = now()
 where id = 'email:apollo_free';

-- 2) Integrações: fornecedores de dados e APIs -------------------------------------------
create table if not exists public.integrations (
  id text primary key,
  label text not null,
  status text,                 -- ok | atencao | erro
  note text,
  data jsonb,
  checked_at timestamptz,
  sort int not null default 100
);
alter table public.integrations enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'integrations' and policyname = 'dash_owner_read') then
    create policy dash_owner_read on public.integrations for select to authenticated using (public.is_dash_owner());
  end if;
end $$;
insert into public.integrations (id, label, sort) values
  ('apollo', 'Apollo', 10),
  ('telegram_finder', 'Telegram Finder', 20),
  ('unipile', 'Unipile', 30),
  ('github', 'GitHub Actions', 40)
on conflict (id) do nothing;

-- 3) Detalhe legível no registro de sincronizações --------------------------------------
alter table public.sync_log add column if not exists detail text;

-- 4) Frequência esperada de cada peça (para acusar atraso) ------------------------------
create table if not exists public.mon_cadence (
  component text primary key,      -- igual a v_health.component
  label text not null,
  freq_label text not null,
  every interval,                  -- null = não acusa atraso (roda só quando há o que fazer)
  grace interval not null default interval '30 minutes',
  sort int not null default 100,
  active boolean not null default true   -- false = esconde do monitor (duplicata de outra peça)
);
alter table public.mon_cadence enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'mon_cadence' and policyname = 'dash_owner_read') then
    create policy dash_owner_read on public.mon_cadence for select to authenticated using (public.is_dash_owner());
  end if;
end $$;

insert into public.mon_cadence (component, label, freq_label, every, grace, sort, active) values
  ('sync:monitor_refresh',     'Atualização do monitor',                      'de hora em hora',           interval '1 hour',     interval '30 minutes', 10, true),
  ('pipeline:sync_status',     'Sync do Apollo (respostas e bounces)',        'de hora em hora',           interval '1 hour',     interval '1 hour',     20, true),
  ('pipeline:monitor_apollo',  'Estado do Apollo (caixa, créditos, sequências)', 'de hora em hora',        interval '1 hour',     interval '1 hour',     30, true),
  ('pipeline:fetch_raises',    'Leitura do canal CryptoRank',                 'a cada 2h',                 interval '2 hours',    interval '2 hours',    40, true),
  ('pipeline:enrich_contacts', 'Enriquecimento de contatos',                  'diário',                    interval '1 day',      interval '12 hours',   50, true),
  ('pipeline:push_to_apollo',  'Inscrição na sequência do Apollo',            'diário',                    interval '1 day',      interval '12 hours',   60, true),
  ('cron:tg-lookup-hourly',    'Busca do @ no Telegram',                      'de hora em hora',           interval '1 hour',     interval '30 minutes', 70, true),
  ('cron:tg-sync-replies',     'Respostas do Telegram',                       'a cada 30 min',             interval '30 minutes', interval '30 minutes', 80, true),
  ('cron:tg-plan-daily',       'Fila do Telegram do dia',                     'diário, 13h20',             interval '1 day',      interval '2 hours',    90, true),
  ('sync:tg_send',             'Envio do Telegram',                           'a cada 10 min, 14h–23h',    null,                  interval '0',          100, true),
  ('cron:tg-classify-daily',   'Classificação das conversas do Telegram',     'diário, 6h30',              interval '1 day',      interval '2 hours',    110, true),
  -- duplicatas de peças acima: ficam fora do monitor
  ('cron:monitor-refresh',     'Atualização do monitor (agendador)',          'de hora em hora',           null,                  interval '0',          900, false),
  ('cron:tg-send',             'Envio do Telegram (agendador)',               'a cada 10 min, 14h–23h',    null,                  interval '0',          900, false),
  ('sync:tg_lookup',           'Busca do @ no Telegram (registro)',           'de hora em hora',           null,                  interval '0',          900, false),
  ('sync:tg_replies',          'Respostas do Telegram (registro)',            'a cada 30 min',             null,                  interval '0',          900, false),
  ('sync:tg_plan',             'Fila do Telegram (registro)',                 'diário',                    null,                  interval '0',          900, false)
on conflict (component) do update
  set label = excluded.label, freq_label = excluded.freq_label, every = excluded.every,
      grace = excluded.grace, sort = excluded.sort, active = excluded.active;

-- 5) Saúde: última execução, frequência esperada e atraso -------------------------------
-- As 4 primeiras colunas são as de antes (o monitor antigo segue funcionando).
create or replace view public.v_health with (security_invoker = on) as
with base as (
  select 'pipeline:' || r.step as component,
         max(r.ran_at) as last_at,
         bool_and(r.ok) filter (where r.ran_at > now() - interval '24 hours') as ok_24h,
         (array_agg(r.detail order by r.ran_at desc))[1] as last_detail,
         (array_agg(r.ok order by r.ran_at desc))[1] as last_ok
  from public.runs r
  where r.step !~~ 'test:%'
  group by r.step
  union all
  select 'rotina:' || rr.routine, max(rr.started_at),
         bool_and(rr.status = 'ok') filter (where rr.started_at > now() - interval '24 hours'),
         (array_agg(rr.summary order by rr.started_at desc))[1],
         (array_agg(rr.status = 'ok' order by rr.started_at desc))[1]
  from public.routine_runs rr
  group by rr.routine
  union all
  select 'sync:' || s.source, max(s.ran_at),
         bool_and(s.ok) filter (where s.ran_at > now() - interval '24 hours'),
         (array_agg(coalesce(s.error, s.detail, s.rows_affected::text || ' linhas') order by s.ran_at desc))[1],
         (array_agg(s.ok order by s.ran_at desc))[1]
  from public.sync_log s
  where s.source <> 'teste_permissao'
  group by s.source
  union all
  select 'cron:' || j.jobname, max(d.start_time),
         bool_and(d.status = 'succeeded') filter (where d.start_time > now() - interval '24 hours'),
         (array_agg(case when d.status = 'succeeded' then 'rodou sem erro'
                         else left(coalesce(d.return_message, d.status), 300) end order by d.start_time desc))[1],
         (array_agg(d.status = 'succeeded' order by d.start_time desc))[1]
  from cron.job j
  left join cron.job_run_details d on d.jobid = j.jobid
  group by j.jobname
)
select coalesce(b.component, m.component) as component,
       b.last_at,
       b.ok_24h,
       b.last_detail,
       coalesce(m.label, b.component) as label,
       m.freq_label,
       b.last_ok,
       coalesce(m.every is not null and b.last_at < now() - m.every - m.grace, false) as late,   -- nunca rodou não é atraso
       coalesce(m.sort, 1000) as sort,
       m.component is not null as tracked
from base b
full join public.mon_cadence m on m.component = b.component
where (m.component is not null and m.active)
   or (m.component is null and b.last_at > now() - interval '24 hours');

-- 6) Contas de envio com o estado medido; aposentadas saem ------------------------------
create or replace view public.v_account_usage with (security_invoker = on) as
select a.id, a.channel, a.handle, a.provider, a.provider_account_id, a.daily_limit, a.weekly_limit,
       a.status, a.status_note, a.updated_at,
       (select count(*) from public.touches t
         where t.account_id = a.id and t.direction = 'out'
           and t.sent_at >= (date_trunc('day', now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai')) as sent_today,
       (select count(*) from public.touches t
         where t.account_id = a.id and t.direction = 'out' and t.sent_at > now() - interval '7 days') as sent_7d,
       a.live_status, a.live_note, a.live_data, a.live_checked_at
from public.channel_accounts a
where a.retired_at is null;

-- 7) Atualização horária ---------------------------------------------------------------
create schema if not exists mon;

create or replace function mon.refresh()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb; acc jsonb; v_items jsonb := '[]'; v_st text;
  v_tf_u jsonb; v_tf_r jsonb;
  v_gh text; v_resp extensions.http_response; w record; v_last timestamptz;
  v_errs text[] := '{}'; v_bits text[] := '{}'; v_late text[] := '{}'; v_sent text[] := '{}';
begin
  -- Unipile: conexão de cada conta (Telegram, LinkedIn)
  begin
    r := unipile.get('/api/v1/accounts');
    if coalesce((r->>'status')::int, 0) <> 200 then
      raise exception 'respondeu %', coalesce(r->>'status', 'sem status');
    end if;
    v_items := coalesce(r->'body'->'items', '[]'::jsonb);
    for acc in select * from jsonb_array_elements(v_items) loop
      select string_agg(distinct s->>'status', ',') into v_st from jsonb_array_elements(coalesce(acc->'sources', '[]')) s;
      update channel_accounts ca
         set live_status = case when v_st = 'OK' then 'ok' when v_st ~ 'CONNECTING|SYNC' then 'atencao' else 'erro' end,
             live_note = case when v_st = 'OK' then 'Conectada na Unipile'
                              when v_st ~ 'CREDENTIALS' then 'A Unipile pede login de novo nesta conta'
                              else 'Unipile: ' || coalesce(v_st, 'sem status') end,
             live_data = jsonb_build_object('provider_status', v_st, 'type', acc->>'type'),
             live_checked_at = now()
       where ca.provider = 'unipile' and ca.provider_account_id = acc->>'id';
    end loop;
    update channel_accounts ca
       set live_status = 'erro', live_note = 'Conta não aparece mais na Unipile', live_checked_at = now()
     where ca.provider = 'unipile' and ca.provider_account_id is not null and ca.retired_at is null
       and not exists (select 1 from jsonb_array_elements(v_items) x where x->>'id' = ca.provider_account_id);
    update channel_accounts ca
       set live_status = null, live_note = 'Não conectada na Unipile', live_checked_at = now()
     where ca.provider = 'unipile' and ca.provider_account_id is null and ca.retired_at is null;
    update integrations
       set status = case when exists (select 1 from jsonb_array_elements(v_items) x, jsonb_array_elements(x->'sources') s
                                      where s->>'status' <> 'OK') then 'atencao' else 'ok' end,
           note = coalesce((select string_agg(
                     case x->>'type' when 'TELEGRAM' then 'Telegram' when 'LINKEDIN' then 'LinkedIn'
                                     when 'WHATSAPP' then 'WhatsApp' else initcap(lower(x->>'type')) end
                     || ': ' || coalesce((select string_agg(distinct s->>'status', ',') from jsonb_array_elements(x->'sources') s), '?'),
                     ' · ' order by x->>'type') from jsonb_array_elements(v_items) x), 'nenhuma conta conectada'),
           data = jsonb_build_object('accounts', jsonb_array_length(v_items)),
           checked_at = now()
     where id = 'unipile';
    v_bits := v_bits || format('Unipile: %s conta(s)', jsonb_array_length(v_items));
  exception when others then
    v_errs := v_errs || ('Unipile: ' || sqlerrm);
    update integrations set status = 'erro', note = left('Falha ao consultar: ' || sqlerrm, 200), checked_at = now()
     where id = 'unipile';
  end;

  -- Telegram Finder: créditos e limite por hora
  begin
    v_tf_u := tg.tf('GET', '/api/account/usage');
    v_tf_r := tg.tf('GET', '/api/account/rate-limit');
    if coalesce((v_tf_u->>'status')::int, 0) <> 200 then
      raise exception 'respondeu %', coalesce(v_tf_u->>'status', 'sem status');
    end if;
    update integrations
       set status = case when coalesce((v_tf_u->'body'->>'remaining')::int, 0) <= 2 then 'atencao' else 'ok' end,
           note = format('%s de %s créditos restantes (%s) · requisições na hora: %s de %s',
                         coalesce(v_tf_u->'body'->>'remaining', '?'), coalesce(v_tf_u->'body'->>'limit', '?'),
                         case v_tf_u->'body'->>'planType' when 'prepaid_pack' then 'pacote pré-pago'
                              else coalesce(v_tf_u->'body'->>'planType', 'plano ?') end,
                         coalesce(v_tf_r->'body'->'limits'->'hourlyRequests'->>'remaining', '?'),
                         coalesce(v_tf_r->'body'->'limits'->'hourlyRequests'->>'limit', '?')),
           data = jsonb_build_object('usage', v_tf_u->'body', 'rate', v_tf_r->'body'),
           checked_at = now()
     where id = 'telegram_finder';
    v_bits := v_bits || format('Telegram Finder: %s créditos', coalesce(v_tf_u->'body'->>'remaining', '?'));
  exception when others then
    v_errs := v_errs || ('Telegram Finder: ' || sqlerrm);
    update integrations set status = 'erro', note = left('Falha ao consultar: ' || sqlerrm, 200), checked_at = now()
     where id = 'telegram_finder';
  end;

  -- Vigia do GitHub: o agendador do GitHub atrasa e pula rodadas. Se o sync do Apollo ou a
  -- leitura do CryptoRank passarem do prazo, reaciona o workflow (só com o token no Vault).
  begin
    select decrypted_secret into v_gh from vault.decrypted_secrets where name = 'github_actions_token' limit 1;
    for w in select * from (values
               ('sync_status', 'sync.yml', interval '75 minutes'),
               ('fetch_raises', 'scrape.yml', interval '150 minutes')) as t(step, workflow, max_age) loop
      select max(ran_at) into v_last from runs where step = w.step;
      continue when v_last is not null and v_last >= now() - w.max_age;
      if v_gh is null then
        v_late := v_late || w.step;
      else
        v_resp := extensions.http((
          'POST',
          'https://api.github.com/repos/lukafe/GPT_eng_CertiK_Raisefounds/actions/workflows/' || w.workflow || '/dispatches',
          array[extensions.http_header('Authorization', 'Bearer ' || v_gh),
                extensions.http_header('Accept', 'application/vnd.github+json'),
                extensions.http_header('X-GitHub-Api-Version', '2022-11-28'),
                extensions.http_header('User-Agent', 'aurora-monitor')],
          'application/json', '{"ref":"main"}'
        )::extensions.http_request);
        if v_resp.status = 204 then
          v_sent := v_sent || w.workflow;
        else
          v_errs := v_errs || format('GitHub %s: respondeu %s', w.workflow, v_resp.status);
        end if;
      end if;
    end loop;
    update integrations
       set status = case when cardinality(v_late) > 0 then 'atencao' else 'ok' end,
           note = case when v_gh is null and cardinality(v_late) > 0
                         then 'Atrasado: ' || array_to_string(v_late, ', ') || ' (sem token no Vault para religar sozinho)'
                       when v_gh is null then 'Agendador do GitHub em dia (sem token no Vault: só vigia)'
                       when cardinality(v_sent) > 0 then 'Religado agora: ' || array_to_string(v_sent, ', ')
                       else 'Agendador do GitHub em dia (vigia com token)' end,
           data = jsonb_build_object('token', v_gh is not null, 'late', to_jsonb(v_late), 'dispatched', to_jsonb(v_sent)),
           checked_at = now()
     where id = 'github';
    if cardinality(v_sent) > 0 then v_bits := v_bits || ('GitHub religado: ' || array_to_string(v_sent, ', ')); end if;
    if cardinality(v_late) > 0 then v_bits := v_bits || ('GitHub atrasado: ' || array_to_string(v_late, ', ')); end if;
  exception when others then
    v_errs := v_errs || ('GitHub: ' || sqlerrm);
  end;

  insert into sync_log (source, rows_affected, ok, error, detail)
  values ('monitor_refresh', cardinality(v_bits), cardinality(v_errs) = 0,
          nullif(array_to_string(v_errs, ' · '), ''), array_to_string(v_bits, ' · '));

  return jsonb_build_object('ok', cardinality(v_errs) = 0, 'detail', v_bits, 'errors', v_errs);
end
$$;

comment on function mon.refresh() is
  'Atualização horária do monitor: conexão das contas na Unipile, créditos do Telegram Finder e vigia do agendador do GitHub. Não mexe em envio.';

select cron.schedule('monitor-refresh', '5 * * * *', 'select mon.refresh()');

-- 8) Snapshot do monitor: integrações, horário das sincronizações e respostas reais ------
create or replace function public.dash_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.is_dash_owner()
          or coalesce((select s.value from public.source_state s where s.key = 'dash_public'), 'false') = 'true') then
    raise exception 'acesso negado ao monitor' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'funnel', coalesce((select jsonb_agg(to_jsonb(f) order by f.id) from public.v_campaign_funnel f), '[]'::jsonb),
    'accounts', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.last_touch desc nulls last)
      from (select * from public.v_accounts order by last_touch desc nulls last limit 40) a), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.sent_at desc nulls last)
      from (select * from public.v_recent_touches order by sent_at desc nulls last limit 50) r), '[]'::jsonb),
    'next', coalesce((
      select jsonb_agg(to_jsonb(n) order by n.next_touch_at)
      from (select * from public.v_next_touches order by next_touch_at limit 30) n), '[]'::jsonb),
    -- Respostas: as classificadas pela rotina de catch-up e as que ainda esperam classificação
    -- (email com resposta no Apollo; última mensagem recebida em cada conversa do Telegram).
    'replies', coalesce((
      select jsonb_agg(x.j order by x.at desc)
      from (
        select y.j, y.at from (
          select jsonb_build_object(
                   'id', 'r' || r.id, 'channel', r.channel, 'class', r.class, 'is_decision_maker', r.is_decision_maker,
                   'confidence', r.confidence, 'summary', r.summary, 'link', r.link, 'received_at', r.received_at,
                   'handled', r.handled,
                   'contacts', case when c.id is null then null
                                    else jsonb_build_object('first_name', c.first_name, 'last_name', c.last_name, 'position', c.position) end,
                   'companies', case when co.id is null then null else jsonb_build_object('name', co.name) end) as j,
                 r.received_at as at
          from public.replies r
          left join public.contacts c on c.id = r.contact_id
          left join public.companies co on co.id = coalesce(r.company_id, c.company_id)

          union all
          select jsonb_build_object(
                   'id', 'o' || o.id, 'channel', 'email', 'class', null, 'is_decision_maker', null,
                   'summary', 'Respondeu ao email da sequência (abrir no Apollo)',
                   'link', case when c.apollo_id is not null then 'https://app.apollo.io/#/contacts/' || c.apollo_id end,
                   'received_at', o.replied_at, 'handled', false,
                   'contacts', jsonb_build_object('first_name', c.first_name, 'last_name', c.last_name, 'position', c.position),
                   'companies', case when co.id is null then null else jsonb_build_object('name', co.name) end),
                 o.replied_at
          from public.outreach o
          join public.contacts c on c.id = o.contact_id
          left join public.companies co on co.id = c.company_id
          where o.replied_at is not null
            and not exists (select 1 from public.replies r where r.contact_id = o.contact_id and r.channel = 'email')

          union all
          select z.j, z.at from (
            select distinct on (coalesce(t.contact_id::text, t.provider_chat_id, t.id::text))
                   jsonb_build_object(
                     'id', 't' || t.id, 'channel', 'telegram', 'class', null, 'is_decision_maker', null,
                     'summary', left(t.body, 200), 'link', null, 'received_at', t.sent_at, 'handled', false,
                     'contacts', case when c.id is null then jsonb_build_object('first_name', t.target_name)
                                      else jsonb_build_object('first_name', c.first_name, 'last_name', c.last_name, 'position', c.position) end,
                     'companies', case when co.id is null then null else jsonb_build_object('name', co.name) end) as j,
                   t.sent_at as at
            from public.touches t
            left join public.contacts c on c.id = t.contact_id
            left join public.companies co on co.id = coalesce(t.company_id, c.company_id)
            where t.channel = 'telegram' and t.direction = 'in' and t.sent_at is not null
              and not exists (select 1 from public.replies r
                              where r.touch_id = t.id
                                 or (t.contact_id is not null and r.contact_id = t.contact_id
                                     and r.channel = 'telegram' and r.received_at >= t.sent_at))
            order by coalesce(t.contact_id::text, t.provider_chat_id, t.id::text), t.sent_at desc
          ) z
        ) y
        order by y.at desc nulls last
        limit 25
      ) x), '[]'::jsonb),
    'health', coalesce((select jsonb_agg(to_jsonb(h) order by h.sort, h.last_at desc nulls last) from public.v_health h), '[]'::jsonb),
    'channels', coalesce((select jsonb_agg(to_jsonb(u) order by u.id) from public.v_account_usage u), '[]'::jsonb),
    'integrations', coalesce((select jsonb_agg(to_jsonb(i) order by i.sort) from public.integrations i), '[]'::jsonb),
    'synced', jsonb_build_object(
      'monitor', (select max(ran_at) from public.sync_log where source = 'monitor_refresh'),
      'apollo', (select max(ran_at) from public.runs where step in ('sync_status', 'monitor_apollo')),
      'telegram', (select max(d.start_time) from cron.job j join cron.job_run_details d on d.jobid = j.jobid
                   where j.jobname = 'tg-sync-replies' and d.status = 'succeeded')),
    'state', coalesce((
      select jsonb_agg(jsonb_build_object('key', s.key, 'value', s.value, 'updated_at', s.updated_at))
      from public.source_state s where s.key in ('push_paused', 'dash_public')), '[]'::jsonb),
    'daily', coalesce((select jsonb_agg(to_jsonb(d) order by d.day) from public.v_daily_touches d), '[]'::jsonb)
  );
end
$$;

grant execute on function public.dash_snapshot() to anon, authenticated;

-- Calendário: programação de email.
-- Além do que já saiu e dos follow-ups de quem está na sequência, o calendário passa a prever:
--   * os contatos prontos (ready/held) entrando na sequência, no ritmo do pipeline
--     (teto diário do envio e no máximo 3 por empresa por dia), com os follow-ups da sequência atual;
--   * as empresas da fila de enriquecimento, no dia em que o pipeline deve processá-las.
-- A distribuição pelos dias é feita na página (lib/calendar.js), como já acontece com o Telegram.

create or replace function public.dash_calendar(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, unipile
as $$
declare
  v_tz constant text := 'Asia/Shanghai';
  v_from timestamptz := p_from::timestamp at time zone v_tz;
  v_to timestamptz := (p_to + 1)::timestamp at time zone v_tz;
begin
  if not (public.is_dash_owner()
          or coalesce((select s.value from public.source_state s where s.key = 'dash_public'), 'false') = 'true') then
    raise exception 'acesso negado ao monitor' using errcode = '42501';
  end if;
  if p_to - p_from > 62 then
    raise exception 'intervalo grande demais';
  end if;

  return jsonb_build_object(
    'email', (
      select jsonb_build_object(
        'paused', coalesce((select value from source_state where key = 'push_paused'), 'false') = 'true',
        'cap', coalesce((select coalesce((ca.live_data->>'daily_cap')::int, ca.daily_limit)
                         from channel_accounts ca where ca.id = 'email:apollo_free'), 40),
        'per_company', 3,
        'companies_per_day', coalesce((select (ca.live_data->>'companies_per_day')::int
                                       from channel_accounts ca where ca.id = 'email:apollo_free'), 40),
        'offsets', case (select value from source_state where key = 'apollo_seq_id')
                     when '6aa310116ac35f00149db433' then '[0, 5]'::jsonb
                     when '6ac25620a246a700147a45bf' then '[0, 3, 7, 30, 90, 180]'::jsonb
                     else '[0]'::jsonb end,
        -- a rodada diária (enriquecimento + entrada na sequência) já aconteceu hoje (dia de Xangai)?
        'ran_today', exists (select 1 from runs r where r.step = 'push_to_apollo' and r.ok
                             and r.ran_at >= (now() at time zone v_tz)::date::timestamp at time zone v_tz),
        -- contatos prontos, na ordem em que o pipeline escolhe (raise mais recente primeiro)
        'ready', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')),
                   'company', co.name, 'company_id', c.company_id, 'position', c.position)
                 order by co.raise_date desc nulls last, c.id)
          from contacts c left join companies co on co.id = c.company_id
          where c.status in ('ready', 'held')
        ), '[]'::jsonb),
        -- empresas na fila de enriquecimento, na ordem do pipeline (maior raise primeiro)
        'queue', coalesce((
          select jsonb_agg(jsonb_build_object('company', q.name, 'company_id', q.id) order by q.rn)
          from (
            select co.id, co.name,
                   row_number() over (order by co.amount_usd desc nulls last, co.raise_date desc nulls last, co.id) as rn
            from companies co where co.status = 'queued'
          ) q where q.rn <= 600
        ), '[]'::jsonb)
      )
    ),
    'tg_quota', (select least(coalesce(cp.daily_quota, 20), coalesce(ca.daily_limit, 20))
                 from campaigns cp cross join channel_accounts ca
                 where cp.channel = 'telegram' and cp.persona_id = 'web3' and ca.channel = 'telegram' limit 1),
    'tg_send_enabled', coalesce((select value from source_state where key = 'tg_send_enabled'), 'false') = 'true',
    'events', coalesce((
      select jsonb_agg(e order by e->>'at')
      from (
        -- toques enviados
        select jsonb_build_object(
                 'at', t.sent_at, 'channel', t.channel, 'kind', t.kind,
                 'state', case when t.status = 'bounced' then 'bounce' else 'feito' end,
                 'name', coalesce(nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), t.target_name),
                 'company', co.name, 'position', c.position) as e
        from touches t
        left join contacts c on c.id = t.contact_id
        left join companies co on co.id = t.company_id
        where t.direction = 'out' and t.sent_at >= v_from and t.sent_at < v_to

        union all
        -- follow-ups de email pela cadência da sequência (estimados)
        select jsonb_build_object(
                 'at', case when s.due < now() then s.due else greatest(s.due, now()) end,
                 'channel', 'email', 'kind', 'followup',
                 'state', case when s.due < now() then 'feito' else 'previsto' end,
                 'est', true,
                 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')),
                 'company', co.name, 'position', c.position)
        from (
          select o.contact_id, o.replied_at, o.bounced,
                 o.added_at + make_interval(days => d.offs[k]) as due
          from outreach o
          cross join lateral (
            select case o.sequence_id
                     when '6aa310116ac35f00149db433' then array[0, 5]
                     when '6ac25620a246a700147a45bf' then array[0, 3, 7, 30, 90, 180]
                     else array[0]::int[] end as offs
          ) d
          cross join lateral generate_subscripts(d.offs, 1) k
          where k > 1
        ) s
        join contacts c on c.id = s.contact_id
        left join companies co on co.id = c.company_id
        where not coalesce(s.bounced, false)
          and (s.replied_at is null or s.replied_at > s.due)
          and (s.due < now() or c.status = 'in_sequence')
          and case when s.due < now() then s.due else greatest(s.due, now()) end >= v_from
          and case when s.due < now() then s.due else greatest(s.due, now()) end < v_to

        union all
        -- respostas de email
        select jsonb_build_object(
                 'at', o.replied_at, 'channel', 'email', 'kind', 'reply', 'state', 'resposta',
                 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')),
                 'company', co.name, 'position', c.position)
        from outreach o
        join contacts c on c.id = o.contact_id
        left join companies co on co.id = c.company_id
        where o.replied_at >= v_from and o.replied_at < v_to

        union all
        -- respostas de Telegram
        select jsonb_build_object(
                 'at', t.sent_at, 'channel', t.channel, 'kind', 'reply', 'state', 'resposta',
                 'name', coalesce(nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), t.target_name),
                 'company', co.name, 'detail', left(t.body, 160))
        from touches t
        left join contacts c on c.id = t.contact_id
        left join companies co on co.id = t.company_id
        where t.direction = 'in' and t.sent_at >= v_from and t.sent_at < v_to

        union all
        -- fila do Telegram
        select jsonb_build_object(
                 'at', t.scheduled_for, 'channel', t.channel, 'kind', t.kind, 'state', 'fila',
                 'name', coalesce(nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), t.target_name),
                 'company', co.name, 'position', c.position, 'detail', left(t.body, 160))
        from touches t
        left join contacts c on c.id = t.contact_id
        left join companies co on co.id = t.company_id
        where t.channel = 'telegram' and t.status = 'queued' and t.cancelled_at is null
          and t.scheduled_for >= v_from and t.scheduled_for < v_to
      ) x
    ), '[]'::jsonb),
    'tg_forecast', coalesce((
      select jsonb_agg(jsonb_build_object(
               'due', c.due_at, 'kind', c.kind, 'prio', c.prio, 'company_id', c.company_id, 'chat_id', c.chat_id,
               'name', c.target_name, 'company', co.name) order by c.prio, c.due_at)
      from tg.candidates(v_to) c
      left join companies co on co.id = c.company_id
    ), '[]'::jsonb)
  );
end
$$;

comment on function public.dash_calendar(date, date) is
  'Calendário do monitor Aurora (feito, bounce, resposta, fila, previsto). Mesmo acesso do dash_snapshot.';

grant execute on function public.dash_calendar(date, date) to anon, authenticated;

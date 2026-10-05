-- Telegram só com a reativação (decisão do Lucas em 05/10, 15h48: "deixar o TG de lado e terminar a reativação;
-- o Telegram Finder não é uma boa ferramenta").
--   * 1º contato no Telegram para contatos novos: desligado (source_state.tg_first_touch_enabled = 'false');
--     a reativação das conversas "aguardando" segue (25/dia, termina em 07/10).
--   * Telegram Finder desligado: lookup de hora em hora (tg_lookup_enabled) e busca reversa (tg_reverse_enabled).
--   * Telefones pelo Apollo desligados (tg_phone_reveal_enabled): public.tg_phone_candidates não devolve ninguém,
--     então a etapa phone_reveal do pipeline não gasta crédito.
-- Para religar qualquer peça, basta voltar a chave correspondente para 'true'.

insert into source_state (key, value) values
  ('tg_first_touch_enabled', 'false'), ('tg_phone_reveal_enabled', 'false')
  on conflict (key) do update set value = excluded.value, updated_at = now();
update source_state set value = 'false', updated_at = now() where key in ('tg_lookup_enabled', 'tg_reverse_enabled');

create or replace function tg.candidates(p_until timestamp with time zone)
 returns table(prio integer, kind text, contact_id bigint, company_id bigint, chat_id text, user_id text,
               target_name text, first_name text, due_at timestamp with time zone)
 language sql
 stable security definer
 set search_path to 'public', 'unipile'
as $function$
  with camp as (
    select reactivation_days from campaigns where channel = 'telegram' and persona_id = 'web3' order by id limit 1
  ),
  backlog as (
    select nullif((select value from source_state where key = 'tg_reactivation_backlog_before'), '')::timestamptz as before
  ),
  sent as (
    select t.contact_id, min(t.sent_at) as first_at, count(*)::int as n, max(t.company_id) as company_id,
           (array_agg(t.provider_chat_id order by t.sent_at) filter (where t.provider_chat_id is not null))[1] as chat_id,
           (array_agg(t.provider_user_id order by t.sent_at))[1] as user_id
    from touches t
    where t.channel = 'telegram' and t.direction = 'out' and t.contact_id is not null and t.status = 'sent'
    group by t.contact_id
  ),
  queued as (
    select contact_id, provider_chat_id from touches
    where channel = 'telegram' and status = 'queued' and cancelled_at is null
  ),
  fu as (
    select 1 as prio, case when s.n = 1 then 'followup' else 'reactivation' end as kind,
           s.contact_id, s.company_id, s.chat_id, s.user_id,
           trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as target_name, c.first_name,
           s.first_at + make_interval(days => camp.reactivation_days[s.n]) as due_at
    from sent s cross join camp
    join contacts c on c.id = s.contact_id
    left join companies co on co.id = s.company_id
    where s.n <= coalesce(array_length(camp.reactivation_days, 1), 0)
      and coalesce(co.account_state, 'active') = 'active'
      and coalesce(c.stage, 'new') not in ('do_not_contact', 'replied')
      and not exists (select 1 from touches i where i.channel = 'telegram' and i.direction = 'in' and i.contact_id = s.contact_id)
      and not exists (select 1 from queued q where q.contact_id = s.contact_id)
  ),
  first_touch as (
    select 2 as prio, 'first' as kind, c.id as contact_id, c.company_id, null::text as chat_id, c.telegram_user_id as user_id,
           trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as target_name, c.first_name,
           coalesce((select min(e.sent_at) from touches e
                     where e.contact_id = c.id and e.channel = 'email' and e.direction = 'out' and e.sent_at is not null)
                    + interval '2 days', c.tg_lookup_at, now()) as due_at
    from contacts c join companies co on co.id = c.company_id
    where coalesce((select value from source_state where key = 'tg_first_touch_enabled'), 'true') = 'true'
      and c.persona_id = 'web3' and c.telegram_user_id is not null and c.tg_lookup_status = 'found'
      and coalesce(c.stage, 'new') not in ('do_not_contact', 'replied') and co.account_state = 'active'
      and not exists (select 1 from touches t where t.contact_id = c.id and t.channel = 'telegram'
                      and t.cancelled_at is null and t.status <> 'failed')
  ),
  old_chat as (
    select 3 as prio, 'reactivation' as kind, null::bigint as contact_id, null::bigint as company_id,
           ch.chat_id, ch.provider_id as user_id, ch.name as target_name, ch.name as first_name,
           case k.n when 0 then
                  -- conversa anterior ao corte: apta 1 dia depois da última mensagem (as mais antigas primeiro)
                  case when ch.last_ts < bk.before then ch.last_ts + interval '1 day'
                       else ch.last_ts + interval '30 days' end
                    when 1 then k.last_at + interval '60 days'
                    when 2 then k.last_at + interval '90 days' end as due_at
    from unipile.tg_chats ch
    cross join backlog bk
    cross join lateral (
      select count(*)::int as n, max(t.sent_at) as last_at from touches t
      where t.provider_chat_id = ch.chat_id and t.channel = 'telegram' and t.direction = 'out' and t.status = 'sent'
    ) k
    where ch.folder = 'aguardando' and ch.chat_type = 0 and not coalesce(ch.junk, false) and ch.last_from_me
      and k.n < 3
      and not exists (select 1 from queued q where q.provider_chat_id = ch.chat_id)
      and not exists (select 1 from touches i where i.provider_chat_id = ch.chat_id and i.direction = 'in')
  )
  select * from fu where due_at <= p_until
  union all select * from first_touch where due_at <= p_until
  union all select * from old_chat where due_at <= p_until
$function$;

create or replace function public.tg_phone_candidates(p_daily_max int)
returns table(id bigint, apollo_person_id text, first_name text, last_name text, email text, domain text, tg_profile jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'somente o pipeline' using errcode = '42501';
  end if;
  if coalesce((select value from source_state where key = 'tg_phone_reveal_enabled'), 'true') <> 'true' then
    return;   -- desligado: o pipeline não pede telefone a ninguém
  end if;
  return query
  select ct.id, ct.apollo_person_id, ct.first_name, ct.last_name, ct.email, co.domain, ct.tg_profile
  from contacts ct join companies co on co.id = ct.company_id
  where ct.persona_id = 'web3' and ct.telegram_user_id is null and ct.phone is null and ct.tg_lookup_status is null
    and ct.tg_profile->>'phone_requested_at' is null and ct.tg_profile->>'phone_none_at' is null
    and coalesce(ct.stage, 'new') not in ('do_not_contact', 'replied')
    and coalesce(co.status, '') not in ('no_fit', 'no_domain') and co.account_state = 'active'
    and tg.is_target(ct.position, ct.role_level)
  order by (co.stage_tier in ('early', 'ico_other')) desc nulls last, tg.target_rank(ct.position),
           co.raise_date desc nulls last, ct.id
  limit greatest(0, p_daily_max - (
    select count(*) from contacts x
    where (x.tg_profile->>'phone_requested_at')::timestamptz >= date_trunc('day', now())))::int;
end
$$;

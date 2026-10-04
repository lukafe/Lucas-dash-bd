-- Motor do Telegram (Aurora · Web3 nativo / fundraising), todo dentro do Supabase.
--
-- Peças (schema tg, chamadas pelo pg_cron):
--   tg.lookup_batch  acha o Telegram dos decisores: @ conhecido → telefone → Telegram Finder
--                    reverso (email/LinkedIn → telefone, só com tg_reverse_enabled e crédito)
--   tg.plan_day      monta a fila do dia (até a cota, 1 conta por dia, 14h–22h45 de Xangai):
--                    follow-ups/reativações → primeiros toques → conversas antigas sem resposta
--   tg.send_due      envia o que venceu, pela Unipile, só com tg_send_enabled = true
--   tg.sync_replies  lê respostas, registra, pausa a conta e cancela a fila dela
--
-- Interruptores em source_state: tg_send_enabled (começa 'false'), tg_lookup_enabled,
-- tg_reverse_enabled (começa 'false': créditos do Finder a confirmar).

create schema if not exists tg;

-- Colunas novas ------------------------------------------------------------------------
alter table public.contacts add column if not exists tg_profile jsonb;
alter table public.contacts add column if not exists tg_lookup_note text;
alter table public.touches add column if not exists provider_chat_id text;
alter table public.touches add column if not exists target_name text;
alter table public.touches add column if not exists cancelled_at timestamptz;
create index if not exists touches_queue_idx on public.touches (channel, scheduled_for) where status = 'queued';
create index if not exists touches_chat_idx on public.touches (provider_chat_id);

insert into public.source_state (key, value) values
  ('tg_send_enabled', 'false'), ('tg_lookup_enabled', 'true'), ('tg_reverse_enabled', 'false')
on conflict (key) do nothing;

update public.channel_accounts
set provider_account_id = 'eIezcuS3T2-Nxfx-7xdXFw', status = 'ok',
    status_note = 'Unipile ok; @SpamBot sem restrição (confirmado pelo Lucas em 04/out)', updated_at = now()
where id = 'telegram:lucascecconn';

-- Chamadas HTTP --------------------------------------------------------------------------
create or replace function tg.unipile_post(p_path text, p_fields jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_key text; v_resp extensions.http_response;
  v_b text := 'aurora' || md5(random()::text); v_body text := ''; k text; v jsonb; e jsonb;
begin
  if p_path !~ '^/api/v1/' then raise exception 'path inválido'; end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'unipile_api_key' limit 1;
  for k, v in select * from jsonb_each(p_fields) loop
    for e in select * from jsonb_array_elements(case when jsonb_typeof(v) = 'array' then v else jsonb_build_array(v) end) loop
      v_body := v_body || '--' || v_b || E'\r\n' || 'Content-Disposition: form-data; name="' || k || '"'
                || E'\r\n\r\n' || (e #>> '{}') || E'\r\n';
    end loop;
  end loop;
  v_body := v_body || '--' || v_b || '--' || E'\r\n';
  v_resp := extensions.http((
    'POST', 'https://api45.unipile.com:17566' || p_path,
    array[extensions.http_header('X-API-KEY', coalesce(v_key, 'missing')),
          extensions.http_header('accept', 'application/json')],
    'multipart/form-data; boundary=' || v_b, v_body
  )::extensions.http_request);
  return jsonb_build_object('status', v_resp.status,
    'body', case when v_resp.content ~ '^\s*[\{\[]' then v_resp.content::jsonb else to_jsonb(left(v_resp.content, 2000)) end);
end $$;

create or replace function tg.tf(p_method text, p_path text, p_body jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_key text; v_resp extensions.http_response;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'telegram_finder_api_key' limit 1;
  v_resp := extensions.http((
    p_method, 'https://www.telegram-finder.io' || p_path,
    array[extensions.http_header('x-api-key', coalesce(v_key, 'missing'))],
    case when p_body is null then null else 'application/json' end, p_body::text
  )::extensions.http_request);
  return jsonb_build_object('status', v_resp.status,
    'body', case when v_resp.content ~ '^\s*[\{\[]' or v_resp.content in ('true', 'false') then v_resp.content::jsonb
                 else to_jsonb(left(v_resp.content, 2000)) end);
end $$;

-- Regras puras ---------------------------------------------------------------------------
create or replace function tg.norm(p text) returns text language sql immutable as $$
  select trim(regexp_replace(lower(translate(coalesce(p, ''),
    'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ',
    'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')), '[^a-z0-9]+', ' ', 'g'))
$$;

-- O Telegram achado é da pessoa? Primeiro nome tem que bater; o sobrenome bate, ou o
-- nome/bio do Telegram cita a empresa ("Lucas | CertiK"), ou o Telegram não tem sobrenome.
create or replace function tg.name_ok(c_first text, c_last text, c_company text, t_first text, t_last text, t_bio text)
returns boolean language plpgsql immutable as $$
declare
  toks text[] := string_to_array(tg.norm(coalesce(t_first, '') || ' ' || coalesce(t_last, '')), ' ');
  f text := split_part(tg.norm(c_first), ' ', 1);
  l text := split_part(tg.norm(c_last), ' ', 1);
  comp text := (select w from unnest(string_to_array(tg.norm(c_company), ' ')) w where length(w) >= 3 limit 1);
begin
  if f = '' or not (f = any(toks)) then return false; end if;
  if l = '' or l = any(toks) then return true; end if;
  if comp is not null and (comp = any(toks) or position(comp in tg.norm(t_bio)) > 0) then return true; end if;
  return tg.norm(t_last) = '';
end $$;

create or replace function tg.render(p_tpl text, p_first text) returns text language sql immutable as $$
  select replace(coalesce(p_tpl, ''), '{first_name}',
    case when split_part(trim(coalesce(p_first, '')), ' ', 1) ~ '^[[:alpha:]]'
         then split_part(trim(p_first), ' ', 1) else 'there' end)
$$;

-- Busca do Telegram ------------------------------------------------------------------------
create or replace function tg.save_found(p_contact_id bigint, u jsonb, p_src text, p_phone text)
returns text language plpgsql security definer set search_path = public as $$
declare c record; v_ok boolean;
begin
  select ct.*, co.name as company_name into c
  from contacts ct left join companies co on co.id = ct.company_id where ct.id = p_contact_id;
  v_ok := tg.name_ok(c.first_name, c.last_name, c.company_name, u->>'firstName', u->>'lastName', u->>'bio');
  update contacts set
    telegram_user_id = u->>'id',
    telegram_handle = case when u->>'username' is not null then '@' || (u->>'username') else telegram_handle end,
    tg_source = p_src,
    tg_lookup_status = case when v_ok then 'found' else 'mismatch' end,
    tg_lookup_at = now(),
    phone = coalesce(phone, p_phone),
    tg_profile = coalesce(tg_profile, '{}') || jsonb_strip_nulls(jsonb_build_object(
      'first', u->>'firstName', 'last', u->>'lastName', 'username', u->>'username', 'bio', u->>'bio')),
    tg_lookup_note = case when v_ok then null
                          else 'nome no Telegram não bate: ' || coalesce(u->>'fullname', u->>'firstName', '?') end
  where id = p_contact_id;
  return case when v_ok then 'achado' else 'nome não bate (revisar)' end;
end $$;

create or replace function tg.lookup_one(p_contact_id bigint)
returns text language plpgsql security definer set search_path = public as $$
declare
  c record; r jsonb; u jsonb; v_phone text; v_tf text; v_ident jsonb; v_src text; v_credits int;
begin
  select ct.*, co.name as company_name into c
  from contacts ct left join companies co on co.id = ct.company_id where ct.id = p_contact_id;
  if c.id is null then return 'contato não existe'; end if;

  -- 1) @ já conhecido (manual, nReach): id pelo username, grátis
  if c.telegram_handle is not null then
    r := tg.tf('POST', '/api/telegram/usernames',
               jsonb_build_object('usernames', jsonb_build_array(ltrim(c.telegram_handle, '@'))));
    if (r->'body'->'results'->0->>'status') = 'found' then
      return tg.save_found(p_contact_id, r->'body'->'results'->0->'user', coalesce(c.tg_source, 'manual'), c.phone);
    end if;
  end if;

  v_phone := c.phone;
  v_src := 'telegram_finder_phone';

  -- 2) reverso: email (depois LinkedIn) → telefone. 1 crédito só quando acha telefone.
  if v_phone is null and coalesce((select value from source_state where key = 'tg_reverse_enabled'), 'false') = 'true'
     and (c.email is not null or c.linkedin_url is not null) then
    v_tf := c.tg_profile->>'tf_contact_id';
    if v_tf is null then
      v_credits := (tg.tf('GET', '/api/account/usage')->'body'->>'remaining')::int;
      if coalesce(v_credits, 0) <= 0 then return 'sem créditos de busca reversa'; end if;
      r := tg.tf('POST', '/api/contacts', jsonb_build_object('contacts', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
             'firstname', coalesce(nullif(c.first_name, ''), 'Unknown'), 'lastname', c.last_name, 'company', c.company_name,
             'emails', case when c.email is not null then jsonb_build_array(c.email) end,
             'linkedins', case when c.linkedin_url is not null then jsonb_build_array(c.linkedin_url) end)))));
      v_tf := r->'body'->'contacts'->0->>'id';
      if v_tf is null then
        update contacts set tg_lookup_status = 'error', tg_lookup_at = now(),
               tg_lookup_note = left('Finder (criar contato): ' || r::text, 300) where id = p_contact_id;
        return 'erro no Finder';
      end if;
      update contacts set tg_profile = coalesce(tg_profile, '{}') || jsonb_build_object('tf_contact_id', v_tf)
      where id = p_contact_id;
      r := tg.tf('GET', '/api/contacts/' || v_tf);
      for v_ident in
        select e from jsonb_array_elements(coalesce(r->'body'->'identifiers', '[]')) e
        where e->>'type' in ('email', 'linkedin') order by (e->>'type') = 'linkedin'
      loop
        perform tg.tf('POST', '/api/enrich/phone', jsonb_build_object('id', v_ident->>'id'));
        r := tg.tf('GET', '/api/contacts/' || v_tf);
        v_src := case when v_ident->>'type' = 'email' then 'telegram_finder_email' else 'telegram_finder_linkedin' end;
        exit when exists (select 1 from jsonb_array_elements(coalesce(r->'body'->'identifiers', '[]')) e where e->>'type' = 'phone');
      end loop;
    else
      r := tg.tf('GET', '/api/contacts/' || v_tf);
      v_src := 'telegram_finder_email';
    end if;
    select e->>'value' into v_phone from jsonb_array_elements(coalesce(r->'body'->'identifiers', '[]')) e
    where e->>'type' = 'phone' limit 1;
    if v_phone is null then
      update contacts set tg_lookup_status = 'not_found', tg_lookup_at = now(),
             tg_lookup_note = 'Finder não achou telefone pelo email/LinkedIn' where id = p_contact_id;
      return 'sem telefone';
    end if;
    update contacts set phone = coalesce(phone, v_phone) where id = p_contact_id;
  end if;

  if v_phone is null then return 'nada para buscar ainda'; end if;  -- não marca: tenta de novo quando houver caminho

  -- 3) telefone → Telegram, grátis (100/hora)
  r := tg.tf('POST', '/api/telegram', jsonb_build_object('phoneNumbers', jsonb_build_array(v_phone)));
  select value into u from jsonb_each(case when jsonb_typeof(r->'body') = 'object' then r->'body' else '{}'::jsonb end)
  where jsonb_typeof(value) = 'object' and value ? 'id' limit 1;
  if u is null then
    update contacts set tg_lookup_status = 'not_found', tg_lookup_at = now(),
           tg_lookup_note = 'telefone sem Telegram visível' where id = p_contact_id;
    return 'telefone sem Telegram';
  end if;
  return tg.save_found(p_contact_id, u, v_src, v_phone);
end $$;

create or replace function tg.lookup_batch(p_limit int default 6)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_res text; v_out jsonb := '{}'; v_n int := 0;
  v_rev boolean := coalesce((select value from source_state where key = 'tg_reverse_enabled'), 'false') = 'true';
begin
  if coalesce((select value from source_state where key = 'tg_lookup_enabled'), 'true') <> 'true' then
    return '{"desligado": true}';
  end if;
  for r in
    select ct.id from contacts ct join companies co on co.id = ct.company_id
    where ct.persona_id = 'web3' and ct.telegram_user_id is null and ct.tg_lookup_status is null
      and coalesce(ct.stage, 'new') not in ('do_not_contact', 'replied')
      and coalesce(co.status, '') not in ('no_fit', 'no_domain') and co.account_state = 'active'
      and (ct.role_level in ('founder_ceo', 'cto_tech', 'security')
           or ct.position ~* '(founder|\mceo\M|\mcto\M|\mciso\M|chief|head of (security|engineering|technology|tech))')
      and coalesce(ct.position, '') !~* '(marketing|sales|business development|community|advisor|intern|recruit)'
      and (select count(*) from contacts x where x.company_id = ct.company_id and x.tg_lookup_status in ('found', 'mismatch')) < 3
      and (ct.telegram_handle is not null or ct.phone is not null
           or (v_rev and (ct.email is not null or ct.linkedin_url is not null)))
    order by co.amount_usd desc nulls last, co.raise_date desc nulls last, (ct.role_level = 'founder_ceo') desc nulls last, ct.id
    limit p_limit
  loop
    begin
      v_res := tg.lookup_one(r.id);
    exception when others then
      v_res := 'erro: ' || sqlerrm;
      update contacts set tg_lookup_status = 'error', tg_lookup_at = now(), tg_lookup_note = left(sqlerrm, 300) where id = r.id;
    end;
    v_out := v_out || jsonb_build_object(r.id::text, v_res);
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then insert into sync_log (source, rows_affected, ok) values ('tg_lookup', v_n, true); end if;
  return v_out;
end $$;

-- Quem está apto a receber, e quando -------------------------------------------------------
-- prio 1: follow-up (D+14) e reativações (D+30/90/180) de quem já recebeu e não respondeu
-- prio 2: primeiro toque de quem teve o Telegram achado (2 dias depois do 1º email, se houve)
-- prio 3: conversas antigas sem resposta (30 dias após a última msg sua; depois 60 e 90)
create or replace function tg.candidates(p_until timestamptz)
returns table (prio int, kind text, contact_id bigint, company_id bigint, chat_id text, user_id text,
               target_name text, first_name text, due_at timestamptz)
language sql stable security definer set search_path = public, unipile as $$
  with camp as (
    select reactivation_days from campaigns where channel = 'telegram' and persona_id = 'web3' order by id limit 1
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
    where c.persona_id = 'web3' and c.telegram_user_id is not null and c.tg_lookup_status = 'found'
      and coalesce(c.stage, 'new') not in ('do_not_contact', 'replied') and co.account_state = 'active'
      and not exists (select 1 from touches t where t.contact_id = c.id and t.channel = 'telegram'
                      and t.cancelled_at is null and t.status <> 'failed')
  ),
  old_chat as (
    select 3 as prio, 'reactivation' as kind, null::bigint as contact_id, null::bigint as company_id,
           ch.chat_id, ch.provider_id as user_id, ch.name as target_name, ch.name as first_name,
           case k.n when 0 then ch.last_ts + interval '30 days'
                    when 1 then k.last_at + interval '60 days'
                    when 2 then k.last_at + interval '90 days' end as due_at
    from unipile.tg_chats ch
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
$$;

-- Fila do dia ---------------------------------------------------------------------------------
create or replace function tg.plan_day()
returns int language plpgsql security definer set search_path = public, unipile as $$
declare
  v_tz constant text := 'Asia/Shanghai';
  v_day date := (now() at time zone v_tz)::date;
  v_day_start timestamptz := (v_day::timestamp) at time zone v_tz;
  v_start timestamptz := (v_day::timestamp + time '14:00') at time zone v_tz;
  v_end timestamptz := (v_day::timestamp + time '22:45') at time zone v_tz;
  v_base timestamptz; v_cap int; v_rows jsonb; v_n int; v_camp record; v_acc record; e jsonb; i int := 0;
begin
  select * into v_camp from campaigns where channel = 'telegram' and persona_id = 'web3' order by id limit 1;
  select * into v_acc from channel_accounts where channel = 'telegram' order by id limit 1;
  if v_camp.id is null or v_acc.id is null then return 0; end if;

  v_cap := least(coalesce(v_camp.daily_quota, 20), coalesce(v_acc.daily_limit, 20))
           - (select count(*) from touches t
              where t.channel = 'telegram' and t.direction = 'out' and t.cancelled_at is null
                and t.status in ('queued', 'sent', 'replied')
                and coalesce(t.sent_at, t.scheduled_for) >= v_day_start
                and coalesce(t.sent_at, t.scheduled_for) < v_day_start + interval '1 day');
  v_base := greatest(v_start, now() + interval '5 minutes');
  if v_cap <= 0 or v_base >= v_end then return 0; end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.prio, x.due_at), '[]') into v_rows
  from (
    select * from (
      select c.*, row_number() over (partition by coalesce(c.company_id::text, 'chat:' || c.chat_id)
                                     order by c.prio, c.due_at) as rn
      from tg.candidates(v_end) c
      where c.company_id is null or not exists (
        select 1 from touches t where t.company_id = c.company_id and t.channel = 'telegram' and t.cancelled_at is null
          and t.status in ('queued', 'sent', 'replied')
          and coalesce(t.sent_at, t.scheduled_for) >= v_day_start)
    ) y where y.rn = 1
    order by y.prio, y.due_at
    limit v_cap
  ) x;
  v_n := jsonb_array_length(v_rows);

  for e in select * from jsonb_array_elements(v_rows) loop
    insert into touches (contact_id, company_id, persona_id, campaign_id, channel, account_id, direction, kind, status,
                         body, scheduled_for, provider_user_id, provider_chat_id, target_name)
    values ((e->>'contact_id')::bigint, (e->>'company_id')::bigint, 'web3', v_camp.id, 'telegram', v_acc.id, 'out',
            e->>'kind', 'queued',
            tg.render(case when e->>'kind' = 'first' then v_camp.template else v_camp.followup_template end, e->>'first_name'),
            v_base + (v_end - v_base) * ((i + random() * 0.8) / v_n),
            e->>'user_id', e->>'chat_id', e->>'target_name');
    i := i + 1;
  end loop;
  insert into sync_log (source, rows_affected, ok) values ('tg_plan', v_n, true);
  return v_n;
end $$;

-- Envio ---------------------------------------------------------------------------------------
create or replace function tg.send_touch(p_id bigint, p_acc text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t record; v_res jsonb;
begin
  select * into t from touches where id = p_id for update;
  if t.id is null or t.status <> 'queued' or t.cancelled_at is not null then
    return jsonb_build_object('status', 409, 'body', 'fora da fila');
  end if;
  if t.provider_chat_id is not null then
    v_res := tg.unipile_post('/api/v1/chats/' || t.provider_chat_id || '/messages', jsonb_build_object('text', t.body));
  else
    v_res := tg.unipile_post('/api/v1/chats', jsonb_build_object(
      'account_id', p_acc, 'attendees_ids', jsonb_build_array(t.provider_user_id), 'text', t.body));
  end if;
  if (v_res->>'status')::int between 200 and 299 then
    update touches set status = 'sent', sent_at = now(), error = null,
      provider_message_id = coalesce(v_res->'body'->>'message_id', v_res->'body'->>'id'),
      provider_chat_id = coalesce(provider_chat_id, v_res->'body'->>'chat_id')
    where id = p_id;
    if t.contact_id is not null then
      update contacts set stage = 'contacted' where id = t.contact_id and coalesce(stage, 'new') = 'new';
    end if;
  else
    update touches set status = 'failed', error = left(v_res::text, 500) where id = p_id;
  end if;
  return v_res;
end $$;

create or replace function tg.send_due(p_max int default 2)
returns int language plpgsql security definer set search_path = public, unipile as $$
declare
  v_local time := (now() at time zone 'Asia/Shanghai')::time;
  r record; v_res jsonb; v_sent int := 0; v_acc text; v_last jsonb;
begin
  if coalesce((select value from source_state where key = 'tg_send_enabled'), 'false') <> 'true' then return 0; end if;
  if v_local < time '14:00' or v_local >= time '23:00' then return 0; end if;
  select provider_account_id into v_acc from channel_accounts where channel = 'telegram' and status = 'ok' order by id limit 1;
  if v_acc is null then return 0; end if;

  for r in
    select * from touches t
    where t.channel = 'telegram' and t.status = 'queued' and t.cancelled_at is null and t.scheduled_for <= now()
    order by t.scheduled_for limit p_max
  loop
    if r.company_id is not null and exists (select 1 from companies co where co.id = r.company_id and co.account_state <> 'active') then
      update touches set cancelled_at = now(), error = 'cancelado: conta não está mais ativa' where id = r.id;
      continue;
    end if;
    if r.provider_chat_id is not null then
      v_last := unipile.get('/api/v1/chats/' || r.provider_chat_id || '/messages?limit=1')->'body'->'items'->0;
      if v_last is not null and (v_last->>'is_sender') = '0' then
        update touches set cancelled_at = now(), error = 'cancelado: a pessoa escreveu por último' where id = r.id;
        continue;
      end if;
    end if;

    v_res := tg.send_touch(r.id, v_acc);
    if (v_res->>'status')::int between 200 and 299 then
      v_sent := v_sent + 1;
    elsif (v_res->>'status') = '429' or v_res::text ~* '(flood|too many|restricted|spam)' then
      update source_state set value = 'false', updated_at = now() where key = 'tg_send_enabled';
      update channel_accounts set status = 'restricted', status_note = 'Pausa automática: ' || left(v_res::text, 200), updated_at = now()
      where channel = 'telegram';
      insert into sync_log (source, rows_affected, ok, error) values ('tg_send', v_sent, false, 'pausa automática: ' || left(v_res::text, 500));
      return v_sent;
    end if;
  end loop;

  -- 3 falhas em 24h também desligam o envio
  if (select count(*) from touches where channel = 'telegram' and status = 'failed'
        and scheduled_for > now() - interval '24 hours') >= 3 then
    update source_state set value = 'false', updated_at = now() where key = 'tg_send_enabled';
    insert into sync_log (source, rows_affected, ok, error) values ('tg_send', v_sent, false, 'pausa automática: 3 falhas em 24h');
  elsif v_sent > 0 then
    insert into sync_log (source, rows_affected, ok) values ('tg_send', v_sent, true);
  end if;
  return v_sent;
end $$;

-- Respostas -----------------------------------------------------------------------------------
create or replace function tg.sync_replies()
returns int language plpgsql security definer set search_path = public, unipile as $$
declare
  v_acc record; r jsonb; c jsonb; cur text; v_map jsonb := '{}'; v_pages int := 0; v_min timestamptz;
  tr record; m jsonb; v_ts timestamptz; v_n int := 0; v_tid bigint;
begin
  select * into v_acc from channel_accounts where channel = 'telegram' order by id limit 1;
  select min(sent_at) into v_min from touches
  where channel = 'telegram' and direction = 'out' and status = 'sent' and provider_chat_id is not null;
  if v_min is null or v_acc.provider_account_id is null then return 0; end if;

  -- atividade recente de cada conversa (uma chamada por página de 100)
  loop
    r := unipile.get('/api/v1/chats?account_id=' || v_acc.provider_account_id || '&limit=100' || coalesce('&cursor=' || cur, ''));
    exit when (r->>'status') <> '200';
    for c in select * from jsonb_array_elements(coalesce(r->'body'->'items', '[]')) loop
      v_map := v_map || jsonb_build_object(c->>'id', c->>'timestamp');
    end loop;
    cur := r->'body'->>'cursor';
    v_pages := v_pages + 1;
    exit when cur is null or v_pages >= 5
      or coalesce((r->'body'->'items'->(-1)->>'timestamp')::timestamptz, now()) < v_min;
  end loop;

  for tr in
    select t.provider_chat_id as chat_id, min(t.sent_at) as first_at, max(t.sent_at) as last_at,
           (array_agg(t.contact_id order by t.sent_at desc))[1] as contact_id,
           (array_agg(t.company_id order by t.sent_at desc))[1] as company_id,
           (array_agg(t.id order by t.sent_at desc))[1] as touch_id,
           (array_agg(t.campaign_id order by t.sent_at desc))[1] as campaign_id,
           max(t.target_name) as target_name
    from touches t
    where t.channel = 'telegram' and t.direction = 'out' and t.status = 'sent' and t.provider_chat_id is not null
    group by t.provider_chat_id
  loop
    v_ts := (v_map->>tr.chat_id)::timestamptz;
    continue when v_ts is null or v_ts <= tr.last_at + interval '1 second';
    r := unipile.get('/api/v1/chats/' || tr.chat_id || '/messages?limit=10');
    m := null;
    select x into m from jsonb_array_elements(coalesce(r->'body'->'items', '[]')) x
    where (x->>'is_sender') = '0' and (x->>'timestamp')::timestamptz > tr.first_at
    order by (x->>'timestamp')::timestamptz limit 1;
    continue when m is null;

    insert into touches (contact_id, company_id, persona_id, campaign_id, channel, account_id, direction, kind, status,
                         body, sent_at, provider_message_id, provider_chat_id, target_name)
    values (tr.contact_id, tr.company_id, 'web3', tr.campaign_id, 'telegram', v_acc.id, 'in', 'reply', 'replied',
            left(m->>'text', 2000), (m->>'timestamp')::timestamptz, m->>'id', tr.chat_id, tr.target_name)
    returning id into v_tid;
    update touches set status = 'replied' where provider_chat_id = tr.chat_id and direction = 'out' and status = 'sent';
    insert into replies (contact_id, company_id, touch_id, channel, summary, received_at, handled)
    values (tr.contact_id, tr.company_id, tr.touch_id, 'telegram', left(m->>'text', 280), (m->>'timestamp')::timestamptz, false);
    if tr.company_id is not null then
      update companies set account_state = 'replied' where id = tr.company_id and account_state = 'active';
    end if;
    if tr.contact_id is not null then update contacts set stage = 'replied' where id = tr.contact_id; end if;
    update touches set cancelled_at = now(), error = 'cancelado: respondeu no Telegram'
    where status = 'queued' and cancelled_at is null
      and (provider_chat_id = tr.chat_id
           or (tr.company_id is not null and company_id = tr.company_id)
           or (tr.contact_id is not null and contact_id = tr.contact_id));
    update unipile.tg_chats set folder = 'respondeu', last_from_me = false, updated_at = now() where chat_id = tr.chat_id;
    v_n := v_n + 1;
  end loop;
  insert into sync_log (source, rows_affected, ok) values ('tg_replies', v_n, true);
  return v_n;
end $$;

-- Painel: "enviado" só conta o que saiu de fato (a fila não entra), e a fila aparece à parte ----
create or replace view public.v_campaign_funnel with (security_invoker = on) as
select cp.id, cp.name, cp.channel, cp.status, cp.daily_quota, cp.reactivation_days,
       count(distinct t.company_id) filter (where t.direction = 'out' and t.sent_at is not null) as accounts_reached,
       count(distinct t.contact_id) filter (where t.direction = 'out' and t.sent_at is not null) as people_reached,
       count(*) filter (where t.direction = 'out' and t.sent_at is not null) as sent,
       count(*) filter (where t.direction = 'out' and t.sent_at >= date_trunc('day', now() at time zone 'Asia/Shanghai') at time zone 'Asia/Shanghai') as sent_today,
       count(*) filter (where t.direction = 'out' and t.sent_at > now() - interval '7 days') as sent_7d,
       count(distinct coalesce(t.contact_id::text, t.provider_chat_id)) filter (where t.status = 'replied') as replied,
       count(*) filter (where t.status = 'bounced') as bounced,
       round(100.0 * count(*) filter (where t.status = 'bounced')
             / nullif(count(*) filter (where t.direction = 'out' and t.sent_at is not null), 0), 1) as bounce_pct,
       round(100.0 * count(*) filter (where t.status = 'bounced' and t.sent_at > now() - interval '7 days')
             / nullif(count(*) filter (where t.direction = 'out' and t.sent_at > now() - interval '7 days'), 0), 1) as bounce_pct_7d,
       max(t.sent_at) filter (where t.direction = 'out') as last_sent,
       count(*) filter (where t.status = 'queued' and t.cancelled_at is null) as queued
from public.campaigns cp
left join public.touches t on t.campaign_id = cp.id
group by cp.id;

create or replace view public.v_accounts with (security_invoker = on) as
select co.id, co.name, co.category as round, co.stage_tier, co.amount_usd, co.account_state, co.created_at,
       (select count(*) from public.contacts c where c.company_id = co.id) as contacts,
       coalesce(t.people_reached, 0) as people_reached, coalesce(t.emails, 0) as emails,
       coalesce(t.telegrams, 0) as telegrams, coalesce(t.replies, 0) as replies,
       coalesce(t.bounces, 0) as bounces, t.last_touch
from public.companies co
left join lateral (
  select count(distinct tt.contact_id) filter (where tt.direction = 'out' and tt.sent_at is not null) as people_reached,
         count(*) filter (where tt.channel = 'email' and tt.direction = 'out' and tt.sent_at is not null) as emails,
         count(*) filter (where tt.channel = 'telegram' and tt.direction = 'out' and tt.sent_at is not null) as telegrams,
         count(distinct coalesce(tt.contact_id::text, tt.provider_chat_id)) filter (where tt.status = 'replied') as replies,
         count(*) filter (where tt.status = 'bounced') as bounces,
         max(tt.sent_at) as last_touch
  from public.touches tt where tt.company_id = co.id
) t on true;

-- Agendador (UTC). Envio só das 14h às 23h de Xangai (06–14 UTC) e só com tg_send_enabled.
select cron.schedule('tg-lookup-hourly', '7 * * * *', 'select tg.lookup_batch(6)');
select cron.schedule('tg-plan-daily', '20 5 * * *', 'select tg.plan_day()');
select cron.schedule('tg-send', '*/10 6-14 * * *', 'select tg.send_due(2)');
select cron.schedule('tg-sync-replies', '*/30 * * * *', 'select tg.sync_replies()');

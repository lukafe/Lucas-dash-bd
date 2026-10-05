-- Telefones dos decisores pelo waterfall do Apollo, todo dia, para achar o Telegram pelo número.
-- Decisão do Lucas (05/10): até 5 decisores por dia (~8 créditos por telefone achado).
--
-- Fluxo:
--   1. pipeline diário (outbound/tg_phones.py) pega até 5 decisores sem telefone em public.tg_phone_candidates
--      e chama o bulk_match do Apollo com run_waterfall_phone e o webhook de public.apollo_phone_webhook_url();
--   2. o Apollo devolve os números na edge function apollo-phone-webhook, que chama public.apollo_phone_ingest;
--   3. tg.lookup_batch (de hora em hora) confere o número no Telegram Finder (grátis no Premium) e,
--      se achar, o contato entra na fila do Telegram 2 dias depois do 1º email.
--   A busca reversa do Finder (email/LinkedIn → telefone, gasta crédito) só roda depois que o Apollo
--   disse que não tem telefone.
-- O token do webhook fica no Vault ('apollo_phone_webhook_token'), criado à parte (nunca no repo):
--   select vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'apollo_phone_webhook_token');

create or replace function public.apollo_phone_ingest(p_token text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ok boolean;
  p jsonb;
  v_id text;
  v_phone text;
  v_saved int := 0;
  v_none int := 0;
begin
  select p_token is not null and p_token = s.decrypted_secret into v_ok
  from vault.decrypted_secrets s where s.name = 'apollo_phone_webhook_token';
  if not coalesce(v_ok, false) then
    raise exception 'token inválido' using errcode = '42501';
  end if;

  for p in select * from jsonb_array_elements(coalesce(p_payload->'people', '[]'::jsonb)) loop
    v_id := p->>'id';
    continue when v_id is null;
    -- números no formato do webhook (phone_numbers, waterfall.phone_numbers) ou por tipo (mobile_phone, ...)
    select n.num->>'sanitized_number' into v_phone
    from (
      select x as num, x->>'type_cd' as kind from jsonb_array_elements(coalesce(p->'phone_numbers', '[]'::jsonb)) x
      union all
      select x, x->>'type_cd' from jsonb_array_elements(coalesce(p->'waterfall'->'phone_numbers', '[]'::jsonb)) x
      union all
      select x, e.key from jsonb_each(p) e
        cross join lateral jsonb_array_elements(
          case when e.key in ('mobile_phone', 'direct_phone', 'other_phone', 'corporate_phone', 'home_phone')
                    and jsonb_typeof(e.value) = 'array' then e.value else '[]'::jsonb end) x
    ) n
    where coalesce(n.num->>'sanitized_number', '') <> ''
      and coalesce(n.num->>'status_cd', '') !~* 'invalid'
    order by case when n.kind ~* 'mobile' then 1 when n.kind ~* 'direct' then 2 when n.kind ~* 'other' then 3 else 4 end
    limit 1;

    if v_phone is not null then
      update contacts set phone = v_phone,
             tg_profile = coalesce(tg_profile, '{}'::jsonb) || jsonb_build_object('phone_source', 'apollo_waterfall', 'phone_at', now())
      where apollo_person_id = v_id and phone is null;
      if found then v_saved := v_saved + 1; end if;
    else
      update contacts set tg_profile = coalesce(tg_profile, '{}'::jsonb) || jsonb_build_object('phone_none_at', now())
      where apollo_person_id = v_id and phone is null;
      v_none := v_none + 1;
    end if;
  end loop;

  insert into sync_log (source, rows_affected, ok, detail)
  values ('apollo_phone_webhook', v_saved, true, format('%s telefone(s) salvos, %s sem telefone', v_saved, v_none));
  return jsonb_build_object('saved', v_saved, 'none', v_none);
end
$$;

comment on function public.apollo_phone_ingest(text, jsonb) is
  'Webhook do waterfall de telefone do Apollo (via edge function apollo-phone-webhook). Exige o token do Vault.';

-- Só o pipeline (chave service_role) lê candidatos e a URL do webhook.
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

create or replace function public.apollo_phone_webhook_url()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_token text;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'somente o pipeline' using errcode = '42501';
  end if;
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'apollo_phone_webhook_token';
  if v_token is null then return null; end if;
  return 'https://eiyjwmckmoyhfidabizu.supabase.co/functions/v1/apollo-phone-webhook?token=' || v_token;
end
$$;

-- Busca reversa do Finder só depois que o Apollo disse que não tem telefone.
create or replace function tg.lookup_batch(p_limit integer default 6)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r record; v_res text; v_out jsonb := '{}'; v_n int := 0;
  v_rev boolean := coalesce((select value from source_state where key = 'tg_reverse_enabled'), 'false') = 'true';
begin
  if coalesce((select value from source_state where key = 'tg_lookup_enabled'), 'true') <> 'true' then
    return '{"desligado": true}';
  end if;
  for r in
    select ct.id from contacts ct join companies co on co.id = ct.company_id
    where ct.persona_id = 'web3' and ct.telegram_user_id is null
      and (ct.tg_lookup_status is null or ct.tg_lookup_status = 'pending')
      and coalesce(ct.stage, 'new') not in ('do_not_contact', 'replied')
      and coalesce(co.status, '') not in ('no_fit', 'no_domain') and co.account_state = 'active'
      and tg.is_target(ct.position, ct.role_level)
      and (ct.tg_lookup_status = 'pending'
           or (select count(*) from contacts x where x.company_id = ct.company_id and x.tg_lookup_status in ('found', 'mismatch', 'pending')) < 3)
      and (ct.telegram_handle is not null or ct.phone is not null
           or (v_rev and (ct.email is not null or ct.linkedin_url is not null) and ct.tg_profile ? 'phone_none_at'))
    -- early-stage cripto primeiro (fundadores costumam estar no Telegram), raise mais recente antes
    order by (ct.tg_lookup_status = 'pending') desc nulls last,
             (co.stage_tier in ('early', 'ico_other')) desc nulls last,
             tg.target_rank(ct.position), co.raise_date desc nulls last, ct.id
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
end $function$;

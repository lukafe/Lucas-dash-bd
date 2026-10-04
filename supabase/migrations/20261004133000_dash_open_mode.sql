-- Monitor aberto, sem login (decisão do Lucas em 04/out/2026, "por enquanto").
-- A página lê tudo por esta função única, que devolve só o que ela mostra; as tabelas continuam
-- fechadas pelo RLS. Interruptor: source_state.dash_public. Com 'true', qualquer visitante lê;
-- com 'false', só o dono logado (is_dash_owner). Para voltar a exigir login:
--   update public.source_state set value = 'false' where key = 'dash_public';
--   e DASH_REQUIRE_LOGIN=true na Vercel.

insert into public.source_state (key, value) values ('dash_public', 'true')
on conflict (key) do update set value = excluded.value, updated_at = now();

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
    'replies', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.received_at desc nulls last)
      from (
        select r.id, r.channel, r.class, r.is_decision_maker, r.confidence, r.summary, r.link, r.received_at, r.handled,
               case when c.id is null then null
                    else jsonb_build_object('first_name', c.first_name, 'last_name', c.last_name, 'position', c.position) end as contacts,
               case when co.id is null then null else jsonb_build_object('name', co.name) end as companies
        from public.replies r
        left join public.contacts c on c.id = r.contact_id
        left join public.companies co on co.id = r.company_id
        order by r.received_at desc nulls last
        limit 20) x), '[]'::jsonb),
    'health', coalesce((select jsonb_agg(to_jsonb(h) order by h.last_at desc nulls last) from public.v_health h), '[]'::jsonb),
    'channels', coalesce((select jsonb_agg(to_jsonb(u) order by u.id) from public.v_account_usage u), '[]'::jsonb),
    'state', coalesce((
      select jsonb_agg(jsonb_build_object('key', s.key, 'value', s.value, 'updated_at', s.updated_at))
      from public.source_state s where s.key in ('push_paused', 'dash_public')), '[]'::jsonb),
    'daily', coalesce((select jsonb_agg(to_jsonb(d) order by d.day) from public.v_daily_touches d), '[]'::jsonb)
  );
end
$$;

comment on function public.dash_snapshot() is
  'Snapshot do monitor Aurora. Aberto a visitantes enquanto source_state.dash_public = true; senão só o dono.';

grant execute on function public.dash_snapshot() to anon, authenticated;

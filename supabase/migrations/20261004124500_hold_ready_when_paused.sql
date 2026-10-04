-- Enquanto source_state.push_paused = 'true', contatos que ficariam 'ready' entram como 'held':
-- o push do pipeline só lê 'ready', então ninguém novo é inscrito na sequência.
create or replace function public.hold_ready_when_paused() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'ready'
     and coalesce((select lower(value) from source_state where key = 'push_paused'), '') = 'true' then
    new.status := 'held';
  end if;
  return new;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_hold_ready_when_paused') then
    create trigger trg_hold_ready_when_paused before insert or update of status on public.contacts
      for each row execute function public.hold_ready_when_paused();
  end if;
end $$;

-- Calendário: migração do Apollo para o workspace da CertiK (out/2026).
-- A cadência de cada sequência deixa de ficar escrita aqui e passa a vir de public.apollo_sequences
-- (criada pela migration 012 do repo do outbound). Também deixa de prever follow-ups de uma
-- inscrição que foi substituída (contato migrado para a sequência de continuação) ou encerrada.
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.dash_calendar(date,date)'::regprocedure);
  if position('apollo_sequences' in d) > 0 then
    return;  -- já aplicado
  end if;

  -- 1) cadência da sequência que recebe inscrições
  d := replace(d,
    E'''offsets'', case (select value from source_state where key = ''apollo_seq_id'')\n'
    || E'                     when ''6aa310116ac35f00149db433'' then ''[0, 5]''::jsonb\n'
    || E'                     when ''6ac25620a246a700147a45bf'' then ''[0, 3, 7, 30, 90, 180]''::jsonb\n'
    || E'                     else ''[0]''::jsonb end,',
    E'''offsets'', coalesce((select to_jsonb(sq.offsets) from apollo_sequences sq\n'
    || E'                               where sq.id = (select value from source_state where key = ''apollo_seq_id'')),\n'
    || E'                              ''[0]''::jsonb),');

  -- 2) cadência de cada inscrição + até quando ela vale
  d := replace(d,
    E'          select o.contact_id, o.replied_at, o.bounced,\n',
    E'          select o.contact_id, o.replied_at, o.bounced,\n'
    || E'                 least(o.finished_at,\n'
    || E'                       (select min(o2.added_at) from outreach o2\n'
    || E'                         where o2.contact_id = o.contact_id and o2.id > o.id)) as ends_at,\n');
  d := replace(d,
    E'            select case o.sequence_id\n'
    || E'                     when ''6aa310116ac35f00149db433'' then array[0, 5]\n'
    || E'                     when ''6ac25620a246a700147a45bf'' then array[0, 3, 7, 30, 90, 180]\n'
    || E'                     when ''6ac38945e24c1900103286a5'' then array[0, 3, 7, 30, 90, 180]\n'
    || E'                     else array[0]::int[] end as offs\n',
    E'            select coalesce((select sq.offsets from apollo_sequences sq where sq.id = o.sequence_id),\n'
    || E'                            array[0]::int[]) as offs\n');
  d := replace(d,
    E'        where not coalesce(s.bounced, false)\n',
    E'        where not coalesce(s.bounced, false)\n'
    || E'          and (s.ends_at is null or s.due <= s.ends_at)\n');

  if position('6ac25620a246a700147a45bf' in d) > 0 or position('ends_at' in d) = 0
     or position('apollo_sequences sq where sq.id = o.sequence_id' in d) = 0 then
    raise exception 'dash_calendar mudou; ajuste manual necessário';
  end if;
  execute d;
end $mig$;

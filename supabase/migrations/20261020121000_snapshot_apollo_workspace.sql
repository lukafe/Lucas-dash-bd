-- Monitor: o card do Apollo passa a mostrar o workspace (time), a caixa de envio e a sequência
-- que recebe inscrições (current_sequence_id). Esses campos vêm do outbound/monitor_refresh.py.
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.dash_snapshot()'::regprocedure);
  if position('current_sequence_id' in d) > 0 then
    return;  -- já aplicado
  end if;
  d := replace(d,
    E'''alerts'', coalesce(i.data->''alerts'', ''[]''::jsonb),\n',
    E'''alerts'', coalesce(i.data->''alerts'', ''[]''::jsonb),\n'
    || E'                 ''workspace'', i.data->''workspace'',\n'
    || E'                 ''mailbox_email'', i.data->''mailbox''->>''email'',\n'
    || E'                 ''current_sequence_id'', i.data->>''current_sequence_id'',\n'
    || E'                 ''current_sequence_name'', i.data->>''current_sequence_name'',\n'
    || E'                 ''continuation_sequence_id'', i.data->>''continuation_sequence_id'',\n');
  if position('current_sequence_id' in d) = 0 then
    raise exception 'dash_snapshot mudou; ajuste manual necessário';
  end if;
  execute d;
end $mig$;

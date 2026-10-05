-- Monitor: com o Telegram Finder desligado (source_state.tg_lookup_enabled = 'false'), o mon.refresh
-- não consulta mais a API dele (o plano foi encerrado e ela responde 402) e mostra a integração como
-- "Desligado", em vez de acusar erro toda hora. Religando a chave, a checagem volta sozinha.
do $mig$
declare d text;
begin
  d := pg_get_functiondef('mon.refresh()'::regprocedure);
  if position('tg_lookup_enabled' in d) > 0 then
    return;  -- já aplicado
  end if;
  d := replace(d,
    E'  -- Telegram Finder: créditos e limite por hora\n  begin\n',
    E'  -- Telegram Finder: créditos e limite por hora (pulado quando o Finder está desligado)\n'
    || E'  if coalesce((select value from source_state where key = ''tg_lookup_enabled''), ''true'') <> ''true'' then\n'
    || E'    update integrations set status = ''desligado'', note = ''Desligado (decisão do Lucas em 05/10)'', checked_at = now()\n'
    || E'     where id = ''telegram_finder'';\n'
    || E'  else\n  begin\n');
  d := replace(d,
    E'     where id = ''telegram_finder'';\n  end;\n\n  -- Vigia do GitHub',
    E'     where id = ''telegram_finder'';\n  end;\n  end if;\n\n  -- Vigia do GitHub');
  if position('end if;' || E'\n\n  -- Vigia do GitHub' in d) = 0 then
    raise exception 'mon.refresh mudou; ajuste manual necessário';
  end if;
  execute d;
end
$mig$;

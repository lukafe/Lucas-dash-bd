-- Calendário: a sequência "Raises 1–4 meses" (6ac38945e24c1900103286a5) tem a mesma cadência da v2,
-- e a fila de enriquecimento põe os raises dos últimos 30 dias na frente (igual ao pipeline).
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.dash_calendar(date,date)'::regprocedure);
  if position('6ac38945e24c1900103286a5' in d) > 0 then
    return;  -- já aplicado
  end if;
  d := replace(d,
    E'when ''6ac25620a246a700147a45bf'' then array[0, 3, 7, 30, 90, 180]',
    E'when ''6ac25620a246a700147a45bf'' then array[0, 3, 7, 30, 90, 180]\n'
    || E'                     when ''6ac38945e24c1900103286a5'' then array[0, 3, 7, 30, 90, 180]');
  d := replace(d,
    'row_number() over (order by co.amount_usd desc nulls last, co.raise_date desc nulls last, co.id) as rn',
    'row_number() over (order by (co.raise_date is null or co.raise_date < current_date - 30),'
    || ' co.amount_usd desc nulls last, co.raise_date desc nulls last, co.id) as rn');
  if position('6ac38945e24c1900103286a5' in d) = 0 or position('current_date - 30' in d) = 0 then
    raise exception 'dash_calendar mudou; ajuste manual necessário';
  end if;
  execute d;
end
$mig$;

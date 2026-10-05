-- Saúde do sistema: a coleta do ICO Drops roda no máximo a cada 6 h (dentro do scrape.yml, a cada 2 h).
-- Já aplicado no banco em 05/10; registrado aqui para o histórico de migrations.
insert into public.mon_cadence (component, label, freq_label, every, grace, sort, active)
values ('pipeline:fetch_icos', 'Leitura do ICO Drops (vendas de token)', 'a cada 6h', interval '6 hours', interval '4 hours', 45, true)
on conflict (component) do nothing;

-- Classificação das conexões do LinkedIn (pelo headline) para os eventos de reachout:
-- parceiros de referral e empresas reguladas. Uma linha por conexão (member_id).
-- Preenchida em 05/10 por classificação do Claude a partir do headline (classified_by = 'claude_headline').
create table if not exists public.li_classification (
  member_id text primary key,
  li_connection_id bigint references public.li_connections(id),
  org_name text,
  org_type text check (org_type in (
    'law_firm','consultancy','software_house','accelerator_vc','association','audit_accounting','marketing_agency',
    'bank','exchange_vasp','payments_fintech','custody','broker_asset_manager','tokenization_stablecoin','market_infra',
    'web3_project','regulator_gov','other')),
  event text check (event in ('referral_partner','regulated','web3_project','regulator','none')),
  seniority text check (seniority in ('c_level_founder','head_director','manager','individual','student_other')),
  region text check (region in ('brasil','latam','north_america','europe','uk','middle_east','asia','africa','oceania','a_confirmar')),
  persona_id text references public.personas(id),
  confidence text check (confidence in ('alta','media','baixa')),
  reason text,
  classified_by text not null default 'claude_headline',
  classified_at timestamptz not null default now()
);
comment on table public.li_classification is
  'Classificação das conexões do LinkedIn (pelo headline) para os eventos de reachout: parceiros de referral e empresas reguladas.';
alter table public.li_classification enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'li_classification' and policyname = 'dash_owner_read') then
    create policy dash_owner_read on public.li_classification for select using (public.is_dash_owner());
  end if;
end $$;

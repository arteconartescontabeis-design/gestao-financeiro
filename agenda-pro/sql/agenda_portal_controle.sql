-- ============================================================
-- AGENDA PRO NO PORTAL ARTECON — CONTROLE DE ACESSO
-- Projeto Supabase do Agenda: vuwgxndahrzinfdlapxz
-- Aplicado em 10/10/2026.
--
-- 1. Organização do portal (núcleo, projeto fbxelwhdiisfmnwrerbl) → escritório
--    do Agenda. A função portal-provisionar usa este mapa.
-- 2. Pessoa DESATIVADA no Agenda deixa de ver os dados: as funções que a RLS
--    usa passam a considerar só cadastros ativos (antes a desativação só
--    escondia a pessoa das telas). O login continua existindo, porque é o
--    mesmo do Financeiro Pro (projeto compartilhado).
-- ============================================================

create table if not exists public.agenda_portal_orgs (
  org_id     uuid primary key,                       -- core.organizations.id no núcleo do portal
  tenant_id  bigint not null references public.agenda_tenants(id),
  criado_em  timestamptz not null default now()
);
alter table public.agenda_portal_orgs enable row level security;   -- sem políticas: só a chave de serviço lê

insert into public.agenda_portal_orgs (org_id, tenant_id)
values ('a47ec000-0000-4000-8000-000000000001', 2)                 -- Artecon
on conflict (org_id) do nothing;

create or replace function public.agenda_meu_tenant_id()
returns bigint language sql stable security definer as $$
  select tenant_id from agenda_usuarios where auth_id = auth.uid() and ativo limit 1;
$$;

create or replace function public.agenda_meu_perfil()
returns text language sql stable security definer as $$
  select perfil from agenda_usuarios where auth_id = auth.uid() and ativo limit 1;
$$;

create or replace function public.agenda_meu_usuario_id()
returns bigint language sql stable security definer as $$
  select id from agenda_usuarios where auth_id = auth.uid() and ativo limit 1;
$$;

-- a política dos compromissos repetia a consulta por conta própria; passa a usar a mesma função
alter policy compromissos_tenant on public.agenda_compromissos
  using (tenant_id = public.agenda_meu_tenant_id());

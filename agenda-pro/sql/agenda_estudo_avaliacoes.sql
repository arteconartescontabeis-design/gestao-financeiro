-- ============================================================
-- AGENDA PRO — notas das avaliações dos módulos do Estudo da Reforma Tributária (v2.9.0, Estudo 1.5.0)
-- Projeto Supabase do Agenda: vuwgxndahrzinfdlapxz
-- Cada entrega de avaliação vira uma linha (histórico de tentativas; vale a melhor nota no app).
-- A pessoa grava e lê as suas; admin e gerente do escritório leem as da equipe.
-- Vale para a equipe do Agenda e para as pessoas só do Estudo (agenda_estudo_tenant_id(), sql/agenda_estudo_usuarios.sql).
-- A referência de aprovação (70%) é só do app: não bloqueia nada. Só acréscimos.
-- ============================================================
create table if not exists public.agenda_estudo_avaliacoes (
  id         bigint generated always as identity primary key,
  tenant_id  bigint not null default public.agenda_estudo_tenant_id(),
  auth_id    uuid   not null default auth.uid(),
  modulo     text   not null,                 -- m1 … m9
  acertos    int    not null,
  total      int    not null,
  nota       numeric(5,2) not null,           -- 0 a 100
  respostas  jsonb,                           -- [{q, escolhida, correta, ok}]
  criado_em  timestamptz not null default now(),
  constraint estudo_aval_conta check (total > 0 and acertos between 0 and total and nota = round(100.0 * acertos / total, 2))
);
create index if not exists estudo_aval_tenant_idx on public.agenda_estudo_avaliacoes (tenant_id, modulo);
create index if not exists estudo_aval_auth_idx on public.agenda_estudo_avaliacoes (auth_id, criado_em desc);

alter table public.agenda_estudo_avaliacoes enable row level security;
grant select, insert on public.agenda_estudo_avaliacoes to authenticated;

-- leitura: a própria pessoa, ou admin/gerente do escritório
create policy estudo_aval_select on public.agenda_estudo_avaliacoes for select
  using (auth_id = auth.uid()
         or (tenant_id = public.agenda_meu_tenant_id() and public.agenda_meu_perfil() in ('admin', 'gerente')));
-- gravação: só a própria tentativa, no próprio escritório (sem alterar nem apagar depois: é o histórico)
create policy estudo_aval_insert on public.agenda_estudo_avaliacoes for insert
  with check (auth_id = auth.uid() and tenant_id = public.agenda_estudo_tenant_id());

-- ------------------------------------------------------------
-- PARA REMOVER (só com confirmação do usuário), junto com o Estudo:
-- drop table if exists public.agenda_estudo_avaliacoes;
-- ------------------------------------------------------------

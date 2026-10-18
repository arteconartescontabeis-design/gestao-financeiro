-- ============================================================
-- AGENDA PRO — Estudo da Reforma Tributária (estudo.html)
-- Projeto Supabase do Agenda: vuwgxndahrzinfdlapxz
-- Tabelas separadas do resto do Agenda, para poderem ser apagadas depois
-- (o comando de remoção está no fim do arquivo, comentado).
--   agenda_estudo_progresso: faixa de áudio, vídeo ou tarefa concluída e onde parou no áudio
--   agenda_estudo_notas:     anotações da pessoa ("onde parei", "o que falta")
--   agenda_estudo_perfil:    trilha escolhida e última faixa aberta
-- Visitante sem login (anon) não passa nas regras (agenda_meu_tenant_id() fica nulo).
-- Cada pessoa vê e grava só o que é seu; admin e gerente veem o progresso e a trilha
-- da equipe do escritório (as anotações continuam pessoais).
-- ============================================================
create table if not exists public.agenda_estudo_progresso (
  id            bigint generated always as identity primary key,
  tenant_id     bigint not null default public.agenda_meu_tenant_id(),
  auth_id       uuid   not null default auth.uid(),
  item          text   not null,               -- 'faixa:m1a', 'video:fg:11162044', 'tarefa:av-normas'
  concluido     boolean not null default false,
  posicao_seg   numeric not null default 0,     -- onde parou no áudio
  atualizado_em timestamptz not null default now(),
  unique (auth_id, item)
);

create table if not exists public.agenda_estudo_notas (
  id            bigint generated always as identity primary key,
  tenant_id     bigint not null default public.agenda_meu_tenant_id(),
  auth_id       uuid   not null default auth.uid(),
  trilha        text,                           -- 'exec', 'int', 'av', 'fiscal', 'contabil', 'pessoal'
  item          text,                           -- faixa ou vídeo da anotação (opcional)
  texto         text   not null check (length(texto) <= 4000),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists agenda_estudo_notas_auth_idx on public.agenda_estudo_notas (auth_id, criado_em desc);

create table if not exists public.agenda_estudo_perfil (
  auth_id       uuid   primary key default auth.uid(),
  tenant_id     bigint not null default public.agenda_meu_tenant_id(),
  trilha        text,
  ultimo_item   text,
  atualizado_em timestamptz not null default now()
);

create or replace function public.agenda_estudo_tocar()
returns trigger language plpgsql set search_path = public as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

create or replace trigger trg_estudo_progresso_tocar before update on public.agenda_estudo_progresso
  for each row execute function public.agenda_estudo_tocar();
create or replace trigger trg_estudo_notas_tocar before update on public.agenda_estudo_notas
  for each row execute function public.agenda_estudo_tocar();
create or replace trigger trg_estudo_perfil_tocar before update on public.agenda_estudo_perfil
  for each row execute function public.agenda_estudo_tocar();

alter table public.agenda_estudo_progresso enable row level security;
alter table public.agenda_estudo_notas     enable row level security;
alter table public.agenda_estudo_perfil    enable row level security;

grant select, insert, update, delete on public.agenda_estudo_progresso, public.agenda_estudo_notas, public.agenda_estudo_perfil to authenticated;

-- Progresso: a pessoa grava o seu; admin e gerente leem o da equipe
create policy estudo_progresso_select on public.agenda_estudo_progresso for select
  using (tenant_id = public.agenda_meu_tenant_id()
         and (auth_id = auth.uid() or public.agenda_meu_perfil() in ('admin', 'gerente')));
create policy estudo_progresso_insert on public.agenda_estudo_progresso for insert
  with check (tenant_id = public.agenda_meu_tenant_id() and auth_id = auth.uid());
create policy estudo_progresso_update on public.agenda_estudo_progresso for update
  using (auth_id = auth.uid())
  with check (tenant_id = public.agenda_meu_tenant_id() and auth_id = auth.uid());
create policy estudo_progresso_delete on public.agenda_estudo_progresso for delete
  using (auth_id = auth.uid());

-- Anotações: só a própria pessoa
create policy estudo_notas_select on public.agenda_estudo_notas for select
  using (auth_id = auth.uid());
create policy estudo_notas_insert on public.agenda_estudo_notas for insert
  with check (tenant_id = public.agenda_meu_tenant_id() and auth_id = auth.uid());
create policy estudo_notas_update on public.agenda_estudo_notas for update
  using (auth_id = auth.uid())
  with check (tenant_id = public.agenda_meu_tenant_id() and auth_id = auth.uid());
create policy estudo_notas_delete on public.agenda_estudo_notas for delete
  using (auth_id = auth.uid());

-- Perfil (trilha escolhida): a pessoa grava o seu; admin e gerente leem o da equipe
create policy estudo_perfil_select on public.agenda_estudo_perfil for select
  using (tenant_id = public.agenda_meu_tenant_id()
         and (auth_id = auth.uid() or public.agenda_meu_perfil() in ('admin', 'gerente')));
create policy estudo_perfil_insert on public.agenda_estudo_perfil for insert
  with check (tenant_id = public.agenda_meu_tenant_id() and auth_id = auth.uid());
create policy estudo_perfil_update on public.agenda_estudo_perfil for update
  using (auth_id = auth.uid())
  with check (tenant_id = public.agenda_meu_tenant_id() and auth_id = auth.uid());

-- ------------------------------------------------------------
-- PARA REMOVER O ESTUDO (só com confirmação do usuário):
-- drop table if exists public.agenda_estudo_progresso, public.agenda_estudo_notas, public.agenda_estudo_perfil;
-- drop function if exists public.agenda_estudo_tocar();
-- ------------------------------------------------------------

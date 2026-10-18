-- ============================================================
-- AGENDA PRO — pessoas cadastradas SÓ para o Estudo da Reforma Tributária (v2.5.0)
-- Projeto Supabase do Agenda: vuwgxndahrzinfdlapxz
-- Quem está aqui entra no estudo.html com o mesmo login (Supabase Auth), mas NÃO está em
-- agenda_usuarios: agenda_meu_tenant_id() fica nulo e a pessoa não vê nada da agenda.
-- O cadastro é feito pela Edge Function estudo-usuario (cria o login com senha provisória);
-- admin e gerente do escritório leem a lista e ativam/desativam pelo próprio Estudo.
-- Só acréscimos: as regras abaixo SOMAM às de sql/agenda_estudo.sql.
-- ============================================================
create table if not exists public.agenda_estudo_usuarios (
  id            bigint generated always as identity primary key,
  tenant_id     bigint not null,
  auth_id       uuid   not null unique,
  nome          text   not null,
  email         text   not null,
  whatsapp      text,
  ativo         boolean not null default true,
  criado_por    uuid,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create or replace trigger trg_estudo_usuarios_tocar before update on public.agenda_estudo_usuarios
  for each row execute function public.agenda_estudo_tocar();

alter table public.agenda_estudo_usuarios enable row level security;
grant select, update on public.agenda_estudo_usuarios to authenticated;

-- leitura: a própria pessoa, ou admin/gerente do escritório
create policy estudo_usuarios_select on public.agenda_estudo_usuarios for select
  using (auth_id = auth.uid()
         or (tenant_id = public.agenda_meu_tenant_id() and public.agenda_meu_perfil() in ('admin', 'gerente')));
-- alteração (ativar/desativar, nome, WhatsApp): admin/gerente do escritório
create policy estudo_usuarios_update on public.agenda_estudo_usuarios for update
  using (tenant_id = public.agenda_meu_tenant_id() and public.agenda_meu_perfil() in ('admin', 'gerente'))
  with check (tenant_id = public.agenda_meu_tenant_id());
-- cadastro: só pela função estudo-usuario (chave de serviço), por isso não há regra de insert

-- escritório de quem usa o Estudo: equipe do Agenda ou pessoa só do Estudo (ativas)
create or replace function public.agenda_estudo_tenant_id()
returns bigint language sql stable security definer set search_path = public as $$
  select coalesce(
    (select tenant_id from agenda_usuarios where auth_id = auth.uid() and ativo limit 1),
    (select tenant_id from agenda_estudo_usuarios where auth_id = auth.uid() and ativo limit 1))
$$;

-- regras extras para quem é só do Estudo (o app envia tenant_id nas gravações)
create policy estudo_progresso_select_so on public.agenda_estudo_progresso for select
  using (auth_id = auth.uid() and tenant_id = public.agenda_estudo_tenant_id());
create policy estudo_progresso_insert_so on public.agenda_estudo_progresso for insert
  with check (auth_id = auth.uid() and tenant_id = public.agenda_estudo_tenant_id());
create policy estudo_progresso_update_so on public.agenda_estudo_progresso for update
  using (auth_id = auth.uid())
  with check (auth_id = auth.uid() and tenant_id = public.agenda_estudo_tenant_id());

create policy estudo_notas_insert_so on public.agenda_estudo_notas for insert
  with check (auth_id = auth.uid() and tenant_id = public.agenda_estudo_tenant_id());
create policy estudo_notas_update_so on public.agenda_estudo_notas for update
  using (auth_id = auth.uid())
  with check (auth_id = auth.uid() and tenant_id = public.agenda_estudo_tenant_id());

create policy estudo_perfil_select_so on public.agenda_estudo_perfil for select
  using (auth_id = auth.uid());
create policy estudo_perfil_insert_so on public.agenda_estudo_perfil for insert
  with check (auth_id = auth.uid() and tenant_id = public.agenda_estudo_tenant_id());
create policy estudo_perfil_update_so on public.agenda_estudo_perfil for update
  using (auth_id = auth.uid())
  with check (auth_id = auth.uid() and tenant_id = public.agenda_estudo_tenant_id());

-- ------------------------------------------------------------
-- PARA REMOVER (só com confirmação do usuário), junto com sql/agenda_estudo.sql:
-- drop table if exists public.agenda_estudo_usuarios;
-- drop function if exists public.agenda_estudo_tenant_id();
-- (as regras *_so somem junto com as tabelas agenda_estudo_*; apagar também a função estudo-usuario)
-- ------------------------------------------------------------

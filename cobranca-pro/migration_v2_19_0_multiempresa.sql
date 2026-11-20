-- ============================================================
-- Cobrança Pro v2.19.0 — Multiempresa (etapa 1: banco)
-- Rodar no SQL Editor do Supabase (projeto yeujqjtjqtegsnzwwazb).
-- Pode rodar mais de uma vez (idempotente). Não apaga nem altera dados existentes.
--
-- O que faz:
-- 1) Cria cob_empresas — as empresas de cobrança do grupo (cadastro aberto: 4 ou mais)
-- 2) Semeia a empresa padrão a partir do tenant atual (Artecon) e marca como padrão
-- 3) Adiciona empresa_id (opcional) nas tabelas operacionais + questor_id em cob_parcelas
-- 4) Preenche todo o histórico com a empresa padrão
-- 5) Gatilho: insert sem empresa_id recebe a empresa padrão (o app atual segue igual)
-- 6) Trava: só diretor ou robô troca a empresa de uma parcela
-- 7) Índices por (tenant_id, empresa_id)
--
-- O que NÃO faz (de propósito): o índice único do nosso número continua
-- (tenant_id, nosso_numero). O app de hoje faz upsert com
-- onConflict 'tenant_id,nosso_numero' (importações e boleto manual);
-- a troca para (tenant_id, empresa_id, nosso_numero) sai na v2.21.0,
-- junto com a mudança do app — nunca antes.
-- ============================================================

-- ── 1) Tabela de empresas ───────────────────────────────────
create table if not exists public.cob_empresas (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.cob_tenants(id),
  nome          text not null,
  cnpj          text,
  apelido       text,                               -- rótulo curto no seletor
  assinatura    text,                               -- como assina e-mail/WhatsApp
  cor           text,                               -- etiqueta nos relatórios (ex.: #2e86ab)
  questor_cnpj  text,                               -- inscrição federal do estabelecimento na API do Questor Negócio
  padrao        boolean not null default false,     -- recebe lançamentos sem empresa definida
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.cob_empresas is
  'v2.19.0: empresas de cobrança do grupo. Clientes, templates e envio continuam do tenant (compartilhados); parcelas, pagamentos, conciliações e confrontos pertencem a uma empresa.';

-- só uma empresa padrão por tenant; um estabelecimento do Questor não pode ter duas donas
create unique index if not exists cob_empresas_padrao_uk
  on public.cob_empresas (tenant_id) where padrao;
create unique index if not exists cob_empresas_questor_uk
  on public.cob_empresas (tenant_id, questor_cnpj) where questor_cnpj is not null;

alter table public.cob_empresas enable row level security;
drop policy if exists cob_empresas_sel on public.cob_empresas;
create policy cob_empresas_sel on public.cob_empresas for select using (public.cob_pode(tenant_id));
drop policy if exists cob_empresas_ins on public.cob_empresas;
create policy cob_empresas_ins on public.cob_empresas for insert with check (public.cob_eh_diretor(tenant_id));
drop policy if exists cob_empresas_upd on public.cob_empresas;
create policy cob_empresas_upd on public.cob_empresas for update using (public.cob_eh_diretor(tenant_id)) with check (public.cob_eh_diretor(tenant_id));
drop policy if exists cob_empresas_del on public.cob_empresas;
create policy cob_empresas_del on public.cob_empresas for delete using (public.cob_eh_diretor(tenant_id));

-- ── 2) Empresa padrão a partir do tenant atual ──────────────
insert into public.cob_empresas (tenant_id, nome, cnpj, apelido, padrao)
select t.id, t.nome, t.cnpj, t.nome, true
  from public.cob_tenants t
 where not exists (select 1 from public.cob_empresas e where e.tenant_id = t.id);

-- ── 3) Coluna empresa_id nas tabelas operacionais ───────────
alter table public.cob_parcelas      add column if not exists empresa_id uuid references public.cob_empresas(id);
alter table public.cob_pagamentos    add column if not exists empresa_id uuid references public.cob_empresas(id);
alter table public.cob_conciliacoes  add column if not exists empresa_id uuid references public.cob_empresas(id);
alter table public.cob_confrontos    add column if not exists empresa_id uuid references public.cob_empresas(id);
alter table public.cob_fila_envios   add column if not exists empresa_id uuid references public.cob_empresas(id);
alter table public.cob_whatsapp_fila add column if not exists empresa_id uuid references public.cob_empresas(id);
alter table public.cob_eventos       add column if not exists empresa_id uuid references public.cob_empresas(id);

-- id do título na API do Questor Negócio (chave do upsert da sincronização, v2.22+)
alter table public.cob_parcelas add column if not exists questor_id text;
comment on column public.cob_parcelas.questor_id is
  'v2.19.0: Id do título na API do Questor Negócio — chave do upsert da sincronização (v2.22+).';

-- ── 4) Histórico aponta para a empresa padrão ───────────────
update public.cob_parcelas      x set empresa_id = e.id from public.cob_empresas e where e.tenant_id = x.tenant_id and e.padrao and x.empresa_id is null;
update public.cob_pagamentos    x set empresa_id = e.id from public.cob_empresas e where e.tenant_id = x.tenant_id and e.padrao and x.empresa_id is null;
update public.cob_conciliacoes  x set empresa_id = e.id from public.cob_empresas e where e.tenant_id = x.tenant_id and e.padrao and x.empresa_id is null;
update public.cob_confrontos    x set empresa_id = e.id from public.cob_empresas e where e.tenant_id = x.tenant_id and e.padrao and x.empresa_id is null;
update public.cob_fila_envios   x set empresa_id = e.id from public.cob_empresas e where e.tenant_id = x.tenant_id and e.padrao and x.empresa_id is null;
update public.cob_whatsapp_fila x set empresa_id = e.id from public.cob_empresas e where e.tenant_id = x.tenant_id and e.padrao and x.empresa_id is null;
update public.cob_eventos       x set empresa_id = e.id from public.cob_empresas e where e.tenant_id = x.tenant_id and e.padrao and x.empresa_id is null;

-- ── 5) Insert sem empresa recebe a padrão ───────────────────
-- Mantém o app atual funcionando sem nenhuma mudança de código: tudo que ele
-- inserir continua caindo na Artecon até o seletor existir (v2.20.0).
create or replace function public.cob__empresa_padrao()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  if new.empresa_id is null then
    select id into new.empresa_id
      from public.cob_empresas
     where tenant_id = new.tenant_id and padrao and ativo
     limit 1;
  end if;
  return new;
end $$;

drop trigger if exists cob__empresa_padrao on public.cob_parcelas;
create trigger cob__empresa_padrao before insert on public.cob_parcelas      for each row execute function public.cob__empresa_padrao();
drop trigger if exists cob__empresa_padrao on public.cob_pagamentos;
create trigger cob__empresa_padrao before insert on public.cob_pagamentos    for each row execute function public.cob__empresa_padrao();
drop trigger if exists cob__empresa_padrao on public.cob_conciliacoes;
create trigger cob__empresa_padrao before insert on public.cob_conciliacoes  for each row execute function public.cob__empresa_padrao();
drop trigger if exists cob__empresa_padrao on public.cob_confrontos;
create trigger cob__empresa_padrao before insert on public.cob_confrontos    for each row execute function public.cob__empresa_padrao();
drop trigger if exists cob__empresa_padrao on public.cob_fila_envios;
create trigger cob__empresa_padrao before insert on public.cob_fila_envios   for each row execute function public.cob__empresa_padrao();
drop trigger if exists cob__empresa_padrao on public.cob_whatsapp_fila;
create trigger cob__empresa_padrao before insert on public.cob_whatsapp_fila for each row execute function public.cob__empresa_padrao();
drop trigger if exists cob__empresa_padrao on public.cob_eventos;
create trigger cob__empresa_padrao before insert on public.cob_eventos       for each row execute function public.cob__empresa_padrao();

-- ── 6) Trava: trocar a empresa de uma parcela é coisa rara ──
-- Segue o espírito da v2.17.0 (cob_trava_parcela_campos): campos estruturais
-- da parcela só mudam por diretor ou pelo robô.
create or replace function public.cob__trava_parcela_empresa()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  if new.empresa_id is distinct from old.empresa_id then
    if not (public.cob_eh_diretor(old.tenant_id) or public.cob_eh_robo(old.tenant_id)) then
      raise exception 'Trocar a empresa de uma parcela é permitido só ao diretor ou ao robô.'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists cob__trava_parcela_empresa on public.cob_parcelas;
create trigger cob__trava_parcela_empresa before update on public.cob_parcelas
  for each row execute function public.cob__trava_parcela_empresa();

-- ── 7) Índices ──────────────────────────────────────────────
create index if not exists cob_parcelas_tenant_empresa_idx      on public.cob_parcelas      (tenant_id, empresa_id);
create index if not exists cob_pagamentos_tenant_empresa_idx    on public.cob_pagamentos    (tenant_id, empresa_id);
create index if not exists cob_conciliacoes_tenant_empresa_idx  on public.cob_conciliacoes  (tenant_id, empresa_id);
create index if not exists cob_confrontos_tenant_empresa_idx    on public.cob_confrontos    (tenant_id, empresa_id);
create index if not exists cob_fila_envios_tenant_empresa_idx   on public.cob_fila_envios   (tenant_id, empresa_id);
create index if not exists cob_whatsapp_fila_tenant_empresa_idx on public.cob_whatsapp_fila (tenant_id, empresa_id);
create index if not exists cob_eventos_tenant_empresa_idx       on public.cob_eventos       (tenant_id, empresa_id);

-- título da API: um registro por (tenant, empresa, id no Questor)
create unique index if not exists cob_parcelas_questor_uk
  on public.cob_parcelas (tenant_id, empresa_id, questor_id) where questor_id is not null;

-- ── Conferência rápida (opcional, só leitura) ───────────────
-- select nome, padrao, ativo from cob_empresas;
-- select count(*) filter (where empresa_id is null) as sem_empresa, count(*) as total from cob_parcelas;

-- =====================================================================
-- Artecon Propostas v2.3.0 — lotes de propostas
-- ---------------------------------------------------------------------
-- O que faz:
--   1. Tabela prop_lotes (o usuário cria o lote: reajuste anual ou
--      serviço avulso; "mensal com 3 níveis" fica para a tabela de preços).
--   2. prop_propostas.lote_id: as propostas geradas ficam ligadas ao lote
--      (numeração normal; o lote do escritório certo; não muda depois).
--   3. RPC prop_lote_descartar: descarta o lote inteiro enquanto todas as
--      propostas dele estiverem em rascunho e sem assinatura (só diretor).
--
-- Exige: setup v1.x. O app v2.3.0 também precisa da migração 21.
-- Idempotente: pode rodar de novo sem efeito colateral.
-- Reversão: 91_reversao_v2_3_0.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Estado antes (guarde o resultado)
-- ---------------------------------------------------------------------
select 'antes' as etapa,
       (select count(*) from public.prop_propostas) as propostas,
       to_regclass('public.prop_lotes') is not null as tabela_lotes,
       exists (select 1 from information_schema.columns where table_schema = 'public'
                and table_name = 'prop_propostas' and column_name = 'lote_id') as coluna_lote_id;

begin;

-- ---------------------------------------------------------------------
-- 1. Lotes
-- ---------------------------------------------------------------------
create table if not exists public.prop_lotes (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.prop_tenants(id),
  nome            text not null,
  tipo            text not null,
  status          text not null default 'rascunho',
  parametros      jsonb not null default '{}'::jsonb,   -- percentual, índice, vigência, arredondamento, serviço, preço, pagamento…
  filtros         jsonb not null default '{}'::jsonb,   -- regimes, situações, atividades, departamentos, faixa de honorário…
  data_proposta   date not null default current_date,
  validade_dias   int not null default 10,
  abertura        text,
  total_propostas int not null default 0,
  criado_por      uuid,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now(),
  descartado_em   timestamptz,
  excluido_em     timestamptz,
  constraint prop_lotes_nome_ck       check (length(btrim(nome)) > 0),
  constraint prop_lotes_tipo_ck       check (tipo in ('reajuste','avulso','mensal')),
  constraint prop_lotes_status_ck     check (status in ('rascunho','gerado','descartado')),
  constraint prop_lotes_parametros_ck check (jsonb_typeof(parametros) = 'object'),
  constraint prop_lotes_filtros_ck    check (jsonb_typeof(filtros) = 'object'),
  constraint prop_lotes_validade_ck   check (validade_dias between 1 and 365),
  constraint prop_lotes_total_ck      check (total_propostas >= 0)
);
create index if not exists prop_lotes_tenant_ix on public.prop_lotes (tenant_id);

alter table public.prop_lotes enable row level security;
drop policy if exists prop_lotes_sel on public.prop_lotes;
create policy prop_lotes_sel on public.prop_lotes for select to authenticated
  using (tenant_id in (select public.prop_meus_tenants()));
drop policy if exists prop_lotes_ins on public.prop_lotes;
create policy prop_lotes_ins on public.prop_lotes for insert to authenticated
  with check (tenant_id in (select public.prop_meus_tenants()));
drop policy if exists prop_lotes_upd on public.prop_lotes;
create policy prop_lotes_upd on public.prop_lotes for update to authenticated
  using (tenant_id in (select public.prop_meus_tenants()))
  with check (tenant_id in (select public.prop_meus_tenants()));
grant select, insert, update on public.prop_lotes to authenticated;

-- escritório, autoria e tipo não mudam; descartar só pela função própria
create or replace function public.prop_lotes_guarda()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_desc boolean := coalesce(current_setting('prop.lote_descartando', true), '') = '1';
begin
  if tg_op = 'INSERT' then
    new.criado_por := auth.uid(); new.criado_em := now(); new.atualizado_em := now();
    new.status := 'rascunho'; new.descartado_em := null; new.excluido_em := null; new.total_propostas := 0;
    return new;
  end if;
  if new.tenant_id <> old.tenant_id or new.criado_por is distinct from old.criado_por or new.criado_em is distinct from old.criado_em
     or new.tipo <> old.tipo then
    raise exception 'PROP101: escritório, autoria e tipo do lote não mudam';
  end if;
  if old.status = 'descartado' and to_jsonb(new) - 'atualizado_em' is distinct from to_jsonb(old) - 'atualizado_em' then
    raise exception 'PROP102: lote descartado não pode ser alterado';
  end if;
  if new.status is distinct from old.status then
    if new.status = 'descartado' and not v_desc then
      raise exception 'PROP102: para descartar o lote use o botão Descartar (todas as propostas precisam estar em rascunho)';
    end if;
    if not ((old.status, new.status) in (('rascunho','gerado'),('rascunho','descartado'),('gerado','descartado'))) then
      raise exception 'PROP102: mudança de situação do lote não permitida (% para %)', old.status, new.status;
    end if;
  end if;
  if new.excluido_em is distinct from old.excluido_em and not v_desc then
    raise exception 'PROP102: lote não é excluído; use Descartar';
  end if;
  new.atualizado_em := now();
  return new;
end $$;
drop trigger if exists prop_lotes_guarda on public.prop_lotes;
create trigger prop_lotes_guarda before insert or update on public.prop_lotes
  for each row execute function public.prop_lotes_guarda();

-- ---------------------------------------------------------------------
-- 2. Propostas ligadas ao lote
-- ---------------------------------------------------------------------
alter table public.prop_propostas add column if not exists lote_id uuid;
alter table public.prop_propostas drop constraint if exists prop_propostas_lote_fkey;
alter table public.prop_propostas add  constraint prop_propostas_lote_fkey
  foreign key (lote_id) references public.prop_lotes(id);
create index if not exists prop_propostas_lote_ix on public.prop_propostas (lote_id) where lote_id is not null;
comment on column public.prop_propostas.lote_id is 'lote que gerou a proposta (v2.3.0); não muda depois de criada';

create or replace function public.prop_propostas_lote()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if tg_op = 'UPDATE' then
    if new.lote_id is distinct from old.lote_id then
      raise exception 'PROP103: a proposta não muda de lote';
    end if;
    return new;
  end if;
  if new.lote_id is not null and not exists (select 1 from public.prop_lotes l where l.id = new.lote_id
        and l.tenant_id = new.tenant_id and l.status in ('rascunho','gerado')) then
    raise exception 'PROP103: o lote não pertence a este escritório ou já foi descartado';
  end if;
  return new;
end $$;
drop trigger if exists prop_propostas_lote on public.prop_propostas;
create trigger prop_propostas_lote before insert or update of lote_id on public.prop_propostas
  for each row execute function public.prop_propostas_lote();

-- ---------------------------------------------------------------------
-- 3. Descartar o lote (tudo ou nada)
-- ---------------------------------------------------------------------
create or replace function public.prop_lote_descartar(p_lote uuid)
returns int language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_l public.prop_lotes; v_n int;
begin
  select * into v_l from public.prop_lotes where id = p_lote for update;
  if not found or not public.prop_ct_membro(v_l.tenant_id) then
    raise exception 'PROP104: lote não encontrado neste escritório';
  end if;
  if not public.prop_sou_diretor(v_l.tenant_id) then
    raise exception 'PROP104: só o diretor descarta lotes';
  end if;
  if v_l.status = 'descartado' then
    raise exception 'PROP104: este lote já foi descartado';
  end if;
  if exists (select 1 from public.prop_propostas p where p.lote_id = p_lote and p.excluido_em is null
              and (p.status <> 'rascunho' or exists (select 1 from public.prop_assinaturas a where a.proposta_id = p.id))) then
    raise exception 'PROP104: só dá para descartar lote com todas as propostas em rascunho e sem assinatura';
  end if;
  update public.prop_propostas set excluido_em = now() where lote_id = p_lote and excluido_em is null;
  get diagnostics v_n = row_count;
  perform set_config('prop.lote_descartando', '1', true);
  update public.prop_lotes set status = 'descartado', descartado_em = now() where id = p_lote;
  perform set_config('prop.lote_descartando', '', true);
  return v_n;
end $$;
revoke all on function public.prop_lote_descartar(uuid) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.prop_lote_descartar(uuid) from anon';
    execute 'grant execute on function public.prop_lote_descartar(uuid) to authenticated';
  end if;
end $$;

commit;

-- ---------------------------------------------------------------------
-- 4. Verificação (todas as colunas "ok" devem vir true)
-- ---------------------------------------------------------------------
select 'depois' as etapa,
       to_regclass('public.prop_lotes') is not null as ok_tabela_lotes,
       exists (select 1 from information_schema.columns where table_schema = 'public'
                and table_name = 'prop_propostas' and column_name = 'lote_id') as ok_coluna_lote_id,
       (select count(*) from pg_policies where tablename = 'prop_lotes') = 3 as ok_politicas,
       (select count(*) from pg_trigger where tgname in ('prop_lotes_guarda','prop_propostas_lote') and tgenabled = 'O') = 2 as ok_gatilhos,
       (select count(*) from pg_constraint where conname = 'prop_propostas_lote_fkey') = 1 as ok_fk,
       to_regprocedure('public.prop_lote_descartar(uuid)') is not null as ok_rpc,
       (select count(*) from public.prop_propostas) as propostas;

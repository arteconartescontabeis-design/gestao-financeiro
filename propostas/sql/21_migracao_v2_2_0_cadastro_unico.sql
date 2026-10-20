-- =====================================================================
-- Artecon Propostas v2.2.0 — cadastro único de clientes
-- ---------------------------------------------------------------------
-- O que faz:
--   1. prop_clientes ganha os dados do contrato (endereço, representante,
--      dados da Receita) e o perfil (regime, atividade, apuração, situação,
--      matriz/filial, departamentos, honorário atual, enquadramento).
--   2. Nova tabela prop_clientes_contatos (quem recebe e quem assina).
--   3. Os Contratantes viram clientes; contratos e confissões passam a
--      apontar para prop_clientes (a coluna continua "contratante_id").
--   4. Guarda nova em prop_clientes (matriz e exclusão).
--   5. RPC prop_cobranca_clientes: lê do Cobrança Pro clientes, contatos e
--      boletos dos últimos meses, para a importação com conferência.
--
-- Exige: setup v1.x + migrações 17 (contratos) e 19 (confissões).
-- Idempotente: pode rodar de novo sem efeito colateral.
-- Reversão: 92_reversao_v2_2_0.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Estado antes (guarde o resultado)
-- ---------------------------------------------------------------------
select 'antes' as etapa,
       (select count(*) from public.prop_clientes)                         as clientes,
       (select count(*) from public.prop_contratantes)                     as contratantes,
       (select count(*) from public.prop_contratos)                        as contratos,
       (select count(*) from public.prop_confissoes)                       as confissoes,
       (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'prop_clientes')   as colunas_clientes,
       (select count(*) from information_schema.tables
         where table_schema = 'public' and table_name = 'prop_clientes_contatos') as tabela_contatos,
       (select string_agg(conname || ' -> ' || confrelid::regclass::text, ', ' order by conname)
          from pg_constraint
         where contype = 'f' and conrelid in ('public.prop_contratos'::regclass, 'public.prop_confissoes'::regclass)
           and conkey = array[(select attnum from pg_attribute where attrelid = conrelid and attname = 'contratante_id')]) as fks_contratante;

begin;

-- ---------------------------------------------------------------------
-- 1. Colunas novas em prop_clientes
-- ---------------------------------------------------------------------
alter table public.prop_clientes
  add column if not exists nome_fantasia     text,
  add column if not exists endereco          text,
  add column if not exists complemento       text,
  add column if not exists bairro            text,
  add column if not exists cep               text,
  add column if not exists municipio         text,
  add column if not exists uf                text,
  add column if not exists cnae              text,
  add column if not exists situacao_receita  text,
  add column if not exists rep_nome          text,
  add column if not exists rep_cpf           text,
  add column if not exists rep_qualidade     text,
  add column if not exists rep_profissao     text,
  add column if not exists rep_email         text,
  add column if not exists rep_celular       text,
  add column if not exists receita           jsonb,
  add column if not exists receita_em        timestamptz,
  add column if not exists regime            text,
  add column if not exists atividade         text,
  add column if not exists apuracao          text,
  add column if not exists situacao          text not null default 'ativa',
  add column if not exists matriz_id         uuid,
  add column if not exists codigo_questor    text,
  add column if not exists cob_cliente_id    uuid,
  add column if not exists departamentos     jsonb not null default '[]'::jsonb,
  add column if not exists nivel_atual       text,
  add column if not exists honorario_atual   numeric,
  add column if not exists honorario_ref     date,
  add column if not exists honorario_origem  text,
  add column if not exists enquadramento     jsonb not null default '{}'::jsonb;

alter table public.prop_clientes drop constraint if exists prop_clientes_regime_ck;
alter table public.prop_clientes add  constraint prop_clientes_regime_ck
  check (regime is null or regime in ('simples','presumido','real','mei','imune'));
alter table public.prop_clientes drop constraint if exists prop_clientes_atividade_ck;
alter table public.prop_clientes add  constraint prop_clientes_atividade_ck
  check (atividade is null or atividade in ('servicos','comercio','industria','mista'));
alter table public.prop_clientes drop constraint if exists prop_clientes_apuracao_ck;
alter table public.prop_clientes add  constraint prop_clientes_apuracao_ck
  check (apuracao is null or apuracao in ('mensal','trimestral'));
alter table public.prop_clientes drop constraint if exists prop_clientes_situacao_ck;
alter table public.prop_clientes add  constraint prop_clientes_situacao_ck
  check (situacao in ('ativa','sem_movimento','inativa'));
alter table public.prop_clientes drop constraint if exists prop_clientes_nivel_ck;
alter table public.prop_clientes add  constraint prop_clientes_nivel_ck
  check (nivel_atual is null or nivel_atual in ('essencial','gestao','estrategico'));
alter table public.prop_clientes drop constraint if exists prop_clientes_departamentos_ck;
alter table public.prop_clientes add  constraint prop_clientes_departamentos_ck
  check (jsonb_typeof(departamentos) = 'array'
         and departamentos <@ '["fiscal","contabil","pessoal","societario"]'::jsonb);
alter table public.prop_clientes drop constraint if exists prop_clientes_honorario_ck;
alter table public.prop_clientes add  constraint prop_clientes_honorario_ck
  check (honorario_atual is null or honorario_atual >= 0);
alter table public.prop_clientes drop constraint if exists prop_clientes_enquadramento_ck;
alter table public.prop_clientes add  constraint prop_clientes_enquadramento_ck
  check (jsonb_typeof(enquadramento) = 'object');
alter table public.prop_clientes drop constraint if exists prop_clientes_matriz_ck;
alter table public.prop_clientes add  constraint prop_clientes_matriz_ck
  check (matriz_id is null or matriz_id <> id);
alter table public.prop_clientes drop constraint if exists prop_clientes_matriz_fkey;
alter table public.prop_clientes add  constraint prop_clientes_matriz_fkey
  foreign key (matriz_id) references public.prop_clientes(id);

create index if not exists prop_clientes_matriz_ix on public.prop_clientes (matriz_id) where matriz_id is not null;

comment on column public.prop_clientes.regime is 'simples | presumido | real | mei | imune — filtro principal dos lotes';
comment on column public.prop_clientes.enquadramento is 'Questor: lanc_fiscal, lanc_contabil, empregados, socios_prolabore, contas, eventos_dp, periodo, importado_em';
comment on column public.prop_clientes.cob_cliente_id is 'id em cob_clientes (Cobrança Pro), gravado na importação; sem FK para não amarrar os dois apps';

-- ---------------------------------------------------------------------
-- 2. Contatos para envio
-- ---------------------------------------------------------------------
create table if not exists public.prop_clientes_contatos (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.prop_tenants(id),
  cliente_id      uuid not null references public.prop_clientes(id),
  nome            text,
  funcao          text,
  email           text,
  celular         text,
  recebe_email    boolean not null default true,
  recebe_whatsapp boolean not null default false,
  assina          boolean not null default false,
  origem          text not null default 'manual',
  observacao      text,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now(),
  excluido_em     timestamptz,
  constraint prop_cc_origem_ck  check (origem in ('manual','cobranca','migracao')),
  constraint prop_cc_meio_ck    check (email is not null or celular is not null),
  constraint prop_cc_email_ck   check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint prop_cc_celular_ck check (celular is null or celular ~ '^[0-9]{10,13}$')
);
create index if not exists prop_clientes_contatos_cliente_ix on public.prop_clientes_contatos (cliente_id);
create index if not exists prop_clientes_contatos_tenant_ix  on public.prop_clientes_contatos (tenant_id);

alter table public.prop_clientes_contatos enable row level security;
drop policy if exists prop_cc_sel on public.prop_clientes_contatos;
create policy prop_cc_sel on public.prop_clientes_contatos for select to authenticated
  using (tenant_id in (select public.prop_meus_tenants()));
drop policy if exists prop_cc_ins on public.prop_clientes_contatos;
create policy prop_cc_ins on public.prop_clientes_contatos for insert to authenticated
  with check (tenant_id in (select public.prop_meus_tenants()));
drop policy if exists prop_cc_upd on public.prop_clientes_contatos;
create policy prop_cc_upd on public.prop_clientes_contatos for update to authenticated
  using (tenant_id in (select public.prop_meus_tenants()))
  with check (tenant_id in (select public.prop_meus_tenants()));
grant select, insert, update on public.prop_clientes_contatos to authenticated;

-- o contato é sempre do mesmo escritório do cliente; escritório não muda
create or replace function public.prop_clientes_contatos_guarda()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if tg_op = 'UPDATE' and new.tenant_id <> old.tenant_id then
    raise exception 'PROP004: tenant_id não pode ser alterado';
  end if;
  if tg_op = 'INSERT' or new.cliente_id is distinct from old.cliente_id then
    if not exists (select 1 from public.prop_clientes c where c.id = new.cliente_id and c.tenant_id = new.tenant_id) then
      raise exception 'PROP081: o contato precisa ser de um cliente deste escritório';
    end if;
  end if;
  if tg_op = 'INSERT' then new.criado_em := now(); new.excluido_em := null; end if;
  new.atualizado_em := now();
  new.email := nullif(lower(btrim(coalesce(new.email, ''))), '');
  new.celular := nullif(regexp_replace(coalesce(new.celular, ''), '\D', '', 'g'), '');
  return new;
end $$;
drop trigger if exists prop_clientes_contatos_guarda on public.prop_clientes_contatos;
create trigger prop_clientes_contatos_guarda before insert or update on public.prop_clientes_contatos
  for each row execute function public.prop_clientes_contatos_guarda();

-- ---------------------------------------------------------------------
-- 3. Contratantes viram clientes
-- ---------------------------------------------------------------------
create table if not exists prop_priv.migracao_v220_ctt (
  contratante_id uuid primary key,
  cliente_id     uuid not null,
  criado         boolean not null,           -- true = cliente criado pela migração
  migrado_em     timestamptz not null default now()
);
create table if not exists prop_priv.migracao_v220_ref (
  tabela         text not null,              -- prop_contratos | prop_confissoes
  registro_id    uuid not null,
  contratante_id uuid not null,              -- valor antigo, para a reversão
  primary key (tabela, registro_id)
);
revoke all on prop_priv.migracao_v220_ctt, prop_priv.migracao_v220_ref from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on prop_priv.migracao_v220_ctt, prop_priv.migracao_v220_ref from authenticated, anon';
  end if;
end $$;

do $$
declare t record; alvo uuid; novo boolean;
begin
  for t in select * from public.prop_contratantes k
            where not exists (select 1 from prop_priv.migracao_v220_ctt m where m.contratante_id = k.id)
            order by k.criado_em
  loop
    novo := false;
    alvo := null;
    -- 1º o cliente ligado; 2º o mesmo CNPJ/CPF ativo no escritório; senão cria
    if t.cliente_id is not null then
      select c.id into alvo from public.prop_clientes c where c.id = t.cliente_id and c.tenant_id = t.tenant_id;
    end if;
    if alvo is null and t.excluido_em is null then
      select c.id into alvo from public.prop_clientes c
       where c.tenant_id = t.tenant_id and c.documento = t.documento and c.excluido_em is null;
    end if;
    if alvo is null then
      insert into public.prop_clientes (tenant_id, nome, documento, email, telefone, contato, criado_em, excluido_em)
      values (t.tenant_id, t.razao_social,
              case when t.documento ~ '^[0-9]{11}$|^[0-9A-Z]{12}[0-9]{2}$' then t.documento end,
              t.email, t.telefone, t.rep_nome, t.criado_em, t.excluido_em)
      returning id into alvo;
      novo := true;
    end if;
    -- completa o cliente sem apagar o que já existe nele
    update public.prop_clientes c set
      nome_fantasia    = coalesce(c.nome_fantasia, t.nome_fantasia),
      endereco         = coalesce(c.endereco, t.endereco),
      complemento      = coalesce(c.complemento, t.complemento),
      bairro           = coalesce(c.bairro, t.bairro),
      cep              = coalesce(c.cep, t.cep),
      municipio        = coalesce(c.municipio, t.municipio),
      uf               = coalesce(c.uf, t.uf),
      cnae             = coalesce(c.cnae, t.cnae),
      situacao_receita = coalesce(c.situacao_receita, t.situacao),
      rep_nome         = coalesce(c.rep_nome, t.rep_nome),
      rep_cpf          = coalesce(c.rep_cpf, t.rep_cpf),
      rep_qualidade    = coalesce(c.rep_qualidade, t.rep_qualidade),
      rep_profissao    = coalesce(c.rep_profissao, t.rep_profissao),
      rep_email        = coalesce(c.rep_email, t.rep_email),
      rep_celular      = coalesce(c.rep_celular, t.rep_celular),
      receita          = coalesce(c.receita, t.receita),
      receita_em       = coalesce(c.receita_em, t.receita_em),
      regime           = coalesce(c.regime, case lower(coalesce(t.regime, ''))
                           when 'simples' then 'simples' when 'simples nacional' then 'simples'
                           when 'presumido' then 'presumido' when 'lucro presumido' then 'presumido'
                           when 'real' then 'real' when 'lucro real' then 'real'
                           when 'mei' then 'mei' end),
      email            = coalesce(c.email, t.email),
      telefone         = coalesce(c.telefone, t.telefone)
     where c.id = alvo;
    insert into prop_priv.migracao_v220_ctt (contratante_id, cliente_id, criado) values (t.id, alvo, novo);
  end loop;
end $$;

-- contatos iniciais: o e-mail/telefone do cliente e o representante do contrato
insert into public.prop_clientes_contatos (tenant_id, cliente_id, nome, funcao, email, celular, recebe_email, recebe_whatsapp, assina, origem)
select c.tenant_id, c.id, nullif(btrim(coalesce(c.contato, '')), ''), null,
       case when lower(btrim(c.email)) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then lower(btrim(c.email)) end,
       case when regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g') ~ '^[0-9]{10,13}$'
            then regexp_replace(c.telefone, '\D', '', 'g') end,
       true, false, c.rep_nome is null, 'migracao'
  from public.prop_clientes c
 where c.excluido_em is null
   and (lower(btrim(c.email)) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
        or regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g') ~ '^[0-9]{10,13}$')
   and not exists (select 1 from public.prop_clientes_contatos x where x.cliente_id = c.id and x.origem = 'migracao');

insert into public.prop_clientes_contatos (tenant_id, cliente_id, nome, funcao, email, celular, recebe_email, recebe_whatsapp, assina, origem)
select c.tenant_id, c.id, c.rep_nome, c.rep_qualidade,
       case when lower(btrim(c.rep_email)) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then lower(btrim(c.rep_email)) end,
       case when regexp_replace(coalesce(c.rep_celular, ''), '\D', '', 'g') ~ '^[0-9]{10,13}$'
            then regexp_replace(c.rep_celular, '\D', '', 'g') end,
       true, false, true, 'migracao'
  from public.prop_clientes c
 where c.excluido_em is null
   and (lower(btrim(c.rep_email)) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
        or regexp_replace(coalesce(c.rep_celular, ''), '\D', '', 'g') ~ '^[0-9]{10,13}$')
   and not exists (select 1 from public.prop_clientes_contatos x
                    where x.cliente_id = c.id
                      and (x.email = lower(btrim(c.rep_email))
                           or x.celular = regexp_replace(coalesce(c.rep_celular, ''), '\D', '', 'g')));

-- o representante que já era o contato principal passa a assinar
update public.prop_clientes_contatos k set assina = true
  from public.prop_clientes c
 where c.id = k.cliente_id and k.origem = 'migracao' and not k.assina and c.rep_nome is not null
   and (k.email = lower(btrim(c.rep_email))
        or k.celular = regexp_replace(coalesce(c.rep_celular, ''), '\D', '', 'g'));

-- ---------------------------------------------------------------------
-- 4. Contratos e confissões passam a apontar para prop_clientes
-- ---------------------------------------------------------------------
alter table public.prop_contratos  drop constraint if exists prop_contratos_contratante_id_fkey;
alter table public.prop_confissoes drop constraint if exists prop_confissoes_contratante_id_fkey;

do $$
begin
  if exists (select 1 from public.prop_contratos ct join prop_priv.migracao_v220_ctt m on m.contratante_id = ct.contratante_id) then
    -- sem guarda, histórico e carimbo de data: é troca de referência, não alteração do documento
    alter table public.prop_contratos disable trigger prop_contratos_guarda;
    alter table public.prop_contratos disable trigger prop_contratos_hist;
    alter table public.prop_contratos disable trigger prop_contratos_toca;
    insert into prop_priv.migracao_v220_ref (tabela, registro_id, contratante_id)
      select 'prop_contratos', ct.id, ct.contratante_id from public.prop_contratos ct
        join prop_priv.migracao_v220_ctt m on m.contratante_id = ct.contratante_id
      on conflict do nothing;
    update public.prop_contratos ct set contratante_id = m.cliente_id
      from prop_priv.migracao_v220_ctt m where m.contratante_id = ct.contratante_id;
    alter table public.prop_contratos enable trigger prop_contratos_guarda;
    alter table public.prop_contratos enable trigger prop_contratos_hist;
    alter table public.prop_contratos enable trigger prop_contratos_toca;
  end if;
  if exists (select 1 from public.prop_confissoes cd join prop_priv.migracao_v220_ctt m on m.contratante_id = cd.contratante_id) then
    alter table public.prop_confissoes disable trigger prop_confissoes_guarda;
    alter table public.prop_confissoes disable trigger prop_confissoes_hist;
    alter table public.prop_confissoes disable trigger prop_confissoes_toca;
    insert into prop_priv.migracao_v220_ref (tabela, registro_id, contratante_id)
      select 'prop_confissoes', cd.id, cd.contratante_id from public.prop_confissoes cd
        join prop_priv.migracao_v220_ctt m on m.contratante_id = cd.contratante_id
      on conflict do nothing;
    update public.prop_confissoes cd set contratante_id = m.cliente_id
      from prop_priv.migracao_v220_ctt m where m.contratante_id = cd.contratante_id;
    alter table public.prop_confissoes enable trigger prop_confissoes_guarda;
    alter table public.prop_confissoes enable trigger prop_confissoes_hist;
    alter table public.prop_confissoes enable trigger prop_confissoes_toca;
  end if;
end $$;

alter table public.prop_contratos  drop constraint if exists prop_contratos_cliente_fkey;
alter table public.prop_contratos  add  constraint prop_contratos_cliente_fkey
  foreign key (contratante_id) references public.prop_clientes(id);
alter table public.prop_confissoes drop constraint if exists prop_confissoes_cliente_fkey;
alter table public.prop_confissoes add  constraint prop_confissoes_cliente_fkey
  foreign key (contratante_id) references public.prop_clientes(id);
create index if not exists prop_contratos_contratante_ix  on public.prop_contratos  (contratante_id);
create index if not exists prop_confissoes_contratante_ix on public.prop_confissoes (contratante_id);
comment on column public.prop_contratos.contratante_id  is 'cliente contratante (prop_clientes.id) desde a v2.2.0';
comment on column public.prop_confissoes.contratante_id is 'cliente devedor (prop_clientes.id) desde a v2.2.0';
comment on table  public.prop_contratantes is 'DESCONTINUADA na v2.2.0: os dados foram para prop_clientes (correspondência em prop_priv.migracao_v220_ctt). Mantida só para a reversão.';

create or replace function public.prop_contratos_numera()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if not exists (select 1 from public.prop_clientes t where t.id = new.contratante_id and t.tenant_id = new.tenant_id and t.excluido_em is null) then
    raise exception 'PROP056: o contratante não pertence a este escritório';
  end if;
  if new.proposta_id is not null and not exists (select 1 from public.prop_propostas p where p.id = new.proposta_id and p.tenant_id = new.tenant_id) then
    raise exception 'PROP057: a proposta não pertence a este escritório';
  end if;
  new.ano := extract(year from coalesce(new.data_contrato, current_date))::int;
  insert into public.prop_ct_numeradores as n (tenant_id, ano, ultimo) values (new.tenant_id, new.ano, 1)
    on conflict (tenant_id, ano) do update set ultimo = n.ultimo + 1
    returning ultimo into new.numero;
  new.criado_em := now(); new.atualizado_em := now(); new.excluido_em := null;
  if new.status not in ('rascunho','enviado') then new.status := 'rascunho'; end if;
  return new;
end $$;

create or replace function public.prop_confissoes_numera()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if not exists (select 1 from public.prop_clientes t where t.id = new.contratante_id and t.tenant_id = new.tenant_id and t.excluido_em is null) then
    raise exception 'PROP071: o devedor não pertence a este escritório';
  end if;
  if new.contrato_id is not null and not exists (select 1 from public.prop_contratos c where c.id = new.contrato_id
        and c.tenant_id = new.tenant_id and c.contratante_id = new.contratante_id) then
    raise exception 'PROP072: o contrato de origem precisa ser do mesmo devedor e escritório';
  end if;
  new.ano := extract(year from coalesce(new.data_documento, current_date))::int;
  insert into public.prop_cd_numeradores as n (tenant_id, ano, ultimo) values (new.tenant_id, new.ano, 1)
    on conflict (tenant_id, ano) do update set ultimo = n.ultimo + 1
    returning ultimo into new.numero;
  new.criado_em := now(); new.atualizado_em := now(); new.excluido_em := null;
  new.pagamentos := '[]'::jsonb; new.assinado_em := null; new.quitado_em := null; new.cancelado_em := null; new.cancelado_motivo := null;
  if new.status not in ('rascunho','enviado') then new.status := 'rascunho'; end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 5. Guarda do cadastro único
-- ---------------------------------------------------------------------
create or replace function public.prop_clientes_guarda()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if new.matriz_id is not null and (tg_op = 'INSERT' or new.matriz_id is distinct from old.matriz_id) then
    if not exists (select 1 from public.prop_clientes m where m.id = new.matriz_id and m.tenant_id = new.tenant_id
                    and m.excluido_em is null and m.matriz_id is null) then
      raise exception 'PROP082: a matriz precisa ser um cliente ativo deste escritório (e não pode ser filial)';
    end if;
    if tg_op = 'UPDATE' and exists (select 1 from public.prop_clientes f where f.matriz_id = new.id and f.excluido_em is null) then
      raise exception 'PROP082: este cliente é matriz de outras empresas e não pode virar filial';
    end if;
  end if;
  if tg_op = 'UPDATE' and new.excluido_em is not null and old.excluido_em is null then
    if exists (select 1 from public.prop_contratos c where c.contratante_id = old.id and c.excluido_em is null
                and c.status in ('rascunho','enviado','vigente','aviso')) then
      raise exception 'PROP055: cliente com contrato em andamento não pode ser excluído';
    end if;
    if exists (select 1 from public.prop_confissoes d where d.contratante_id = old.id and d.excluido_em is null
                and d.status in ('rascunho','enviado','assinado','inadimplente')) then
      raise exception 'PROP083: cliente com confissão de dívida em andamento não pode ser excluído';
    end if;
    if exists (select 1 from public.prop_clientes f where f.matriz_id = old.id and f.excluido_em is null) then
      raise exception 'PROP084: cliente é matriz de filiais ativas; exclua ou desvincule as filiais antes';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.excluido_em is not null and new.excluido_em is null
     and new.documento is not null and exists (select 1 from public.prop_clientes o where o.tenant_id = new.tenant_id
          and o.documento = new.documento and o.excluido_em is null and o.id <> new.id) then
    raise exception 'PROP085: já existe outro cliente ativo com este CNPJ/CPF';
  end if;
  return new;
end $$;
drop trigger if exists prop_clientes_guarda on public.prop_clientes;
create trigger prop_clientes_guarda before insert or update on public.prop_clientes
  for each row execute function public.prop_clientes_guarda();

-- ---------------------------------------------------------------------
-- 6. Ponte de leitura com o Cobrança Pro (importação com conferência)
-- ---------------------------------------------------------------------
create or replace function public.prop_cobranca_clientes(p_tenant uuid, p_meses int default 4)
returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_cob uuid; v_ini date; v_fim date; r jsonb;
begin
  if not public.prop_ct_membro(p_tenant) then
    raise exception 'PROP090: sem acesso a este escritório';
  end if;
  select ct.id into v_cob
    from public.cob_tenants ct join public.prop_tenants pt on pt.id = p_tenant
   where pt.cnpj is not null
     and upper(regexp_replace(ct.cnpj, '[^0-9A-Za-z]', '', 'g')) = upper(regexp_replace(pt.cnpj, '[^0-9A-Za-z]', '', 'g'));
  if v_cob is null then
    raise exception 'PROP091: este escritório não está no Cobrança Pro (confira o CNPJ do escritório)';
  end if;
  if not public.cob_pode(v_cob) then
    raise exception 'PROP092: seu usuário não tem acesso a este escritório no Cobrança Pro';
  end if;
  p_meses := least(greatest(coalesce(p_meses, 4), 1), 12);
  v_fim := (date_trunc('month', current_date) + interval '1 month')::date;
  v_ini := (date_trunc('month', current_date) - make_interval(months => p_meses - 1))::date;

  select jsonb_build_object(
    'cob_tenant', v_cob,
    'meses', (select jsonb_agg(to_char(m, 'YYYY-MM') order by m)
                from generate_series(v_ini, v_fim - 1, interval '1 month') m),
    'gerado_em', now(),
    'clientes', coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'razao_social', c.razao_social, 'cnpj', c.cnpj, 'codigo', c.codigo_externo,
        'responsavel', c.responsavel, 'email', c.email, 'telefone', c.telefone, 'contato', c.contato_nome,
        'forma_envio', c.forma_envio, 'nao_notificar', c.nao_notificar,
        'contatos', coalesce((select jsonb_agg(jsonb_build_object('tipo', k.tipo, 'valor', k.valor, 'nome', k.nome, 'whatsapp', k.whatsapp) order by k.tipo, k.valor)
                                from public.cob_clientes_contatos k where k.cliente_id = c.id and k.ativo), '[]'::jsonb),
        'boletos', coalesce((select jsonb_agg(jsonb_build_object('mes', b.mes, 'qtd', b.qtd, 'soma', b.soma) order by b.mes)
                               from (select to_char(p.data_vencimento, 'YYYY-MM') mes, count(*) qtd, sum(p.valor_original) soma
                                       from public.cob_parcelas p
                                      where p.cliente_id = c.id and p.data_vencimento >= v_ini and p.data_vencimento < v_fim
                                        and p.status not in ('renegociada','cancelada')
                                      group by 1) b), '[]'::jsonb)
      ) order by c.razao_social), '[]'::jsonb))
    into r
    from public.cob_clientes c
   where c.tenant_id = v_cob;
  return r;
end $$;
revoke all on function public.prop_cobranca_clientes(uuid, int) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.prop_cobranca_clientes(uuid, int) from anon';
    execute 'grant execute on function public.prop_cobranca_clientes(uuid, int) to authenticated';
  end if;
end $$;

commit;

-- ---------------------------------------------------------------------
-- 7. Verificação (todas as colunas "ok" devem vir true)
-- ---------------------------------------------------------------------
select 'depois' as etapa,
       (select count(*) from public.prop_clientes)                       as clientes,
       (select count(*) from public.prop_clientes_contatos)              as contatos,
       (select count(*) from prop_priv.migracao_v220_ctt)                as contratantes_migrados,
       (select count(*) from public.prop_contratantes)
         = (select count(*) from prop_priv.migracao_v220_ctt)            as ok_todos_contratantes,
       not exists (select 1 from public.prop_contratos ct
                    where not exists (select 1 from public.prop_clientes c where c.id = ct.contratante_id)) as ok_contratos,
       not exists (select 1 from public.prop_confissoes cd
                    where not exists (select 1 from public.prop_clientes c where c.id = cd.contratante_id)) as ok_confissoes,
       (select count(*) from pg_constraint where conname in ('prop_contratos_cliente_fkey','prop_confissoes_cliente_fkey')) = 2 as ok_fks_novas,
       (select count(*) from pg_constraint where conname in ('prop_contratos_contratante_id_fkey','prop_confissoes_contratante_id_fkey')) = 0 as ok_fks_antigas,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'prop_clientes'
          and column_name in ('regime','atividade','apuracao','situacao','matriz_id','departamentos','honorario_atual','enquadramento','rep_nome','endereco')) = 10 as ok_colunas,
       (select count(*) from pg_policies where tablename = 'prop_clientes_contatos') = 3 as ok_politicas_contatos,
       (select count(*) from pg_trigger where tgname in ('prop_clientes_guarda','prop_clientes_contatos_guarda') and tgenabled = 'O') = 2 as ok_gatilhos,
       (select count(*) from pg_trigger where tgrelid in ('public.prop_contratos'::regclass, 'public.prop_confissoes'::regclass)
          and not tgisinternal and tgenabled <> 'O') = 0 as ok_gatilhos_religados,
       position('prop_clientes' in pg_get_functiondef('public.prop_contratos_numera'::regproc)) > 0 as ok_numera_ct,
       position('prop_clientes' in pg_get_functiondef('public.prop_confissoes_numera'::regproc)) > 0 as ok_numera_cd,
       to_regprocedure('public.prop_cobranca_clientes(uuid,integer)') is not null as ok_rpc;

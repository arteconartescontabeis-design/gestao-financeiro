-- =====================================================================
-- Artecon Propostas — REVERSÃO da v2.2.0 (cadastro único)
-- ---------------------------------------------------------------------
-- Volta o banco ao ponto em que a v2.1.x funciona:
--   - contratos e confissões voltam a apontar para prop_contratantes
--     (os que foram criados depois da v2.2.0 ganham um contratante feito
--      a partir do cliente);
--   - funções de numeração voltam a conferir prop_contratantes;
--   - saem a guarda nova de prop_clientes e a RPC do Cobrança Pro.
-- NÃO apaga dados: as colunas novas de prop_clientes e a tabela
-- prop_clientes_contatos ficam (a v2.1.x simplesmente não as usa).
-- Para apagá-las também, rode o bloco OPCIONAL no fim.
-- Idempotente. Depois de reverter, suba de novo o index.html da v2.1.2.
-- =====================================================================

-- Estado antes
select 'antes da reversão' as etapa,
       (select count(*) from public.prop_contratos)  as contratos,
       (select count(*) from public.prop_confissoes) as confissoes,
       (select count(*) from public.prop_contratos ct
         where not exists (select 1 from public.prop_contratantes k where k.id = ct.contratante_id)) as contratos_a_repontar,
       (select count(*) from public.prop_confissoes cd
         where not exists (select 1 from public.prop_contratantes k where k.id = cd.contratante_id)) as confissoes_a_repontar;

begin;

-- 1. Clientes usados em contratos/confissões novos precisam de CNPJ/CPF
do $$
declare v text;
begin
  select string_agg(distinct c.nome, '; ') into v
    from public.prop_clientes c
   where c.documento is null
     and (exists (select 1 from public.prop_contratos ct where ct.contratante_id = c.id)
          or exists (select 1 from public.prop_confissoes cd where cd.contratante_id = c.id))
     and not exists (select 1 from public.prop_contratantes k where k.id = c.id);
  if v is not null then
    raise exception 'REV01: preencha o CNPJ/CPF destes clientes antes de reverter: %', v;
  end if;
end $$;

-- 2. Contratante para cada cliente usado em documento novo (mesmo id do cliente),
--    a não ser que já exista contratante ativo com o mesmo CNPJ/CPF
create temporary table rev_v220_map (cliente_id uuid primary key, contratante_id uuid not null) on commit drop;

insert into rev_v220_map (cliente_id, contratante_id)
select c.id, coalesce(
         (select k.id from public.prop_contratantes k
           where k.tenant_id = c.tenant_id and k.documento = c.documento and k.excluido_em is null limit 1),
         c.id)
  from public.prop_clientes c
 where (exists (select 1 from public.prop_contratos ct where ct.contratante_id = c.id)
        or exists (select 1 from public.prop_confissoes cd where cd.contratante_id = c.id))
   and not exists (select 1 from public.prop_contratantes k where k.id = c.id);

insert into public.prop_contratantes (id, tenant_id, cliente_id, documento, razao_social, nome_fantasia, endereco, complemento,
       bairro, cep, municipio, uf, cnae, situacao, regime, email, telefone, rep_nome, rep_cpf, rep_qualidade, rep_profissao,
       rep_email, rep_celular, receita, receita_em, excluido_em)
select c.id, c.tenant_id, c.id, c.documento, c.nome, c.nome_fantasia, c.endereco, c.complemento,
       c.bairro, c.cep, c.municipio, c.uf, c.cnae, c.situacao_receita,
       case c.regime when 'simples' then 'Simples Nacional' when 'presumido' then 'Lucro Presumido'
                     when 'real' then 'Lucro Real' when 'mei' then 'MEI' when 'imune' then 'Imune/isenta' end,
       c.email, c.telefone, c.rep_nome, c.rep_cpf, c.rep_qualidade, c.rep_profissao,
       c.rep_email, c.rep_celular, c.receita, c.receita_em, c.excluido_em
  from public.prop_clientes c
  join rev_v220_map m on m.cliente_id = c.id and m.contratante_id = c.id
 on conflict (id) do nothing;

-- 3. Repontar sem guarda, histórico e carimbo de data
alter table public.prop_contratos  drop constraint if exists prop_contratos_cliente_fkey;
alter table public.prop_confissoes drop constraint if exists prop_confissoes_cliente_fkey;

alter table public.prop_contratos disable trigger prop_contratos_guarda;
alter table public.prop_contratos disable trigger prop_contratos_hist;
alter table public.prop_contratos disable trigger prop_contratos_toca;
update public.prop_contratos ct set contratante_id = r.contratante_id
  from prop_priv.migracao_v220_ref r
 where r.tabela = 'prop_contratos' and r.registro_id = ct.id
   and not exists (select 1 from public.prop_contratantes k where k.id = ct.contratante_id);
update public.prop_contratos ct set contratante_id = m.contratante_id
  from rev_v220_map m
 where m.cliente_id = ct.contratante_id
   and not exists (select 1 from public.prop_contratantes k where k.id = ct.contratante_id);
alter table public.prop_contratos enable trigger prop_contratos_guarda;
alter table public.prop_contratos enable trigger prop_contratos_hist;
alter table public.prop_contratos enable trigger prop_contratos_toca;

alter table public.prop_confissoes disable trigger prop_confissoes_guarda;
alter table public.prop_confissoes disable trigger prop_confissoes_hist;
alter table public.prop_confissoes disable trigger prop_confissoes_toca;
update public.prop_confissoes cd set contratante_id = r.contratante_id
  from prop_priv.migracao_v220_ref r
 where r.tabela = 'prop_confissoes' and r.registro_id = cd.id
   and not exists (select 1 from public.prop_contratantes k where k.id = cd.contratante_id);
update public.prop_confissoes cd set contratante_id = m.contratante_id
  from rev_v220_map m
 where m.cliente_id = cd.contratante_id
   and not exists (select 1 from public.prop_contratantes k where k.id = cd.contratante_id);
alter table public.prop_confissoes enable trigger prop_confissoes_guarda;
alter table public.prop_confissoes enable trigger prop_confissoes_hist;
alter table public.prop_confissoes enable trigger prop_confissoes_toca;

alter table public.prop_contratos  drop constraint if exists prop_contratos_contratante_id_fkey;
alter table public.prop_contratos  add  constraint prop_contratos_contratante_id_fkey
  foreign key (contratante_id) references public.prop_contratantes(id);
alter table public.prop_confissoes drop constraint if exists prop_confissoes_contratante_id_fkey;
alter table public.prop_confissoes add  constraint prop_confissoes_contratante_id_fkey
  foreign key (contratante_id) references public.prop_contratantes(id);
comment on column public.prop_contratos.contratante_id  is null;
comment on column public.prop_confissoes.contratante_id is null;
comment on table  public.prop_contratantes is null;

-- 4. Numeração volta a conferir prop_contratantes (texto original da v2.0/v2.1)
create or replace function public.prop_contratos_numera()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if not exists (select 1 from public.prop_contratantes t where t.id = new.contratante_id and t.tenant_id = new.tenant_id) then
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
  if not exists (select 1 from public.prop_contratantes t where t.id = new.contratante_id and t.tenant_id = new.tenant_id) then
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

-- 5. Sai o que só a v2.2.0 usa
drop trigger  if exists prop_clientes_guarda on public.prop_clientes;
drop function if exists public.prop_clientes_guarda();
drop function if exists public.prop_cobranca_clientes(uuid, int);

commit;

-- Verificação (todas as colunas "ok" devem vir true)
select 'depois da reversão' as etapa,
       not exists (select 1 from public.prop_contratos ct
                    where not exists (select 1 from public.prop_contratantes k where k.id = ct.contratante_id)) as ok_contratos,
       not exists (select 1 from public.prop_confissoes cd
                    where not exists (select 1 from public.prop_contratantes k where k.id = cd.contratante_id)) as ok_confissoes,
       (select count(*) from pg_constraint where conname in ('prop_contratos_contratante_id_fkey','prop_confissoes_contratante_id_fkey')) = 2 as ok_fks_antigas,
       (select count(*) from pg_constraint where conname in ('prop_contratos_cliente_fkey','prop_confissoes_cliente_fkey')) = 0 as ok_fks_novas_removidas,
       position('prop_contratantes' in pg_get_functiondef('public.prop_contratos_numera'::regproc)) > 0 as ok_numera_ct,
       position('prop_contratantes' in pg_get_functiondef('public.prop_confissoes_numera'::regproc)) > 0 as ok_numera_cd,
       (select count(*) from pg_trigger where tgrelid in ('public.prop_contratos'::regclass, 'public.prop_confissoes'::regclass)
          and not tgisinternal and tgenabled <> 'O') = 0 as ok_gatilhos_religados,
       to_regprocedure('public.prop_cobranca_clientes(uuid,integer)') is null as ok_rpc_removida;

-- ---------------------------------------------------------------------
-- OPCIONAL — apaga também os dados novos (contatos e colunas do perfil).
-- Só rode se tiver certeza: os contatos e o enquadramento se perdem.
-- ---------------------------------------------------------------------
-- begin;
-- drop table if exists public.prop_clientes_contatos;
-- drop function if exists public.prop_clientes_contatos_guarda();
-- alter table public.prop_clientes
--   drop constraint if exists prop_clientes_matriz_fkey,
--   drop column if exists nome_fantasia, drop column if exists endereco, drop column if exists complemento,
--   drop column if exists bairro, drop column if exists cep, drop column if exists municipio, drop column if exists uf,
--   drop column if exists cnae, drop column if exists situacao_receita, drop column if exists rep_nome,
--   drop column if exists rep_cpf, drop column if exists rep_qualidade, drop column if exists rep_profissao,
--   drop column if exists rep_email, drop column if exists rep_celular, drop column if exists receita,
--   drop column if exists receita_em, drop column if exists regime, drop column if exists atividade,
--   drop column if exists apuracao, drop column if exists situacao, drop column if exists matriz_id,
--   drop column if exists codigo_questor, drop column if exists cob_cliente_id, drop column if exists departamentos,
--   drop column if exists nivel_atual, drop column if exists honorario_atual, drop column if exists honorario_ref,
--   drop column if exists honorario_origem, drop column if exists enquadramento;
-- drop table if exists prop_priv.migracao_v220_ref;
-- drop table if exists prop_priv.migracao_v220_ctt;
-- commit;

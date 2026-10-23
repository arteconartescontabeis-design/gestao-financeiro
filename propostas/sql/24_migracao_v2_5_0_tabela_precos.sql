-- =====================================================================
-- Artecon Propostas v2.5.0 — tabela de preços versionada
-- ---------------------------------------------------------------------
-- O que faz:
--   prop_tabelas_preco: uma linha por versão da tabela de preços, com a
--   data em que passa a valer (vigencia) e os valores em jsonb (dados):
--   preços do Essencial por regime/atividade/faixa, acréscimo de cada
--   nível, parâmetros (vínculo, filial, sem movimento, MEI, degraus acima
--   de 900 lançamentos, pouco movimento, escala de vínculos) e avulsos.
--   - Só o diretor grava. Versão gravada não muda: para mudar, grava-se
--     outra versão (a proposta guarda qual versão usou).
--   - Excluir (excluido_em) só versão que nenhuma proposta usou.
--   Os valores NÃO ficam neste arquivo (repositório público): entram pelo
--   app (Configurações › Tabela de preços › Importar planilha).
--
-- Exige: migrações 21 e 22. Idempotente. Reversão: 89_reversao_v2_5_0.sql
-- =====================================================================

-- 0. Estado antes
select 'antes' as etapa,
       to_regclass('public.prop_tabelas_preco') is not null as tabela_existe;

begin;

create table if not exists public.prop_tabelas_preco (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.prop_tenants(id),
  vigencia         date not null,
  descricao        text,
  dados            jsonb not null,
  criado_por       uuid,
  criado_por_email text,
  criado_em        timestamptz not null default now(),
  excluido_em      timestamptz,
  constraint prop_tp_dados_ck check (jsonb_typeof(dados) = 'object' and dados ? 'precos' and dados ? 'params' and dados ? 'acrescimos'),
  constraint prop_tp_desc_ck  check (descricao is null or length(descricao) <= 300)
);
create unique index if not exists prop_tp_vigencia_uk on public.prop_tabelas_preco (tenant_id, vigencia) where excluido_em is null;
comment on table public.prop_tabelas_preco is 'Tabela de preços por versão (v2.5.0). Vale a versão de maior vigência <= hoje, não excluída.';

-- guarda: só o diretor grava; versão gravada não muda; excluir só a que nenhuma proposta usou
create or replace function public.prop_tabelas_preco_guarda()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if tg_op = 'INSERT' then
    if not public.prop_sou_diretor(new.tenant_id) then
      raise exception 'PROP120: só o diretor grava a tabela de preços';
    end if;
    new.criado_por := auth.uid();
    new.criado_por_email := (select u.email from auth.users u where u.id = auth.uid());
    new.criado_em := now();
    new.excluido_em := null;
    return new;
  end if;
  if tg_op = 'DELETE' then
    raise exception 'PROP121: versão da tabela de preços não é apagada; use Excluir versão';
  end if;
  -- UPDATE: só marcar como excluída
  if (to_jsonb(new) - 'excluido_em') is distinct from (to_jsonb(old) - 'excluido_em')
     or old.excluido_em is not null or new.excluido_em is null then
    raise exception 'PROP122: versão gravada da tabela de preços não muda; grave uma versão nova';
  end if;
  if not public.prop_sou_diretor(old.tenant_id) then
    raise exception 'PROP120: só o diretor grava a tabela de preços';
  end if;
  if exists (select 1 from public.prop_propostas p
              where p.tenant_id = old.tenant_id and p.condicoes ->> 'tabela_preco_id' = old.id::text) then
    raise exception 'PROP123: esta versão já foi usada em proposta e não pode ser excluída';
  end if;
  new.excluido_em := now();
  return new;
end $$;
drop trigger if exists prop_tabelas_preco_guarda on public.prop_tabelas_preco;
create trigger prop_tabelas_preco_guarda before insert or update or delete on public.prop_tabelas_preco
  for each row execute function public.prop_tabelas_preco_guarda();
revoke all on function public.prop_tabelas_preco_guarda() from public;

alter table public.prop_tabelas_preco enable row level security;
drop policy if exists prop_tp_sel on public.prop_tabelas_preco;
drop policy if exists prop_tp_ins on public.prop_tabelas_preco;
drop policy if exists prop_tp_upd on public.prop_tabelas_preco;
create policy prop_tp_sel on public.prop_tabelas_preco for select to authenticated
  using (tenant_id in (select public.prop_meus_tenants()));
create policy prop_tp_ins on public.prop_tabelas_preco for insert to authenticated
  with check (tenant_id in (select public.prop_meus_tenants()));
create policy prop_tp_upd on public.prop_tabelas_preco for update to authenticated
  using (tenant_id in (select public.prop_meus_tenants())) with check (tenant_id in (select public.prop_meus_tenants()));
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on public.prop_tabelas_preco from anon';
    execute 'grant select, insert, update on public.prop_tabelas_preco to authenticated';
  end if;
end $$;

commit;

-- Verificação (todas as colunas "ok" devem vir true)
select 'depois' as etapa,
       to_regclass('public.prop_tabelas_preco') is not null as ok_tabela,
       (select count(*) from pg_policies where tablename = 'prop_tabelas_preco') = 3 as ok_politicas,
       exists (select 1 from pg_trigger where tgname = 'prop_tabelas_preco_guarda') as ok_guarda,
       (select relrowsecurity from pg_class where oid = 'public.prop_tabelas_preco'::regclass) as ok_rls;

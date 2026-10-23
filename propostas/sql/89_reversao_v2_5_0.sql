-- =====================================================================
-- Artecon Propostas — reversão da v2.5.0 (tabela de preços versionada)
-- ---------------------------------------------------------------------
-- Desfaz a 24_migracao_v2_5_0_tabela_precos.sql. A tabela só é apagada se
-- estiver vazia; com versões gravadas ela fica, sem acesso pelo app (a
-- migração 24 a reaproveita se for reaplicada). Idempotente.
-- =====================================================================

select 'antes' as etapa,
       to_regclass('public.prop_tabelas_preco') is not null as tabela_existe,
       exists (select 1 from pg_trigger where tgname = 'prop_tabelas_preco_guarda') as guarda;

begin;

do $$ begin
  if to_regclass('public.prop_tabelas_preco') is not null then
    if exists (select 1 from public.prop_tabelas_preco) then
      execute 'revoke all on public.prop_tabelas_preco from authenticated';
      raise notice 'prop_tabelas_preco tem versões gravadas: a tabela foi mantida, sem acesso pelo app';
    else
      execute 'drop table public.prop_tabelas_preco';
    end if;
  end if;
end $$;
drop function if exists public.prop_tabelas_preco_guarda() cascade;

commit;

select 'depois' as etapa,
       to_regprocedure('public.prop_tabelas_preco_guarda()') is null as ok_guarda,
       to_regclass('public.prop_tabelas_preco') is null
         or not has_table_privilege('authenticated', 'public.prop_tabelas_preco', 'select') as ok_tabela;

-- =====================================================================
-- Artecon Propostas — REVERSÃO da v2.3.0 (lotes)
-- ---------------------------------------------------------------------
-- Tira as travas e a função dos lotes, para o banco voltar a se comportar
-- como na v2.2.0. NÃO apaga dados: a tabela prop_lotes e a coluna
-- prop_propostas.lote_id ficam (a v2.2.0 não as usa). Para apagá-las,
-- rode o bloco OPCIONAL no fim. Idempotente.
-- Depois de reverter, suba de novo o index.html da v2.2.0.
-- =====================================================================

select 'antes da reversão' as etapa,
       to_regclass('public.prop_lotes') is not null as tabela_lotes,
       (select count(*) from pg_trigger where tgname in ('prop_lotes_guarda','prop_propostas_lote')) as gatilhos,
       to_regprocedure('public.prop_lote_descartar(uuid)') is not null as rpc;

begin;
drop trigger  if exists prop_propostas_lote on public.prop_propostas;
drop function if exists public.prop_propostas_lote();
drop function if exists public.prop_lote_descartar(uuid);
commit;

select 'depois da reversão' as etapa,
       (select count(*) from pg_trigger where tgname = 'prop_propostas_lote') = 0 as ok_gatilho_propostas,
       to_regprocedure('public.prop_lote_descartar(uuid)') is null as ok_rpc_removida;

-- ---------------------------------------------------------------------
-- OPCIONAL — apaga também os lotes e a ligação das propostas com eles.
-- As propostas continuam; só perdem a indicação do lote.
-- ---------------------------------------------------------------------
-- begin;
-- alter table public.prop_propostas drop constraint if exists prop_propostas_lote_fkey;
-- alter table public.prop_propostas drop column if exists lote_id;
-- drop table if exists public.prop_lotes;
-- drop function if exists public.prop_lotes_guarda();
-- commit;

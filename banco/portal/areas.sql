-- ESTRUTURA (18/10/2026, decisão do usuário): "Contábil" sem apps por enquanto; "Gestão Empresarial e Financeiro" com
-- Cobrança, Financeiro, Propostas, Agenda, Patrimonial e Carreira. Só nomes e área dos apps — ids das áreas não mudam.
-- Volta: areas_volta.sql.
update core.areas set nome = 'Contábil' where id = 'contabil_financeiro';
update core.areas set nome = 'Gestão Empresarial e Financeiro' where id = 'gestao';
update core.apps set area_id = 'gestao', atualizado_em = now() where id in ('cobranca', 'financeiro');
select a.id, a.nome, (select string_agg(x.id, ', ' order by x.ordem) from core.apps x where x.area_id = a.id) as apps
  from core.areas a where a.id in ('contabil_financeiro', 'gestao');

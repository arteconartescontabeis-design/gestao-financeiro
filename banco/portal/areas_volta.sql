-- VOLTA ATRÁS · áreas como eram antes de 18/10/2026.
update core.areas set nome = 'Contábil e Financeiro' where id = 'contabil_financeiro';
update core.areas set nome = 'Gestão Empresarial' where id = 'gestao';
update core.apps set area_id = 'contabil_financeiro', atualizado_em = now() where id in ('cobranca', 'financeiro');

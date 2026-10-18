-- VIRADA · Portal (banco do Departamento Pessoal / fbxelwhdiisfmnwrerbl, schema core)
-- Gestão Empresarial e Financeiro: apps nos endereços novos. Rodar por app, na virada de cada um
-- (Carreira, Patrimonial e Financeiro só junto com a mudança de banco deles). Volta: volta_destinos.sql.
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/gestao-financeiro/cobranca-pro/',    atualizado_em = now() where id = 'cobranca';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/gestao-financeiro/propostas/',       atualizado_em = now() where id = 'propostas';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/gestao-financeiro/agenda-pro/',      atualizado_em = now() where id = 'agenda';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/gestao-financeiro/patrimonial-pro/', atualizado_em = now() where id = 'patrimonial';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/gestao-financeiro/financeiro-pro/',  atualizado_em = now() where id = 'financeiro';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/gestao-financeiro/carreira-pro/',    atualizado_em = now() where id = 'carreira';
select id, area_id, destino_url from core.apps where area_id in ('gestao','contabil_financeiro') order by area_id, ordem;

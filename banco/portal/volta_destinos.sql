-- VOLTA ATRÁS · Portal — apps da Gestão/Financeiro de volta aos endereços antigos.
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/cobranca-pro/',    atualizado_em = now() where id = 'cobranca';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/propostas/',       atualizado_em = now() where id = 'propostas';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/agenda-pro/',      atualizado_em = now() where id = 'agenda';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/patrimonial-pro/', atualizado_em = now() where id = 'patrimonial';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/financeiro-pro/',  atualizado_em = now() where id = 'financeiro';
update core.apps set destino_url = 'https://arteconartescontabeis-design.github.io/carreira-pro/',    atualizado_em = now() where id = 'carreira';
select id, area_id, destino_url from core.apps where area_id in ('gestao','contabil_financeiro') order by area_id, ordem;

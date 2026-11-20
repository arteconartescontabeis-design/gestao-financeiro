-- ============================================================
-- Cobrança Pro v2.20.0 — a view do Painel passa a informar a empresa
-- Rodar DEPOIS da migration_v2_19_0_multiempresa.sql.
-- Pode rodar mais de uma vez (idempotente).
--
-- A coluna nova (empresa_id) entra no FIM da view — a ordem das
-- colunas existentes não muda. security_invoker continua true,
-- então a RLS das tabelas de origem segue valendo.
-- ============================================================

create or replace view public.cob_parcelas_abertas_com_encargos
with (security_invoker = true) as
 select p.id,
        p.tenant_id,
        p.cliente_id,
        p.nosso_numero,
        p.valor_original,
        p.data_vencimento,
        p.status,
        c.razao_social,
        c.email,
        c.cnpj,
        c.telefone,
        (current_date - p.data_vencimento) as dias_atraso,
        (select e.valor_atualizado
           from public.cob_atualizar_valor(p.valor_original, p.data_vencimento)
                e(valor_original, multa, juros, correcao, valor_atualizado, dias_atraso, memoria_json)) as valor_atualizado,
        p.empresa_id                                   -- v2.20.0: empresa dona do boleto
   from public.cob_parcelas p
   join public.cob_clientes c on c.id = p.cliente_id
  where p.status = 'aberta' and p.data_vencimento < current_date;

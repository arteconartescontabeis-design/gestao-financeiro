-- ============================================================
-- Cobrança Pro v2.21.0 (parte A) — índice do nosso número POR EMPRESA
-- Rodar ANTES de publicar o index.html v2.21.0. Idempotente.
--
-- Cria o índice único (tenant, empresa, nosso número) MANTENDO o índice
-- antigo (tenant, nosso número). Com os dois existindo:
--   · o app antigo (v2.20) continua funcionando (upsert pelo índice antigo);
--   · o app novo (v2.21) já usa o índice novo.
-- O índice antigo só é removido pela migration_v2_21_1 (parte B),
-- DEPOIS que o v2.21.0 estiver publicado — aí o mesmo nosso número
-- pode existir em empresas diferentes sem um baixar o boleto do outro.
-- ============================================================

create unique index if not exists cob_parcelas_tenant_empresa_nosso_uk
  on public.cob_parcelas (tenant_id, empresa_id, nosso_numero);

comment on index public.cob_parcelas_tenant_empresa_nosso_uk is
  'v2.21.0: unicidade do nosso número por empresa (upsert das importações).';

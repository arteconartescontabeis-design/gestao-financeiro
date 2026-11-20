-- ============================================================
-- Cobrança Pro v2.21.0 (parte B) — solta o índice antigo do nosso número
-- Rodar SÓ DEPOIS que o index.html v2.21.0 estiver publicado e os
-- usuários tiverem recarregado o app (o app v2.20 depende do índice
-- antigo para o upsert das importações; o v2.21 já usa o novo).
-- Idempotente.
--
-- Depois desta migration, o mesmo nosso número pode existir em
-- empresas diferentes (convênios bancários distintos) sem conflito.
-- ============================================================

alter table public.cob_parcelas
  drop constraint if exists cob_parcelas_tenant_id_nosso_numero_key;

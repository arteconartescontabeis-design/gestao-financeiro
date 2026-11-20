-- ============================================================
-- Cobrança Pro v2.22.0 — integração Questor Negócio (modo paralelo)
-- Rodar no SQL Editor do Supabase. Idempotente.
--
-- 1) Execuções ganham a origem 'questor_api' (painel do robô e aba Erros
--    mostram as capturas da API separadas das do robô e das do app).
-- 2) O cofre (segredo_servico) passa a poder entregar à Edge Function
--    questor-sync a chave 'questor_api_key' e, opcionalmente, o endereço
--    'questor_api_url'. Os VALORES ficam só no Vault (Dashboard →
--    Integrations → Vault), nunca em código ou mensagem.
--    Registrar a mudança da lista no repositório artecon-supabase
--    (docs/DECISOES.md), como manda a regra de 20/10/2026.
-- ============================================================

-- ── 1) origem 'questor_api' nas execuções ───────────────────
alter table public.cob_automacao_execucoes
  drop constraint if exists cob_automacao_execucoes_origem_check;
alter table public.cob_automacao_execucoes
  add constraint cob_automacao_execucoes_origem_check
  check (origem = any (array['robo'::text, 'app'::text, 'questor_api'::text]));

-- ── 2) cofre: chaves da API do Questor Negócio na lista fechada ──
create or replace function public.segredo_servico(p_nome text)
 returns text
 language sql
 stable security definer
 set search_path to ''
as $function$
  select s.decrypted_secret from vault.decrypted_secrets s
   where s.name = p_nome and p_nome = any (array[
     'mail_hub_key_cobranca', 'mail_hub_key_propostas', 'ia_gateway_token_financeiro',
     'questor_api_key', 'questor_api_url'])
$function$;

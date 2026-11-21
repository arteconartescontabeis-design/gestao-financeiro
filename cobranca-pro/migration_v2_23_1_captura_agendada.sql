-- ============================================================
-- Cobrança Pro v2.23.1 — captura paralela agendada + alerta por e-mail
-- Rodar no SQL Editor do Supabase. Idempotente.
--
-- 1) Token interno da agenda ('questor_cron_token'): gerado AQUI, direto
--    no cofre (ninguém vê o valor). A agenda do banco manda esse token à
--    função questor-sync, que só aceita a ação 'capturar' (paralelo,
--    só leitura) por esse caminho — a fonte única continua só pelo diretor.
-- 2) A lista fechada do cofre (segredo_servico) passa a incluir o token.
-- 3) E-mail de alerta (cob_automacao_config.questor_alerta_email): recebe
--    um aviso quando a captura encontrar "liquidada no banco × aberta no
--    app", divergência de valor ou erro. Só aceita @artecon.cnt.br.
-- 4) Agenda (pg_cron): todo dia às 07:35 e 13:35 (horário de Brasília).
-- ============================================================

-- ── 1) token da agenda no cofre (gerado no servidor) ────────
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'questor_cron_token') then
    perform vault.create_secret(encode(gen_random_bytes(32), 'hex'), 'questor_cron_token',
      'Cobrança Pro v2.23.1: token interno da captura agendada (questor-sync)');
  end if;
end $$;

-- ── 2) lista fechada do cofre ───────────────────────────────
create or replace function public.segredo_servico(p_nome text)
 returns text
 language sql
 stable security definer
 set search_path to ''
as $function$
  select s.decrypted_secret from vault.decrypted_secrets s
   where s.name = p_nome and p_nome = any (array[
     'mail_hub_key_cobranca', 'mail_hub_key_propostas', 'ia_gateway_token_financeiro',
     'questor_api_key', 'questor_api_url', 'questor_cron_token'])
$function$;

-- ── 3) e-mail de alerta ─────────────────────────────────────
alter table public.cob_automacao_config
  add column if not exists questor_alerta_email text;
comment on column public.cob_automacao_config.questor_alerta_email is
  'v2.23.1: destino do alerta da captura Questor (só @artecon.cnt.br); vazio = sem alerta.';
update public.cob_automacao_config
   set questor_alerta_email = 'cleiver@artecon.cnt.br'
 where questor_alerta_email is null;

-- ── 4) agenda: captura paralela às 07:35 e 13:35 (Brasília = 10:35/16:35 UTC) ──
do $$ begin
  perform cron.unschedule('questor-captura-paralela');
exception when others then null; end $$;

select cron.schedule('questor-captura-paralela', '35 10,16 * * *', $cron$
  select net.http_post(
    url := 'https://yeujqjtjqtegsnzwwazb.supabase.co/functions/v1/questor-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      -- a anon key é pública (a mesma do index.html); serve só para passar no portão da função
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlldWpxanRqcXRlZ3Nuend3YXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1NDE0OTksImV4cCI6MjEwMTExNzQ5OX0.5p1_wJ_aApJpRrN6tFu8qmAytK5FMXWt1soCubpzqao',
      'x-cron-token', (select decrypted_secret from vault.decrypted_secrets where name = 'questor_cron_token')
    ),
    body := jsonb_build_object('acao', 'capturar',
      'tenant_id', (select id::text from public.cob_tenants where ativo limit 1)),
    timeout_milliseconds := 240000
  );
$cron$);

-- ============================================================
-- Cobrança Pro v2.23.2 — horários definidos pelo usuário (21/11/2026)
-- Já aplicada no banco em 21/11/2026 (registro: este arquivo documenta o que rodou).
-- Idempotente — pode rodar de novo sem efeito colateral.
--
-- 1) Captura da integração Questor: 10:00 e 16:00 (Brasília) = 13:00/19:00 UTC.
--    A captura agendada NÃO envia e-mail (questor-sync v1.5) — só registra.
-- 2) Alerta por e-mail: 10:30 (Brasília) = 13:30 UTC, ação nova 'alertar' da
--    questor-sync v1.5: lê a última captura registrada e envia e-mail SÓ se
--    houver "liquidada no banco × aberta no app", divergência de valor ou erro.
-- 3) Robô do ARTEAPP01 "desativado até segunda ordem": pelo app, o ciclo cai
--    para 1×/dia às 03:00 (fora do horário comercial). A DESATIVAÇÃO TOTAL é
--    no servidor ARTEAPP01 (Agendador de Tarefas → desabilitar a tarefa
--    "Artecon Robo Cobranca" e fechar a janela do vigia) — fora deste banco.
-- 4) Aviso de boleto a vencer: parâmetro em 5 dias. O duplo aviso automático
--    (5 dias E 1 dia antes do vencimento) entra na v2.24.
-- Janela de envio de cobranças: continua 08:00–20:00 (nada muda aqui).
-- ============================================================

-- ── 1) captura paralela às 10:00 e 16:00 de Brasília (13:00/19:00 UTC) ──
do $$ begin
  perform cron.unschedule('questor-captura-paralela');
exception when others then null; end $$;

select cron.schedule('questor-captura-paralela', '0 13,19 * * *', $cron$
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

-- ── 2) alerta diário às 10:30 de Brasília (13:30 UTC) ──
do $$ begin
  perform cron.unschedule('questor-alerta-diario');
exception when others then null; end $$;

select cron.schedule('questor-alerta-diario', '30 13 * * *', $cron$
  select net.http_post(
    url := 'https://yeujqjtjqtegsnzwwazb.supabase.co/functions/v1/questor-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlldWpxanRqcXRlZ3Nuend3YXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1NDE0OTksImV4cCI6MjEwMTExNzQ5OX0.5p1_wJ_aApJpRrN6tFu8qmAytK5FMXWt1soCubpzqao',
      'x-cron-token', (select decrypted_secret from vault.decrypted_secrets where name = 'questor_cron_token')
    ),
    body := jsonb_build_object('acao', 'alertar',
      'tenant_id', (select id::text from public.cob_tenants where ativo limit 1)),
    timeout_milliseconds := 60000
  );
$cron$);

-- ── 3) aviso de boleto a vencer: 5 dias (o duplo aviso 5+1 é a v2.24) ──
update public.cob_politicas set dias_aviso_boleto_vencimento = 5;

-- ── 4) robô do ARTEAPP01 reduzido a 1×/dia de madrugada (mitigação pelo app) ──
update public.cob_automacao_config
   set robo_intervalo_min = 1440,
       robo_hora_base = '03:00';

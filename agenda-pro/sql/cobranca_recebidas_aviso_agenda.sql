-- ============================================================
-- WHATSAPP — AVISO IMEDIATO AO AGENDA (lado do Cobrança Pro)
-- Projeto Supabase do Cobrança: yeujqjtjqtegsnzwwazb
-- Aplicado em 10/10/2026.
--
-- Antes, o Agenda só lia as mensagens recebidas quando o pg_cron chamava a
-- função agenda-whats (a cada 30 s). Agora, assim que o serviço artecon-whats
-- grava uma mensagem em cob_whatsapp_recebidas, este gatilho chama a função
-- na hora (pg_net, sem esperar). O pg_cron continua como reserva.
--
-- Chamar a função várias vezes é seguro: o id único de cada mensagem
-- recebida (agenda_whats_comandos.recebida_id) impede agendar em dobro.
-- A chave usada é a pública (anon) do projeto do Agenda, a mesma do app.
-- Um erro aqui nunca impede a gravação da mensagem.
-- ============================================================

create or replace function public.cob_recebida_avisar_agenda()
returns trigger language plpgsql security definer
set search_path = public, extensions
as $$
begin
  if exists (select 1 from public.cob_agenda_integracao where ativo and tenant_id = new.tenant_id) then
    perform net.http_post(
      url := 'https://vuwgxndahrzinfdlapxz.supabase.co/functions/v1/agenda-whats',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ1d2d4bmRhaHJ6aW5mZGxhcHh6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ3NTA0ODgsImV4cCI6MjA5MDMyNjQ4OH0.9DaPGHIxt0CO-pjYPBwsHaoSqDN35CwVU0lJUyTXQIQ'),
      body := jsonb_build_object('origem', 'recebida', 'recebida_id', new.id),
      timeout_milliseconds := 60000);
  end if;
  return null;
exception when others then
  return null;
end $$;

revoke all on function public.cob_recebida_avisar_agenda() from public, anon, authenticated;

create or replace trigger trg_recebida_avisar_agenda
  after insert on public.cob_whatsapp_recebidas
  for each row execute function public.cob_recebida_avisar_agenda();

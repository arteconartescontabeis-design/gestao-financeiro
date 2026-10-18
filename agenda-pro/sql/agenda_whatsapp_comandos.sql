-- ============================================================
-- AGENDA PRO — agendar por mensagem de WhatsApp (só equipe)
-- Projeto Supabase do Agenda: vuwgxndahrzinfdlapxz
--
-- Quem da equipe tiver o WhatsApp no cadastro (agenda_usuarios.whatsapp)
-- pode mandar para o número da Artecon, por exemplo:
--   agendar Maria Souza amanhã 10h reunião
--   agenda hoje        (lista os agendamentos do dia)
--   cancelar           (desfaz o último agendado por mensagem)
--   ajuda
-- A Edge Function agenda-whats lê as mensagens (cob_agenda_recebidas, no
-- projeto do Cobrança), interpreta, cria o agendamento e responde.
-- Mensagens de outros números (clientes) nunca chegam ao Agenda.
-- ============================================================

alter table public.agenda_usuarios add column if not exists whatsapp text;

create table if not exists public.agenda_whats_comandos (
  id              bigserial primary key,
  tenant_id       bigint not null references public.agenda_tenants(id) on delete cascade,
  usuario_id      bigint references public.agenda_usuarios(id) on delete set null,
  recebida_id     bigint not null unique,      -- id em cob_whatsapp_recebidas (Cobrança)
  telefone        text not null,
  texto           text not null,
  acao            text,                         -- agendar | listar | cancelar | ajuda | desconhecido
  status          text not null default 'processando'
                  check (status in ('processando','feito','pergunta','erro','ignorado')),
  agendamento_id  bigint references public.agenda_agendamentos(id) on delete set null,
  resposta        text,
  fila_id         bigint,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
create index if not exists agenda_whats_comandos_tenant_ix on public.agenda_whats_comandos (tenant_id, id desc);
alter table public.agenda_whats_comandos enable row level security;
create policy whats_comandos_select on public.agenda_whats_comandos
  for select using (tenant_id = public.agenda_meu_tenant_id());

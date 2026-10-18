-- ============================================================
-- REVISÃO DE SEGURANÇA — 12/10/2026 (aplicado nesta data)
-- Nada foi apagado: só permissões fechadas, visões e regras ajustadas.
-- ============================================================

-- ------------------------------------------------------------
-- 1) PROJETO DO AGENDA (vuwgxndahrzinfdlapxz)
-- ------------------------------------------------------------
-- 1a) GRAVE: as visões agenda_v_* eram SECURITY DEFINER e liberadas para a chave
--     pública (anon). Sem login, dava para ler todos os agendamentos de todos os
--     escritórios (cliente, e-mail, CPF/CNPJ, observação interna). Nenhuma tela usa
--     essas visões. Agora valem as regras (RLS) de quem consulta, e sem login não abrem.
alter view public.agenda_v_agendamentos set (security_invoker = true);
alter view public.agenda_v_hoje set (security_invoker = true);
alter view public.agenda_v_noshow_por_cliente set (security_invoker = true);
revoke all on public.agenda_v_agendamentos, public.agenda_v_hoje, public.agenda_v_noshow_por_cliente from anon;

-- 1b) Não existe página pública de agendamento: as regras para quem não está logado
--     (criar agendamento em qualquer escritório, ler bloqueios e horários de todos)
--     passam a não liberar nada. Ficam no banco (para religar, se um dia houver a página).
alter policy ag_anon_insert_link_publico on public.agenda_agendamentos with check (false);
alter policy bloq_anon_select on public.agenda_bloqueios using (false);
alter policy disp_anon_select on public.agenda_disponibilidade using (false);

-- 1c) Gerente cadastra colaborador, visualizador e gerente; administrador, só outro administrador
--     (a função agenda-equipe já fazia isso, mas o cadastro direto pela API não).
alter policy usuarios_insert_admin on public.agenda_usuarios
  with check ((tenant_id = agenda_meu_tenant_id())
              and (agenda_meu_perfil() = 'admin' or (agenda_meu_perfil() = 'gerente' and perfil <> 'admin')));

-- 1d) Caminho de busca fixo nas funções do Agenda
alter function public.agenda_meu_tenant_id() set search_path = public;
alter function public.agenda_meu_perfil() set search_path = public;
alter function public.agenda_meu_usuario_id() set search_path = public;
alter function public.agenda_atualizar_score_noshow() set search_path = public;
alter function public.agenda_registrar_historico_status() set search_path = public;
alter function public.agenda_set_atualizado_em() set search_path = public;
alter function public.agenda_slots_disponiveis(bigint, bigint, date, integer) set search_path = public;
alter function public.agenda_verificar_conflito(bigint, bigint, timestamp with time zone, timestamp with time zone, bigint) set search_path = public;

-- ------------------------------------------------------------
-- 2) NÚCLEO DO PORTAL (fbxelwhdiisfmnwrerbl)
-- ------------------------------------------------------------
-- 2a) GRAVE: enviar_email e cct_email_db mandavam e-mail pelo hub artecon-mail para
--     qualquer endereço, chamadas sem login. Agora só o próprio banco (cron, heartbeat)
--     e a chave de serviço. O mesmo para as listas de e-mail dos gerentes.
revoke execute on function public.enviar_email(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.cct_email_db(uuid, text[], text, text, text) from public, anon, authenticated;
revoke execute on function public.cct_emails_gerentes(uuid) from public, anon, authenticated;
revoke execute on function public.cct_emails_erros_criticos(uuid) from public, anon, authenticated;
grant execute on function public.enviar_email(text, text, text, text, text) to service_role;
grant execute on function public.cct_email_db(uuid, text[], text, text, text) to service_role;
grant execute on function public.cct_emails_gerentes(uuid) to service_role;
grant execute on function public.cct_emails_erros_criticos(uuid) to service_role;
alter function public.enviar_email(text, text, text, text, text) set search_path = public;

-- 2b) Funções do robô do CCT e de apoio: fechadas sem login. O robô usa a chave de
--     serviço (conferido nos registros) e as telas usam login.
do $$
declare f text;
begin
  foreach f in array array[
    'public.cct_registrar_incidente(uuid, text, text, text, text, uuid, uuid, jsonb)',
    'public.cct_resolver_incidente(uuid, text, text)',
    'public.cct_execucao_encerrar(uuid, text, text, jsonb)',
    'public.cct_enfileirar_historico(uuid)',
    'public.cct_saude_robo(uuid, timestamp with time zone)',
    'public.cct_sugerir_lote(uuid)',
    'public.cct_sugerir_sindicatos(uuid, text, text, text)',
    'public.cct_horarios(uuid)',
    'public.cct_ia_uso_mes(uuid)',
    'public.cct_verificar_heartbeat(timestamp with time zone)',
    'public.cct_verificar_heartbeat(integer)',
    'public.cct_anterior(uuid)',
    'public.cct_adicionar_dias_uteis(date, integer)',
    'public.cct_instrumentos_da_empresa()'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

alter function core.ia_ini_mes(timestamp with time zone) set search_path = core, public;
alter function core.ia_ini_dia(timestamp with time zone) set search_path = core, public;

-- 2c) Avisos de cota da Azure: ver sql/nucleo_ia_fala_avisos.sql

-- 2d) (aplicado no fim do dia) cct_deduplicar_por_cnpj junta e apaga empresas/sindicatos repetidos de TODOS os
--     escritórios e não conferia quem chama (abria sem login). Agora só pelo editor SQL ou pela chave de serviço.
--     cct_execucao_iniciar é do robô (só a chave de serviço chama, conferido nos registros).
revoke execute on function public.cct_deduplicar_por_cnpj(text) from public, anon, authenticated;
grant execute on function public.cct_deduplicar_por_cnpj(text) to service_role;
revoke execute on function public.cct_execucao_iniciar(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.cct_execucao_iniciar(text, text, text, text, text) to service_role;

-- ------------------------------------------------------------
-- 3) COBRANÇA (yeujqjtjqtegsnzwwazb)
-- ------------------------------------------------------------
alter function public.cob_fone_chave(text) set search_path = public;
-- As funções cob_agenda_* abertas à chave pública são de propósito: só funcionam com o token do cofre.

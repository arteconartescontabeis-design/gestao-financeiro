-- ============================================================
-- MINUTOS DE ÁUDIO (AZURE) NO "CONSUMO DE IA" DO PORTAL
-- Projeto Supabase do NÚCLEO do portal: fbxelwhdiisfmnwrerbl (schema core)
-- Aplicado em 11/10/2026.
--
-- A IA Central (ia-gateway, core.ia_uso) só conhece Anthropic e OpenAI, cobradas
-- em dólar por chamada. A transcrição de áudio da Azure é outra coisa: o serviço
-- do WhatsApp chama a Azure direto, e o plano gratuito (F0) dá 5 h por mês para
-- o recurso inteiro (artecon-voz), sem cobrança — passando disso a Azure recusa
-- até o mês seguinte. Por isso o uso fica em tabelas próprias, em segundos, e o
-- portal mostra um quadro separado na tela Consumo de IA. Nada da IA Central
-- existente foi alterado.
--
-- Quem informa: a função agenda-whats (projeto do Agenda), depois de tratar um
-- áudio que o serviço do WhatsApp transcreveu (cob_whatsapp_recebidas.audio_seg),
-- chama public.ia_fala_registrar com o token do aplicativo (cofre do projeto do
-- Agenda: ia_fala_token). O núcleo guarda só o hash do token.
--
-- Trocar o token do Agenda (se um dia precisar):
--   1) no projeto do Agenda:
--        select vault.update_secret((select id from vault.secrets where name = 'ia_fala_token'),
--                                   'iafala_agenda_' || encode(extensions.gen_random_bytes(24), 'hex'));
--        select encode(extensions.digest(decrypted_secret, 'sha256'), 'hex')
--          from vault.decrypted_secrets where name = 'ia_fala_token';
--   2) aqui no núcleo: update core.ia_fala_apps set token_hash = '<hash>', token_criado_em = now() where app = 'agenda';
-- ============================================================

create table if not exists core.ia_fala_apps (
  app             text primary key check (app ~ '^[a-z0-9_]{2,30}$'),
  nome            text not null,
  token_hash      text unique,                  -- sha256 do token; o token fica no cofre do projeto do aplicativo
  token_criado_em timestamptz,
  criado_em       timestamptz not null default now()
);

create table if not exists core.ia_fala_uso (
  id        bigint generated always as identity primary key,
  em        timestamptz not null default now(),
  app       text not null references core.ia_fala_apps(app),
  usuario   text,                                -- nome da pessoa da equipe
  segundos  integer not null check (segundos between 0 and 3600),
  ref       text,                                -- id da origem (ex.: whats:123), para não contar duas vezes
  detalhe   text
);
create unique index if not exists ia_fala_uso_ref on core.ia_fala_uso (app, ref);
create index if not exists ia_fala_uso_em on core.ia_fala_uso (em);

alter table core.ia_fala_apps enable row level security;   -- sem políticas: só as funções abaixo leem e gravam
alter table core.ia_fala_uso  enable row level security;
revoke all on core.ia_fala_apps, core.ia_fala_uso from anon, authenticated;

insert into core.ia_fala_apps (app, nome) values ('agenda', 'Agenda — áudios do WhatsApp')
on conflict (app) do nothing;

-- Chamada pelo aplicativo (chave pública do núcleo + token do aplicativo). Fica em public porque o
-- schema core não é aberto para a chave pública.
create or replace function public.ia_fala_registrar(p_token text, p_segundos integer, p_ref text default null,
                                                    p_usuario text default null, p_detalhe text default null)
returns jsonb language plpgsql security definer set search_path = core, public as $$
declare a core.ia_fala_apps; v_total bigint;
begin
  select * into a from core.ia_fala_apps
   where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found then raise exception 'token inválido' using errcode = '28000'; end if;
  insert into core.ia_fala_uso (app, usuario, segundos, ref, detalhe)
  values (a.app, left(p_usuario, 120), least(greatest(coalesce(p_segundos, 0), 0), 3600), left(p_ref, 120), left(p_detalhe, 300))
  on conflict (app, ref) do nothing;
  select coalesce(sum(segundos), 0) into v_total from core.ia_fala_uso where em >= core.ia_ini_mes();
  return jsonb_build_object('ok', true, 'app', a.app, 'segundos_mes_total', v_total);
end $$;
revoke all on function public.ia_fala_registrar(text, integer, text, text, text) from public;
grant execute on function public.ia_fala_registrar(text, integer, text, text, text) to anon, authenticated, service_role;

-- Quadro "Transcrição de áudio" da tela Consumo de IA (só administradores da IA Central).
create or replace function core.ia_fala_painel(p_mes date default null)
returns jsonb language plpgsql stable security definer set search_path = core, public as $$
declare
  v_ref  date := date_trunc('month', coalesce(p_mes, (now() at time zone 'America/Sao_Paulo')::date))::date;
  v_ini  timestamptz := v_ref::timestamp at time zone 'America/Sao_Paulo';
  v_fim  timestamptz := (v_ref + interval '1 month')::timestamp at time zone 'America/Sao_Paulo';
  v_hoje timestamptz := core.ia_ini_dia();
begin
  perform core.ia_exigir_admin();
  return jsonb_build_object(
    'mes', to_char(v_ref, 'YYYY-MM'),
    'franquia_seg', 18000,                         -- plano F0 da Azure: 5 h de transcrição por mês, para o recurso inteiro
    'recurso', 'artecon-voz (Azure, plano gratuito F0)',
    'total_seg',  (select coalesce(sum(u.segundos), 0) from core.ia_fala_uso u where u.em >= v_ini and u.em < v_fim),
    'total_hoje', (select coalesce(sum(u.segundos), 0) from core.ia_fala_uso u where u.em >= v_hoje),
    'apps', coalesce((
      select jsonb_agg(jsonb_build_object(
               'app', a.app, 'nome', a.nome, 'tem_token', a.token_hash is not null, 'token_criado_em', a.token_criado_em,
               'segundos_mes',  (select coalesce(sum(u.segundos), 0) from core.ia_fala_uso u where u.app = a.app and u.em >= v_ini and u.em < v_fim),
               'segundos_hoje', (select coalesce(sum(u.segundos), 0) from core.ia_fala_uso u where u.app = a.app and u.em >= v_hoje),
               'audios_mes',    (select count(*) from core.ia_fala_uso u where u.app = a.app and u.em >= v_ini and u.em < v_fim),
               'ultimo_uso',    (select max(u.em) from core.ia_fala_uso u where u.app = a.app)
             ) order by a.nome)
        from core.ia_fala_apps a), '[]'::jsonb)
  );
end $$;
revoke all on function core.ia_fala_painel(date) from public, anon;
grant execute on function core.ia_fala_painel(date) to authenticated;

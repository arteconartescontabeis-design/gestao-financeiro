-- ============================================================
-- AZURE (artecon-voz) NO "CONSUMO DE IA" — v2: VOZ E LANÇAMENTOS
-- Projeto Supabase do NÚCLEO do portal: fbxelwhdiisfmnwrerbl (schema core)
-- Aplicado em 11/10/2026. Continuação de sql/nucleo_ia_fala.sql.
--
-- O recurso artecon-voz (plano gratuito F0) tem duas cotas por mês, cada uma
-- para o recurso inteiro:
--   transcrição (fala → texto): 5 h  → Agenda (áudios da equipe no WhatsApp)
--   voz (texto → fala):     500 mil caracteres → Projeto Criança (voz da Sarah),
--                                               Estudo da Reforma do Agenda
-- O Agenda informa a transcrição sozinho (public.ia_fala_registrar). A voz é
-- gerada de vez em quando (pelo Claude, com a CHAVE 1): o uso entra por
-- lançamento no portal (core.ia_fala_lancar) — ao gerar falas novas, lançar
-- os caracteres. Cada aplicativo vira um cartão em "Por aplicativo".
-- ============================================================

alter table core.ia_fala_apps add column if not exists tipo text not null default 'transcricao'
  check (tipo in ('transcricao', 'voz'));
alter table core.ia_fala_apps add column if not exists descricao text;

alter table core.ia_fala_uso add column if not exists tipo text not null default 'transcricao'
  check (tipo in ('transcricao', 'voz'));
alter table core.ia_fala_uso add column if not exists caracteres integer not null default 0
  check (caracteres between 0 and 10000000);
alter table core.ia_fala_uso add column if not exists lancado_por text;   -- e-mail de quem lançou à mão (null = o aplicativo informou)
alter table core.ia_fala_uso add column if not exists cancelado_em timestamptz;   -- lançamento desfeito: fica guardado, fora das somas

update core.ia_fala_apps set descricao = 'Áudios da equipe no WhatsApp (fala → texto)'
 where app = 'agenda' and descricao is null;
insert into core.ia_fala_apps (app, nome, tipo, descricao) values
  ('crianca', 'Projeto Criança — voz da Sarah', 'voz', 'Falas do jogo nas vozes Francisca e Ava (texto → fala)'),
  ('estudo',  'Agenda — Estudo da Reforma',     'voz', 'Narração das faixas na voz Francisca (texto → fala)')
on conflict (app) do nothing;

-- Lançamento à mão (só administradores da IA Central). p_quantidade: segundos (transcrição) ou caracteres (voz).
create or replace function core.ia_fala_lancar(p_app text, p_quantidade integer, p_detalhe text default null,
                                               p_em timestamptz default null)
returns jsonb language plpgsql security definer set search_path = core, public as $$
declare a core.ia_fala_apps; v_id bigint;
begin
  perform core.ia_exigir_admin();
  select * into a from core.ia_fala_apps where app = p_app;
  if not found then raise exception 'Aplicativo % não encontrado.', p_app; end if;
  if coalesce(p_quantidade, 0) <= 0 then raise exception 'Informe uma quantidade maior que zero.'; end if;
  if a.tipo = 'transcricao' and p_quantidade > 3600 then raise exception 'No máximo 3.600 segundos por lançamento.'; end if;
  insert into core.ia_fala_uso (app, tipo, segundos, caracteres, detalhe, em, lancado_por)
  values (a.app, a.tipo,
          case when a.tipo = 'transcricao' then p_quantidade else 0 end,
          case when a.tipo = 'voz' then p_quantidade else 0 end,
          left(p_detalhe, 300), coalesce(p_em, now()), core.ia_email_atual())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function core.ia_fala_lancar(text, integer, text, timestamptz) from public, anon;
grant execute on function core.ia_fala_lancar(text, integer, text, timestamptz) to authenticated;

-- Desfaz um lançamento feito à mão: marca como cancelado (nada é apagado; os informados pelo aplicativo não mudam).
create or replace function core.ia_fala_desfazer(p_id bigint)
returns jsonb language plpgsql security definer set search_path = core, public as $$
begin
  perform core.ia_exigir_admin();
  update core.ia_fala_uso set cancelado_em = now() where id = p_id and lancado_por is not null and cancelado_em is null;
  if not found then raise exception 'Lançamento não encontrado (só os lançados à mão podem ser desfeitos).'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function core.ia_fala_desfazer(bigint) from public, anon;
grant execute on function core.ia_fala_desfazer(bigint) to authenticated;

-- Painel: as duas cotas e um cartão por aplicativo (mantém os campos da v1 para o portal v1.6.0).
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
    'recurso', 'artecon-voz (Azure, plano gratuito F0)',
    'franquia_seg', 18000,                         -- transcrição: 5 h por mês
    'franquia_caracteres', 500000,                 -- voz: 500 mil caracteres por mês
    'total_seg',  (select coalesce(sum(u.segundos), 0) from core.ia_fala_uso u where u.cancelado_em is null and u.em >= v_ini and u.em < v_fim),
    'total_hoje', (select coalesce(sum(u.segundos), 0) from core.ia_fala_uso u where u.cancelado_em is null and u.em >= v_hoje),
    'total_caracteres', (select coalesce(sum(u.caracteres), 0) from core.ia_fala_uso u where u.cancelado_em is null and u.em >= v_ini and u.em < v_fim),
    'total_caracteres_hoje', (select coalesce(sum(u.caracteres), 0) from core.ia_fala_uso u where u.cancelado_em is null and u.em >= v_hoje),
    'apps', coalesce((
      select jsonb_agg(jsonb_build_object(
               'app', a.app, 'nome', a.nome, 'tipo', a.tipo, 'descricao', a.descricao,
               'tem_token', a.token_hash is not null, 'token_criado_em', a.token_criado_em,
               'segundos_mes',  (select coalesce(sum(u.segundos), 0) from core.ia_fala_uso u where u.cancelado_em is null and u.app = a.app and u.em >= v_ini and u.em < v_fim),
               'segundos_hoje', (select coalesce(sum(u.segundos), 0) from core.ia_fala_uso u where u.cancelado_em is null and u.app = a.app and u.em >= v_hoje),
               'caracteres_mes',  (select coalesce(sum(u.caracteres), 0) from core.ia_fala_uso u where u.cancelado_em is null and u.app = a.app and u.em >= v_ini and u.em < v_fim),
               'caracteres_hoje', (select coalesce(sum(u.caracteres), 0) from core.ia_fala_uso u where u.cancelado_em is null and u.app = a.app and u.em >= v_hoje),
               'audios_mes',    (select count(*) from core.ia_fala_uso u where u.cancelado_em is null and u.app = a.app and u.em >= v_ini and u.em < v_fim),
               'ultimo_uso',    (select max(u.em) from core.ia_fala_uso u where u.cancelado_em is null and u.app = a.app)
             ) order by case a.tipo when 'transcricao' then 0 else 1 end, a.nome)
        from core.ia_fala_apps a), '[]'::jsonb),
    'lancamentos', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.em desc)
        from (select u.id, u.em, u.app, u.tipo, u.segundos, u.caracteres, u.detalhe, u.lancado_por
                from core.ia_fala_uso u where u.lancado_por is not null and u.cancelado_em is null order by u.em desc limit 10) x), '[]'::jsonb)
  );
end $$;
revoke all on function core.ia_fala_painel(date) from public, anon;
grant execute on function core.ia_fala_painel(date) to authenticated;

-- Uso que já tinha acontecido antes do controle (lançado em 11/10/2026):
--   Projeto Criança: cerca de 7 mil caracteres (613 falas da Sarah, 07–09/10/2026; valor do LEIA-ME do projeto)
--   Estudo da Reforma: cerca de 112 mil caracteres (40 faixas, 179 min, 11/10/2026; estimado pelo texto das faixas)

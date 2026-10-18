-- ============================================================
-- AZURE (artecon-voz): AVISO AO CHEGAR EM 80% E 100% DA COTA GRÁTIS
-- Projeto Supabase do NÚCLEO do portal: fbxelwhdiisfmnwrerbl (schema core)
-- Aplicado em 12/10/2026. Continuação de nucleo_ia_fala.sql e nucleo_ia_fala_v2.sql.
--
-- Depois de cada uso informado (public.ia_fala_registrar) ou lançado à mão
-- (core.ia_fala_lancar), confere as duas cotas do mês: transcrição (5 h) e voz
-- (500 mil caracteres). Em 80% e em 100% cria o aviso no sino do portal
-- (core.ia_notificar, uma vez por mês e por cota) e manda e-mail para
-- core.ia_config.email_alertas (public.enviar_email, hub artecon-mail).
-- Um erro no aviso nunca impede o registro do uso.
-- ============================================================

create or replace function core.ia_fala_avisar()
returns void language plpgsql security definer set search_path = core, public as $$
declare
  v_mes text := to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM');
  v_ini timestamptz := core.ia_ini_mes();
  v_seg bigint; v_car bigint; v_n jsonb; c core.ia_config; e text; r record;
begin
  select coalesce(sum(segundos), 0), coalesce(sum(caracteres), 0) into v_seg, v_car
    from core.ia_fala_uso where cancelado_em is null and em >= v_ini;
  select * into c from core.ia_config where id = 1;
  for r in select * from (values
      ('transcricao', v_seg::numeric, 18000::numeric,  'Transcrição de áudio da Azure', round(v_seg / 60.0)::text || ' min de 300 min'),
      ('voz',         v_car::numeric, 500000::numeric, 'Voz da Azure',
                      replace(to_char(v_car, 'FM999,999,999'), ',', '.') || ' de 500.000 caracteres')
    ) t(tipo, usado, cota, nome, txt)
  loop
    v_n := null;
    if r.usado >= r.cota then
      v_n := core.ia_notificar('fala100:' || r.tipo || ':' || v_mes, 'critico',
               format('%s: acabou a cota grátis do mês', r.nome),
               format('Usado: %s. A Azure recusa novos pedidos até o mês virar (não cobra nada).', r.txt));
    elsif r.usado >= r.cota * 0.8 then
      v_n := core.ia_notificar('fala80:' || r.tipo || ':' || v_mes, 'aviso',
               format('%s: 80%% da cota grátis do mês', r.nome),
               format('Usado: %s. Passando de 100%%, a Azure recusa até o mês virar (não cobra nada).', r.txt));
    end if;
    if v_n is not null then
      foreach e in array coalesce(c.email_alertas, '{}'::text[]) loop
        begin
          perform public.enviar_email(e, '[IA Artecon] ' || (v_n ->> 'titulo'),
            '<p><b>' || (v_n ->> 'titulo') || '</b></p><p>' || (v_n ->> 'texto') ||
            '</p><p>Detalhes em Portal Artecon → Consumo de IA → Azure — voz e transcrição.</p>',
            null, 'Portal Artecon — IA Central');
        exception when others then null;
        end;
      end loop;
    end if;
  end loop;
end $$;
revoke all on function core.ia_fala_avisar() from public, anon, authenticated;

-- registrar (o Agenda informa a transcrição) — igual à v1, mais o aviso
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
  select coalesce(sum(segundos), 0) into v_total from core.ia_fala_uso where cancelado_em is null and em >= core.ia_ini_mes();
  begin perform core.ia_fala_avisar(); exception when others then null; end;
  return jsonb_build_object('ok', true, 'app', a.app, 'segundos_mes_total', v_total);
end $$;

-- lançar à mão — igual à v2, mais o aviso
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
  begin perform core.ia_fala_avisar(); exception when others then null; end;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

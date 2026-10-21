-- =====================================================================
-- Artecon Propostas — reversão da v2.4.0 (envio em massa)
-- ---------------------------------------------------------------------
-- Desfaz a 23_migracao_v2_4_0_envio_em_massa.sql:
--   - tira o gotejamento do pg_cron e as funções do WhatsApp;
--   - tira o gatilho que fecha os outros canais quando a pessoa assina;
--   - prop_link_signatario volta a derrubar o link de todos os canais.
-- O histórico prop_whats_envios só é apagado se estiver vazio (senão fica,
-- sem acesso pelo app, e a migração 23 o reaproveita se for reaplicada).
-- Mensagens que já estão na fila do robô do Cobrança Pro não são mexidas.
-- Idempotente.
-- =====================================================================

select 'antes' as etapa,
       to_regclass('public.prop_whats_envios') is not null as tabela_envios,
       to_regprocedure('public.prop_whats_gotejar()') is not null as gotejar,
       exists (select 1 from pg_trigger where tgname = 'prop_assinatura_fecha_canais') as gatilho_fecha_canais;

begin;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'prop-whats-gotejar';
  end if;
end $$;

drop trigger if exists prop_assinatura_fecha_canais on public.prop_assinaturas;
drop function if exists public.prop_assinatura_fecha_canais();
drop function if exists public.prop_whats_gotejar();
drop function if exists public.prop_whats_reagendar(uuid[]);
drop function if exists public.prop_whats_cancelar(uuid[]);
drop function if exists public.prop_whats_agendar(jsonb, text);
drop function if exists public.prop_whats_destino(uuid, uuid, text);
drop function if exists public.prop_whats_cob_tenant(uuid);

do $$ begin
  if to_regclass('public.prop_whats_envios') is not null then
    if exists (select 1 from public.prop_whats_envios) then
      execute 'revoke all on public.prop_whats_envios from authenticated';
      raise notice 'prop_whats_envios tem histórico: a tabela foi mantida, sem acesso pelo app';
    else
      execute 'drop table public.prop_whats_envios';
    end if;
  end if;
end $$;

-- prop_link_signatario como era antes (um link válido por pessoa, qualquer canal)
create or replace function public.prop_link_signatario(p_signatario uuid, p_tipo text default 'assinatura'::text, p_canal text default 'email'::text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_s public.prop_signatarios; v_p public.prop_propostas; v_token text; v_email text; v_expira timestamptz; v_id uuid; v_para text;
begin
  select * into v_s from public.prop_signatarios where id = p_signatario and excluido_em is null and tenant_id in (select public.prop_meus_tenants());
  if not found then raise exception 'PROP030: signatário não encontrado'; end if;
  select * into v_p from public.prop_propostas where id = v_s.proposta_id and excluido_em is null;
  if not found then raise exception 'PROP010: proposta não encontrada'; end if;
  if p_tipo not in ('assinatura','leitura') or p_canal not in ('email','whatsapp','link') then raise exception 'PROP031: tipo ou canal inválido'; end if;
  v_para := case p_canal when 'email' then v_s.email when 'whatsapp' then v_s.celular else 'link copiado pelo escritório' end;
  if v_para is null then raise exception 'PROP032: % sem % cadastrado', v_s.nome, case p_canal when 'email' then 'e-mail' else 'celular' end; end if;

  if p_tipo = 'assinatura' then
    if v_p.assinada_em is not null then raise exception 'PROP011: esta proposta já está com todas as assinaturas'; end if;
    if v_p.status in ('aprovada','perdida') then raise exception 'PROP012: proposta aprovada ou perdida não recebe link de assinatura; reabra como Enviada'; end if;
    if exists (select 1 from public.prop_assinaturas a where a.signatario_id = v_s.id) then raise exception 'PROP033: % já assinou', v_s.nome; end if;
  else
    if v_p.assinada_em is null then raise exception 'PROP034: a via assinada só é enviada depois que todos assinarem'; end if;
  end if;

  select u.email into v_email from auth.users u where u.id = auth.uid();
  update public.prop_links set revogado_em = now(), revogado_por_email = v_email, motivo_revogacao = 'substituido'
   where signatario_id = v_s.id and tipo = p_tipo and revogado_em is null;

  v_token  := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_expira := now() + interval '30 days';
  insert into public.prop_links (tenant_id, proposta_id, signatario_id, tipo, canal, enviado_para, token_hash, criado_por, criado_por_email, expira_em)
  values (v_s.tenant_id, v_s.proposta_id, v_s.id, p_tipo, p_canal, v_para, public.prop_hash(to_jsonb(v_token)), auth.uid(), v_email, v_expira)
  returning id into v_id;

  if p_tipo = 'assinatura' and v_p.status = 'rascunho' then
    update public.prop_propostas set status = 'enviada' where id = v_p.id;
  end if;
  return jsonb_build_object('link_id', v_id, 'token', v_token, 'expira_em', v_expira, 'para', v_para);
end $$;

commit;

select 'depois' as etapa,
       to_regprocedure('public.prop_whats_gotejar()') is null and to_regprocedure('public.prop_whats_agendar(jsonb,text)') is null
         and to_regprocedure('public.prop_whats_cancelar(uuid[])') is null and to_regprocedure('public.prop_whats_reagendar(uuid[])') is null
         and to_regprocedure('public.prop_whats_cob_tenant(uuid)') is null and to_regprocedure('public.prop_whats_destino(uuid,uuid,text)') is null as ok_funcoes,
       not exists (select 1 from pg_trigger where tgname = 'prop_assinatura_fecha_canais') as ok_gatilho,
       position('canal is not distinct from p_canal' in pg_get_functiondef('public.prop_link_signatario(uuid,text,text)'::regprocedure)) = 0 as ok_link_original,
       to_regclass('public.prop_whats_envios') is null
         or not has_table_privilege('authenticated', 'public.prop_whats_envios', 'select') as ok_tabela,
       case when not exists (select 1 from pg_extension where extname = 'pg_cron') then true
            else (xpath('/row/n/text()', query_to_xml('select count(*) as n from cron.job where jobname = ''prop-whats-gotejar''', false, true, '')))[1]::text::int = 0
       end as ok_agenda_cron;

-- =====================================================================
-- Artecon Propostas v2.4.0 — envio em massa (WhatsApp aos poucos)
-- ---------------------------------------------------------------------
-- O que faz:
--   1. prop_link_signatario: cada pessoa pode ter UM link válido por canal
--      (e-mail, WhatsApp, link copiado). Antes, gerar o link do WhatsApp
--      derrubava o do e-mail — no envio "ambos" os dois precisam valer.
--   2. prop_whats_envios: agenda dos pedidos de assinatura por WhatsApp.
--   3. prop_whats_agendar / prop_whats_cancelar / prop_whats_reagendar:
--      o app agenda, cancela e reagenda (só escritório e celular válidos).
--   4. prop_whats_gotejar (pg_cron, a cada minuto): coloca na fila do robô
--      do Cobrança Pro (cob_whatsapp_fila) um pedido por vez, respeitando
--      horário (dias úteis, 8h–18h), intervalo (3 min) e limite do dia (40),
--      configuráveis em prop_tenants.escritorio (whats_*). Gera o link do
--      WhatsApp na hora do envio e acompanha o resultado do robô.
--      Mesma trava do Cobrança: só vai para celular cadastrado lá para o
--      cliente (cob_whats_destino_ok).
--   5. prop_assinatura_fecha_canais (gatilho): quem assinou por um canal tem
--      os links dos outros canais encerrados e o WhatsApp pendente cancelado.
--
-- Exige: migrações 21 e 22 e o Cobrança Pro v2.17+ (cob_whats_destino_ok).
-- Idempotente. Reversão: 90_reversao_v2_4_0.sql
-- =====================================================================

-- 0. Estado antes
select 'antes' as etapa,
       to_regclass('public.prop_whats_envios') is not null as tabela_envios,
       to_regprocedure('public.cob_whats_destino_ok(uuid,uuid,text,boolean)') is not null as cobranca_tem_trava,
       exists (select 1 from pg_extension where extname = 'pg_cron') as pg_cron,
       (select count(*) from public.prop_links where revogado_em is null and tipo = 'assinatura') as links_assinatura_ativos;

begin;

-- ---------------------------------------------------------------------
-- 1. Um link válido por canal
-- ---------------------------------------------------------------------
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
  -- v2.4.0: substitui só o link do MESMO canal (o do outro canal continua valendo)
  update public.prop_links set revogado_em = now(), revogado_por_email = v_email, motivo_revogacao = 'substituido'
   where signatario_id = v_s.id and tipo = p_tipo and canal is not distinct from p_canal and revogado_em is null;

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

-- ---------------------------------------------------------------------
-- 2. Agenda do WhatsApp
-- ---------------------------------------------------------------------
create table if not exists public.prop_whats_envios (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.prop_tenants(id),
  lote_id        uuid references public.prop_lotes(id),
  proposta_id    uuid not null references public.prop_propostas(id),
  signatario_id  uuid not null references public.prop_signatarios(id),
  telefone       text not null,
  tipo           text not null default 'assinatura',
  status         text not null default 'agendado',
  agendado_para  timestamptz not null default now(),
  enfileirado_em timestamptz,
  enviado_em     timestamptz,
  cob_fila_id    bigint,
  link_id        uuid,
  erro           text,
  tentativas     int not null default 0,
  criado_por     uuid,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  constraint prop_we_tipo_ck     check (tipo in ('assinatura','lembrete')),
  constraint prop_we_status_ck   check (status in ('agendado','na_fila','enviado','erro','cancelado')),
  constraint prop_we_telefone_ck check (telefone ~ '^[0-9]{10,13}$')
);
create index if not exists prop_we_tenant_status_ix on public.prop_whats_envios (tenant_id, status, agendado_para);
create index if not exists prop_we_lote_ix on public.prop_whats_envios (lote_id);
create index if not exists prop_we_proposta_ix on public.prop_whats_envios (proposta_id);
create unique index if not exists prop_we_ativo_uk on public.prop_whats_envios (signatario_id) where status in ('agendado','na_fila');

alter table public.prop_whats_envios enable row level security;
drop policy if exists prop_we_sel on public.prop_whats_envios;
create policy prop_we_sel on public.prop_whats_envios for select to authenticated
  using (tenant_id in (select public.prop_meus_tenants()));
grant select on public.prop_whats_envios to authenticated;     -- escrita só pelas funções abaixo

-- escritório do Cobrança Pro correspondente (mesmo CNPJ)
create or replace function public.prop_whats_cob_tenant(p_tenant uuid)
returns uuid language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select ct.id from public.cob_tenants ct join public.prop_tenants pt on pt.id = p_tenant
   where pt.cnpj is not null
     and upper(regexp_replace(ct.cnpj, '[^0-9A-Za-z]', '', 'g')) = upper(regexp_replace(pt.cnpj, '[^0-9A-Za-z]', '', 'g'))
   limit 1
$$;

-- celular do signatário no formato em que está no Cobrança Pro (com ou sem o 55 na frente); null se não estiver lá
create or replace function public.prop_whats_destino(p_cob uuid, p_cob_cliente uuid, p_celular text)
returns text language sql stable security definer set search_path to 'public', 'pg_temp' as $$
  select t from (values (1, p_celular),
                        (2, case when length(p_celular) in (12, 13) and left(p_celular, 2) = '55' then substr(p_celular, 3) end),
                        (3, case when length(p_celular) in (10, 11) then '55' || p_celular end)) v(o, t)
   where t is not null and p_cob is not null and p_cob_cliente is not null
     and public.cob_whats_destino_ok(p_cob, p_cob_cliente, t, false)
   order by o limit 1
$$;

-- o app agenda: [{ "signatario_id": "..." }, ...]; devolve quantos entraram e os recusados com o motivo
create or replace function public.prop_whats_agendar(p_itens jsonb, p_tipo text default 'assinatura')
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare it jsonb; v_s public.prop_signatarios; v_p public.prop_propostas; v_c public.prop_clientes; v_cob uuid; v_tel text;
        v_ok int := 0; v_rec jsonb := '[]'::jsonb; v_motivo text;
begin
  if p_tipo not in ('assinatura','lembrete') then raise exception 'PROP110: tipo de envio inválido'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) loop
    v_motivo := null; v_s := null; v_p := null; v_c := null; v_tel := null;
    select * into v_s from public.prop_signatarios where id = (it ->> 'signatario_id')::uuid and excluido_em is null;
    if v_s.id is null or v_s.tenant_id not in (select public.prop_meus_tenants()) then v_motivo := 'signatário não encontrado';
    else
      select * into v_p from public.prop_propostas where id = v_s.proposta_id and excluido_em is null;
      select * into v_c from public.prop_clientes where id = v_p.cliente_id;
      v_cob := public.prop_whats_cob_tenant(v_s.tenant_id);
      if v_p.id is null then v_motivo := 'proposta não encontrada';
      elsif v_p.assinada_em is not null or v_p.status in ('aprovada','perdida') then v_motivo := 'proposta concluída, aprovada ou perdida';
      elsif v_p.escritorio_assinou_em is null then v_motivo := 'o escritório ainda não assinou a proposta';
      elsif exists (select 1 from public.prop_assinaturas a where a.signatario_id = v_s.id) then v_motivo := 'já assinou';
      elsif v_s.celular is null then v_motivo := 'sem celular';
      elsif exists (select 1 from public.prop_whats_envios e where e.signatario_id = v_s.id and e.status in ('agendado','na_fila')) then v_motivo := 'já está agendado';
      elsif v_cob is null then v_motivo := 'escritório não encontrado no Cobrança Pro';
      elsif not public.cob_pode(v_cob) then v_motivo := 'seu usuário não tem acesso ao Cobrança Pro';
      else
        v_tel := public.prop_whats_destino(v_cob, v_c.cob_cliente_id, v_s.celular);
        if v_tel is null then v_motivo := 'celular não cadastrado no Cobrança Pro para este cliente'; end if;
      end if;
    end if;
    if v_motivo is null then
      insert into public.prop_whats_envios (tenant_id, lote_id, proposta_id, signatario_id, telefone, tipo, criado_por)
      values (v_s.tenant_id, v_p.lote_id, v_p.id, v_s.id, v_tel, p_tipo, auth.uid());
      v_ok := v_ok + 1;
    else
      v_rec := v_rec || jsonb_build_object('signatario_id', it ->> 'signatario_id', 'motivo', v_motivo);
    end if;
  end loop;
  return jsonb_build_object('agendados', v_ok, 'recusados', v_rec);
end $$;

-- cancela o que ainda não saiu (agendado, ou na fila do robô sem ter sido enviado)
create or replace function public.prop_whats_cancelar(p_ids uuid[])
returns int language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_n int := 0; r record;
begin
  for r in select e.* from public.prop_whats_envios e
            where e.id = any(coalesce(p_ids, '{}')) and e.tenant_id in (select public.prop_meus_tenants())
              and e.status in ('agendado','na_fila') for update loop
    if r.status = 'na_fila' then
      update public.cob_whatsapp_fila set status = 'cancelado', erro = 'cancelado pelo escritório (propostas)'
       where id = r.cob_fila_id and status = 'pendente';
      if not found then continue; end if;          -- o robô já pegou: não dá mais para cancelar
      update public.prop_links set revogado_em = now(), motivo_revogacao = 'cancelado_pelo_escritorio'
       where id = r.link_id and revogado_em is null;
    end if;
    update public.prop_whats_envios set status = 'cancelado', erro = 'cancelado pelo escritório', atualizado_em = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- agenda de novo o que deu erro ou foi cancelado (gera link novo na hora do envio)
create or replace function public.prop_whats_reagendar(p_ids uuid[])
returns int language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_n int := 0; r record;
begin
  for r in select e.* from public.prop_whats_envios e
            where e.id = any(coalesce(p_ids, '{}')) and e.tenant_id in (select public.prop_meus_tenants())
              and e.status in ('erro','cancelado') for update loop
    if exists (select 1 from public.prop_whats_envios x where x.signatario_id = r.signatario_id and x.status in ('agendado','na_fila')) then continue; end if;
    update public.prop_whats_envios set status = 'agendado', agendado_para = now(), erro = null, cob_fila_id = null, link_id = null,
           enfileirado_em = null, enviado_em = null, atualizado_em = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- quem assinou por um canal: os links dos outros canais morrem e o WhatsApp que ainda não saiu é cancelado
create or replace function public.prop_assinatura_fecha_canais()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare r record;
begin
  begin
    update public.prop_links set revogado_em = now(), motivo_revogacao = 'assinado'
     where signatario_id = new.signatario_id and tipo = 'assinatura' and revogado_em is null;
    for r in select e.id, e.status, e.cob_fila_id from public.prop_whats_envios e
              where e.signatario_id = new.signatario_id and e.status in ('agendado','na_fila') loop
      if r.status = 'na_fila' then
        update public.cob_whatsapp_fila set status = 'cancelado', erro = 'já assinou (propostas)' where id = r.cob_fila_id and status = 'pendente';
        if not found then continue; end if;          -- o robô já pegou: o gotejamento acompanha o resultado
      end if;
      update public.prop_whats_envios set status = 'cancelado', erro = 'já assinou', atualizado_em = now() where id = r.id;
    end loop;
  exception when others then raise warning 'prop_assinatura_fecha_canais: %', sqlerrm;   -- nunca impede a assinatura
  end;
  return null;
end $$;
drop trigger if exists prop_assinatura_fecha_canais on public.prop_assinaturas;
create trigger prop_assinatura_fecha_canais after insert on public.prop_assinaturas
  for each row when (new.signatario_id is not null) execute function public.prop_assinatura_fecha_canais();

-- ---------------------------------------------------------------------
-- 3. Gotejamento para a fila do robô (pg_cron, a cada minuto)
-- ---------------------------------------------------------------------
create or replace function public.prop_whats_gotejar()
returns text language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_t record; v_e public.prop_whats_envios; v_p public.prop_propostas; v_s public.prop_signatarios; v_c public.prop_clientes;
        v_cfg jsonb; v_nome_esc text; v_agora timestamp := now() at time zone 'America/Sao_Paulo';
        v_int int; v_lim int; v_ini int; v_fim int; v_sab boolean; v_cob uuid; v_ult timestamptz; v_hoje int; v_fim_dia timestamptz;
        v_token text; v_link uuid; v_app text; v_url text; v_msg text; v_n text; v_fila bigint; v_res text := '';
begin
  -- 1. acompanha o que já está com o robô
  update public.prop_whats_envios e set status = 'enviado', enviado_em = coalesce(f.enviado_em, now()), atualizado_em = now()
    from public.cob_whatsapp_fila f where f.id = e.cob_fila_id and e.status = 'na_fila' and f.status = 'enviado';
  update public.prop_links l set enviado_em = e.enviado_em
    from public.prop_whats_envios e where e.link_id = l.id and e.status = 'enviado' and l.enviado_em is null;
  with x as (update public.prop_whats_envios e set status = 'erro', erro = coalesce(nullif(f.erro, ''), 'robô: ' || f.status), atualizado_em = now()
               from public.cob_whatsapp_fila f where f.id = e.cob_fila_id and e.status = 'na_fila' and f.status in ('erro','expirado','cancelado')
             returning e.link_id)
  update public.prop_links l set revogado_em = now(), motivo_revogacao = 'falha_no_envio'
    from x where l.id = x.link_id and l.revogado_em is null and l.enviado_em is null;

  -- 2. um pedido por escritório por rodada, dentro do horário, do intervalo e do limite do dia
  for v_t in select distinct e.tenant_id from public.prop_whats_envios e where e.status = 'agendado' and e.agendado_para <= now() loop
    v_e := null;
    begin
      select escritorio, nome into v_cfg, v_nome_esc from public.prop_tenants where id = v_t.tenant_id;
      v_int := coalesce(nullif(v_cfg ->> 'whats_intervalo_min', '')::int, 3);
      v_lim := coalesce(nullif(v_cfg ->> 'whats_limite_dia', '')::int, 40);
      v_ini := coalesce(nullif(v_cfg ->> 'whats_hora_ini', '')::int, 8);
      v_fim := coalesce(nullif(v_cfg ->> 'whats_hora_fim', '')::int, 18);
      v_sab := coalesce((v_cfg ->> 'whats_sabado')::boolean, false);
      if extract(isodow from v_agora) = 7 or (extract(isodow from v_agora) = 6 and not v_sab)
         or extract(hour from v_agora) < v_ini or extract(hour from v_agora) >= v_fim then continue; end if;
      v_cob := public.prop_whats_cob_tenant(v_t.tenant_id);
      v_fim_dia := (date_trunc('day', v_agora) + interval '1 day') at time zone 'America/Sao_Paulo';
      -- intervalo e limite contados na própria fila do robô (reagendar não "devolve" envio do dia)
      select max(f.criado_em), count(*) filter (where f.criado_em >= v_fim_dia - interval '1 day') into v_ult, v_hoje
        from public.cob_whatsapp_fila f
       where f.tenant_id = v_cob and f.contexto ->> 'origem' = 'propostas' and f.criado_em >= now() - interval '2 days';
      if v_ult is not null and v_ult > now() - make_interval(mins => greatest(v_int, 1)) then continue; end if;
      if v_hoje >= v_lim then continue; end if;

      select * into v_e from public.prop_whats_envios where tenant_id = v_t.tenant_id and status = 'agendado' and agendado_para <= now()
       order by agendado_para, criado_em limit 1 for update skip locked;
      if v_e.id is null then continue; end if;
      select * into v_s from public.prop_signatarios where id = v_e.signatario_id;
      select * into v_p from public.prop_propostas where id = v_e.proposta_id;
      select * into v_c from public.prop_clientes where id = v_p.cliente_id;
      if v_s.excluido_em is not null or v_p.excluido_em is not null or v_p.assinada_em is not null or v_p.status in ('aprovada','perdida')
         or exists (select 1 from public.prop_assinaturas a where a.signatario_id = v_s.id) then
        update public.prop_whats_envios set status = 'cancelado', erro = 'proposta concluída ou signatário removido', atualizado_em = now() where id = v_e.id;
        continue;
      end if;
      if v_cob is null or v_c.cob_cliente_id is null or not public.cob_whats_destino_ok(v_cob, v_c.cob_cliente_id, v_e.telefone, false) then
        update public.prop_whats_envios set status = 'erro', erro = 'celular não cadastrado no Cobrança Pro para este cliente', atualizado_em = now() where id = v_e.id;
        continue;
      end if;

      -- link próprio do WhatsApp (o do e-mail continua valendo)
      update public.prop_links set revogado_em = now(), revogado_por_email = 'sistema', motivo_revogacao = 'substituido'
       where signatario_id = v_s.id and tipo = 'assinatura' and canal = 'whatsapp' and revogado_em is null;
      v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
      insert into public.prop_links (tenant_id, proposta_id, signatario_id, tipo, canal, enviado_para, token_hash, criado_por, criado_por_email, expira_em)
      values (v_p.tenant_id, v_p.id, v_s.id, 'assinatura', 'whatsapp', v_e.telefone, public.prop_hash(to_jsonb(v_token)), v_e.criado_por,
              'sistema: envio em lote', now() + interval '30 days')
      returning id into v_link;
      v_app := coalesce(nullif(v_cfg ->> 'app_url', ''), (select valor from prop_priv.config where chave = 'app_url'),
                        'https://arteconartescontabeis-design.github.io/gestao-financeiro/propostas/');
      v_url := split_part(v_app, '#', 1) || '#/c/' || v_token;
      v_n := lpad(v_p.numero::text, 3, '0') || '/' || v_p.ano;
      v_msg := case when v_e.tipo = 'lembrete'
        then 'Olá, ' || split_part(v_s.nome, ' ', 1) || '! Lembrete: a Proposta de Honorários nº ' || v_n || ' da ' || v_nome_esc || ' aguarda a sua leitura e assinatura eletrônica: ' || v_url
        else 'Olá, ' || split_part(v_s.nome, ' ', 1) || '! Segue a Proposta de Honorários nº ' || v_n || ' da ' || v_nome_esc || ' para leitura e assinatura eletrônica: ' || v_url end;

      insert into public.cob_whatsapp_fila (tenant_id, cliente_id, telefone, mensagem, teste, valido_ate, contexto, criado_por)
      values (v_cob, v_c.cob_cliente_id, v_e.telefone, v_msg, false, v_fim_dia,
              jsonb_build_object('origem', 'propostas', 'proposta_id', v_p.id, 'envio_id', v_e.id, 'lote_id', v_e.lote_id), v_e.criado_por)
      returning id into v_fila;

      if v_p.status = 'rascunho' then
        perform set_config('prop.ator', 'sistema: envio em lote por WhatsApp', true);
        update public.prop_propostas set status = 'enviada' where id = v_p.id;
      end if;
      update public.prop_whats_envios set status = 'na_fila', enfileirado_em = now(), cob_fila_id = v_fila, link_id = v_link,
             tentativas = tentativas + 1, erro = null, atualizado_em = now() where id = v_e.id;
      v_res := v_res || 'na fila ' || v_e.id || '; ';
    exception when others then
      if v_e.id is not null then
        update public.prop_whats_envios set status = 'erro', erro = left(sqlerrm, 300), atualizado_em = now() where id = v_e.id;
      end if;
      v_res := v_res || 'erro: ' || left(sqlerrm, 120) || '; ';
    end;
  end loop;
  return coalesce(nullif(v_res, ''), 'nada a enviar');
end $$;

-- quem pode chamar o quê
revoke all on function public.prop_whats_cob_tenant(uuid) from public;
revoke all on function public.prop_whats_destino(uuid, uuid, text) from public;
revoke all on function public.prop_assinatura_fecha_canais() from public;
revoke all on function public.prop_whats_agendar(jsonb, text) from public;
revoke all on function public.prop_whats_cancelar(uuid[]) from public;
revoke all on function public.prop_whats_reagendar(uuid[]) from public;
revoke all on function public.prop_whats_gotejar() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.prop_whats_cob_tenant(uuid), public.prop_whats_destino(uuid, uuid, text), public.prop_whats_gotejar(),
             public.prop_assinatura_fecha_canais() from anon, authenticated';
    execute 'revoke all on function public.prop_whats_agendar(jsonb, text), public.prop_whats_cancelar(uuid[]), public.prop_whats_reagendar(uuid[]) from anon';
    execute 'grant execute on function public.prop_whats_agendar(jsonb, text), public.prop_whats_cancelar(uuid[]), public.prop_whats_reagendar(uuid[]) to authenticated';
  end if;
end $$;

-- agenda do pg_cron (a cada minuto)
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'prop-whats-gotejar';
    perform cron.schedule('prop-whats-gotejar', '* * * * *', 'select public.prop_whats_gotejar()');
  end if;
end $$;

commit;

-- ---------------------------------------------------------------------
-- 4. Verificação (todas as colunas "ok" devem vir true)
-- ---------------------------------------------------------------------
select 'depois' as etapa,
       to_regclass('public.prop_whats_envios') is not null as ok_tabela,
       (select count(*) from pg_policies where tablename = 'prop_whats_envios') = 1 as ok_politica,
       to_regprocedure('public.prop_whats_agendar(jsonb,text)') is not null
         and to_regprocedure('public.prop_whats_cancelar(uuid[])') is not null
         and to_regprocedure('public.prop_whats_reagendar(uuid[])') is not null
         and to_regprocedure('public.prop_whats_gotejar()') is not null as ok_funcoes,
       position('canal is not distinct from p_canal' in pg_get_functiondef('public.prop_link_signatario(uuid,text,text)'::regprocedure)) > 0 as ok_link_por_canal,
       exists (select 1 from pg_trigger where tgname = 'prop_assinatura_fecha_canais') as ok_fecha_canais,
       case when not exists (select 1 from pg_extension where extname = 'pg_cron') then true
            else (xpath('/row/n/text()', query_to_xml('select count(*) as n from cron.job where jobname = ''prop-whats-gotejar''', false, true, '')))[1]::text::int = 1
       end as ok_agenda_cron;

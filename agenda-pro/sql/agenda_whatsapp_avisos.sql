-- ============================================================
-- AGENDA PRO — avisos ao cliente por WhatsApp
-- Projeto Supabase do Agenda: vuwgxndahrzinfdlapxz
--
-- Como funciona:
--   1. Gatilho em agenda_agendamentos cria o aviso (confirmação,
--      cancelamento, reagendamento) em agenda_whats_avisos, status 'pendente'.
--   2. agenda_whats_gerar_lembretes() cria os lembretes (24 h antes e no dia).
--   3. A Edge Function agenda-whats (chamada pelo pg_cron a cada 2 min e
--      pelo app logo após salvar) reserva os pendentes, monta o texto e
--      coloca na fila do WhatsApp do Cobrança Pro (cob_agenda_enfileirar).
--      Depois acompanha a fila e marca 'enviado' ou 'falha'.
-- Cada tipo de aviso só sai se estiver ligado nas Configurações
-- (agenda_config: whats_confirmacao, whats_lembrete_24h, whats_lembrete_dia,
-- whats_cancelamento, whats_reagendamento) e se o escritório estiver em
-- agenda_whats_tenants (o número é o da Artecon).
-- ============================================================

-- ── 1. Cliente: autoriza avisos por WhatsApp ────────────────
alter table public.agenda_clientes
  add column if not exists whatsapp_avisos boolean not null default true;

-- ── 2. Avisos de WhatsApp (fila de saída do Agenda) ────────
create table if not exists public.agenda_whats_avisos (
  id              bigserial primary key,
  tenant_id       bigint not null references public.agenda_tenants(id) on delete cascade,
  agendamento_id  bigint references public.agenda_agendamentos(id) on delete cascade,  -- vazio na mensagem de teste
  tipo            text not null check (tipo in ('confirmacao','lembrete_24h','lembrete_dia','cancelamento','reagendamento','teste')),
  telefone        text not null,
  status          text not null default 'pendente'
                  check (status in ('pendente','enviando','na_fila','enviado','falha','cancelado')),
  tentativas      integer not null default 0,
  mensagem        text,
  fila_id         bigint,          -- id em cob_whatsapp_fila (Cobrança Pro)
  erro            text,
  chave           text not null unique,  -- evita aviso repetido
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now(),
  enviado_em      timestamptz
);
create index if not exists agenda_whats_avisos_abertos_ix on public.agenda_whats_avisos (status)
  where status in ('pendente','enviando','na_fila');
create index if not exists agenda_whats_avisos_ag_ix on public.agenda_whats_avisos (agendamento_id);
create index if not exists agenda_whats_avisos_tenant_ix on public.agenda_whats_avisos (tenant_id, criado_em desc);
alter table public.agenda_whats_avisos enable row level security;
create policy whats_avisos_select on public.agenda_whats_avisos
  for select using (tenant_id = public.agenda_meu_tenant_id());

-- ── 3. Escritórios liberados para usar o WhatsApp da Artecon ─
create table if not exists public.agenda_whats_tenants (
  tenant_id  bigint primary key references public.agenda_tenants(id) on delete cascade,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);
alter table public.agenda_whats_tenants enable row level security;
create policy whats_tenants_select on public.agenda_whats_tenants
  for select using (tenant_id = public.agenda_meu_tenant_id());

-- ── 4. Funções auxiliares ───────────────────────────────────
create or replace function public.agenda_whats_cfg(p_tenant bigint, p_chave text)
returns text language sql stable security definer set search_path = public as $$
  select valor from public.agenda_config where tenant_id = p_tenant and chave = p_chave limit 1
$$;

-- Número para WhatsApp (DDD + número, sem 55). Usa o campo WhatsApp;
-- se vazio, aceita o telefone só quando é celular (11 dígitos com 9).
create or replace function public.agenda_whats_fone(p_whatsapp text, p_telefone text)
returns text language sql immutable set search_path = public as $$
  with d as (
    select regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g') w,
           regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g') t
  ), n as (
    select case when length(w) in (12, 13) and left(w, 2) = '55' then substr(w, 3) else w end w,
           case when length(t) in (12, 13) and left(t, 2) = '55' then substr(t, 3) else t end t
      from d
  )
  select case when length(w) in (10, 11) then w
              when length(t) = 11 and substr(t, 3, 1) = '9' then t end
    from n
$$;

-- Cria um aviso pendente, se o tipo estiver ligado e o cliente puder receber.
create or replace function public.agenda_whats_criar(p_ag_id bigint, p_tipo text, p_chave text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_ag   public.agenda_agendamentos%rowtype;
  v_cli  public.agenda_clientes%rowtype;
  v_fone text;
begin
  select * into v_ag from public.agenda_agendamentos where id = p_ag_id;
  if not found then return false; end if;
  if not exists (select 1 from public.agenda_whats_tenants where tenant_id = v_ag.tenant_id and ativo) then return false; end if;
  if coalesce(public.agenda_whats_cfg(v_ag.tenant_id, 'whats_' || p_tipo), 'false') <> 'true' then return false; end if;
  select * into v_cli from public.agenda_clientes where id = v_ag.cliente_id;
  if not found or not v_cli.whatsapp_avisos then return false; end if;
  v_fone := public.agenda_whats_fone(v_cli.whatsapp, v_cli.telefone);
  if v_fone is null then return false; end if;
  insert into public.agenda_whats_avisos (tenant_id, agendamento_id, tipo, telefone, status, chave)
  values (v_ag.tenant_id, v_ag.id, p_tipo, v_fone, 'pendente', p_chave)
  on conflict (chave) do nothing;
  return found;
end $$;

-- ── 5. Gatilho: confirmação, cancelamento, reagendamento ────
create or replace function public.agenda_whats_evento()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_ep text := extract(epoch from new.data_inicio)::bigint::text;
begin
  begin  -- nunca impede salvar o agendamento
    if new.data_inicio > now() then
      if tg_op = 'INSERT' then
        if new.status = 'confirmado' then
          perform public.agenda_whats_criar(new.id, 'confirmacao', 'confirmacao:' || new.id || ':' || v_ep);
        end if;
      elsif new.status in ('cancelado_cliente', 'cancelado_escritorio')
            and old.status not in ('cancelado_cliente', 'cancelado_escritorio') then
        update public.agenda_whats_avisos set status = 'cancelado', erro = 'agendamento cancelado', atualizado_em = now()
         where agendamento_id = new.id and status = 'pendente';
        perform public.agenda_whats_criar(new.id, 'cancelamento', 'cancelamento:' || new.id || ':' || v_ep);
      elsif new.data_inicio is distinct from old.data_inicio
            and new.status not in ('cancelado_cliente', 'cancelado_escritorio', 'concluido', 'nao_compareceu') then
        update public.agenda_whats_avisos set status = 'cancelado', erro = 'agendamento reagendado', atualizado_em = now()
         where agendamento_id = new.id and status = 'pendente';
        perform public.agenda_whats_criar(new.id, 'reagendamento', 'reagendamento:' || new.id || ':' || v_ep);
      elsif new.status = 'confirmado' and old.status in ('solicitado', 'pendente_confirmacao') then
        perform public.agenda_whats_criar(new.id, 'confirmacao', 'confirmacao:' || new.id || ':' || v_ep);
      end if;
    end if;
  exception when others then
    raise warning 'agenda_whats_evento (agendamento %): %', new.id, sqlerrm;
  end;
  return new;
end $$;

create or replace trigger trg_whats_evento
  after insert or update of status, data_inicio on public.agenda_agendamentos
  for each row execute function public.agenda_whats_evento();

-- ── 6. Lembretes (chamado pela Edge Function a cada rodada) ─
-- 24 h: sai quando faltam 24 h (até 12 h, se cair no horário de silêncio),
--       só se o agendamento foi confirmado com mais de 24 h de antecedência.
-- No dia: sai a partir do horário escolhido (padrão 08:00), para os
--       agendamentos do dia confirmados antes desse horário.
-- Nada sai entre 21:00 e 07:00.
create or replace function public.agenda_whats_gerar_lembretes()
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_agora timestamp := now() at time zone 'America/Sao_Paulo';
  v_n     integer := 0;
  v_cfg   text;
  v_hora  time;
  r       record;
begin
  if v_agora::time < time '07:00' or v_agora::time >= time '21:00' then return 0; end if;
  for r in
    select a.id, a.tenant_id, a.data_inicio, coalesce(a.confirmado_em, a.criado_em) as base
      from public.agenda_agendamentos a
      join public.agenda_whats_tenants t on t.tenant_id = a.tenant_id and t.ativo
     where a.status = 'confirmado'
       and a.data_inicio >  now() + interval '30 minutes'
       and a.data_inicio <= now() + interval '24 hours'
  loop
    if r.data_inicio > now() + interval '12 hours' and r.base <= r.data_inicio - interval '24 hours' then
      if public.agenda_whats_criar(r.id, 'lembrete_24h', 'lembrete_24h:' || r.id || ':' || extract(epoch from r.data_inicio)::bigint) then
        v_n := v_n + 1;
      end if;
    end if;
    v_cfg  := public.agenda_whats_cfg(r.tenant_id, 'whats_hora_lembrete_dia');
    v_hora := case when v_cfg ~ '^\d{2}:\d{2}$' then v_cfg::time else time '08:00' end;
    if (r.data_inicio at time zone 'America/Sao_Paulo')::date = v_agora::date
       and v_agora::time >= v_hora
       and (r.base at time zone 'America/Sao_Paulo') < (v_agora::date + v_hora) then
      if public.agenda_whats_criar(r.id, 'lembrete_dia', 'lembrete_dia:' || r.id || ':' || extract(epoch from r.data_inicio)::bigint) then
        v_n := v_n + 1;
      end if;
    end if;
  end loop;
  return v_n;
end $$;

-- ── 7. Reserva para envio (evita mandar duas vezes) ─────────
-- Entre 21:00 e 07:00 só sai a mensagem de teste; o resto espera as 07:00.
create or replace function public.agenda_whats_reservar(p_limite integer default 20)
returns setof public.agenda_whats_avisos language plpgsql security definer set search_path = public as $$
declare
  v_hora time := (now() at time zone 'America/Sao_Paulo')::time;
  v_silencio boolean := v_hora < time '07:00' or v_hora >= time '21:00';
begin
  -- os que travaram em 'enviando' voltam para a fila (até 3 tentativas)
  update public.agenda_whats_avisos
     set status = case when tentativas >= 3 then 'falha' else 'pendente' end,
         erro = case when tentativas >= 3 then coalesce(erro, 'não foi possível colocar na fila') else erro end,
         atualizado_em = now()
   where status = 'enviando' and atualizado_em < now() - interval '10 minutes';
  return query
    update public.agenda_whats_avisos n
       set status = 'enviando', tentativas = n.tentativas + 1, atualizado_em = now()
     where n.id in (select x.id from public.agenda_whats_avisos x
                     where x.status = 'pendente'
                       and (not v_silencio or x.tipo = 'teste')
                     order by x.id for update skip locked limit p_limite)
    returning n.*;
end $$;

-- ── 8. Token da fila do Cobrança (cofre) ────────────────────
create or replace function public.agenda_whats_token()
returns text language sql stable security definer set search_path = public as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'cob_agenda_token' limit 1
$$;

-- ── 9. Mensagem de teste (só administrador) ─────────────────
create or replace function public.agenda_whats_teste(p_telefone text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_t    bigint := public.agenda_meu_tenant_id();
  v_fone text;
  v_id   bigint;
begin
  if v_t is null or public.agenda_meu_perfil() is distinct from 'admin' then
    raise exception 'Só o administrador pode enviar a mensagem de teste.';
  end if;
  if not exists (select 1 from public.agenda_whats_tenants where tenant_id = v_t and ativo) then
    raise exception 'O WhatsApp não está liberado para este escritório.';
  end if;
  v_fone := public.agenda_whats_fone(p_telefone, null);
  if v_fone is null then raise exception 'Telefone inválido: informe DDD + número.'; end if;
  if (select count(*) from public.agenda_whats_avisos
       where tenant_id = v_t and tipo = 'teste' and criado_em > now() - interval '1 day') >= 10 then
    raise exception 'Limite de 10 mensagens de teste por dia.';
  end if;
  insert into public.agenda_whats_avisos (tenant_id, agendamento_id, tipo, telefone, status, chave)
  values (v_t, null, 'teste', v_fone, 'pendente', 'teste:' || v_t || ':' || gen_random_uuid())
  returning id into v_id;
  return v_id;
end $$;

-- ── 10. Permissões ──────────────────────────────────────────
revoke all on function public.agenda_whats_cfg(bigint, text)              from public, anon, authenticated;
revoke all on function public.agenda_whats_criar(bigint, text, text)      from public, anon, authenticated;
revoke all on function public.agenda_whats_evento()                       from public, anon, authenticated;
revoke all on function public.agenda_whats_gerar_lembretes()              from public, anon, authenticated;
revoke all on function public.agenda_whats_reservar(integer)              from public, anon, authenticated;
revoke all on function public.agenda_whats_token()                        from public, anon, authenticated;
revoke all on function public.agenda_whats_teste(text)                    from public, anon;
grant execute on function public.agenda_whats_gerar_lembretes() to service_role;
grant execute on function public.agenda_whats_reservar(integer) to service_role;
grant execute on function public.agenda_whats_token()           to service_role;
grant execute on function public.agenda_whats_cfg(bigint, text) to service_role;
grant execute on function public.agenda_whats_teste(text)       to authenticated;

-- ── 11. Artecon liberada ────────────────────────────────────
insert into public.agenda_whats_tenants (tenant_id) values (2) on conflict do nothing;

-- ── 12. Agendamento da Edge Function (a cada 2 minutos) ─────
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
-- a chave no cabeçalho é a anon (pública, a mesma do app.html)
select cron.schedule('agenda-whats', '*/2 * * * *', $cron$
  select net.http_post(
    url := 'https://vuwgxndahrzinfdlapxz.supabase.co/functions/v1/agenda-whats',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer <SUPA_KEY do app.html>'),
    body := '{"origem":"cron"}'::jsonb,
    timeout_milliseconds := 60000)
$cron$);

-- ── 13. Token (gerado no cofre; só o hash vai para o Cobrança) ──
-- select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'cob_agenda_token', 'Token do Agenda Pro para a fila de WhatsApp do Cobrança Pro');
-- select encode(extensions.digest(decrypted_secret, 'sha256'), 'hex') from vault.decrypted_secrets where name = 'cob_agenda_token';
--   → gravar em cob_agenda_integracao.token_hash no projeto do Cobrança.

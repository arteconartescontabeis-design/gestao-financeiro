-- ============================================================
-- AGENDA PRO → WHATSAPP (lado do Cobrança Pro)
-- Projeto Supabase do Cobrança: yeujqjtjqtegsnzwwazb
--
-- O serviço artecon-whats (servidor ARTEDB01) envia o que estiver na
-- fila cob_whatsapp_fila. O Agenda Pro fica em outro projeto Supabase,
-- então entra na fila só por estas duas funções, protegidas por um
-- token (guardado no cofre do projeto do Agenda; aqui fica só o hash).
-- As mensagens entram sem cliente_id e com contexto.origem = 'agenda'.
-- ============================================================

create table if not exists public.cob_agenda_integracao (
  id          smallint primary key default 1 check (id = 1),
  tenant_id   uuid not null references public.cob_tenants(id),
  token_hash  text not null,
  limite_dia  integer not null default 300,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);
alter table public.cob_agenda_integracao enable row level security;
-- sem políticas: ninguém lê pela API; só as funções abaixo
revoke all on public.cob_agenda_integracao from anon, authenticated;

create or replace function public.cob_agenda_enfileirar(
  p_token text, p_telefone text, p_mensagem text,
  p_valido_ate timestamptz default null, p_contexto jsonb default null)
returns bigint
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_int     public.cob_agenda_integracao%rowtype;
  v_tel     text;
  v_fim_dia timestamptz;
  v_hoje    integer;
  v_id      bigint;
begin
  select * into v_int from public.cob_agenda_integracao
   where ativo and token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found then raise exception 'token inválido' using errcode = '28000'; end if;

  -- mesmo formato da fila do Cobrança: DDD + número, sem o 55
  v_tel := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  if length(v_tel) in (12, 13) and left(v_tel, 2) = '55' then v_tel := substr(v_tel, 3); end if;
  if length(v_tel) not in (10, 11) then raise exception 'telefone inválido'; end if;

  if coalesce(btrim(p_mensagem), '') = '' or length(p_mensagem) > 2000 then
    raise exception 'mensagem vazia ou longa demais';
  end if;

  v_fim_dia := (date_trunc('day', now() at time zone 'America/Sao_Paulo') + interval '1 day') at time zone 'America/Sao_Paulo';

  select count(*) into v_hoje from public.cob_whatsapp_fila
   where tenant_id = v_int.tenant_id and contexto->>'origem' = 'agenda'
     and criado_em >= v_fim_dia - interval '1 day';
  if v_hoje >= v_int.limite_dia then raise exception 'limite diário de mensagens da agenda atingido'; end if;

  insert into public.cob_whatsapp_fila (tenant_id, cliente_id, telefone, mensagem, teste, valido_ate, contexto)
  values (v_int.tenant_id, null, v_tel, p_mensagem, false,
          least(v_fim_dia, coalesce(p_valido_ate, v_fim_dia)),
          (coalesce(p_contexto, '{}'::jsonb) - 'imagem' - 'legenda') || jsonb_build_object('origem', 'agenda'))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.cob_agenda_status(p_token text, p_ids bigint[])
returns table (id bigint, status text, erro text, enviado_em timestamptz)
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.cob_agenda_integracao
   where ativo and token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if v_tenant is null then raise exception 'token inválido' using errcode = '28000'; end if;
  return query
    select f.id, f.status, f.erro, f.enviado_em from public.cob_whatsapp_fila f
     where f.id = any(p_ids[1:200]) and f.tenant_id = v_tenant and f.contexto->>'origem' = 'agenda';
end $$;

revoke all on function public.cob_agenda_enfileirar(text, text, text, timestamptz, jsonb) from public;
revoke all on function public.cob_agenda_status(text, bigint[]) from public;
grant execute on function public.cob_agenda_enfileirar(text, text, text, timestamptz, jsonb) to anon;
grant execute on function public.cob_agenda_status(text, bigint[]) to anon;

-- O hash do token é gravado à parte (gerado no projeto do Agenda):
-- insert into public.cob_agenda_integracao (tenant_id, token_hash) values ('<tenant Artecon>', '<sha256>');

-- ============================================================
-- WHATSAPP — MENSAGENS RECEBIDAS (lado do Cobrança Pro)
-- Projeto Supabase do Cobrança: yeujqjtjqtegsnzwwazb
--
-- O serviço artecon-whats grava aqui o que chega no número da Artecon
-- (só conversas individuais, texto). O Agenda Pro lê apenas as mensagens
-- vindas dos números da equipe (cob_agenda_recebidas, com token) para
-- agendar reuniões por mensagem. Respostas de clientes às cobranças
-- também ficam aqui e podem ser usadas pelo Cobrança no futuro.
-- ============================================================

create table if not exists public.cob_whatsapp_recebidas (
  id           bigserial primary key,
  tenant_id    uuid not null references public.cob_tenants(id),
  telefone     text not null,            -- dígitos, sem o 55
  jid          text,
  nome         text,                     -- nome do contato no WhatsApp
  texto        text not null,
  id_mensagem  text unique,
  recebido_em  timestamptz not null default now(),
  criado_em    timestamptz not null default now()
);
create index if not exists cob_whatsapp_recebidas_tenant_ix on public.cob_whatsapp_recebidas (tenant_id, id);
alter table public.cob_whatsapp_recebidas enable row level security;
create policy cob_whatsapp_recebidas_sel on public.cob_whatsapp_recebidas
  for select using (exists (select 1 from public.cob_usuarios_tenants u
                             where u.tenant_id = cob_whatsapp_recebidas.tenant_id and u.usuario_id = auth.uid() and u.ativo));
create policy cob_whatsapp_recebidas_ins on public.cob_whatsapp_recebidas
  for insert with check (exists (select 1 from public.cob_usuarios_tenants u
                                  where u.tenant_id = cob_whatsapp_recebidas.tenant_id and u.usuario_id = auth.uid() and u.ativo));

-- Chave de comparação de telefone: DDD + 8 últimos dígitos
-- (o WhatsApp às vezes entrega o celular sem o 9 da frente).
create or replace function public.cob_fone_chave(p text)
returns text language sql immutable as $$
  with d as (select regexp_replace(coalesce(p, ''), '\D', '', 'g') x),
       n as (select case when length(x) in (12, 13) and left(x, 2) = '55' then substr(x, 3) else x end x from d)
  select case when length(x) in (10, 11) then left(x, 2) || right(x, 8) end from n
$$;

-- Agenda Pro: mensagens recebidas dos números informados (equipe), depois do id p_apos_id.
create or replace function public.cob_agenda_recebidas(p_token text, p_apos_id bigint, p_telefones text[])
returns table (id bigint, telefone text, nome text, texto text, recebido_em timestamptz)
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.cob_agenda_integracao
   where ativo and token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if v_tenant is null then raise exception 'token inválido' using errcode = '28000'; end if;
  return query
    select r.id, r.telefone, r.nome, r.texto, r.recebido_em
      from public.cob_whatsapp_recebidas r
     where r.tenant_id = v_tenant
       and r.id > coalesce(p_apos_id, 0)
       and r.recebido_em > now() - interval '2 days'
       and public.cob_fone_chave(r.telefone) = any (select public.cob_fone_chave(t) from unnest(p_telefones[1:50]) t)
     order by r.id
     limit 50;
end $$;

-- Ponto de partida do Agenda: o id mais recente (para não ler mensagens antigas).
create or replace function public.cob_agenda_recebidas_ultimo(p_token text)
returns bigint language plpgsql security definer
set search_path = public, extensions
as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.cob_agenda_integracao
   where ativo and token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if v_tenant is null then raise exception 'token inválido' using errcode = '28000'; end if;
  return (select coalesce(max(id), 0) from public.cob_whatsapp_recebidas where tenant_id = v_tenant);
end $$;

revoke all on function public.cob_agenda_recebidas(text, bigint, text[]) from public;
revoke all on function public.cob_agenda_recebidas_ultimo(text) from public;
grant execute on function public.cob_agenda_recebidas(text, bigint, text[]) to anon;
grant execute on function public.cob_agenda_recebidas_ultimo(text) to anon;

-- ============================================================
-- WHATSAPP — EQUIPE DO AGENDA E RESPOSTA RÁPIDA (lado do Cobrança Pro)
-- Projeto Supabase do Cobrança: yeujqjtjqtegsnzwwazb
-- Aplicado em 10/10/2026 (para o artecon-whats v1.5.0).
--
-- 1. O Agenda publica aqui os números da equipe (só a chave DDD + 8 últimos
--    dígitos). O serviço artecon-whats usa a lista para transcrever ÁUDIO só
--    de quem é da equipe (áudio de cliente não gasta a cota da Azure).
-- 2. O serviço pega primeiro as respostas aos comandos da equipe, sem a pausa
--    de 20–45 s que existe entre as cobranças (proteção contra bloqueio).
-- Só acréscimos: duas colunas e três funções novas.
-- ============================================================

alter table public.cob_agenda_integracao add column if not exists equipe_chaves text[] not null default '{}';
alter table public.cob_agenda_integracao add column if not exists equipe_atualizada_em timestamptz;

-- Agenda → Cobrança: lista da equipe (com o token da integração).
create or replace function public.cob_agenda_equipe_set(p_token text, p_telefones text[])
returns integer language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_id     smallint;
  v_chaves text[];
begin
  select id into v_id from public.cob_agenda_integracao
   where ativo and token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if v_id is null then raise exception 'token inválido' using errcode = '28000'; end if;
  select coalesce(array_agg(distinct x.c order by x.c), '{}') into v_chaves
    from (select public.cob_fone_chave(t) as c from unnest((coalesce(p_telefones, '{}'::text[]))[1:100]) t) x
   where x.c is not null;
  update public.cob_agenda_integracao
     set equipe_chaves = v_chaves, equipe_atualizada_em = now()
   where id = v_id and equipe_chaves is distinct from v_chaves;
  return coalesce(array_length(v_chaves, 1), 0);
end $$;

-- Serviço (usuário do robô) → chaves da equipe do escritório.
create or replace function public.cob_whatsapp_equipe(p_tenant_id uuid)
returns text[] language plpgsql stable security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.cob_usuarios_tenants u
                  where u.tenant_id = p_tenant_id and u.usuario_id = auth.uid() and u.ativo) then
    raise exception 'sem acesso ao tenant';
  end if;
  return coalesce((select array_agg(distinct c)
                     from public.cob_agenda_integracao i, unnest(i.equipe_chaves) c
                    where i.tenant_id = p_tenant_id and i.ativo), '{}');
end $$;

-- Serviço: próxima resposta a comando da equipe (mesma regra da cob_whatsapp_proxima).
create or replace function public.cob_whatsapp_proxima_resposta(p_tenant_id uuid)
returns setof public.cob_whatsapp_fila language plpgsql
set search_path = public
as $$
declare v_id bigint;
begin
  if not exists (select 1 from cob_usuarios_tenants u
                  where u.tenant_id = p_tenant_id and u.usuario_id = auth.uid() and u.ativo) then
    raise exception 'sem acesso ao tenant';
  end if;
  select id into v_id from cob_whatsapp_fila
   where tenant_id = p_tenant_id and status = 'pendente' and valido_ate >= now()
     and contexto->>'origem' = 'agenda' and contexto->>'tipo' = 'resposta_comando'
   order by criado_em limit 1 for update skip locked;
  if v_id is null then return; end if;
  update cob_whatsapp_fila set status = 'enviando', tentativas = tentativas + 1 where id = v_id;
  return query select * from cob_whatsapp_fila where id = v_id;
end $$;

revoke all on function public.cob_agenda_equipe_set(text, text[])       from public;
revoke all on function public.cob_whatsapp_equipe(uuid)                 from public, anon;
revoke all on function public.cob_whatsapp_proxima_resposta(uuid)       from public, anon;
grant execute on function public.cob_agenda_equipe_set(text, text[])    to anon, authenticated, service_role;
grant execute on function public.cob_whatsapp_equipe(uuid)              to authenticated, service_role;
grant execute on function public.cob_whatsapp_proxima_resposta(uuid)    to authenticated, service_role;

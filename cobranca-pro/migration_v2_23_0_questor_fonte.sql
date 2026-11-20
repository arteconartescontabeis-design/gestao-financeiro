-- ============================================================
-- Cobrança Pro v2.23.0 — interruptor da integração Questor Negócio
-- Rodar no SQL Editor do Supabase. Idempotente.
--
-- A integração ganha dois modos:
--   'paralelo' (padrão) — só leitura: compara e registra, nada grava;
--   'fonte'             — fonte única: a sincronização GRAVA títulos
--                         novos e aplica BAIXAS pela API.
-- Só o diretor troca o modo (RPC cob_questor_modo_set), e a recomendação
-- é ligar 'fonte' apenas depois do paralelo rodar sem divergências.
-- ============================================================

alter table public.cob_automacao_config
  add column if not exists questor_api_modo text not null default 'paralelo';

do $$ begin
  alter table public.cob_automacao_config
    add constraint cob_automacao_config_questor_modo_chk
    check (questor_api_modo in ('paralelo', 'fonte'));
exception when duplicate_object then null; end $$;

comment on column public.cob_automacao_config.questor_api_modo is
  'v2.23.0: paralelo (só leitura) ou fonte (a API grava títulos e baixas). Só diretor troca.';

create or replace function public.cob_questor_modo_set(p_tenant_id uuid, p_modo text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  if not public.cob_tem_acesso(p_tenant_id) then raise exception 'Sem acesso ao tenant'; end if;
  if not public.cob_eh_diretor(p_tenant_id) then
    raise exception 'Trocar o modo da integração é permitido só ao diretor.' using errcode = '42501';
  end if;
  if p_modo not in ('paralelo', 'fonte') then
    raise exception 'Modo inválido (use paralelo ou fonte).';
  end if;
  update public.cob_automacao_config
     set questor_api_modo = p_modo, atualizado_em = now(), atualizado_por = auth.uid()
   where tenant_id = p_tenant_id;
  if not found then raise exception 'Configuração do tenant não encontrada.'; end if;
  return jsonb_build_object('ok', true, 'modo', p_modo);
end $$;
revoke all on function public.cob_questor_modo_set(uuid, text) from public, anon;
grant execute on function public.cob_questor_modo_set(uuid, text) to authenticated;

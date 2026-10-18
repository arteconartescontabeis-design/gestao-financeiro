-- ============================================================
-- Cobrança Pro v2.17.0 — Segurança, etapa A: travas no banco
-- Rodar no SQL Editor do Supabase (projeto yeujqjtjqtegsnzwwazb).
-- Pode rodar mais de uma vez (idempotente). Não apaga nem altera dados existentes.
--
-- 1) Parcelas: cliente, vencimento, documento e nosso número só mudam por diretor
--    (exceções: robô e a troca automática da remessa — documento ⇄ nosso número)
-- 2) Fila do WhatsApp: só para telefone cadastrado do cliente (ou o número de teste);
--    depois de enfileirada, a mensagem e o telefone não podem ser trocados
-- 3) Execuções do robô: só o usuário do robô grava execução "robo"
-- 4) search_path fixo em 3 funções antigas (aviso do Supabase)
-- ============================================================

-- usuário do robô (cob_automacao_segredos.robo_usuario_id)
create or replace function public.cob_eh_robo(p_tenant_id uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (select 1 from public.cob_automacao_segredos s
                  where s.tenant_id = p_tenant_id and s.robo_usuario_id = auth.uid())
$$;
revoke all on function public.cob_eh_robo(uuid) from public, anon;
grant execute on function public.cob_eh_robo(uuid) to authenticated;

-- ── 1) Parcelas ─────────────────────────────────────────────
create or replace function public.cob__trava_parcela_campos()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  -- só vale para chamadas pela API; funções SECURITY DEFINER (retorno, baixas, confronto) passam
  if current_user not in ('anon', 'authenticated') then return new; end if;
  if public.cob_eh_diretor(new.tenant_id) or public.cob_eh_robo(new.tenant_id) then return new; end if;
  if new.cliente_id is distinct from old.cliente_id or new.data_vencimento is distinct from old.data_vencimento then
    raise exception 'Alterar cliente ou vencimento de parcela é permitido só ao diretor.' using errcode = '42501';
  end if;
  if new.nosso_numero is distinct from old.nosso_numero or new.documento is distinct from old.documento then
    -- remessa (.CRM): a parcela lançada antes pelo documento recebe o nosso número do banco (v2.1.4)
    -- (só parcela de confronto/manual, em que documento = nosso número; coalesce: NULL nunca libera)
    if not coalesce(old.status = 'aberta'
                    and old.documento is not distinct from old.nosso_numero
                    and new.documento = old.nosso_numero
                    and new.nosso_numero is not null, false) then
      raise exception 'Alterar documento ou nosso número de parcela é permitido só ao diretor.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists cob_trava_parcela_campos on public.cob_parcelas;
create trigger cob_trava_parcela_campos
  before update of cliente_id, data_vencimento, nosso_numero, documento on public.cob_parcelas
  for each row execute function public.cob__trava_parcela_campos();

-- ── 2) Fila do WhatsApp ─────────────────────────────────────
alter table public.cob_whatsapp_fila drop constraint if exists cob_whatsapp_fila_telefone_check;
alter table public.cob_whatsapp_fila add constraint cob_whatsapp_fila_telefone_check
  check (telefone ~ '^\d{10,13}$');

-- telefone pode receber: contato ativo do cliente (ou telefone do cadastro) ou, em teste, o número de teste
create or replace function public.cob_whats_destino_ok(p_tenant_id uuid, p_cliente_id uuid, p_telefone text, p_teste boolean)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select case
    when p_teste then exists (select 1 from public.cob_politicas p
                               where p.tenant_id = p_tenant_id
                                 and regexp_replace(coalesce(p.teste_whatsapp, ''), '\D', '', 'g') = p_telefone)
    else p_cliente_id is not null and (
         exists (select 1 from public.cob_clientes_contatos c
                  where c.tenant_id = p_tenant_id and c.cliente_id = p_cliente_id and c.tipo = 'telefone' and c.ativo
                    and regexp_replace(c.valor, '\D', '', 'g') = p_telefone)
      or exists (select 1 from public.cob_clientes k
                  where k.tenant_id = p_tenant_id and k.id = p_cliente_id
                    and regexp_replace(coalesce(k.telefone, ''), '\D', '', 'g') = p_telefone))
  end
$$;
revoke all on function public.cob_whats_destino_ok(uuid, uuid, text, boolean) from public, anon;
grant execute on function public.cob_whats_destino_ok(uuid, uuid, text, boolean) to authenticated;

drop policy if exists cob_whatsapp_fila_ins on public.cob_whatsapp_fila;
create policy cob_whatsapp_fila_ins on public.cob_whatsapp_fila for insert to authenticated
  with check (
    exists (select 1 from public.cob_usuarios_tenants u
             where u.tenant_id = cob_whatsapp_fila.tenant_id and u.usuario_id = auth.uid() and u.ativo)
    and public.cob_whats_destino_ok(tenant_id, cliente_id, telefone, teste)
  );

-- depois de enfileirada: destino, conteúdo e validade não mudam (o robô só atualiza status/erro/tentativas);
-- mensagem já enviada, cancelada ou expirada não volta para "pendente" (seria reenviada)
create or replace function public.cob__trava_whats_fila()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if current_user not in ('anon', 'authenticated') then return new; end if;
  if new.telefone is distinct from old.telefone or new.mensagem is distinct from old.mensagem
     or new.cliente_id is distinct from old.cliente_id or new.tenant_id is distinct from old.tenant_id
     or new.teste is distinct from old.teste or new.contexto is distinct from old.contexto
     or new.valido_ate is distinct from old.valido_ate or new.destinatario_original is distinct from old.destinatario_original
     or new.criado_por is distinct from old.criado_por or new.criado_em is distinct from old.criado_em then
    raise exception 'Mensagem da fila do WhatsApp não pode ser alterada depois de enfileirada (cancele e gere outra).' using errcode = '42501';
  end if;
  if new.status in ('pendente', 'enviando') and old.status in ('enviado', 'cancelado', 'expirado') then
    raise exception 'Mensagem % não pode voltar para a fila (gere outra).', old.status using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists cob_trava_whats_fila on public.cob_whatsapp_fila;
create trigger cob_trava_whats_fila before update on public.cob_whatsapp_fila
  for each row execute function public.cob__trava_whats_fila();

-- ── 3) Execuções do robô ────────────────────────────────────
drop policy if exists cob_automacao_execucoes_ins on public.cob_automacao_execucoes;
create policy cob_automacao_execucoes_ins on public.cob_automacao_execucoes for insert to authenticated
  with check (cob_tem_acesso(tenant_id) and (origem = 'app' or public.cob_eh_robo(tenant_id)));

drop policy if exists cob_automacao_execucoes_upd on public.cob_automacao_execucoes;
create policy cob_automacao_execucoes_upd on public.cob_automacao_execucoes for update to authenticated
  using (cob_tem_acesso(tenant_id) and (origem = 'app' or public.cob_eh_robo(tenant_id)))
  with check (cob_tem_acesso(tenant_id) and (origem = 'app' or public.cob_eh_robo(tenant_id)));

create or replace function public.cob_registrar_execucao(p_tenant_id uuid, p_etapa text, p_status text, p_resumo jsonb default null::jsonb,
  p_erro text default null::text, p_arquivo text default null::text, p_hash text default null::text, p_maquina text default null::text,
  p_origem text default 'robo'::text)
returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not public.cob_tem_acesso(p_tenant_id) then raise exception 'Sem acesso ao tenant'; end if;
  insert into public.cob_automacao_execucoes (tenant_id, etapa, origem, status, arquivo, hash_arquivo, resumo, erro, maquina, usuario_email, concluido_em)
  values (p_tenant_id, p_etapa,
          -- v2.17.0: "robo" só para o usuário do robô; qualquer outro usuário grava como "app"
          case when p_origem = 'robo' and public.cob_eh_robo(p_tenant_id) then 'robo' else 'app' end,
          p_status, p_arquivo, p_hash, p_resumo, p_erro, p_maquina,
          coalesce(current_setting('request.jwt.claims', true)::json->>'email', current_user),
          case when p_status <> 'iniciado' then now() end)
  returning id into v_id;
  return v_id;
end $$;

-- as funções do retorno, do confronto e dos recebimentos também gravam execução com p_origem:
-- quem não é o robô fica sempre como "app" (vale para qualquer caminho, inclusive SECURITY DEFINER)
create or replace function public.cob__origem_execucao()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if new.origem = 'robo' and auth.uid() is not null and not public.cob_eh_robo(new.tenant_id) then
    new.origem := 'app';
  end if;
  return new;
end $$;

drop trigger if exists cob_origem_execucao on public.cob_automacao_execucoes;
create trigger cob_origem_execucao before insert or update of origem on public.cob_automacao_execucoes
  for each row execute function public.cob__origem_execucao();

-- ── 4) search_path fixo ─────────────────────────────────────
alter function public.cob_chave_doc set search_path = public, pg_temp;
alter function public.cob_atualizar_valor set search_path = public, pg_temp;
alter function public.cob_set_updated_at set search_path = public, pg_temp;

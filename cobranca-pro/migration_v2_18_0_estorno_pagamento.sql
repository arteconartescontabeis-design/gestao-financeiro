-- ============================================================
-- Cobrança Pro v2.18.0 — Estornar pagamento (e desfazer o estorno)
-- Rodar no SQL Editor do Supabase (projeto yeujqjtjqtegsnzwwazb).
-- Pode rodar mais de uma vez (idempotente). Não apaga nem altera dados existentes.
--
-- O pagamento NÃO é apagado: fica marcado como "estornado", com motivo,
-- usuário e data. A parcela volta para "aberta" e o item do retorno (ou do
-- recebimento) vira "ignorada", para o Reprocessar pendentes e o robô não
-- baixarem de novo. O estorno pode ser desfeito (volta tudo como estava).
--
-- 1) Colunas de estorno em cob_pagamentos (pagamento estornado continua na tabela)
-- 2) Função cob_estornar_pagamento  — só diretor, com motivo (mín. 5 caracteres)
-- 3) Função cob_desfazer_estorno    — só diretor; a parcela precisa seguir em aberto
-- ============================================================

-- ── 1) Colunas de estorno ───────────────────────────────────
alter table public.cob_pagamentos add column if not exists estornado_em  timestamptz;
alter table public.cob_pagamentos add column if not exists estornado_por text;
alter table public.cob_pagamentos add column if not exists estorno_motivo text;
-- como estavam a parcela e o item do retorno antes do estorno (para desfazer)
alter table public.cob_pagamentos add column if not exists estorno_antes jsonb;

comment on column public.cob_pagamentos.estornado_em is 'v2.18.0: quando o pagamento foi estornado (NULL = pagamento válido)';

-- ── 2) Estornar pagamento ───────────────────────────────────
create or replace function public.cob_estornar_pagamento(p_tenant_id uuid, p_pagamento_id uuid, p_motivo text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_pag record; v_par record; v_it record;
  v_email text; v_mot text; v_outros int; v_novo_status text;
begin
  if not public.cob_tem_acesso(p_tenant_id) then raise exception 'Sem acesso ao tenant'; end if;
  if not public.cob_eh_diretor(p_tenant_id) then
    raise exception 'Estornar pagamento é permitido só ao diretor.' using errcode = '42501';
  end if;
  v_mot := nullif(trim(coalesce(p_motivo, '')), '');
  if length(coalesce(v_mot, '')) < 5 then raise exception 'Informe o motivo do estorno (mínimo 5 caracteres).'; end if;
  v_email := coalesce(auth.jwt() ->> 'email', current_user);

  select * into v_pag from public.cob_pagamentos
   where id = p_pagamento_id and tenant_id = p_tenant_id for update;   -- trava contra clique duplo
  if not found then raise exception 'Pagamento não encontrado neste tenant'; end if;
  if v_pag.estornado_em is not null then raise exception 'Este pagamento já está estornado (% por %).', to_char(v_pag.estornado_em, 'DD/MM/YYYY'), v_pag.estornado_por; end if;

  select * into v_par from public.cob_parcelas where id = v_pag.parcela_id for update;
  if v_par.status not in ('paga', 'baixa_manual') then
    raise exception 'A parcela não está paga (status %) — nada foi estornado.', v_par.status;
  end if;

  -- item do retorno/recebimento ligado a este pagamento (baixa manual não tem)
  select * into v_it from public.cob_conciliacao_itens
   where tenant_id = p_tenant_id and pagamento_id = p_pagamento_id
   order by criado_em limit 1 for update;

  -- outro pagamento válido na mesma parcela? então ela não volta para aberta
  select count(*) into v_outros from public.cob_pagamentos
   where tenant_id = p_tenant_id and parcela_id = v_pag.parcela_id
     and id <> p_pagamento_id and estornado_em is null;

  update public.cob_pagamentos
     set estornado_em = now(), estornado_por = v_email, estorno_motivo = v_mot,
         estorno_antes = jsonb_build_object('parcela_status', v_par.status,
                                            'item_id', v_it.id, 'item_status', v_it.status, 'item_motivo', v_it.motivo)
   where id = p_pagamento_id;

  if v_it.id is not null then
    -- "ignorada": o Reprocessar pendentes e o robô não baixam este item de novo
    update public.cob_conciliacao_itens
       set status = 'ignorada', resolvido_em = now(), resolvido_por = v_email,
           motivo = 'Pagamento estornado: ' || v_mot
     where id = v_it.id;
    update public.cob_conciliacoes c
       set total_registros = (select count(*) from public.cob_conciliacao_itens i where i.conciliacao_id = c.id and i.status = 'casada')
     where c.id = v_it.conciliacao_id;
  end if;

  v_novo_status := case when v_outros > 0 then v_par.status else 'aberta' end;
  if v_outros = 0 then
    update public.cob_parcelas set status = 'aberta' where id = v_par.id;
  end if;

  insert into public.cob_eventos (tenant_id, cliente_id, parcela_id, tipo, canal, detalhe)
  values (p_tenant_id, v_par.cliente_id, v_par.id, 'pagamento_estornado', null,
          jsonb_build_object('pagamento_id', p_pagamento_id, 'forma', v_pag.forma,
                             'valor_recebido', v_pag.valor_recebido, 'data_recebimento', v_pag.data_recebimento,
                             'motivo', v_mot, 'por', v_email, 'item_id', v_it.id,
                             'status_parcela_antes', v_par.status, 'status_parcela_depois', v_novo_status,
                             'outros_pagamentos', v_outros));

  perform public.cob__auditar(jsonb_build_object('tenant_id', p_tenant_id, 'usuario_id', auth.uid(), 'user_id', auth.uid(),
    'usuario_email', v_email, 'acao', 'pagamento_estornar', 'operacao', 'pagamento_estornar', 'tipo', 'pagamento_estornar',
    'tabela', 'cob_pagamentos', 'entidade', 'cob_pagamentos', 'registro_id', p_pagamento_id, 'entidade_id', p_pagamento_id,
    'parcela_id', v_par.id,
    'antes', jsonb_build_object('parcela_status', v_par.status, 'item_status', v_it.status, 'valor_recebido', v_pag.valor_recebido),
    'dados_antes', jsonb_build_object('parcela_status', v_par.status, 'item_status', v_it.status, 'valor_recebido', v_pag.valor_recebido),
    'depois', jsonb_build_object('parcela_status', v_novo_status, 'item_status', case when v_it.id is null then null else 'ignorada' end, 'estornado_em', now()),
    'dados_depois', jsonb_build_object('parcela_status', v_novo_status, 'item_status', case when v_it.id is null then null else 'ignorada' end, 'estornado_em', now()),
    'motivo', v_mot, 'justificativa', v_mot, 'origem', 'app'));

  return jsonb_build_object('ok', true, 'parcela_id', v_par.id, 'parcela_status', v_novo_status,
                            'item_id', v_it.id, 'outros_pagamentos', v_outros);
end $$;
revoke all on function public.cob_estornar_pagamento(uuid, uuid, text) from public, anon;
grant execute on function public.cob_estornar_pagamento(uuid, uuid, text) to authenticated;

-- ── 3) Desfazer o estorno ───────────────────────────────────
create or replace function public.cob_desfazer_estorno(p_tenant_id uuid, p_pagamento_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_pag record; v_par record; v_it record;
  v_email text; v_status_volta text; v_item_volta text;
begin
  if not public.cob_tem_acesso(p_tenant_id) then raise exception 'Sem acesso ao tenant'; end if;
  if not public.cob_eh_diretor(p_tenant_id) then
    raise exception 'Desfazer estorno é permitido só ao diretor.' using errcode = '42501';
  end if;
  v_email := coalesce(auth.jwt() ->> 'email', current_user);

  select * into v_pag from public.cob_pagamentos
   where id = p_pagamento_id and tenant_id = p_tenant_id for update;
  if not found then raise exception 'Pagamento não encontrado neste tenant'; end if;
  if v_pag.estornado_em is null then raise exception 'Este pagamento não está estornado.'; end if;

  select * into v_par from public.cob_parcelas where id = v_pag.parcela_id for update;
  if v_par.status <> 'aberta' then
    raise exception 'A parcela não está mais em aberto (status %) — confira antes de desfazer o estorno.', v_par.status;
  end if;

  v_status_volta := coalesce(v_pag.estorno_antes ->> 'parcela_status', 'paga');
  update public.cob_parcelas set status = v_status_volta where id = v_par.id;

  if (v_pag.estorno_antes ->> 'item_id') is not null then
    select * into v_it from public.cob_conciliacao_itens
     where id = (v_pag.estorno_antes ->> 'item_id')::uuid for update;
    if v_it.id is not null and v_it.status = 'ignorada' then   -- se alguém já mexeu no item, fica como está
      v_item_volta := coalesce(v_pag.estorno_antes ->> 'item_status', 'casada');
      update public.cob_conciliacao_itens
         set status = v_item_volta, motivo = v_pag.estorno_antes ->> 'item_motivo',
             resolvido_em = now(), resolvido_por = v_email
       where id = v_it.id;
      update public.cob_conciliacoes c
         set total_registros = (select count(*) from public.cob_conciliacao_itens i where i.conciliacao_id = c.id and i.status = 'casada')
       where c.id = v_it.conciliacao_id;
    end if;
  end if;

  update public.cob_pagamentos
     set estornado_em = null, estornado_por = null, estorno_motivo = null, estorno_antes = null
   where id = p_pagamento_id;

  insert into public.cob_eventos (tenant_id, cliente_id, parcela_id, tipo, canal, detalhe)
  values (p_tenant_id, v_par.cliente_id, v_par.id, 'estorno_desfeito', null,
          jsonb_build_object('pagamento_id', p_pagamento_id, 'forma', v_pag.forma,
                             'valor_recebido', v_pag.valor_recebido, 'data_recebimento', v_pag.data_recebimento,
                             'por', v_email, 'parcela_status', v_status_volta,
                             'estorno_motivo', v_pag.estorno_motivo, 'estornado_por', v_pag.estornado_por));

  perform public.cob__auditar(jsonb_build_object('tenant_id', p_tenant_id, 'usuario_id', auth.uid(), 'user_id', auth.uid(),
    'usuario_email', v_email, 'acao', 'estorno_desfazer', 'operacao', 'estorno_desfazer', 'tipo', 'estorno_desfazer',
    'tabela', 'cob_pagamentos', 'entidade', 'cob_pagamentos', 'registro_id', p_pagamento_id, 'entidade_id', p_pagamento_id,
    'parcela_id', v_par.id,
    'antes', jsonb_build_object('estornado_em', v_pag.estornado_em, 'estornado_por', v_pag.estornado_por, 'estorno_motivo', v_pag.estorno_motivo),
    'dados_antes', jsonb_build_object('estornado_em', v_pag.estornado_em, 'estornado_por', v_pag.estornado_por, 'estorno_motivo', v_pag.estorno_motivo),
    'depois', jsonb_build_object('parcela_status', v_status_volta, 'item_status', v_item_volta),
    'dados_depois', jsonb_build_object('parcela_status', v_status_volta, 'item_status', v_item_volta),
    'origem', 'app'));

  return jsonb_build_object('ok', true, 'parcela_id', v_par.id, 'parcela_status', v_status_volta, 'item_status', v_item_volta);
end $$;
revoke all on function public.cob_desfazer_estorno(uuid, uuid) from public, anon;
grant execute on function public.cob_desfazer_estorno(uuid, uuid) to authenticated;

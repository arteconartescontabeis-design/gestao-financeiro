-- FINANCEIRO PRO → banco da Gestão Empresarial e Financeiro (cobranca-pro) — funções, regras de acesso (RLS) e gatilhos.
-- Rodar depois do 001. Gerado em 18/10/2026 do agenda-pro (texto de pg_get_functiondef / pg_policies / pg_get_triggerdef,
-- sem os \r do original): 47 funções, 109 políticas, 32 gatilhos. Sem nenhuma alteração.
set local check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.fin_aceitar_convite(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_conv      record;
    v_auth_id   uuid;
    v_auth_email text;
    v_user_id   uuid;
    v_existing  uuid;
BEGIN
    -- Busca convite
    SELECT * INTO v_conv FROM public.fin_convites WHERE token = p_token;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Convite não encontrado';
    END IF;
    IF v_conv.usado_em IS NOT NULL THEN
        RAISE EXCEPTION 'Convite já foi utilizado';
    END IF;
    IF v_conv.expira_em < now() THEN
        RAISE EXCEPTION 'Convite expirado';
    END IF;

    -- Identifica usuário autenticado (criado via Auth signup)
    v_auth_id := auth.uid();
    IF v_auth_id IS NULL THEN
        RAISE EXCEPTION 'Não autenticado — faça signup antes';
    END IF;

    -- Pega email do JWT
    BEGIN
        v_auth_email := lower((auth.jwt() ->> 'email'));
    EXCEPTION WHEN OTHERS THEN
        v_auth_email := NULL;
    END;

    -- Confere email bate com o convite
    IF v_auth_email IS NOT NULL AND v_auth_email <> lower(v_conv.email) THEN
        RAISE EXCEPTION 'E-mail autenticado (%) difere do convite (%)', v_auth_email, v_conv.email;
    END IF;

    -- Verifica se já existe um usuário em fin_usuarios com esse auth_id
    SELECT id INTO v_existing FROM public.fin_usuarios WHERE auth_id = v_auth_id;

    IF v_existing IS NOT NULL THEN
        v_user_id := v_existing;
    ELSE
        -- Cria registro em fin_usuarios
        INSERT INTO public.fin_usuarios (
            tenant_id, auth_id, nome, email, perfil
        ) VALUES (
            v_conv.tenant_id, v_auth_id, v_conv.nome, v_conv.email,
            CASE WHEN v_conv.template = 'admin' THEN 'admin' ELSE 'usuario' END
        ) RETURNING id INTO v_user_id;
    END IF;

    -- Cria vínculo em fin_usuarios_empresas (se não existir)
    INSERT INTO public.fin_usuarios_empresas (
        usuario_id, tenant_id, template, permissoes, is_default, ativo
    ) VALUES (
        v_user_id, v_conv.tenant_id, v_conv.template, v_conv.permissoes, true, true
    )
    ON CONFLICT (usuario_id, tenant_id) DO UPDATE
    SET template   = EXCLUDED.template,
        permissoes = EXCLUDED.permissoes,
        ativo      = true;

    -- Marca convite como usado
    UPDATE public.fin_convites
    SET usado_em = now(), usuario_id = v_user_id
    WHERE token = p_token;

    RETURN jsonb_build_object(
        'sucesso',   true,
        'tenant_id', v_conv.tenant_id,
        'usuario_id', v_user_id
    );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_admin_vincular_usuario(p_auth_id uuid, p_tenant_id uuid, p_template text, p_email text, p_nome text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_user_id uuid;
  v_caller_tem_permissao boolean;
  v_auth_user_existe boolean;
  v_user_id uuid;
  v_permissoes jsonb;
  v_template_normalizado text;
BEGIN
  -- 1) Validar parâmetros
  IF p_auth_id IS NULL OR p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'auth_id e tenant_id são obrigatórios.';
  END IF;
  IF p_email IS NULL OR length(trim(p_email)) < 3 THEN
    RAISE EXCEPTION 'Email é obrigatório.';
  END IF;
  IF p_nome IS NULL OR length(trim(p_nome)) < 1 THEN
    RAISE EXCEPTION 'Nome é obrigatório.';
  END IF;

  -- Normalizar template (aceita admin, financeiro, leitura, custom)
  v_template_normalizado := COALESCE(NULLIF(trim(lower(p_template)), ''), 'leitura');
  IF v_template_normalizado NOT IN ('admin', 'financeiro', 'leitura', 'custom') THEN
    RAISE EXCEPTION 'Template inválido: %. Use admin, financeiro, leitura ou custom.', v_template_normalizado;
  END IF;

  -- 2) Autenticação do chamador
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Não autenticado.';
  END IF;

  SELECT id INTO v_caller_user_id
    FROM public.fin_usuarios
   WHERE auth_id = auth.uid()
   LIMIT 1;

  IF v_caller_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuário chamador não encontrado em fin_usuarios.';
  END IF;

  -- 3) Permissão: chamador precisa ser admin do tenant alvo
  --    OU ter usuarios.gerenciar=c (criar) no tenant alvo
  SELECT EXISTS (
    SELECT 1
      FROM public.fin_usuarios_empresas ue
     WHERE ue.usuario_id = v_caller_user_id
       AND ue.tenant_id = p_tenant_id
       AND ue.ativo = true
       AND (
         ue.template = 'admin'
         OR COALESCE((ue.permissoes -> 'usuarios' ->> 'c')::boolean, false) = true
       )
  ) INTO v_caller_tem_permissao;

  IF NOT v_caller_tem_permissao THEN
    RAISE EXCEPTION 'Sem permissão para criar usuários neste tenant.';
  END IF;

  -- 4) Validar que o auth_id informado realmente existe (anti-fraude)
  SELECT EXISTS (
    SELECT 1 FROM auth.users WHERE id = p_auth_id
  ) INTO v_auth_user_existe;

  IF NOT v_auth_user_existe THEN
    RAISE EXCEPTION 'auth_id informado não existe em auth.users. Faça o signup primeiro.';
  END IF;

  -- 5) Upsert em fin_usuarios — pode já existir (usuário com vínculo em outro tenant)
  SELECT id INTO v_user_id
    FROM public.fin_usuarios
   WHERE auth_id = p_auth_id
   LIMIT 1;

  IF v_user_id IS NULL THEN
    INSERT INTO public.fin_usuarios (auth_id, email, nome, tenant_id)
    VALUES (p_auth_id, lower(trim(p_email)), trim(p_nome), p_tenant_id)
    RETURNING id INTO v_user_id;
  END IF;

  -- 6) Verificar se já existe vínculo no tenant alvo
  IF EXISTS (
    SELECT 1 FROM public.fin_usuarios_empresas
     WHERE usuario_id = v_user_id AND tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'Este usuário já tem vínculo nesta empresa.';
  END IF;

  -- 7) Montar permissões pelo preset do template
  --    (espelha _PRESETS do front — manter sincronizado)
  v_permissoes := CASE v_template_normalizado
    WHEN 'admin' THEN jsonb_build_object(
      'dashboard',    jsonb_build_object('v', true),
      'lancamentos',  jsonb_build_object('v', true, 'c', true, 'e', true, 'x', true),
      'caixa_bancos', jsonb_build_object('v', true, 'c', true, 'e', true, 'x', true),
      'dre',          jsonb_build_object('v', true),
      'fluxo_caixa',  jsonb_build_object('v', true),
      'metas',        jsonb_build_object('v', true, 'c', true, 'e', true, 'x', true),
      'recorrencias', jsonb_build_object('v', true, 'c', true, 'e', true, 'x', true),
      'impostos',     jsonb_build_object('v', true, 'c', true, 'e', true, 'x', true),
      'importacao_ia',jsonb_build_object('v', true, 'c', true),
      'cadastros',    jsonb_build_object('v', true, 'c', true, 'e', true, 'x', true),
      'relatorios',   jsonb_build_object('v', true, 'c', true),
      'configuracoes',jsonb_build_object('v', true, 'e', true),
      'usuarios',     jsonb_build_object('v', true, 'c', true, 'e', true, 'x', true)
    )
    WHEN 'financeiro' THEN jsonb_build_object(
      'dashboard',    jsonb_build_object('v', true),
      'lancamentos',  jsonb_build_object('v', true, 'c', true, 'e', true),
      'caixa_bancos', jsonb_build_object('v', true, 'c', true, 'e', true),
      'dre',          jsonb_build_object('v', true),
      'fluxo_caixa',  jsonb_build_object('v', true),
      'metas',        jsonb_build_object('v', true),
      'recorrencias', jsonb_build_object('v', true),
      'impostos',     jsonb_build_object('v', true),
      'importacao_ia',jsonb_build_object('v', true, 'c', true),
      'cadastros',    jsonb_build_object('v', true, 'c', true, 'e', true),
      'relatorios',   jsonb_build_object('v', true, 'c', true),
      'configuracoes',jsonb_build_object('v', false),
      'usuarios',     jsonb_build_object('v', false)
    )
    ELSE -- 'leitura' ou 'custom' (custom = só leitura por default; admin ajusta depois)
      jsonb_build_object(
        'dashboard',    jsonb_build_object('v', true),
        'lancamentos',  jsonb_build_object('v', true),
        'caixa_bancos', jsonb_build_object('v', true),
        'dre',          jsonb_build_object('v', true),
        'fluxo_caixa',  jsonb_build_object('v', true),
        'metas',        jsonb_build_object('v', true),
        'recorrencias', jsonb_build_object('v', true),
        'impostos',     jsonb_build_object('v', true),
        'importacao_ia',jsonb_build_object('v', false),
        'cadastros',    jsonb_build_object('v', true),
        'relatorios',   jsonb_build_object('v', true),
        'configuracoes',jsonb_build_object('v', false),
        'usuarios',     jsonb_build_object('v', false)
      )
  END;

  -- 8) Criar vínculo
  INSERT INTO public.fin_usuarios_empresas (
    usuario_id, tenant_id, template, permissoes, is_default, ativo
  ) VALUES (
    v_user_id, p_tenant_id, v_template_normalizado, v_permissoes,
    -- is_default = true se for o primeiro vínculo do usuário
    NOT EXISTS (
      SELECT 1 FROM public.fin_usuarios_empresas
       WHERE usuario_id = v_user_id AND ativo = true
    ),
    true
  );

  RETURN jsonb_build_object(
    'sucesso', true,
    'user_id', v_user_id,
    'tenant_id', p_tenant_id,
    'template', v_template_normalizado
  );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_aplicar_rls(p_tabela text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE v_modulo text := public.fin_modulo_da_tabela(p_tabela);
BEGIN
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', p_tabela);

    EXECUTE format($f$CREATE POLICY %I_sel ON public.%I FOR SELECT TO authenticated
        USING (tenant_id = public.fin_tenant_atual() AND public.fin_pode(%L,'v'))$f$,
        p_tabela, p_tabela, v_modulo);

    EXECUTE format($f$CREATE POLICY %I_ins ON public.%I FOR INSERT TO authenticated
        WITH CHECK (tenant_id = public.fin_tenant_atual() AND public.fin_pode(%L,'c'))$f$,
        p_tabela, p_tabela, v_modulo);

    EXECUTE format($f$CREATE POLICY %I_upd ON public.%I FOR UPDATE TO authenticated
        USING (tenant_id = public.fin_tenant_atual() AND public.fin_pode(%L,'e'))
        WITH CHECK (tenant_id = public.fin_tenant_atual() AND public.fin_pode(%L,'e'))$f$,
        p_tabela, p_tabela, v_modulo, v_modulo);

    EXECUTE format($f$CREATE POLICY %I_del ON public.%I FOR DELETE TO authenticated
        USING (tenant_id = public.fin_tenant_atual() AND public.fin_pode(%L,'x'))$f$,
        p_tabela, p_tabela, v_modulo);
END;$function$
;
CREATE OR REPLACE FUNCTION public.fin_atualizar_permissoes(p_usuario_id uuid, p_template text, p_permissoes jsonb DEFAULT NULL::jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_perms jsonb; v_tenant uuid;
BEGIN
    IF NOT public.fin_pode('usuarios','e') AND NOT public.fin_eh_superadmin() THEN
        RAISE EXCEPTION 'Sem permissão';
    END IF;
    IF p_template NOT IN ('admin','financeiro','leitura','custom') THEN
        RAISE EXCEPTION 'Template inválido: %', p_template;
    END IF;

    v_tenant := public.fin_tenant_atual();
    v_perms := COALESCE(p_permissoes, public.fin_template_permissoes(p_template));

    UPDATE public.fin_usuarios_empresas
    SET template = p_template, permissoes = v_perms, atualizado_em = now()
    WHERE usuario_id = p_usuario_id AND tenant_id = v_tenant;

    RETURN FOUND;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_atualizar_saldo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- INSERT ou UPDATE: recalcula a conta nova
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
    IF NEW.conta_id IS NOT NULL THEN
      PERFORM fin_recalcular_saldo_conta(NEW.conta_id);
    END IF;
  END IF;

  -- UPDATE com mudança de conta: recalcula a conta antiga também
  IF TG_OP = 'UPDATE' AND OLD.conta_id IS DISTINCT FROM NEW.conta_id THEN
    IF OLD.conta_id IS NOT NULL THEN
      PERFORM fin_recalcular_saldo_conta(OLD.conta_id);
    END IF;
  END IF;

  -- DELETE: recalcula a conta da movimentação removida
  IF TG_OP = 'DELETE' THEN
    IF OLD.conta_id IS NOT NULL THEN
      PERFORM fin_recalcular_saldo_conta(OLD.conta_id);
    END IF;
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_atualizar_vencidos()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  UPDATE fin_receitas SET status = 'vencido'
    WHERE status = 'pendente' AND vencimento < CURRENT_DATE;
  UPDATE fin_despesas SET status = 'vencido'
    WHERE status = 'pendente' AND vencimento < CURRENT_DATE;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_audit_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_tenant uuid; v_user_id uuid; v_user_email text;
    v_registro_id text; v_ativo boolean;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_tenant := (row_to_json(OLD)::jsonb ->> 'tenant_id')::uuid;
        v_registro_id := (row_to_json(OLD)::jsonb ->> 'id');
    ELSE
        v_tenant := (row_to_json(NEW)::jsonb ->> 'tenant_id')::uuid;
        v_registro_id := (row_to_json(NEW)::jsonb ->> 'id');
    END IF;

    SELECT ativo INTO v_ativo
    FROM public.fin_auditoria_config
    WHERE tenant_id = v_tenant AND tabela = TG_TABLE_NAME;

    -- Default: audita só tabelas financeiras (movimentação de dinheiro)
    IF v_ativo IS NULL THEN
        v_ativo := TG_TABLE_NAME IN (
            'fin_receitas','fin_despesas','fin_movimentacoes','fin_transferencias'
        );
    END IF;
    IF NOT v_ativo THEN RETURN COALESCE(NEW, OLD); END IF;

    SELECT id, email INTO v_user_id, v_user_email
    FROM public.fin_usuarios WHERE auth_id = auth.uid() LIMIT 1;

    INSERT INTO public.fin_auditoria (
        tenant_id, usuario_id, usuario_email, tabela, operacao, registro_id,
        dados_antes, dados_depois
    ) VALUES (
        v_tenant, v_user_id, v_user_email, TG_TABLE_NAME, TG_OP, v_registro_id,
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN row_to_json(OLD)::jsonb END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN row_to_json(NEW)::jsonb END
    );
    RETURN COALESCE(NEW, OLD);
END;$function$
;
CREATE OR REPLACE FUNCTION public.fin_auditoria_config_listar()
 RETURNS TABLE(tabela text, ativo boolean, padrao boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_tenant uuid;
    v_padroes text[] := ARRAY[
        'fin_receitas','fin_despesas','fin_movimentacoes','fin_transferencias'
    ];
BEGIN
    IF NOT (public.fin_eh_superadmin() OR public.fin_pode('configuracoes','v')) THEN
        RAISE EXCEPTION 'Sem permissão';
    END IF;
    v_tenant := public.fin_tenant_atual();
    IF v_tenant IS NULL THEN RETURN; END IF;

    -- Lista todas as tabelas auditáveis (que têm trigger instalado)
    RETURN QUERY
    SELECT
        t.event_object_table::text AS tabela,
        COALESCE(c.ativo, t.event_object_table = ANY(v_padroes)) AS ativo,
        (t.event_object_table = ANY(v_padroes)) AS padrao
    FROM information_schema.triggers t
    LEFT JOIN public.fin_auditoria_config c
           ON c.tabela = t.event_object_table AND c.tenant_id = v_tenant
    WHERE t.trigger_schema = 'public'
      AND t.trigger_name LIKE 'trg_%_audit'
    GROUP BY t.event_object_table, c.ativo;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_auditoria_config_set(p_tabela text, p_ativo boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_tenant uuid;
BEGIN
    IF NOT (public.fin_eh_superadmin() OR public.fin_pode('configuracoes','e')) THEN
        RAISE EXCEPTION 'Sem permissão';
    END IF;
    v_tenant := public.fin_tenant_atual();
    IF v_tenant IS NULL THEN RAISE EXCEPTION 'Tenant não definido'; END IF;

    INSERT INTO public.fin_auditoria_config (tenant_id, tabela, ativo)
    VALUES (v_tenant, p_tabela, p_ativo)
    ON CONFLICT (tenant_id, tabela) DO UPDATE
    SET ativo = EXCLUDED.ativo;

    RETURN true;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_auditoria_kpis(p_data_inicio date DEFAULT NULL::date, p_data_fim date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_tenant uuid;
    v_total       bigint;
    v_hoje        bigint;
    v_usuarios    bigint;
    v_tabela_top  text;
    v_tabela_qtd  bigint;
    v_por_op      jsonb;
BEGIN
    IF NOT (public.fin_eh_superadmin() OR public.fin_pode('configuracoes','v')) THEN
        RAISE EXCEPTION 'Sem permissão';
    END IF;

    v_tenant := public.fin_tenant_atual();
    IF v_tenant IS NULL THEN
        RETURN jsonb_build_object('erro','Tenant não definido');
    END IF;

    -- Total no período
    SELECT COUNT(*) INTO v_total FROM public.fin_auditoria
    WHERE tenant_id = v_tenant
      AND (p_data_inicio IS NULL OR criado_em >= p_data_inicio)
      AND (p_data_fim    IS NULL OR criado_em <  (p_data_fim + interval '1 day'));

    -- Hoje
    SELECT COUNT(*) INTO v_hoje FROM public.fin_auditoria
    WHERE tenant_id = v_tenant AND criado_em >= current_date;

    -- Usuários distintos no período
    SELECT COUNT(DISTINCT usuario_id) INTO v_usuarios FROM public.fin_auditoria
    WHERE tenant_id = v_tenant
      AND usuario_id IS NOT NULL
      AND (p_data_inicio IS NULL OR criado_em >= p_data_inicio)
      AND (p_data_fim    IS NULL OR criado_em <  (p_data_fim + interval '1 day'));

    -- Tabela top
    SELECT tabela, COUNT(*) INTO v_tabela_top, v_tabela_qtd
    FROM public.fin_auditoria
    WHERE tenant_id = v_tenant
      AND (p_data_inicio IS NULL OR criado_em >= p_data_inicio)
      AND (p_data_fim    IS NULL OR criado_em <  (p_data_fim + interval '1 day'))
    GROUP BY tabela
    ORDER BY COUNT(*) DESC
    LIMIT 1;

    -- Por operação
    SELECT jsonb_object_agg(operacao, qtd) INTO v_por_op
    FROM (
        SELECT operacao, COUNT(*) AS qtd
        FROM public.fin_auditoria
        WHERE tenant_id = v_tenant
          AND (p_data_inicio IS NULL OR criado_em >= p_data_inicio)
          AND (p_data_fim    IS NULL OR criado_em <  (p_data_fim + interval '1 day'))
        GROUP BY operacao
    ) s;

    RETURN jsonb_build_object(
        'total',       COALESCE(v_total,0),
        'hoje',        COALESCE(v_hoje,0),
        'usuarios',    COALESCE(v_usuarios,0),
        'tabela_top',  v_tabela_top,
        'tabela_qtd',  COALESCE(v_tabela_qtd,0),
        'por_operacao', COALESCE(v_por_op, '{}'::jsonb)
    );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_auditoria_listar(p_data_inicio date DEFAULT NULL::date, p_data_fim date DEFAULT NULL::date, p_usuario_id uuid DEFAULT NULL::uuid, p_tabela text DEFAULT NULL::text, p_operacoes text[] DEFAULT NULL::text[], p_busca text DEFAULT NULL::text, p_limite integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(id bigint, tenant_id uuid, usuario_id uuid, usuario_email text, usuario_nome text, tabela text, operacao text, registro_id text, dados_antes jsonb, dados_depois jsonb, criado_em timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_tenant uuid;
BEGIN
    -- Permissão: admin ou superadmin ou pode_ver('configuracoes')
    IF NOT (public.fin_eh_superadmin() OR public.fin_pode('configuracoes','v')) THEN
        RAISE EXCEPTION 'Sem permissão para visualizar auditoria';
    END IF;

    v_tenant := public.fin_tenant_atual();
    IF v_tenant IS NULL THEN RETURN; END IF;

    RETURN QUERY
    WITH base AS (
        SELECT a.*,
               u.nome AS u_nome,
               COUNT(*) OVER () AS total
        FROM public.fin_auditoria a
        LEFT JOIN public.fin_usuarios u ON u.id = a.usuario_id
        WHERE a.tenant_id = v_tenant
          AND (p_data_inicio IS NULL OR a.criado_em >= p_data_inicio)
          AND (p_data_fim    IS NULL OR a.criado_em <  (p_data_fim + interval '1 day'))
          AND (p_usuario_id  IS NULL OR a.usuario_id = p_usuario_id)
          AND (p_tabela      IS NULL OR a.tabela = p_tabela)
          AND (p_operacoes   IS NULL OR a.operacao = ANY(p_operacoes))
          AND (
            p_busca IS NULL OR p_busca = '' OR
            a.registro_id ILIKE '%'||p_busca||'%' OR
            a.usuario_email ILIKE '%'||p_busca||'%' OR
            a.dados_depois::text ILIKE '%'||p_busca||'%' OR
            a.dados_antes::text  ILIKE '%'||p_busca||'%'
          )
        ORDER BY a.criado_em DESC
        LIMIT p_limite OFFSET p_offset
    )
    SELECT b.id, b.tenant_id, b.usuario_id, b.usuario_email, b.u_nome,
           b.tabela, b.operacao, b.registro_id,
           b.dados_antes, b.dados_depois, b.criado_em,
           b.total
    FROM base b;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_auditoria_tabelas()
 RETURNS TABLE(tabela text, qtd bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_tenant uuid;
BEGIN
    IF NOT (public.fin_eh_superadmin() OR public.fin_pode('configuracoes','v')) THEN
        RAISE EXCEPTION 'Sem permissão';
    END IF;
    v_tenant := public.fin_tenant_atual();
    IF v_tenant IS NULL THEN RETURN; END IF;

    RETURN QUERY
    SELECT a.tabela, COUNT(*) AS qtd
    FROM public.fin_auditoria a
    WHERE a.tenant_id = v_tenant
    GROUP BY a.tabela
    ORDER BY COUNT(*) DESC;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_auditoria_usuarios()
 RETURNS TABLE(usuario_id uuid, nome text, email text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_tenant uuid;
BEGIN
    IF NOT (public.fin_eh_superadmin() OR public.fin_pode('configuracoes','v')) THEN
        RAISE EXCEPTION 'Sem permissão';
    END IF;
    v_tenant := public.fin_tenant_atual();
    IF v_tenant IS NULL THEN RETURN; END IF;

    RETURN QUERY
    SELECT DISTINCT a.usuario_id,
                    COALESCE(u.nome, a.usuario_email, '—')::text AS nome,
                    a.usuario_email
    FROM public.fin_auditoria a
    LEFT JOIN public.fin_usuarios u ON u.id = a.usuario_id
    WHERE a.tenant_id = v_tenant
      AND a.usuario_id IS NOT NULL
    ORDER BY nome;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_categorias_sugerir_vinculo(p_tenant_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(categoria_id uuid, categoria_nome text, categoria_tipo text, conta_id_sugerida uuid, conta_codigo text, conta_descricao text, similaridade real)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id UUID;
BEGIN
  v_tenant_id := COALESCE(
    p_tenant_id,
    fin_tenant_id(),
    (SELECT tenant_id FROM fin_usuarios WHERE auth_id = auth.uid() LIMIT 1)
  );
  IF v_tenant_id IS NULL THEN
    RETURN;
  END IF;

  -- Para cada categoria sem vínculo, pega a conta financeira analítica
  -- com nome mais similar (similarity > 0.3)
  RETURN QUERY
  SELECT DISTINCT ON (c.id)
    c.id,
    c.nome,
    c.tipo,
    pf.id,
    pf.codigo,
    pf.descricao,
    similarity(LOWER(c.nome), LOWER(pf.descricao)) AS sim
  FROM fin_categorias c
  CROSS JOIN fin_plano_financeiro pf
  WHERE c.tenant_id = v_tenant_id
    AND c.ativo = TRUE
    AND c.conta_financeira_id IS NULL
    AND pf.tenant_id = v_tenant_id
    AND pf.ativo = TRUE
    AND pf.tipo = 'A' -- só analíticas
    AND similarity(LOWER(c.nome), LOWER(pf.descricao)) > 0.3
  ORDER BY c.id, sim DESC;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_categorias_vinculo_stats(p_tenant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id UUID;
BEGIN
  v_tenant_id := COALESCE(
    p_tenant_id,
    fin_tenant_id(),
    (SELECT tenant_id FROM fin_usuarios WHERE auth_id = auth.uid() LIMIT 1)
  );
  IF v_tenant_id IS NULL THEN
    RETURN '{}'::JSONB;
  END IF;

  RETURN (
    SELECT JSONB_BUILD_OBJECT(
      'total',                  COUNT(*),
      'com_plano_financeiro',   COUNT(*) FILTER (WHERE conta_financeira_id IS NOT NULL),
      'com_plano_contabil',     COUNT(*) FILTER (WHERE conta_contabil_id   IS NOT NULL),
      'sem_vinculo_financeiro', COUNT(*) FILTER (WHERE conta_financeira_id IS NULL),
      'sem_vinculo_contabil',   COUNT(*) FILTER (WHERE conta_contabil_id   IS NULL)
    )
    FROM fin_categorias
    WHERE tenant_id = v_tenant_id AND ativo = TRUE
  );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_cnpj_tenant_existe(p_cnpj text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cnpj_limpo text;
BEGIN
  -- Exige usuário autenticado (não anônimo)
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  -- Normaliza: remove tudo que não é dígito
  v_cnpj_limpo := regexp_replace(COALESCE(p_cnpj, ''), '\D', '', 'g');

  -- CNPJ válido tem exatamente 14 dígitos
  IF length(v_cnpj_limpo) <> 14 THEN
    RETURN false;
  END IF;

  -- Existe esse CNPJ em algum tenant?
  RETURN EXISTS (
    SELECT 1
      FROM public.fin_tenants
     WHERE regexp_replace(COALESCE(cnpj, ''), '\D', '', 'g') = v_cnpj_limpo
  );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_criar_empresa(p_nome text, p_cnpj text, p_setor text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id    uuid;
    v_tenant_id  uuid;
    v_cnpj_clean text;
    v_perms_admin jsonb;
BEGIN
    -- Validações
    IF p_nome IS NULL OR trim(p_nome) = '' THEN
        RAISE EXCEPTION 'Nome da empresa é obrigatório';
    END IF;

    -- Limpa CNPJ (só números)
    v_cnpj_clean := regexp_replace(COALESCE(p_cnpj, ''), '[^0-9]', '', 'g');
    IF length(v_cnpj_clean) != 14 THEN
        RAISE EXCEPTION 'CNPJ inválido. Deve ter 14 dígitos.';
    END IF;

    -- Identifica usuário
    v_user_id := public.fin_usuario_atual();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Usuário não autenticado';
    END IF;

    -- Checa permissão (admin no tenant atual ou superadmin)
    IF NOT public.fin_eh_superadmin() THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.fin_usuarios_empresas ue
            WHERE ue.usuario_id = v_user_id
              AND ue.template = 'admin'
              AND ue.ativo = true
        ) THEN
            RAISE EXCEPTION 'Sem permissão para criar empresa';
        END IF;
    END IF;

    -- Verifica CNPJ duplicado
    IF EXISTS (SELECT 1 FROM public.fin_tenants WHERE cnpj = v_cnpj_clean) THEN
        RAISE EXCEPTION 'Já existe uma empresa cadastrada com este CNPJ';
    END IF;

    -- Cria a empresa
    INSERT INTO public.fin_tenants (nome, cnpj, setor, observacao)
    VALUES (trim(p_nome), v_cnpj_clean, p_setor, p_observacao)
    RETURNING id INTO v_tenant_id;

    -- Cria vínculo do criador como admin com permissões completas
    v_perms_admin := public.fin_template_permissoes('admin');

    INSERT INTO public.fin_usuarios_empresas (
        usuario_id, tenant_id, template, permissoes,
        is_default, ativo, criado_por
    ) VALUES (
        v_user_id, v_tenant_id, 'admin', v_perms_admin,
        false, true, v_user_id
    );

    RETURN jsonb_build_object(
        'sucesso', true,
        'tenant_id', v_tenant_id,
        'nome', p_nome,
        'cnpj', v_cnpj_clean
    );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_dashboard_kpis(p_tenant_id uuid DEFAULT NULL::uuid, p_data_ref date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id  UUID;
  v_mes_atual  TEXT := TO_CHAR(p_data_ref, 'YYYY-MM');
  v_mes_ant    TEXT := TO_CHAR(p_data_ref - INTERVAL '1 month', 'YYYY-MM');
  v_data_6m    DATE := DATE_TRUNC('month', p_data_ref - INTERVAL '5 months')::DATE;
  v_resultado  JSONB;
BEGIN
  -- Resolve tenant: explícito tem prioridade; senão usa fin_tenant_id() ou perfil do usuário
  v_tenant_id := COALESCE(
    p_tenant_id,
    fin_tenant_id(),
    (SELECT tenant_id FROM fin_usuarios WHERE auth_id = auth.uid() LIMIT 1)
  );
  IF v_tenant_id IS NULL THEN
    RETURN '{}'::JSONB;
  END IF;

  WITH
  -- Saldo total das contas ativas
  saldo AS (
    SELECT COALESCE(SUM(saldo_atual), 0) AS total
    FROM fin_contas
    WHERE tenant_id = v_tenant_id AND ativo = TRUE
  ),
  -- Receitas: pendentes, vencidas, mês atual, mês anterior
  rec AS (
    SELECT
      COALESCE(SUM(valor) FILTER (WHERE status = 'pendente'), 0)                                                    AS total_pendente,
      COALESCE(SUM(valor) FILTER (WHERE status = 'pendente' AND vencimento < p_data_ref), 0)                        AS total_vencido,
      COUNT(*)            FILTER (WHERE status = 'pendente' AND vencimento < p_data_ref)                            AS qtd_vencida,
      COALESCE(SUM(valor) FILTER (WHERE status = 'recebido' AND TO_CHAR(vencimento,'YYYY-MM') = v_mes_atual), 0)    AS total_mes,
      COALESCE(SUM(valor) FILTER (WHERE status = 'recebido' AND TO_CHAR(vencimento,'YYYY-MM') = v_mes_ant), 0)      AS total_ant
    FROM fin_receitas
    WHERE tenant_id = v_tenant_id
  ),
  -- Despesas: pendentes, vencidas, mês atual, mês anterior
  desp AS (
    SELECT
      COALESCE(SUM(valor) FILTER (WHERE status = 'pendente'), 0)                                                    AS total_pendente,
      COALESCE(SUM(valor) FILTER (WHERE status = 'pendente' AND vencimento < p_data_ref), 0)                        AS total_vencido,
      COUNT(*)            FILTER (WHERE status = 'pendente' AND vencimento < p_data_ref)                            AS qtd_vencida,
      COALESCE(SUM(valor) FILTER (WHERE status = 'pago'      AND TO_CHAR(vencimento,'YYYY-MM') = v_mes_atual), 0)   AS total_mes,
      COALESCE(SUM(valor) FILTER (WHERE status = 'pago'      AND TO_CHAR(vencimento,'YYYY-MM') = v_mes_ant), 0)     AS total_ant
    FROM fin_despesas
    WHERE tenant_id = v_tenant_id
  ),
  -- Últimos 6 meses (gera série + agrega receitas e despesas)
  meses_serie AS (
    SELECT TO_CHAR(d,'YYYY-MM') AS mes
    FROM generate_series(v_data_6m, p_data_ref, INTERVAL '1 month') AS d
  ),
  rec_6m AS (
    SELECT
      TO_CHAR(vencimento,'YYYY-MM') AS mes,
      COALESCE(SUM(valor),0) AS total_previsto,
      COALESCE(SUM(valor) FILTER (WHERE status = 'recebido'),0) AS total_realizado
    FROM fin_receitas
    WHERE tenant_id = v_tenant_id
      AND vencimento >= v_data_6m
      AND vencimento <= (DATE_TRUNC('month', p_data_ref) + INTERVAL '1 month' - INTERVAL '1 day')::DATE
    GROUP BY TO_CHAR(vencimento,'YYYY-MM')
  ),
  desp_6m AS (
    SELECT
      TO_CHAR(vencimento,'YYYY-MM') AS mes,
      COALESCE(SUM(valor),0) AS total_previsto,
      COALESCE(SUM(valor) FILTER (WHERE status = 'pago'),0) AS total_realizado
    FROM fin_despesas
    WHERE tenant_id = v_tenant_id
      AND vencimento >= v_data_6m
      AND vencimento <= (DATE_TRUNC('month', p_data_ref) + INTERVAL '1 month' - INTERVAL '1 day')::DATE
    GROUP BY TO_CHAR(vencimento,'YYYY-MM')
  ),
  meses_6 AS (
    SELECT
      ms.mes,
      COALESCE(r.total_previsto,  0) AS rec_previsto,
      COALESCE(r.total_realizado, 0) AS rec_realizado,
      COALESCE(d.total_previsto,  0) AS desp_previsto,
      COALESCE(d.total_realizado, 0) AS desp_realizado
    FROM meses_serie ms
    LEFT JOIN rec_6m  r ON r.mes = ms.mes
    LEFT JOIN desp_6m d ON d.mes = ms.mes
    ORDER BY ms.mes
  )
  SELECT JSONB_BUILD_OBJECT(
    'saldo_total',          (SELECT total FROM saldo),
    'total_a_receber',      (SELECT total_pendente FROM rec),
    'total_a_pagar',        (SELECT total_pendente FROM desp),
    'rec_vencido',          (SELECT total_vencido FROM rec),
    'desp_vencido',         (SELECT total_vencido FROM desp),
    'qtd_rec_vencida',      (SELECT qtd_vencida FROM rec),
    'qtd_desp_vencida',     (SELECT qtd_vencida FROM desp),
    'rec_mes',              (SELECT total_mes FROM rec),
    'desp_mes',             (SELECT total_mes FROM desp),
    'rec_ant',              (SELECT total_ant FROM rec),
    'desp_ant',             (SELECT total_ant FROM desp),
    'meses_6',              (SELECT COALESCE(JSONB_AGG(meses_6.* ORDER BY mes), '[]'::JSONB) FROM meses_6),
    'data_ref',             p_data_ref,
    'mes_atual',            v_mes_atual,
    'mes_ant',              v_mes_ant
  )
  INTO v_resultado;

  RETURN v_resultado;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_depara_stats(p_tenant_id uuid)
 RETURNS TABLE(total_financeiras integer, total_contabeis integer, total_vinculos integer, financeiras_vinculadas integer, financeiras_pendentes integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT
    (SELECT COUNT(*)::INT FROM fin_plano_financeiro WHERE tenant_id = p_tenant_id AND ativo AND tipo = 'A'),
    (SELECT COUNT(*)::INT FROM fin_plano_contabil   WHERE tenant_id = p_tenant_id AND ativo AND sintetica = FALSE),
    (SELECT COUNT(*)::INT FROM fin_plano_depara     WHERE tenant_id = p_tenant_id),
    (SELECT COUNT(DISTINCT conta_financeira_id)::INT FROM fin_plano_depara WHERE tenant_id = p_tenant_id),
    (SELECT COUNT(*)::INT FROM fin_plano_financeiro f
       WHERE f.tenant_id = p_tenant_id AND f.ativo AND f.tipo = 'A'
       AND NOT EXISTS (SELECT 1 FROM fin_plano_depara d WHERE d.conta_financeira_id = f.id));
$function$
;
CREATE OR REPLACE FUNCTION public.fin_dre(p_data_inicio date, p_data_fim date, p_tenant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id UUID;
  v_resultado JSONB;
BEGIN
  v_tenant_id := COALESCE(
    p_tenant_id,
    fin_tenant_id(),
    (SELECT tenant_id FROM fin_usuarios WHERE auth_id = auth.uid() LIMIT 1)
  );
  IF v_tenant_id IS NULL THEN
    RETURN '{}'::JSONB;
  END IF;

  WITH
  rec_cat AS (
    SELECT
      COALESCE(c.nome, '(sem categoria)') AS categoria,
      SUM(r.valor) AS valor
    FROM fin_receitas r
    LEFT JOIN fin_categorias c ON c.id = r.categoria_id
    WHERE r.tenant_id = v_tenant_id
      AND r.status = 'recebido'
      AND r.vencimento BETWEEN p_data_inicio AND p_data_fim
    GROUP BY COALESCE(c.nome, '(sem categoria)')
  ),
  desp_cat AS (
    SELECT
      COALESCE(c.nome, '(sem categoria)') AS categoria,
      SUM(d.valor) AS valor
    FROM fin_despesas d
    LEFT JOIN fin_categorias c ON c.id = d.categoria_id
    WHERE d.tenant_id = v_tenant_id
      AND d.status = 'pago'
      AND d.vencimento BETWEEN p_data_inicio AND p_data_fim
    GROUP BY COALESCE(c.nome, '(sem categoria)')
  ),
  totais AS (
    SELECT
      COALESCE((SELECT SUM(valor) FROM rec_cat), 0)  AS rec_realizada,
      COALESCE((SELECT SUM(valor) FROM desp_cat), 0) AS desp_realizada,
      COALESCE((SELECT SUM(valor) FROM fin_receitas
                WHERE tenant_id = v_tenant_id AND status = 'pendente'
                  AND vencimento BETWEEN p_data_inicio AND p_data_fim), 0) AS rec_pendente,
      COALESCE((SELECT SUM(valor) FROM fin_despesas
                WHERE tenant_id = v_tenant_id AND status = 'pendente'
                  AND vencimento BETWEEN p_data_inicio AND p_data_fim), 0) AS desp_pendente
  )
  SELECT JSONB_BUILD_OBJECT(
    'por_categoria_receita', COALESCE((
      SELECT JSONB_AGG(JSONB_BUILD_OBJECT('categoria', categoria, 'valor', valor) ORDER BY valor DESC)
      FROM rec_cat
    ), '[]'::JSONB),
    'por_categoria_despesa', COALESCE((
      SELECT JSONB_AGG(JSONB_BUILD_OBJECT('categoria', categoria, 'valor', valor) ORDER BY valor DESC)
      FROM desp_cat
    ), '[]'::JSONB),
    'rec_realizada',  (SELECT rec_realizada  FROM totais),
    'desp_realizada', (SELECT desp_realizada FROM totais),
    'rec_pendente',   (SELECT rec_pendente   FROM totais),
    'desp_pendente',  (SELECT desp_pendente  FROM totais),
    'data_inicio',    p_data_inicio,
    'data_fim',       p_data_fim
  )
  INTO v_resultado;

  RETURN v_resultado;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_dre_por_plano(p_data_inicio date, p_data_fim date, p_tenant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id UUID;
  v_resultado JSONB;
BEGIN
  v_tenant_id := COALESCE(
    p_tenant_id,
    fin_tenant_id(),
    (SELECT tenant_id FROM fin_usuarios WHERE auth_id = auth.uid() LIMIT 1)
  );
  IF v_tenant_id IS NULL THEN
    RETURN '{}'::JSONB;
  END IF;

  WITH
  -- Receitas: agrupa por conta financeira (via categoria → conta_financeira_id)
  rec_grp AS (
    SELECT
      COALESCE(pf.codigo, '(sem vínculo)') AS conta_codigo,
      COALESCE(pf.descricao,
               CASE WHEN pf.codigo IS NULL THEN '(categorias sem conta financeira)' END,
               '(sem vínculo)') AS conta_descricao,
      pf.grupo AS grupo,
      SUM(r.valor) AS valor
    FROM fin_receitas r
    LEFT JOIN fin_categorias c       ON c.id = r.categoria_id
    LEFT JOIN fin_plano_financeiro pf ON pf.id = c.conta_financeira_id
    WHERE r.tenant_id = v_tenant_id
      AND r.status = 'recebido'
      AND r.vencimento BETWEEN p_data_inicio AND p_data_fim
    GROUP BY pf.codigo, pf.descricao, pf.grupo
  ),
  -- Despesas idem
  desp_grp AS (
    SELECT
      COALESCE(pf.codigo, '(sem vínculo)') AS conta_codigo,
      COALESCE(pf.descricao,
               CASE WHEN pf.codigo IS NULL THEN '(categorias sem conta financeira)' END,
               '(sem vínculo)') AS conta_descricao,
      pf.grupo AS grupo,
      SUM(d.valor) AS valor
    FROM fin_despesas d
    LEFT JOIN fin_categorias c       ON c.id = d.categoria_id
    LEFT JOIN fin_plano_financeiro pf ON pf.id = c.conta_financeira_id
    WHERE d.tenant_id = v_tenant_id
      AND d.status = 'pago'
      AND d.vencimento BETWEEN p_data_inicio AND p_data_fim
    GROUP BY pf.codigo, pf.descricao, pf.grupo
  ),
  totais AS (
    SELECT
      COALESCE((SELECT SUM(valor) FROM rec_grp), 0)  AS rec_realizada,
      COALESCE((SELECT SUM(valor) FROM desp_grp), 0) AS desp_realizada,
      COALESCE((SELECT SUM(valor) FROM fin_receitas
                WHERE tenant_id = v_tenant_id AND status = 'pendente'
                  AND vencimento BETWEEN p_data_inicio AND p_data_fim), 0) AS rec_pendente,
      COALESCE((SELECT SUM(valor) FROM fin_despesas
                WHERE tenant_id = v_tenant_id AND status = 'pendente'
                  AND vencimento BETWEEN p_data_inicio AND p_data_fim), 0) AS desp_pendente
  )
  SELECT JSONB_BUILD_OBJECT(
    'por_plano_receita', COALESCE((
      SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
        'codigo', conta_codigo,
        'descricao', conta_descricao,
        'grupo', grupo,
        'valor', valor
      ) ORDER BY conta_codigo) FROM rec_grp
    ), '[]'::JSONB),
    'por_plano_despesa', COALESCE((
      SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
        'codigo', conta_codigo,
        'descricao', conta_descricao,
        'grupo', grupo,
        'valor', valor
      ) ORDER BY conta_codigo) FROM desp_grp
    ), '[]'::JSONB),
    'rec_realizada',  (SELECT rec_realizada  FROM totais),
    'desp_realizada', (SELECT desp_realizada FROM totais),
    'rec_pendente',   (SELECT rec_pendente   FROM totais),
    'desp_pendente',  (SELECT desp_pendente  FROM totais),
    'data_inicio',    p_data_inicio,
    'data_fim',       p_data_fim
  )
  INTO v_resultado;

  RETURN v_resultado;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_eh_superadmin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM fin_superadmins sa
      JOIN fin_usuarios u ON u.email = sa.email
     WHERE u.auth_id = auth.uid()
  )
$function$
;
CREATE OR REPLACE FUNCTION public.fin_fluxo(p_data_inicio date, p_data_fim date, p_tenant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id UUID;
  v_resultado JSONB;
BEGIN
  v_tenant_id := COALESCE(
    p_tenant_id,
    fin_tenant_id(),
    (SELECT tenant_id FROM fin_usuarios WHERE auth_id = auth.uid() LIMIT 1)
  );
  IF v_tenant_id IS NULL THEN
    RETURN '{}'::JSONB;
  END IF;

  WITH
  meses_serie AS (
    SELECT TO_CHAR(d, 'YYYY-MM') AS mes
    FROM generate_series(
      DATE_TRUNC('month', p_data_inicio)::DATE,
      DATE_TRUNC('month', p_data_fim)::DATE,
      INTERVAL '1 month'
    ) AS d
  ),
  rec_agg AS (
    SELECT
      TO_CHAR(vencimento,'YYYY-MM') AS mes,
      COALESCE(SUM(valor), 0) AS total_previsto,
      COALESCE(SUM(valor) FILTER (WHERE status = 'recebido'), 0) AS total_realizado
    FROM fin_receitas
    WHERE tenant_id = v_tenant_id
      AND vencimento BETWEEN p_data_inicio AND p_data_fim
    GROUP BY TO_CHAR(vencimento,'YYYY-MM')
  ),
  desp_agg AS (
    SELECT
      TO_CHAR(vencimento,'YYYY-MM') AS mes,
      COALESCE(SUM(valor), 0) AS total_previsto,
      COALESCE(SUM(valor) FILTER (WHERE status = 'pago'), 0) AS total_realizado
    FROM fin_despesas
    WHERE tenant_id = v_tenant_id
      AND vencimento BETWEEN p_data_inicio AND p_data_fim
    GROUP BY TO_CHAR(vencimento,'YYYY-MM')
  ),
  combinado AS (
    SELECT
      ms.mes,
      COALESCE(r.total_previsto,   0) AS rec_previsto,
      COALESCE(r.total_realizado,  0) AS rec_realizado,
      COALESCE(d.total_previsto,   0) AS desp_previsto,
      COALESCE(d.total_realizado,  0) AS desp_realizado
    FROM meses_serie ms
    LEFT JOIN rec_agg  r ON r.mes = ms.mes
    LEFT JOIN desp_agg d ON d.mes = ms.mes
    ORDER BY ms.mes
  )
  SELECT JSONB_BUILD_OBJECT(
    'meses', COALESCE((SELECT JSONB_AGG(combinado.* ORDER BY mes) FROM combinado), '[]'::JSONB),
    'total_rec_previsto',   COALESCE((SELECT SUM(rec_previsto)   FROM combinado), 0),
    'total_rec_realizado',  COALESCE((SELECT SUM(rec_realizado)  FROM combinado), 0),
    'total_desp_previsto',  COALESCE((SELECT SUM(desp_previsto)  FROM combinado), 0),
    'total_desp_realizado', COALESCE((SELECT SUM(desp_realizado) FROM combinado), 0),
    'data_inicio',          p_data_inicio,
    'data_fim',             p_data_fim
  )
  INTO v_resultado;

  RETURN v_resultado;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_gerar_convite(p_email text, p_nome text, p_template text DEFAULT 'leitura'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id     uuid;
    v_user_email  text;
    v_tenant_id   uuid;
    v_token       uuid;
    v_perms       jsonb;
BEGIN
    -- Validações
    IF p_email IS NULL OR p_email = '' THEN
        RAISE EXCEPTION 'E-mail é obrigatório';
    END IF;
    IF p_nome IS NULL OR p_nome = '' THEN
        RAISE EXCEPTION 'Nome é obrigatório';
    END IF;
    IF p_template NOT IN ('admin','financeiro','leitura') THEN
        RAISE EXCEPTION 'Template inválido: %', p_template;
    END IF;

    -- Identifica admin que está convidando
    SELECT id, email INTO v_user_id, v_user_email
    FROM public.fin_usuarios WHERE auth_id = auth.uid() LIMIT 1;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Usuário não autenticado';
    END IF;

    -- Identifica tenant ativo
    v_tenant_id := public.fin_tenant_atual();
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Empresa ativa não definida';
    END IF;

    -- Checa permissão
    IF NOT public.fin_pode('usuarios','c') AND NOT public.fin_eh_superadmin() THEN
        RAISE EXCEPTION 'Sem permissão para convidar usuários';
    END IF;

    -- Bloqueia convite duplicado ativo pro mesmo email/tenant
    IF EXISTS (
        SELECT 1 FROM public.fin_convites
        WHERE tenant_id = v_tenant_id
          AND lower(email) = lower(p_email)
          AND usado_em IS NULL
          AND expira_em > now()
    ) THEN
        RAISE EXCEPTION 'Já existe um convite ativo para este e-mail';
    END IF;

    -- Bloqueia convite pra usuário já vinculado a esse tenant
    IF EXISTS (
        SELECT 1 FROM public.fin_usuarios u
        JOIN public.fin_usuarios_empresas ue ON ue.usuario_id = u.id
        WHERE lower(u.email) = lower(p_email) AND ue.tenant_id = v_tenant_id
    ) THEN
        RAISE EXCEPTION 'Este e-mail já é usuário desta empresa';
    END IF;

    -- Carrega permissões do template
    v_perms := public.fin_template_permissoes(p_template);

    -- Cria convite
    INSERT INTO public.fin_convites (
        tenant_id, email, nome, template, permissoes,
        criado_por, criado_por_email
    ) VALUES (
        v_tenant_id, lower(p_email), p_nome, p_template, v_perms,
        v_user_id, v_user_email
    )
    RETURNING token INTO v_token;

    RETURN jsonb_build_object(
        'token',     v_token,
        'email',     p_email,
        'nome',      p_nome,
        'template',  p_template,
        'expira_em', (now() + interval '7 days')::text
    );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_is_admin_do_tenant(p_tenant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT
    -- Bypass: superadmin pode tudo em qualquer tenant
    EXISTS (
      SELECT 1 FROM public.fin_superadmins s
      JOIN auth.users au ON au.id = (SELECT auth.uid())
      WHERE lower(s.email) = lower(au.email)
    )
    OR
    -- Regra original: admin do tenant
    EXISTS (
      SELECT 1 FROM public.fin_usuarios u
      WHERE u.auth_id = (SELECT auth.uid())
        AND u.tenant_id = p_tenant_id
        AND u.perfil IN ('admin','superadmin')
        AND u.ativo = true
    );
$function$
;
CREATE OR REPLACE FUNCTION public.fin_listar_convites()
 RETURNS TABLE(token uuid, email text, nome text, template text, criado_em timestamp with time zone, expira_em timestamp with time zone, usado_em timestamp with time zone, criado_por_email text, status text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NOT public.fin_pode('usuarios','v') AND NOT public.fin_eh_superadmin() THEN
        RAISE EXCEPTION 'Sem permissão';
    END IF;

    RETURN QUERY
    SELECT c.token, c.email, c.nome, c.template,
           c.criado_em, c.expira_em, c.usado_em, c.criado_por_email,
           CASE
               WHEN c.usado_em IS NOT NULL THEN 'usado'
               WHEN c.expira_em < now() THEN 'expirado'
               ELSE 'ativo'
           END
    FROM public.fin_convites c
    WHERE c.tenant_id = public.fin_tenant_atual()
    ORDER BY c.criado_em DESC;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_minhas_empresas()
 RETURNS TABLE(tenant_id uuid, nome text, template text, is_default boolean, permissoes jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT t.id, t.nome, ue.template, ue.is_default, ue.permissoes
    FROM public.fin_usuarios u
    JOIN public.fin_usuarios_empresas ue ON ue.usuario_id = u.id
    JOIN public.fin_tenants t ON t.id = ue.tenant_id
    WHERE u.auth_id = auth.uid() AND ue.ativo = true
    ORDER BY ue.is_default DESC, t.nome;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_modulo_da_tabela(p_tabela text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE p_tabela
        -- Movimentação financeira
        WHEN 'fin_receitas'        THEN 'receber'
        WHEN 'fin_despesas'        THEN 'pagar'
        WHEN 'fin_movimentacoes'   THEN 'caixa_bancos'
        WHEN 'fin_transferencias'  THEN 'caixa_bancos'
        WHEN 'fin_contas'          THEN 'caixa_bancos'
        -- Cadastros
        WHEN 'fin_clientes'        THEN 'cadastros'
        WHEN 'fin_fornecedores'    THEN 'cadastros'
        WHEN 'fin_categorias'      THEN 'cadastros'
        WHEN 'fin_pessoal'         THEN 'cadastros'
        WHEN 'fin_anexos'          THEN 'cadastros'
        -- Recorrência / planejamento
        WHEN 'fin_recorrencias'    THEN 'recorrencias'
        WHEN 'fin_metas'           THEN 'metas'
        WHEN 'fin_impostos'        THEN 'impostos'
        -- Ferramentas
        WHEN 'fin_documentos'      THEN 'importacao_ia'
        -- Administração
        WHEN 'fin_config'          THEN 'configuracoes'
        WHEN 'fin_convites'        THEN 'usuarios'
        ELSE 'configuracoes'
    END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_pode(p_modulo text, p_acao text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_tenant uuid; v_perm jsonb;
BEGIN
    IF p_acao NOT IN ('v','c','e','x') THEN RETURN false; END IF;
    v_tenant := public.fin_tenant_atual();
    IF v_tenant IS NULL THEN RETURN false; END IF;

    SELECT ue.permissoes INTO v_perm
    FROM public.fin_usuarios u
    JOIN public.fin_usuarios_empresas ue ON ue.usuario_id = u.id
    WHERE u.auth_id = auth.uid() AND ue.tenant_id = v_tenant AND ue.ativo = true
    LIMIT 1;
    IF v_perm IS NULL THEN RETURN false; END IF;
    RETURN COALESCE((v_perm -> p_modulo ->> p_acao)::boolean, false);
END;$function$
;
CREATE OR REPLACE FUNCTION public.fin_recalcular_saldo_conta(p_conta_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_inicial numeric;
  v_entradas numeric;
  v_saidas numeric;
  v_novo numeric;
BEGIN
  SELECT COALESCE(saldo_inicial, 0) INTO v_inicial
    FROM fin_contas WHERE id = p_conta_id;

  IF v_inicial IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(SUM(valor), 0) INTO v_entradas
    FROM fin_movimentacoes
    WHERE conta_id = p_conta_id AND tipo = 'entrada';

  SELECT COALESCE(SUM(valor), 0) INTO v_saidas
    FROM fin_movimentacoes
    WHERE conta_id = p_conta_id AND tipo = 'saida';

  v_novo := v_inicial + v_entradas - v_saidas;

  UPDATE fin_contas
     SET saldo_atual = v_novo
   WHERE id = p_conta_id;

  RETURN v_novo;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_registrar_autorizacao(p_tabela text, p_motivo text, p_dados jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id   uuid;
    v_user_email text;
    v_tenant    uuid;
    v_id        bigint;
BEGIN
    -- Validação
    IF p_motivo IS NULL OR length(trim(p_motivo)) < 5 THEN
        RAISE EXCEPTION 'Motivo é obrigatório (mínimo 5 caracteres)';
    END IF;

    -- Identifica usuário e tenant
    SELECT id, email INTO v_user_id, v_user_email
    FROM public.fin_usuarios
    WHERE auth_id = auth.uid()
    LIMIT 1;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Usuário não autenticado';
    END IF;

    v_tenant := public.fin_tenant_atual();
    IF v_tenant IS NULL THEN
        RAISE EXCEPTION 'Tenant não definido';
    END IF;

    -- Insere registro em fin_auditoria com operacao especial
    INSERT INTO public.fin_auditoria (
        tenant_id, usuario_id, usuario_email,
        tabela, operacao, registro_id,
        dados_antes, dados_depois, criado_em
    ) VALUES (
        v_tenant, v_user_id, v_user_email,
        COALESCE(p_tabela, 'fin_documentos'),
        'AUTORIZACAO_DIVERGENCIA',
        NULL,
        NULL,
        jsonb_build_object(
            'motivo', p_motivo,
            'autorizado_em', now(),
            'autorizado_por', v_user_email,
            'contexto', COALESCE(p_dados, '{}'::jsonb)
        ),
        now()
    ) RETURNING id INTO v_id;

    RETURN jsonb_build_object(
        'sucesso', true,
        'id', v_id,
        'motivo', p_motivo
    );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_regras_categ_touch()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END $function$
;
CREATE OR REPLACE FUNCTION public.fin_remover_usuario_empresa(p_usuario_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_tenant uuid; v_self uuid;
BEGIN
    IF NOT public.fin_pode('usuarios','x') AND NOT public.fin_eh_superadmin() THEN
        RAISE EXCEPTION 'Sem permissão';
    END IF;

    v_tenant := public.fin_tenant_atual();
    v_self   := public.fin_usuario_atual();
    IF p_usuario_id = v_self THEN
        RAISE EXCEPTION 'Você não pode remover a si mesmo';
    END IF;

    DELETE FROM public.fin_usuarios_empresas
    WHERE usuario_id = p_usuario_id AND tenant_id = v_tenant;

    RETURN FOUND;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_revogar_convite(p_token uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NOT public.fin_pode('usuarios','x') AND NOT public.fin_eh_superadmin() THEN
        RAISE EXCEPTION 'Sem permissão';
    END IF;

    DELETE FROM public.fin_convites
    WHERE token = p_token
      AND tenant_id = public.fin_tenant_atual()
      AND usado_em IS NULL;

    RETURN FOUND;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_seed_planos_para_tenant(p_tenant_id uuid)
 RETURNS TABLE(qtd_financeiro integer, qtd_contabil integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_qtd_fin  INT := 0;
  v_qtd_cont INT := 0;
BEGIN
  -- ------- FINANCEIRO (inalterado) -------
  INSERT INTO fin_plano_financeiro
    (tenant_id, codigo, descricao, tipo, grupo, nivel, ordem, ativo)
  SELECT p_tenant_id, t.codigo, t.descricao, t.tipo, t.grupo, t.nivel, t.ordem, t.ativo
  FROM fin_template_plano_financeiro t
  WHERE t.ativo = TRUE
  ON CONFLICT (tenant_id, codigo) DO NOTHING;

  GET DIAGNOSTICS v_qtd_fin = ROW_COUNT;

  UPDATE fin_plano_financeiro f
  SET conta_pai_id = pai.id
  FROM fin_template_plano_financeiro t,
       fin_plano_financeiro pai
  WHERE f.tenant_id = p_tenant_id
    AND f.codigo = t.codigo
    AND t.codigo_pai IS NOT NULL
    AND pai.tenant_id = p_tenant_id
    AND pai.codigo = t.codigo_pai
    AND f.conta_pai_id IS NULL;

  -- ------- CONTÁBIL (NOVA LÓGICA: rastreio por template_seq) -------
  -- Insere todas as contas do template, marcando template_seq
  INSERT INTO fin_plano_contabil
    (tenant_id, codigo, descricao, sintetica, apelido, natureza, entra_balanco, nivel, ordem, ativo, template_seq)
  SELECT p_tenant_id, t.codigo, t.descricao, t.sintetica, t.apelido, t.natureza,
         t.entra_balanco, t.nivel, t.ordem, t.ativo, t.seq
  FROM fin_template_plano_contabil t
  WHERE t.ativo = TRUE
  ON CONFLICT (tenant_id, template_seq) DO NOTHING;

  GET DIAGNOSTICS v_qtd_cont = ROW_COUNT;

  -- Resolve conta_pai_id usando o vínculo template_seq → pai_seq
  UPDATE fin_plano_contabil c
  SET conta_pai_id = pai.id
  FROM fin_template_plano_contabil t
  JOIN fin_plano_contabil pai
    ON pai.tenant_id = p_tenant_id
   AND pai.template_seq = t.pai_seq
  WHERE c.tenant_id = p_tenant_id
    AND c.template_seq = t.seq
    AND t.pai_seq IS NOT NULL
    AND c.conta_pai_id IS NULL;

  RETURN QUERY SELECT v_qtd_fin, v_qtd_cont;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_seed_regras_categ_novo_tenant()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  INSERT INTO public.fin_regras_categorizacao (tenant_id, nome, tipo, padroes, prioridade, is_default) VALUES
  (NEW.id, 'Tarifas Bancárias', 'despesa',
    jsonb_build_array('\bTARIFA\b','\bCESTA\b','\bMANUTEN[CÇ][AÃ]O\b','\bIOF\b','\bANUIDADE\b','\bBAIXA\s+DE\s+T[ÍI]TULO','\bPLANO\s+(INT\s+)?CAPITAL','\bINTEGR\.?\s*CAPITAL','\bENCERRAMENTO\s+DE\s+CONTA','\bDOC\s+ELET','\bTED\s+ELET'),
    10, true),
  (NEW.id, 'Tributos', 'despesa',
    jsonb_build_array('\bRECEITA\s+FEDERAL\b','\bDARF\b','\bDAS\b','\bGPS\b','\bINSS\b','\bISS\b','\bICMS\b','\bIPVA\b','\bIPTU\b','\bSIMPLES\s+NACIONAL\b','\bFGTS\b'),
    20, true),
  (NEW.id, 'Aplicações Financeiras', 'ambos',
    jsonb_build_array('\bAPLIC\.?\s*FINANC','\bRESGATE\s+APLIC','\bFUNDOS\s+CAPTACAO','\bRENDIMENTO\s+APLIC'),
    30, true),
  (NEW.id, 'Recebimentos de Cobrança', 'receita',
    jsonb_build_array('\bLIQ\.?\s*COBRANCA','\bLIQUIDAC[AÃ]O\s+(?:DE\s+)?COBRANC'),
    40, true);
  RETURN NEW;
END $function$
;
CREATE OR REPLACE FUNCTION public.fin_set_tenant(p_tenant_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_user_id uuid;
BEGIN
    SELECT id INTO v_user_id FROM public.fin_usuarios WHERE auth_id = auth.uid() LIMIT 1;
    IF v_user_id IS NULL THEN RETURN false; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.fin_usuarios_empresas
        WHERE usuario_id = v_user_id AND tenant_id = p_tenant_id AND ativo = true
    ) THEN RETURN false; END IF;
    PERFORM set_config('app.current_tenant', p_tenant_id::text, false);
    RETURN true;
END;$function$
;
CREATE OR REPLACE FUNCTION public.fin_set_tenant_persistente(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id uuid;
    v_existe  boolean;
BEGIN
    -- Identifica o usuário autenticado
    SELECT id INTO v_user_id
    FROM public.fin_usuarios
    WHERE auth_id = auth.uid()
    LIMIT 1;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Usuário não autenticado';
    END IF;

    -- Verifica vínculo
    SELECT EXISTS (
        SELECT 1 FROM public.fin_usuarios_empresas
        WHERE usuario_id = v_user_id
          AND tenant_id  = p_tenant_id
          AND ativo = true
    ) INTO v_existe;

    IF NOT v_existe AND NOT public.fin_eh_superadmin() THEN
        RAISE EXCEPTION 'Sem vínculo com a empresa solicitada';
    END IF;

    -- Tira is_default de TODOS os vínculos do usuário
    UPDATE public.fin_usuarios_empresas
    SET is_default = false
    WHERE usuario_id = v_user_id
      AND is_default = true;

    -- Marca o tenant escolhido como default
    IF v_existe THEN
        UPDATE public.fin_usuarios_empresas
        SET is_default = true
        WHERE usuario_id = v_user_id
          AND tenant_id  = p_tenant_id;
    ELSE
        -- Superadmin sem vínculo: cria
        INSERT INTO public.fin_usuarios_empresas (
            usuario_id, tenant_id, template, permissoes,
            is_default, ativo, criado_por
        ) VALUES (
            v_user_id, p_tenant_id, 'admin',
            public.fin_template_permissoes('admin'),
            true, true, v_user_id
        )
        ON CONFLICT (usuario_id, tenant_id) DO UPDATE
        SET is_default = true, ativo = true;
    END IF;

    -- Também seta o app.current_tenant da sessão atual (cinto + suspensório)
    PERFORM set_config('app.current_tenant', p_tenant_id::text, false);

    RETURN jsonb_build_object(
        'sucesso', true,
        'tenant_id', p_tenant_id
    );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_template_permissoes(p_template text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE p_template
        WHEN 'admin' THEN '{
            "dashboard":     {"v":true,"c":true,"e":true,"x":true},
            "receber":       {"v":true,"c":true,"e":true,"x":true},
            "pagar":         {"v":true,"c":true,"e":true,"x":true},
            "caixa_bancos":  {"v":true,"c":true,"e":true,"x":true},
            "cadastros":     {"v":true,"c":true,"e":true,"x":true},
            "recorrencias":  {"v":true,"c":true,"e":true,"x":true},
            "metas":         {"v":true,"c":true,"e":true,"x":true},
            "impostos":      {"v":true,"c":true,"e":true,"x":true},
            "dre":           {"v":true,"c":true,"e":true,"x":true},
            "fluxo_caixa":   {"v":true,"c":true,"e":true,"x":true},
            "importacao_ia": {"v":true,"c":true,"e":true,"x":true},
            "configuracoes": {"v":true,"c":true,"e":true,"x":true},
            "usuarios":      {"v":true,"c":true,"e":true,"x":true}
        }'::jsonb
        WHEN 'financeiro' THEN '{
            "dashboard":     {"v":true, "c":false,"e":false,"x":false},
            "receber":       {"v":true, "c":true, "e":true, "x":false},
            "pagar":         {"v":true, "c":true, "e":true, "x":false},
            "caixa_bancos":  {"v":true, "c":true, "e":true, "x":false},
            "cadastros":     {"v":true, "c":true, "e":true, "x":false},
            "recorrencias":  {"v":true, "c":true, "e":true, "x":false},
            "metas":         {"v":true, "c":false,"e":false,"x":false},
            "impostos":      {"v":true, "c":true, "e":true, "x":false},
            "dre":           {"v":true, "c":false,"e":false,"x":false},
            "fluxo_caixa":   {"v":true, "c":false,"e":false,"x":false},
            "importacao_ia": {"v":true, "c":true, "e":false,"x":false},
            "configuracoes": {"v":false,"c":false,"e":false,"x":false},
            "usuarios":      {"v":false,"c":false,"e":false,"x":false}
        }'::jsonb
        WHEN 'leitura' THEN '{
            "dashboard":     {"v":true, "c":false,"e":false,"x":false},
            "receber":       {"v":true, "c":false,"e":false,"x":false},
            "pagar":         {"v":true, "c":false,"e":false,"x":false},
            "caixa_bancos":  {"v":true, "c":false,"e":false,"x":false},
            "cadastros":     {"v":true, "c":false,"e":false,"x":false},
            "recorrencias":  {"v":true, "c":false,"e":false,"x":false},
            "metas":         {"v":true, "c":false,"e":false,"x":false},
            "impostos":      {"v":true, "c":false,"e":false,"x":false},
            "dre":           {"v":true, "c":false,"e":false,"x":false},
            "fluxo_caixa":   {"v":true, "c":false,"e":false,"x":false},
            "importacao_ia": {"v":false,"c":false,"e":false,"x":false},
            "configuracoes": {"v":false,"c":false,"e":false,"x":false},
            "usuarios":      {"v":false,"c":false,"e":false,"x":false}
        }'::jsonb
        ELSE '{}'::jsonb
    END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_tenant_atual()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_tenant uuid; v_user_id uuid;
BEGIN
    BEGIN
        v_tenant := current_setting('app.current_tenant', true)::uuid;
        IF v_tenant IS NOT NULL THEN
            SELECT u.id INTO v_user_id
            FROM public.fin_usuarios u WHERE u.auth_id = auth.uid() LIMIT 1;
            IF v_user_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM public.fin_usuarios_empresas
                WHERE usuario_id = v_user_id AND tenant_id = v_tenant AND ativo = true
            ) THEN RETURN v_tenant; END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL; END;

    SELECT ue.tenant_id INTO v_tenant
    FROM public.fin_usuarios u
    JOIN public.fin_usuarios_empresas ue ON ue.usuario_id = u.id
    WHERE u.auth_id = auth.uid() AND ue.is_default = true AND ue.ativo = true
    LIMIT 1;
    RETURN v_tenant;
END;$function$
;
CREATE OR REPLACE FUNCTION public.fin_tenant_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT tenant_id FROM fin_usuarios WHERE auth_id = auth.uid() LIMIT 1;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_tenants_acessiveis()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Caso 1: superadmin → todos os tenants
  SELECT t.id
    FROM fin_tenants t
   WHERE EXISTS (
     SELECT 1 FROM fin_superadmins sa
       JOIN fin_usuarios u ON u.email = sa.email
      WHERE u.auth_id = auth.uid()
   )
  UNION
  -- Caso 2: usuário comum → só os tenants vinculados ativos
  SELECT ue.tenant_id
    FROM fin_usuarios_empresas ue
    JOIN fin_usuarios u ON u.id = ue.usuario_id
   WHERE u.auth_id = auth.uid()
     AND ue.ativo = true
$function$
;
CREATE OR REPLACE FUNCTION public.fin_trg_empresa_seed_planos()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  PERFORM fin_seed_planos_para_tenant(NEW.id);
  RETURN NEW;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_usuario_atual()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT id FROM public.fin_usuarios WHERE auth_id = auth.uid() LIMIT 1;
$function$
;
CREATE OR REPLACE FUNCTION public.fin_validar_convite(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_conv record; v_tenant_nome text;
BEGIN
    SELECT c.*, t.nome AS tenant_nome
    INTO v_conv
    FROM public.fin_convites c
    JOIN public.fin_tenants t ON t.id = c.tenant_id
    WHERE c.token = p_token;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('valido', false, 'erro', 'Convite não encontrado');
    END IF;

    IF v_conv.usado_em IS NOT NULL THEN
        RETURN jsonb_build_object('valido', false, 'erro', 'Convite já foi utilizado');
    END IF;

    IF v_conv.expira_em < now() THEN
        RETURN jsonb_build_object('valido', false, 'erro', 'Convite expirado');
    END IF;

    RETURN jsonb_build_object(
        'valido',   true,
        'email',    v_conv.email,
        'nome',     v_conv.nome,
        'empresa',  v_conv.tenant_nome,
        'template', v_conv.template
    );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.fn_atualizar_saldo_conta()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE fin_contas
    SET saldo_atual = COALESCE(saldo_atual, 0) +
      CASE WHEN NEW.tipo = 'entrada' THEN NEW.valor ELSE -NEW.valor END
    WHERE id = NEW.conta_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE fin_contas
    SET saldo_atual = COALESCE(saldo_atual, 0) -
      CASE WHEN OLD.tipo = 'entrada' THEN OLD.valor ELSE -OLD.valor END
    WHERE id = OLD.conta_id;
  ELSIF TG_OP = 'UPDATE' THEN
    -- Reverte o lançamento antigo e aplica o novo
    UPDATE fin_contas
    SET saldo_atual = COALESCE(saldo_atual, 0) -
      CASE WHEN OLD.tipo = 'entrada' THEN OLD.valor ELSE -OLD.valor END
    WHERE id = OLD.conta_id;
    UPDATE fin_contas
    SET saldo_atual = COALESCE(saldo_atual, 0) +
      CASE WHEN NEW.tipo = 'entrada' THEN NEW.valor ELSE -NEW.valor END
    WHERE id = NEW.conta_id;
  END IF;
  RETURN NULL;
END $function$
;
create policy fin_anexos_delete_v2 on public.fin_anexos as PERMISSIVE for DELETE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('importacao_ia'::text, 'x'::text))));
create policy fin_anexos_insert_v2 on public.fin_anexos as PERMISSIVE for INSERT to authenticated with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('importacao_ia'::text, 'c'::text))));
create policy fin_anexos_select_v2 on public.fin_anexos as PERMISSIVE for SELECT to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('importacao_ia'::text, 'v'::text))));
create policy fin_anexos_update_v2 on public.fin_anexos as PERMISSIVE for UPDATE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('importacao_ia'::text, 'e'::text)))) with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('importacao_ia'::text, 'e'::text))));
create policy fin_auditoria_delete_v2 on public.fin_auditoria as PERMISSIVE for DELETE to authenticated using ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_auditoria_insert_v2 on public.fin_auditoria as PERMISSIVE for INSERT to public with check (((EXISTS ( SELECT 1
   FROM fin_usuarios u
  WHERE ((u.auth_id = auth.uid()) AND (u.perfil = 'superadmin'::text) AND (u.ativo = true)))) OR (tenant_id IN ( SELECT fin_tenants_acessiveis() AS fin_tenants_acessiveis))));
create policy fin_auditoria_select_v2 on public.fin_auditoria as PERMISSIVE for SELECT to authenticated using ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_auditoria_update_v2 on public.fin_auditoria as PERMISSIVE for UPDATE to authenticated using ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis)))) with check ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_audit_cfg_all on public.fin_auditoria_config as PERMISSIVE for ALL to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'e'::text)));
create policy fin_audit_cfg_sel on public.fin_auditoria_config as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'v'::text)));
create policy fin_categorias_delete_v2 on public.fin_categorias as PERMISSIVE for DELETE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('cadastros'::text, 'x'::text))));
create policy fin_categorias_insert_v2 on public.fin_categorias as PERMISSIVE for INSERT to authenticated with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('cadastros'::text, 'c'::text))));
create policy fin_categorias_select on public.fin_categorias as PERMISSIVE for SELECT to public using (((EXISTS ( SELECT 1
   FROM fin_usuarios u
  WHERE ((u.auth_id = auth.uid()) AND (u.perfil = 'superadmin'::text) AND u.ativo))) OR (tenant_id IN ( SELECT u.tenant_id
   FROM fin_usuarios u
  WHERE (u.auth_id = auth.uid())))));
create policy fin_categorias_select_v2 on public.fin_categorias as PERMISSIVE for SELECT to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('cadastros'::text, 'v'::text))));
create policy fin_categorias_update_v2 on public.fin_categorias as PERMISSIVE for UPDATE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('cadastros'::text, 'e'::text)))) with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('cadastros'::text, 'e'::text))));
create policy fin_clientes_del on public.fin_clientes as PERMISSIVE for DELETE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'x'::text)));
create policy fin_clientes_ins on public.fin_clientes as PERMISSIVE for INSERT to authenticated with check (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'c'::text)));
create policy fin_clientes_sel on public.fin_clientes as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'v'::text)));
create policy fin_clientes_select on public.fin_clientes as PERMISSIVE for SELECT to public using (((EXISTS ( SELECT 1
   FROM fin_usuarios u
  WHERE ((u.auth_id = auth.uid()) AND (u.perfil = 'superadmin'::text) AND u.ativo))) OR (tenant_id IN ( SELECT u.tenant_id
   FROM fin_usuarios u
  WHERE (u.auth_id = auth.uid())))));
create policy fin_clientes_upd on public.fin_clientes as PERMISSIVE for UPDATE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'e'::text)));
create policy fin_config_del on public.fin_config as PERMISSIVE for DELETE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'x'::text)));
create policy fin_config_ins on public.fin_config as PERMISSIVE for INSERT to authenticated with check (((tenant_id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'c'::text)));
create policy fin_config_sel on public.fin_config as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'v'::text)));
create policy fin_config_upd on public.fin_config as PERMISSIVE for UPDATE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'e'::text)));
create policy fin_contas_del on public.fin_contas as PERMISSIVE for DELETE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'x'::text)));
create policy fin_contas_ins on public.fin_contas as PERMISSIVE for INSERT to authenticated with check (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'c'::text)));
create policy fin_contas_sel on public.fin_contas as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'v'::text)));
create policy fin_contas_select on public.fin_contas as PERMISSIVE for SELECT to public using (((EXISTS ( SELECT 1
   FROM fin_usuarios u
  WHERE ((u.auth_id = auth.uid()) AND (u.perfil = 'superadmin'::text) AND u.ativo))) OR (tenant_id IN ( SELECT u.tenant_id
   FROM fin_usuarios u
  WHERE (u.auth_id = auth.uid())))));
create policy fin_contas_upd on public.fin_contas as PERMISSIVE for UPDATE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'e'::text)));
create policy fin_convites_delete_v2 on public.fin_convites as PERMISSIVE for DELETE to authenticated using ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_convites_insert_v2 on public.fin_convites as PERMISSIVE for INSERT to authenticated with check ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_convites_select_v2 on public.fin_convites as PERMISSIVE for SELECT to authenticated using ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_convites_update_v2 on public.fin_convites as PERMISSIVE for UPDATE to authenticated using ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis)))) with check ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_despesas_del on public.fin_despesas as PERMISSIVE for DELETE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('pagar'::text, 'x'::text)));
create policy fin_despesas_ins on public.fin_despesas as PERMISSIVE for INSERT to authenticated with check (((tenant_id = fin_tenant_atual()) AND fin_pode('pagar'::text, 'c'::text)));
create policy fin_despesas_sel on public.fin_despesas as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('pagar'::text, 'v'::text)));
create policy fin_despesas_upd on public.fin_despesas as PERMISSIVE for UPDATE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('pagar'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('pagar'::text, 'e'::text)));
create policy fin_documentos_del on public.fin_documentos as PERMISSIVE for DELETE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('importacao_ia'::text, 'x'::text)));
create policy fin_documentos_ins on public.fin_documentos as PERMISSIVE for INSERT to authenticated with check (((tenant_id = fin_tenant_atual()) AND fin_pode('importacao_ia'::text, 'c'::text)));
create policy fin_documentos_sel on public.fin_documentos as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('importacao_ia'::text, 'v'::text)));
create policy fin_documentos_upd on public.fin_documentos as PERMISSIVE for UPDATE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('importacao_ia'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('importacao_ia'::text, 'e'::text)));
create policy fin_fornecedores_del on public.fin_fornecedores as PERMISSIVE for DELETE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'x'::text)));
create policy fin_fornecedores_ins on public.fin_fornecedores as PERMISSIVE for INSERT to authenticated with check (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'c'::text)));
create policy fin_fornecedores_sel on public.fin_fornecedores as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'v'::text)));
create policy fin_fornecedores_select on public.fin_fornecedores as PERMISSIVE for SELECT to public using (((EXISTS ( SELECT 1
   FROM fin_usuarios u
  WHERE ((u.auth_id = auth.uid()) AND (u.perfil = 'superadmin'::text) AND u.ativo))) OR (tenant_id IN ( SELECT u.tenant_id
   FROM fin_usuarios u
  WHERE (u.auth_id = auth.uid())))));
create policy fin_fornecedores_upd on public.fin_fornecedores as PERMISSIVE for UPDATE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('cadastros'::text, 'e'::text)));
create policy fin_impostos_delete_v2 on public.fin_impostos as PERMISSIVE for DELETE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('impostos'::text, 'x'::text))));
create policy fin_impostos_insert_v2 on public.fin_impostos as PERMISSIVE for INSERT to authenticated with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('impostos'::text, 'c'::text))));
create policy fin_impostos_select_v2 on public.fin_impostos as PERMISSIVE for SELECT to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('impostos'::text, 'v'::text))));
create policy fin_impostos_update_v2 on public.fin_impostos as PERMISSIVE for UPDATE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('impostos'::text, 'e'::text)))) with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('impostos'::text, 'e'::text))));
create policy fin_metas_delete_v2 on public.fin_metas as PERMISSIVE for DELETE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('metas'::text, 'x'::text))));
create policy fin_metas_insert_v2 on public.fin_metas as PERMISSIVE for INSERT to authenticated with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('metas'::text, 'c'::text))));
create policy fin_metas_select_v2 on public.fin_metas as PERMISSIVE for SELECT to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('metas'::text, 'v'::text))));
create policy fin_metas_update_v2 on public.fin_metas as PERMISSIVE for UPDATE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('metas'::text, 'e'::text)))) with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('metas'::text, 'e'::text))));
create policy fin_movimentacoes_del on public.fin_movimentacoes as PERMISSIVE for DELETE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'x'::text)));
create policy fin_movimentacoes_ins on public.fin_movimentacoes as PERMISSIVE for INSERT to authenticated with check (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'c'::text)));
create policy fin_movimentacoes_sel on public.fin_movimentacoes as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'v'::text)));
create policy fin_movimentacoes_upd on public.fin_movimentacoes as PERMISSIVE for UPDATE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'e'::text)));
create policy pf_plano_cont_delete on public.fin_plano_contabil as PERMISSIVE for DELETE to public using (fin_is_admin_do_tenant(tenant_id));
create policy pf_plano_cont_insert on public.fin_plano_contabil as PERMISSIVE for INSERT to public with check (fin_is_admin_do_tenant(tenant_id));
create policy pf_plano_cont_select on public.fin_plano_contabil as PERMISSIVE for SELECT to public using (((EXISTS ( SELECT 1
   FROM fin_usuarios u
  WHERE ((u.auth_id = auth.uid()) AND (u.perfil = 'superadmin'::text) AND u.ativo))) OR (tenant_id IN ( SELECT u.tenant_id
   FROM fin_usuarios u
  WHERE (u.auth_id = auth.uid())))));
create policy pf_plano_cont_update on public.fin_plano_contabil as PERMISSIVE for UPDATE to public using (fin_is_admin_do_tenant(tenant_id)) with check (fin_is_admin_do_tenant(tenant_id));
create policy pf_depara_delete on public.fin_plano_depara as PERMISSIVE for DELETE to public using (fin_is_admin_do_tenant(tenant_id));
create policy pf_depara_insert on public.fin_plano_depara as PERMISSIVE for INSERT to public with check (fin_is_admin_do_tenant(tenant_id));
create policy pf_depara_select on public.fin_plano_depara as PERMISSIVE for SELECT to public using (((EXISTS ( SELECT 1
   FROM fin_usuarios u
  WHERE ((u.auth_id = auth.uid()) AND (u.perfil = 'superadmin'::text) AND u.ativo))) OR (tenant_id IN ( SELECT u.tenant_id
   FROM fin_usuarios u
  WHERE (u.auth_id = auth.uid())))));
create policy pf_depara_update on public.fin_plano_depara as PERMISSIVE for UPDATE to public using (fin_is_admin_do_tenant(tenant_id)) with check (fin_is_admin_do_tenant(tenant_id));
create policy pf_plano_fin_delete on public.fin_plano_financeiro as PERMISSIVE for DELETE to public using (fin_is_admin_do_tenant(tenant_id));
create policy pf_plano_fin_insert on public.fin_plano_financeiro as PERMISSIVE for INSERT to public with check (fin_is_admin_do_tenant(tenant_id));
create policy pf_plano_fin_select on public.fin_plano_financeiro as PERMISSIVE for SELECT to public using (((EXISTS ( SELECT 1
   FROM fin_usuarios u
  WHERE ((u.auth_id = auth.uid()) AND (u.perfil = 'superadmin'::text) AND u.ativo))) OR (tenant_id IN ( SELECT u.tenant_id
   FROM fin_usuarios u
  WHERE (u.auth_id = auth.uid())))));
create policy pf_plano_fin_update on public.fin_plano_financeiro as PERMISSIVE for UPDATE to public using (fin_is_admin_do_tenant(tenant_id)) with check (fin_is_admin_do_tenant(tenant_id));
create policy fin_receitas_del on public.fin_receitas as PERMISSIVE for DELETE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('receber'::text, 'x'::text)));
create policy fin_receitas_ins on public.fin_receitas as PERMISSIVE for INSERT to authenticated with check (((tenant_id = fin_tenant_atual()) AND fin_pode('receber'::text, 'c'::text)));
create policy fin_receitas_sel on public.fin_receitas as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('receber'::text, 'v'::text)));
create policy fin_receitas_upd on public.fin_receitas as PERMISSIVE for UPDATE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('receber'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('receber'::text, 'e'::text)));
create policy fin_recorrencias_delete_v2 on public.fin_recorrencias as PERMISSIVE for DELETE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('recorrencias'::text, 'x'::text))));
create policy fin_recorrencias_insert_v2 on public.fin_recorrencias as PERMISSIVE for INSERT to authenticated with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('recorrencias'::text, 'c'::text))));
create policy fin_recorrencias_select_v2 on public.fin_recorrencias as PERMISSIVE for SELECT to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('recorrencias'::text, 'v'::text))));
create policy fin_recorrencias_update_v2 on public.fin_recorrencias as PERMISSIVE for UPDATE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('recorrencias'::text, 'e'::text)))) with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('recorrencias'::text, 'e'::text))));
create policy fin_regras_categorizacao_delete_v2 on public.fin_regras_categorizacao as PERMISSIVE for DELETE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('configuracoes'::text, 'x'::text))));
create policy fin_regras_categorizacao_insert_v2 on public.fin_regras_categorizacao as PERMISSIVE for INSERT to authenticated with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('configuracoes'::text, 'c'::text))));
create policy fin_regras_categorizacao_select_v2 on public.fin_regras_categorizacao as PERMISSIVE for SELECT to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('configuracoes'::text, 'v'::text))));
create policy fin_regras_categorizacao_update_v2 on public.fin_regras_categorizacao as PERMISSIVE for UPDATE to authenticated using (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('configuracoes'::text, 'e'::text)))) with check (((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR fin_pode('configuracoes'::text, 'e'::text))));
create policy fin_superadmins_sel on public.fin_superadmins as PERMISSIVE for SELECT to authenticated using (fin_eh_superadmin());
create policy pf_tpl_cont_select on public.fin_template_plano_contabil as PERMISSIVE for SELECT to public using (true);
create policy pf_tpl_fin_select on public.fin_template_plano_financeiro as PERMISSIVE for SELECT to public using (true);
create policy fin_tenants_acesso_sel on public.fin_tenants as PERMISSIVE for SELECT to authenticated using ((id IN ( SELECT fin_usuarios_empresas.tenant_id
   FROM fin_usuarios_empresas
  WHERE ((fin_usuarios_empresas.usuario_id = fin_usuario_atual()) AND (fin_usuarios_empresas.ativo = true)))));
create policy fin_tenants_admin_ins on public.fin_tenants as PERMISSIVE for INSERT to authenticated with check ((fin_eh_superadmin() OR (EXISTS ( SELECT 1
   FROM fin_usuarios_empresas ue
  WHERE ((ue.usuario_id = fin_usuario_atual()) AND (ue.template = 'admin'::text) AND (ue.ativo = true))))));
create policy fin_tenants_admin_upd on public.fin_tenants as PERMISSIVE for UPDATE to authenticated using (((id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'e'::text))) with check (((id = fin_tenant_atual()) AND fin_pode('configuracoes'::text, 'e'::text)));
create policy fin_tenants_delete_v2 on public.fin_tenants as PERMISSIVE for DELETE to authenticated using (fin_eh_superadmin());
create policy fin_tenants_select_v2 on public.fin_tenants as PERMISSIVE for SELECT to authenticated using ((id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_tenants_super_del on public.fin_tenants as PERMISSIVE for DELETE to authenticated using (fin_eh_superadmin());
create policy fin_tenants_super_sel on public.fin_tenants as PERMISSIVE for SELECT to authenticated using (fin_eh_superadmin());
create policy fin_tenants_update_v2 on public.fin_tenants as PERMISSIVE for UPDATE to authenticated using (((id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (fin_eh_superadmin() OR (EXISTS ( SELECT 1
   FROM (fin_usuarios_empresas ue
     JOIN fin_usuarios u ON ((u.id = ue.usuario_id)))
  WHERE ((u.auth_id = auth.uid()) AND (ue.tenant_id = fin_tenants.id) AND (ue.template = 'admin'::text) AND (ue.ativo = true)))))));
create policy fin_transferencias_del on public.fin_transferencias as PERMISSIVE for DELETE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'x'::text)));
create policy fin_transferencias_ins on public.fin_transferencias as PERMISSIVE for INSERT to authenticated with check (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'c'::text)));
create policy fin_transferencias_sel on public.fin_transferencias as PERMISSIVE for SELECT to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'v'::text)));
create policy fin_transferencias_upd on public.fin_transferencias as PERMISSIVE for UPDATE to authenticated using (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'e'::text))) with check (((tenant_id = fin_tenant_atual()) AND fin_pode('caixa_bancos'::text, 'e'::text)));
create policy fin_usuarios_admin_del on public.fin_usuarios as PERMISSIVE for DELETE to authenticated using (fin_pode('usuarios'::text, 'x'::text));
create policy fin_usuarios_admin_ins on public.fin_usuarios as PERMISSIVE for INSERT to authenticated with check (fin_pode('usuarios'::text, 'c'::text));
create policy fin_usuarios_admin_upd on public.fin_usuarios as PERMISSIVE for UPDATE to authenticated using (((auth_id = auth.uid()) OR fin_pode('usuarios'::text, 'e'::text))) with check (((auth_id = auth.uid()) OR fin_pode('usuarios'::text, 'e'::text)));
create policy fin_usuarios_delete_v2 on public.fin_usuarios as PERMISSIVE for DELETE to authenticated using (fin_eh_superadmin());
create policy fin_usuarios_insert_v2 on public.fin_usuarios as PERMISSIVE for INSERT to authenticated with check (((auth_id = auth.uid()) OR fin_eh_superadmin()));
create policy fin_usuarios_select_v2 on public.fin_usuarios as PERMISSIVE for SELECT to authenticated using (((auth_id = auth.uid()) OR fin_eh_superadmin() OR (id IN ( SELECT ue.usuario_id
   FROM fin_usuarios_empresas ue
  WHERE ((ue.tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
           FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))) AND (ue.ativo = true))))));
create policy fin_usuarios_self_sel on public.fin_usuarios as PERMISSIVE for SELECT to authenticated using (((auth_id = auth.uid()) OR (fin_pode('usuarios'::text, 'v'::text) AND (id IN ( SELECT fin_usuarios_empresas.usuario_id
   FROM fin_usuarios_empresas
  WHERE (fin_usuarios_empresas.tenant_id = fin_tenant_atual()))))));
create policy fin_usuarios_update_v2 on public.fin_usuarios as PERMISSIVE for UPDATE to authenticated using (((auth_id = auth.uid()) OR fin_eh_superadmin())) with check (((auth_id = auth.uid()) OR fin_eh_superadmin()));
create policy fin_usuarios_empresas_delete_v2 on public.fin_usuarios_empresas as PERMISSIVE for DELETE to authenticated using ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_usuarios_empresas_insert_v2 on public.fin_usuarios_empresas as PERMISSIVE for INSERT to authenticated with check ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_usuarios_empresas_select_v2 on public.fin_usuarios_empresas as PERMISSIVE for SELECT to authenticated using ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
create policy fin_usuarios_empresas_update_v2 on public.fin_usuarios_empresas as PERMISSIVE for UPDATE to authenticated using ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis)))) with check ((tenant_id IN ( SELECT fin_tenants_acessiveis.fin_tenants_acessiveis
   FROM fin_tenants_acessiveis() fin_tenants_acessiveis(fin_tenants_acessiveis))));
CREATE TRIGGER trg_fin_anexos_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_anexos FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_categorias_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_categorias FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_clientes_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_clientes FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_config_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_config FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_contas_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_contas FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_convites_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_convites FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_despesas_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_despesas FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_documentos_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_documentos FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_fornecedores_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_fornecedores FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_impostos_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_impostos FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_metas_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_metas FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER fin_saldo_trigger AFTER INSERT OR DELETE ON public.fin_movimentacoes FOR EACH ROW EXECUTE FUNCTION fin_atualizar_saldo();
CREATE TRIGGER trg_fin_movimentacoes_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_movimentacoes FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_mov_saldo_del AFTER DELETE ON public.fin_movimentacoes FOR EACH ROW EXECUTE FUNCTION fin_atualizar_saldo();
CREATE TRIGGER trg_mov_saldo_ins AFTER INSERT ON public.fin_movimentacoes FOR EACH ROW EXECUTE FUNCTION fin_atualizar_saldo();
CREATE TRIGGER trg_mov_saldo_upd AFTER UPDATE ON public.fin_movimentacoes FOR EACH ROW EXECUTE FUNCTION fin_atualizar_saldo();
CREATE TRIGGER trg_saldo_conta AFTER INSERT OR DELETE OR UPDATE ON public.fin_movimentacoes FOR EACH ROW EXECUTE FUNCTION fn_atualizar_saldo_conta();
CREATE TRIGGER trg_fin_pessoal_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_pessoal FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_plano_cont_updated BEFORE UPDATE ON public.fin_plano_contabil FOR EACH ROW EXECUTE FUNCTION fin_set_updated_at();
CREATE TRIGGER trg_fin_plano_contabil_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_plano_contabil FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_depara_updated BEFORE UPDATE ON public.fin_plano_depara FOR EACH ROW EXECUTE FUNCTION fin_set_updated_at();
CREATE TRIGGER trg_fin_plano_depara_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_plano_depara FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_plano_fin_updated BEFORE UPDATE ON public.fin_plano_financeiro FOR EACH ROW EXECUTE FUNCTION fin_set_updated_at();
CREATE TRIGGER trg_fin_plano_financeiro_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_plano_financeiro FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_receitas_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_receitas FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_recorrencias_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_recorrencias FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_regras_categ_touch BEFORE UPDATE ON public.fin_regras_categorizacao FOR EACH ROW EXECUTE FUNCTION fin_regras_categ_touch();
CREATE TRIGGER trg_empresa_seed_planos AFTER INSERT ON public.fin_tenants FOR EACH ROW EXECUTE FUNCTION fin_trg_empresa_seed_planos();
CREATE TRIGGER trg_fin_seed_regras_categ AFTER INSERT ON public.fin_tenants FOR EACH ROW EXECUTE FUNCTION fin_seed_regras_categ_novo_tenant();
CREATE TRIGGER trg_fin_tenants_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_tenants FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_transferencias_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_transferencias FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
CREATE TRIGGER trg_fin_usuarios_empresas_audit AFTER INSERT OR DELETE OR UPDATE ON public.fin_usuarios_empresas FOR EACH ROW EXECUTE FUNCTION fin_audit_trigger();
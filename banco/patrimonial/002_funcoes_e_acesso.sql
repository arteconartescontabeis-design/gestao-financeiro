-- PATRIMONIAL PRO → banco da Gestão Empresarial e Financeiro (agenda-pro / vuwgxndahrzinfdlapxz)
-- Funções, regras de acesso (RLS), gatilhos e arquivos (bucket pat-documentos). Rodar depois do 001.
-- Extraído em 18/10/2026 do banco antigo "patrimonial-pro" (rujfstmskkgyeksspyoa).
-- Diferenças propositais em relação ao banco antigo (o banco de destino tem os logins da Agenda e do Carreira):
--   * NÃO leva o gatilho tg_pat_auth_no_null em auth.users (nem a função pat_auth_users_no_null): ele mexeria em todos os
--     logins do banco compartilhado. No lugar, pat_admin_criar_usuario grava os campos de token com '' ao criar o login.
--   * pat_admin_criar_usuario: se o e-mail já tem login neste banco, vincula a pessoa ao Patrimonial em vez de recusar
--     ("Já existe um usuário com este e-mail"); a senha dela não muda.
-- APLICADO em 18/10/2026 no agenda-pro como migration `patrimonial_002_funcoes_e_acesso` (este arquivo).
-- Conferido: 15 funções, 81 políticas (75 das tabelas + 6 dos arquivos), 47 gatilhos e o bucket iguais aos do banco antigo.

-- 1) funções
CREATE OR REPLACE FUNCTION public.pat_admin_criar_usuario(p_email text, p_senha text, p_nome text, p_telefone text, p_cargo text, p_tenant uuid, p_role text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'auth'
AS $function$
declare v_id uuid;
begin
  -- autorização: superadmin ou admin da empresa
  if not (pat_e_superadmin() or pat_role_no_tenant(p_tenant) = 'admin') then
    raise exception 'Sem permissão para criar usuários nesta empresa.';
  end if;
  if coalesce(p_email,'') = '' or coalesce(p_senha,'') = '' or coalesce(p_nome,'') = '' then
    raise exception 'Nome, e-mail e senha são obrigatórios.';
  end if;
  if length(p_senha) < 6 then
    raise exception 'A senha deve ter ao menos 6 caracteres.';
  end if;
  if p_role not in ('admin','operador','consulta','externo') then
    raise exception 'Tipo de usuário inválido.';
  end if;

  -- banco compartilhado da Gestão (Agenda, Carreira…): se o e-mail já tem login, só vincula ao Patrimonial
  -- e a pessoa continua entrando com a senha que já usa (a senha digitada aqui é ignorada).
  select id into v_id from auth.users where email = lower(p_email) limit 1;

  if v_id is null then
    v_id := gen_random_uuid();

    -- campos de token preenchidos com '' (o login recusa NULL); no banco antigo isso era feito por um gatilho em auth.users
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data,
      confirmation_token, recovery_token, email_change, email_change_token_new,
      email_change_token_current, phone_change, phone_change_token, reauthentication_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
      lower(p_email), crypt(p_senha, gen_salt('bf')),
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
      '', '', '', '', '', '', '', ''
    );

    insert into auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(), v_id, v_id::text,
      jsonb_build_object('sub', v_id::text, 'email', lower(p_email)),
      'email', now(), now(), now()
    );
  end if;

  insert into pat_usuarios (id, nome, email, telefone, cargo)
  values (v_id, p_nome, lower(p_email), p_telefone, p_cargo)
  on conflict (id) do update set nome = excluded.nome, telefone = excluded.telefone, cargo = excluded.cargo;

  insert into pat_usuarios_empresas (usuario_id, tenant_id, role)
  values (v_id, p_tenant, p_role)
  on conflict (usuario_id, tenant_id) do update set role = excluded.role, ativo = true;

  return v_id;
end; $function$
;
CREATE OR REPLACE FUNCTION public.pat_audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_old jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  v_data jsonb := coalesce(v_new, v_old);
  v_tenant uuid := nullif(v_data->>'tenant_id','')::uuid;
begin
  if v_tenant is null and tg_table_name = 'pat_tenants' then
    v_tenant := nullif(v_data->>'id','')::uuid;
  end if;
  insert into pat_auditoria(tenant_id, tabela, operacao, registro_id, usuario_id, dados_antes, dados_depois, contexto)
  values (
    v_tenant, tg_table_name, tg_op,
    nullif(v_data->>'id','')::uuid,
    auth.uid(), v_old, v_new,
    nullif(current_setting('pat.contexto', true), '')
  );
  return coalesce(new, old);
end $function$
;
CREATE OR REPLACE FUNCTION public.pat_e_superadmin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists(select 1 from pat_superadmins where usuario_id = auth.uid());
$function$
;
CREATE OR REPLACE FUNCTION public.pat_ged_path_ok(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists(select 1 from pat_superadmins s where s.usuario_id = auth.uid())
      or exists(select 1 from pat_usuarios_empresas ue
                where ue.usuario_id = auth.uid() and ue.ativo = true
                  and ue.tenant_id::text = (storage.foldername(p_name))[1]);
$function$
;
CREATE OR REPLACE FUNCTION public.pat_guard_inativar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_mod text;
begin
  if old.ativo = true and new.ativo = false then
    v_mod := case tg_table_name
               when 'pat_pessoas'         then 'pessoas'
               when 'pat_ativos'          then 'patrimonio'
               when 'pat_participacoes'   then 'societario'
               when 'pat_onus'            then 'onus'
               when 'pat_vencimentos'     then 'vencimentos'
               when 'pat_documentos'      then 'ged'
               when 'pat_vinculos'        then 'sucessorio'
               when 'pat_doacoes'         then 'sucessorio'
               when 'pat_itcmd_uf'        then 'sucessorio'
               when 'pat_sim_parametros'  then 'simulacoes'
               when 'pat_sim_operacoes'   then 'simulacoes' end;
    if not pat_pode(auth.uid(), new.tenant_id, v_mod, 'excluir') then
      raise exception 'Sem permissão para inativar (requer "excluir") no módulo %', v_mod
        using errcode = '42501';
    end if;
  end if;
  return new;
end; $function$
;
CREATE OR REPLACE FUNCTION public.pat_inativar(p_tabela text, p_id uuid, p_tenant uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_mod text;
begin
  v_mod := case p_tabela when 'pat_pessoas' then 'pessoas'
                         when 'pat_ativos'  then 'patrimonio'
                         else null end;
  if v_mod is null then raise exception 'Tabela não suportada: %', p_tabela; end if;
  if not pat_pode(auth.uid(), p_tenant, v_mod, 'excluir') then
    raise exception 'Sem permissão para excluir neste módulo.';
  end if;
  if p_tabela = 'pat_pessoas' then
    update pat_pessoas set ativo=false where id=p_id and tenant_id=p_tenant;
  else
    update pat_ativos   set ativo=false where id=p_id and tenant_id=p_tenant;
  end if;
end; $function$
;
CREATE OR REPLACE FUNCTION public.pat_meus_tenants()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select tenant_id from pat_usuarios_empresas
   where usuario_id = auth.uid() and ativo = true;
$function$
;
CREATE OR REPLACE FUNCTION public.pat_onus_after()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform pat_sync_onerado(new.ativo_id);
  if tg_op = 'UPDATE' and new.ativo_id is distinct from old.ativo_id then
    perform pat_sync_onerado(old.ativo_id);
  end if;
  return new;
end; $function$
;
CREATE OR REPLACE FUNCTION public.pat_pode(p_usuario uuid, p_tenant uuid, p_modulo text, p_acao text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text;
  v_super boolean;
  v_perm pat_permissoes%rowtype;
begin
  if p_usuario is null or p_tenant is null then
    return false;
  end if;
  if p_acao not in ('ver','criar','editar','excluir') then
    return false;
  end if;

  -- superadmin enxerga e faz tudo
  select exists(select 1 from pat_superadmins where usuario_id = p_usuario)
    into v_super;
  if v_super then
    return true;
  end if;

  -- precisa de vínculo ATIVO com a empresa
  select role into v_role
  from pat_usuarios_empresas
  where usuario_id = p_usuario
    and tenant_id  = p_tenant
    and ativo = true
  limit 1;

  if v_role is null then
    return false;
  end if;

  -- admin da empresa: tudo dentro da empresa
  if v_role = 'admin' then
    return true;
  end if;

  -- permissão explícita na matriz (tela Acessos) tem prioridade
  select * into v_perm
  from pat_permissoes
  where usuario_id = p_usuario
    and tenant_id  = p_tenant
    and modulo     = p_modulo;

  if found then
    return case p_acao
      when 'ver'     then coalesce(v_perm.pode_ver,    false)
      when 'criar'   then coalesce(v_perm.pode_criar,  false)
      when 'editar'  then coalesce(v_perm.pode_editar, false)
      when 'excluir' then coalesce(v_perm.pode_excluir,false)
    end;
  end if;

  -- sem linha explícita: herda o padrão do tipo
  -- operador: vê tudo; cria/edita em tudo menos 'admin'; nunca exclui
  if v_role = 'operador' then
    return case p_acao
      when 'ver'     then true
      when 'criar'   then p_modulo <> 'admin'
      when 'editar'  then p_modulo <> 'admin'
      when 'excluir' then false
    end;
  end if;

  -- externo: só visualiza, e só bi / portal / patrimonio
  if v_role = 'externo' then
    return p_acao = 'ver' and p_modulo in ('bi','portal','patrimonio');
  end if;

  return false;
end; $function$
;
CREATE OR REPLACE FUNCTION public.pat_pode(p_tenant uuid, p_modulo text, p_acao text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select pat_pode(auth.uid(), p_tenant, p_modulo, p_acao);
$function$
;
CREATE OR REPLACE FUNCTION public.pat_role_no_tenant(p_tenant uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select role from pat_usuarios_empresas
   where usuario_id = auth.uid() and tenant_id = p_tenant and ativo = true;
$function$
;
CREATE OR REPLACE FUNCTION public.pat_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin new.updated_at := now(); return new; end; $function$
;
CREATE OR REPLACE FUNCTION public.pat_sync_onerado(p_ativo_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tem boolean;
  v_sit text;
begin
  if p_ativo_id is null then return; end if;

  select exists(
    select 1 from pat_onus
    where ativo_id = p_ativo_id
      and ativo = true
      and situacao in ('ativo','em_execucao','suspenso')
  ) into v_tem;

  select situacao into v_sit from pat_ativos where id = p_ativo_id;

  if v_tem and v_sit = 'ativo' then
    update pat_ativos set situacao = 'onerado' where id = p_ativo_id;
  elsif not v_tem and v_sit = 'onerado' then
    update pat_ativos set situacao = 'ativo' where id = p_ativo_id;
  end if;
end; $function$
;
CREATE OR REPLACE FUNCTION public.pat_tem_acesso(p_tenant uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select pat_e_superadmin()
      or exists(select 1 from pat_usuarios_empresas
                 where usuario_id = auth.uid() and tenant_id = p_tenant and ativo = true);
$function$
;
CREATE OR REPLACE FUNCTION public.pat_touch()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end; $function$
;

-- 2) regras de acesso das tabelas
create policy p_pat_anexos_del on public.pat_anexos as PERMISSIVE for DELETE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = 'admin'::text))));
create policy p_pat_anexos_ins on public.pat_anexos as PERMISSIVE for INSERT to public with check ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_anexos_sel on public.pat_anexos as PERMISSIVE for SELECT to public using (((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy p_pat_anexos_upd on public.pat_anexos as PERMISSIVE for UPDATE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_ativo_eventos_del on public.pat_ativo_eventos as PERMISSIVE for DELETE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = 'admin'::text))));
create policy p_pat_ativo_eventos_ins on public.pat_ativo_eventos as PERMISSIVE for INSERT to public with check ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_ativo_eventos_sel on public.pat_ativo_eventos as PERMISSIVE for SELECT to public using (((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy p_pat_ativo_eventos_upd on public.pat_ativo_eventos as PERMISSIVE for UPDATE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy ativos_insert on public.pat_ativos as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'patrimonio'::text, 'criar'::text));
create policy ativos_select on public.pat_ativos as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'patrimonio'::text, 'ver'::text));
create policy ativos_update on public.pat_ativos as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'patrimonio'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'patrimonio'::text, 'editar'::text));
create policy auditoria_select on public.pat_auditoria as PERMISSIVE for SELECT to public using (((EXISTS ( SELECT 1
   FROM pat_superadmins s
  WHERE (s.usuario_id = auth.uid()))) OR ((tenant_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.usuario_id = auth.uid()) AND (ue.tenant_id = pat_auditoria.tenant_id) AND (ue.role = 'admin'::text) AND (ue.ativo = true)))))));
create policy p_pat_avaliacoes_del on public.pat_avaliacoes as PERMISSIVE for DELETE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = 'admin'::text))));
create policy p_pat_avaliacoes_ins on public.pat_avaliacoes as PERMISSIVE for INSERT to public with check ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_avaliacoes_sel on public.pat_avaliacoes as PERMISSIVE for SELECT to public using (((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy p_pat_avaliacoes_upd on public.pat_avaliacoes as PERMISSIVE for UPDATE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy pat_doacoes_ins on public.pat_doacoes as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'criar'::text));
create policy pat_doacoes_sel on public.pat_doacoes as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'ver'::text));
create policy pat_doacoes_upd on public.pat_doacoes as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'editar'::text));
create policy pat_doc_tipos_rw on public.pat_documento_tipos as PERMISSIVE for ALL to authenticated using (((EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.tenant_id = pat_documento_tipos.tenant_id) AND (ue.usuario_id = auth.uid()) AND (ue.ativo = true)))) OR (EXISTS ( SELECT 1
   FROM pat_superadmins s
  WHERE (s.usuario_id = auth.uid()))))) with check (((EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.tenant_id = pat_documento_tipos.tenant_id) AND (ue.usuario_id = auth.uid()) AND (ue.ativo = true)))) OR (EXISTS ( SELECT 1
   FROM pat_superadmins s
  WHERE (s.usuario_id = auth.uid())))));
create policy doc_insert on public.pat_documentos as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'ged'::text, 'criar'::text));
create policy doc_select on public.pat_documentos as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'ged'::text, 'ver'::text));
create policy doc_update on public.pat_documentos as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'ged'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'ged'::text, 'editar'::text));
create policy pat_itcmd_uf_ins on public.pat_itcmd_uf as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'criar'::text));
create policy pat_itcmd_uf_sel on public.pat_itcmd_uf as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'ver'::text));
create policy pat_itcmd_uf_upd on public.pat_itcmd_uf as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'editar'::text));
create policy onus_insert on public.pat_onus as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'onus'::text, 'criar'::text));
create policy onus_select on public.pat_onus as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'onus'::text, 'ver'::text));
create policy onus_update on public.pat_onus as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'onus'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'onus'::text, 'editar'::text));
create policy p_pat_papeis_del on public.pat_papeis as PERMISSIVE for DELETE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = 'admin'::text))));
create policy p_pat_papeis_ins on public.pat_papeis as PERMISSIVE for INSERT to public with check ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_papeis_sel on public.pat_papeis as PERMISSIVE for SELECT to public using (((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy p_pat_papeis_upd on public.pat_papeis as PERMISSIVE for UPDATE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_parametros_del on public.pat_parametros as PERMISSIVE for DELETE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = 'admin'::text))));
create policy p_pat_parametros_ins on public.pat_parametros as PERMISSIVE for INSERT to public with check ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_parametros_sel on public.pat_parametros as PERMISSIVE for SELECT to public using (((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy p_pat_parametros_upd on public.pat_parametros as PERMISSIVE for UPDATE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy part_insert on public.pat_participacoes as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'societario'::text, 'criar'::text));
create policy part_select on public.pat_participacoes as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'societario'::text, 'ver'::text));
create policy part_update on public.pat_participacoes as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'societario'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'societario'::text, 'editar'::text));
create policy p_perm_adm on public.pat_permissoes as PERMISSIVE for ALL to public using ((pat_e_superadmin() OR (pat_role_no_tenant(tenant_id) = 'admin'::text))) with check ((pat_e_superadmin() OR (pat_role_no_tenant(tenant_id) = 'admin'::text)));
create policy p_perm_sel on public.pat_permissoes as PERMISSIVE for SELECT to public using (((usuario_id = auth.uid()) OR (tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy pessoas_insert on public.pat_pessoas as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'pessoas'::text, 'criar'::text));
create policy pessoas_select on public.pat_pessoas as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'pessoas'::text, 'ver'::text));
create policy pessoas_update on public.pat_pessoas as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'pessoas'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'pessoas'::text, 'editar'::text));
create policy p_pat_procuracoes_del on public.pat_procuracoes as PERMISSIVE for DELETE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = 'admin'::text))));
create policy p_pat_procuracoes_ins on public.pat_procuracoes as PERMISSIVE for INSERT to public with check ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_procuracoes_sel on public.pat_procuracoes as PERMISSIVE for SELECT to public using (((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy p_pat_procuracoes_upd on public.pat_procuracoes as PERMISSIVE for UPDATE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy pat_procuracoes_rw on public.pat_procuracoes as PERMISSIVE for ALL to authenticated using (((EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.tenant_id = pat_procuracoes.tenant_id) AND (ue.usuario_id = auth.uid()) AND (ue.ativo = true)))) OR (EXISTS ( SELECT 1
   FROM pat_superadmins s
  WHERE (s.usuario_id = auth.uid()))))) with check (((EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.tenant_id = pat_procuracoes.tenant_id) AND (ue.usuario_id = auth.uid()) AND (ue.ativo = true)))) OR (EXISTS ( SELECT 1
   FROM pat_superadmins s
  WHERE (s.usuario_id = auth.uid())))));
create policy p_pat_relacoes_familiares_del on public.pat_relacoes_familiares as PERMISSIVE for DELETE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = 'admin'::text))));
create policy p_pat_relacoes_familiares_ins on public.pat_relacoes_familiares as PERMISSIVE for INSERT to public with check ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_relacoes_familiares_sel on public.pat_relacoes_familiares as PERMISSIVE for SELECT to public using (((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy p_pat_relacoes_familiares_upd on public.pat_relacoes_familiares as PERMISSIVE for UPDATE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_seguros_del on public.pat_seguros as PERMISSIVE for DELETE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = 'admin'::text))));
create policy p_pat_seguros_ins on public.pat_seguros as PERMISSIVE for INSERT to public with check ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy p_pat_seguros_sel on public.pat_seguros as PERMISSIVE for SELECT to public using (((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy p_pat_seguros_upd on public.pat_seguros as PERMISSIVE for UPDATE to public using ((pat_e_superadmin() OR ((tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(tenant_id) = ANY (ARRAY['admin'::text, 'operador'::text])))));
create policy pat_seguros_rw on public.pat_seguros as PERMISSIVE for ALL to authenticated using (((EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.tenant_id = pat_seguros.tenant_id) AND (ue.usuario_id = auth.uid()) AND (ue.ativo = true)))) OR (EXISTS ( SELECT 1
   FROM pat_superadmins s
  WHERE (s.usuario_id = auth.uid()))))) with check (((EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.tenant_id = pat_seguros.tenant_id) AND (ue.usuario_id = auth.uid()) AND (ue.ativo = true)))) OR (EXISTS ( SELECT 1
   FROM pat_superadmins s
  WHERE (s.usuario_id = auth.uid())))));
create policy pat_sim_operacoes_ins on public.pat_sim_operacoes as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'simulacoes'::text, 'criar'::text));
create policy pat_sim_operacoes_sel on public.pat_sim_operacoes as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'simulacoes'::text, 'ver'::text));
create policy pat_sim_operacoes_upd on public.pat_sim_operacoes as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'simulacoes'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'simulacoes'::text, 'editar'::text));
create policy pat_sim_parametros_ins on public.pat_sim_parametros as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'simulacoes'::text, 'criar'::text));
create policy pat_sim_parametros_sel on public.pat_sim_parametros as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'simulacoes'::text, 'ver'::text));
create policy pat_sim_parametros_upd on public.pat_sim_parametros as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'simulacoes'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'simulacoes'::text, 'editar'::text));
create policy p_super_sel on public.pat_superadmins as PERMISSIVE for SELECT to public using (((usuario_id = auth.uid()) OR pat_e_superadmin()));
create policy p_tenants_adm on public.pat_tenants as PERMISSIVE for ALL to public using ((pat_e_superadmin() OR ((id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(id) = 'admin'::text)))) with check ((pat_e_superadmin() OR ((id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) AND (pat_role_no_tenant(id) = 'admin'::text))));
create policy p_tenants_sel on public.pat_tenants as PERMISSIVE for SELECT to public using (((id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy p_usuarios_sel on public.pat_usuarios as PERMISSIVE for SELECT to public using (((id = auth.uid()) OR pat_e_superadmin() OR (EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.usuario_id = pat_usuarios.id) AND (ue.tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)))))));
create policy p_usuarios_self on public.pat_usuarios as PERMISSIVE for UPDATE to public using (((id = auth.uid()) OR pat_e_superadmin()));
create policy p_ue_adm on public.pat_usuarios_empresas as PERMISSIVE for ALL to public using ((pat_e_superadmin() OR (pat_role_no_tenant(tenant_id) = 'admin'::text))) with check ((pat_e_superadmin() OR (pat_role_no_tenant(tenant_id) = 'admin'::text)));
create policy p_ue_sel on public.pat_usuarios_empresas as PERMISSIVE for SELECT to public using (((usuario_id = auth.uid()) OR (tenant_id IN ( SELECT pat_meus_tenants() AS pat_meus_tenants)) OR pat_e_superadmin()));
create policy pat_vinculos_ins on public.pat_vinculos as PERMISSIVE for INSERT to public with check (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'criar'::text));
create policy pat_vinculos_sel on public.pat_vinculos as PERMISSIVE for SELECT to public using (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'ver'::text));
create policy pat_vinculos_upd on public.pat_vinculos as PERMISSIVE for UPDATE to public using (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'editar'::text)) with check (pat_pode(auth.uid(), tenant_id, 'sucessorio'::text, 'editar'::text));

-- 3) arquivos: bucket privado pat-documentos e suas regras (pasta = empresa)
insert into storage.buckets (id, name, public) values ('pat-documentos', 'pat-documentos', false) on conflict (id) do nothing;
create policy ged_objs_delete on storage.objects as PERMISSIVE for DELETE to authenticated using (((bucket_id = 'pat-documentos'::text) AND pat_ged_path_ok(name)));
create policy ged_objs_insert on storage.objects as PERMISSIVE for INSERT to authenticated with check (((bucket_id = 'pat-documentos'::text) AND pat_ged_path_ok(name)));
create policy ged_objs_select on storage.objects as PERMISSIVE for SELECT to authenticated using (((bucket_id = 'pat-documentos'::text) AND pat_ged_path_ok(name)));
create policy pat_docs_storage_delete on storage.objects as PERMISSIVE for DELETE to authenticated using (((bucket_id = 'pat-documentos'::text) AND (EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.usuario_id = auth.uid()) AND (ue.ativo = true) AND ((ue.tenant_id)::text = (storage.foldername(objects.name))[1]))))));
create policy pat_docs_storage_insert on storage.objects as PERMISSIVE for INSERT to authenticated with check (((bucket_id = 'pat-documentos'::text) AND (EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.usuario_id = auth.uid()) AND (ue.ativo = true) AND ((ue.tenant_id)::text = (storage.foldername(objects.name))[1]))))));
create policy pat_docs_storage_select on storage.objects as PERMISSIVE for SELECT to authenticated using (((bucket_id = 'pat-documentos'::text) AND (EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.usuario_id = auth.uid()) AND (ue.ativo = true) AND ((ue.tenant_id)::text = (storage.foldername(objects.name))[1]))))));

-- 4) gatilhos
CREATE TRIGGER trg_aud_pat_anexos AFTER INSERT OR DELETE OR UPDATE ON public.pat_anexos FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER trg_aud_pat_ativo_eventos AFTER INSERT OR DELETE OR UPDATE ON public.pat_ativo_eventos FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_ativos_guard_inativar BEFORE UPDATE ON public.pat_ativos FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();
CREATE TRIGGER tg_audit_pat_ativos AFTER INSERT OR DELETE OR UPDATE ON public.pat_ativos FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_pat_ativos_touch BEFORE UPDATE ON public.pat_ativos FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER trg_aud_pat_avaliacoes AFTER INSERT OR DELETE OR UPDATE ON public.pat_avaliacoes FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_audit_pat_doacoes AFTER INSERT OR DELETE OR UPDATE ON public.pat_doacoes FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_doa_guard BEFORE UPDATE ON public.pat_doacoes FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();
CREATE TRIGGER tg_pat_doa_touch BEFORE UPDATE ON public.pat_doacoes FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER trg_pat_audit_doc_tipos AFTER INSERT OR DELETE OR UPDATE ON public.pat_documento_tipos FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_audit_pat_documentos AFTER INSERT OR DELETE OR UPDATE ON public.pat_documentos FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_doc_guard_inativar BEFORE UPDATE ON public.pat_documentos FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();
CREATE TRIGGER tg_pat_doc_touch BEFORE UPDATE ON public.pat_documentos FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER tg_audit_pat_itcmd_uf AFTER INSERT OR DELETE OR UPDATE ON public.pat_itcmd_uf FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_itcmd_guard BEFORE UPDATE ON public.pat_itcmd_uf FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();
CREATE TRIGGER tg_pat_itcmd_touch BEFORE UPDATE ON public.pat_itcmd_uf FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER tg_audit_pat_onus AFTER INSERT OR DELETE OR UPDATE ON public.pat_onus FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_onus_guard_inativar BEFORE UPDATE ON public.pat_onus FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();
CREATE TRIGGER tg_onus_sync AFTER INSERT OR UPDATE ON public.pat_onus FOR EACH ROW EXECUTE FUNCTION pat_onus_after();
CREATE TRIGGER tg_pat_onus_touch BEFORE UPDATE ON public.pat_onus FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER trg_aud_pat_papeis AFTER INSERT OR DELETE OR UPDATE ON public.pat_papeis FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_audit_pat_participacoes AFTER INSERT OR DELETE OR UPDATE ON public.pat_participacoes FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_part_guard_inativar BEFORE UPDATE ON public.pat_participacoes FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();
CREATE TRIGGER tg_pat_part_touch BEFORE UPDATE ON public.pat_participacoes FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER tg_audit_pat_permissoes AFTER INSERT OR DELETE OR UPDATE ON public.pat_permissoes FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER trg_aud_pat_permissoes AFTER INSERT OR DELETE OR UPDATE ON public.pat_permissoes FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_audit_pat_pessoas AFTER INSERT OR DELETE OR UPDATE ON public.pat_pessoas FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_pat_pessoas_touch BEFORE UPDATE ON public.pat_pessoas FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER tg_pessoas_guard_inativar BEFORE UPDATE ON public.pat_pessoas FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();
CREATE TRIGGER trg_aud_pat_procuracoes AFTER INSERT OR DELETE OR UPDATE ON public.pat_procuracoes FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER trg_pat_audit_procuracoes AFTER INSERT OR DELETE OR UPDATE ON public.pat_procuracoes FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER trg_aud_pat_relacoes_familiares AFTER INSERT OR DELETE OR UPDATE ON public.pat_relacoes_familiares FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER trg_aud_pat_seguros AFTER INSERT OR DELETE OR UPDATE ON public.pat_seguros FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER trg_pat_audit_seguros AFTER INSERT OR DELETE OR UPDATE ON public.pat_seguros FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_audit_pat_sim_operacoes AFTER INSERT OR DELETE OR UPDATE ON public.pat_sim_operacoes FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_pat_simo_touch BEFORE UPDATE ON public.pat_sim_operacoes FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER tg_simo_guard BEFORE UPDATE ON public.pat_sim_operacoes FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();
CREATE TRIGGER tg_audit_pat_sim_parametros AFTER INSERT OR DELETE OR UPDATE ON public.pat_sim_parametros FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_pat_simp_touch BEFORE UPDATE ON public.pat_sim_parametros FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER tg_simp_guard BEFORE UPDATE ON public.pat_sim_parametros FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();
CREATE TRIGGER tg_audit_pat_tenants AFTER INSERT OR DELETE OR UPDATE ON public.pat_tenants FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER trg_upd_pat_usuarios BEFORE UPDATE ON public.pat_usuarios FOR EACH ROW EXECUTE FUNCTION pat_set_updated_at();
CREATE TRIGGER tg_audit_pat_usuarios_empresas AFTER INSERT OR DELETE OR UPDATE ON public.pat_usuarios_empresas FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER trg_aud_pat_usuarios_empresas AFTER INSERT OR DELETE OR UPDATE ON public.pat_usuarios_empresas FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_audit_pat_vinculos AFTER INSERT OR DELETE OR UPDATE ON public.pat_vinculos FOR EACH ROW EXECUTE FUNCTION pat_audit();
CREATE TRIGGER tg_pat_vinc_touch BEFORE UPDATE ON public.pat_vinculos FOR EACH ROW EXECUTE FUNCTION pat_touch();
CREATE TRIGGER tg_vinc_guard BEFORE UPDATE ON public.pat_vinculos FOR EACH ROW EXECUTE FUNCTION pat_guard_inativar();

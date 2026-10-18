-- CARREIRA PRO → banco da Gestão Empresarial e Financeiro (agenda-pro) — funções, regras de acesso (RLS) e gatilhos.
-- Rodar depois do 001. Extraído em 18/10/2026 do banco antigo "Carreira PRO" (fwishtsueclpehucjmdj).

-- 1) funções
CREATE OR REPLACE FUNCTION public.pcs_classificar_desempenho(p_score numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_score is null then null
    when p_score <= 50  then 'insatisfatorio'   -- 30%–50%
    when p_score <= 70  then 'regular'          -- 51%–70%
    when p_score <= 85  then 'bom'              -- 71%–85%
    else                     'muito_bom'        -- 86%–100%
  end;
$function$
;
CREATE OR REPLACE FUNCTION public.pcs_meu_papel()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select papel from pcs_usuarios where auth_id = auth.uid() limit 1;
$function$
;
CREATE OR REPLACE FUNCTION public.pcs_eh_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select pcs_meu_papel() in ('rh','diretoria');
$function$
;
CREATE OR REPLACE FUNCTION public.pcs_meu_colaborador()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select colaborador_id from pcs_usuarios where auth_id = auth.uid() and ativo limit 1;
$function$
;
CREATE OR REPLACE FUNCTION public.pcs_meu_tenant()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select tenant_id from pcs_usuarios where auth_id = auth.uid() limit 1;
$function$
;
CREATE OR REPLACE FUNCTION public.pcs_nivel_sugerido(p_classificacao text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_classificacao
    when 'muito_bom' then 'III'
    when 'bom'       then 'II'
    else                  'I'
  end;
$function$
;
CREATE OR REPLACE FUNCTION public.pcs_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin new.updated_at = now(); return new; end; $function$
;
CREATE OR REPLACE FUNCTION public.pcs_sou_gestor_de(p_colab uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from pcs_colaboradores c
    where c.id = p_colab and c.gestor_id = pcs_meu_colaborador()
  );
$function$
;

-- 2) RLS ligado nas 22 tabelas
alter table public.pcs_afastamentos enable row level security;
alter table public.pcs_auditoria enable row level security;
alter table public.pcs_aval_faixas enable row level security;
alter table public.pcs_avaliacao_itens enable row level security;
alter table public.pcs_avaliacoes enable row level security;
alter table public.pcs_avaliacoes_itens enable row level security;
alter table public.pcs_cargo_competencias enable row level security;
alter table public.pcs_cargos enable row level security;
alter table public.pcs_classes enable row level security;
alter table public.pcs_colaboradores enable row level security;
alter table public.pcs_competencias enable row level security;
alter table public.pcs_config enable row level security;
alter table public.pcs_faixas enable row level security;
alter table public.pcs_movim_etapas enable row level security;
alter table public.pcs_movimentacoes enable row level security;
alter table public.pcs_notificacoes enable row level security;
alter table public.pcs_restricoes enable row level security;
alter table public.pcs_solicitacoes enable row level security;
alter table public.pcs_tabela_versoes enable row level security;
alter table public.pcs_tenants enable row level security;
alter table public.pcs_usuarios enable row level security;
alter table public.pcs_vagas enable row level security;

-- 3) regras de acesso (47)
create policy pcs_afastamentos_mod on public.pcs_afastamentos as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_afastamentos_sel on public.pcs_afastamentos as PERMISSIVE for SELECT to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR pcs_sou_gestor_de(colaborador_id))));
create policy pcs_aud_sel on public.pcs_auditoria as PERMISSIVE for SELECT to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_avalfx_all on public.pcs_aval_faixas as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = ANY (ARRAY['rh'::text, 'diretoria'::text])))) with check (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = ANY (ARRAY['rh'::text, 'diretoria'::text]))));
create policy pcs_avalfx_sel on public.pcs_aval_faixas as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_avalit_all on public.pcs_avaliacao_itens as PERMISSIVE for ALL to public using ((EXISTS ( SELECT 1
   FROM pcs_avaliacoes a
  WHERE ((a.id = pcs_avaliacao_itens.avaliacao_id) AND (a.tenant_id = pcs_meu_tenant()))))) with check ((EXISTS ( SELECT 1
   FROM pcs_avaliacoes a
  WHERE ((a.id = pcs_avaliacao_itens.avaliacao_id) AND (a.tenant_id = pcs_meu_tenant())))));
create policy pcs_aval_itens_mod on public.pcs_avaliacoes_itens as PERMISSIVE for ALL to public using ((EXISTS ( SELECT 1
   FROM pcs_avaliacoes a
  WHERE ((a.id = pcs_avaliacoes_itens.avaliacao_id) AND (a.tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR pcs_sou_gestor_de(a.colaborador_id)))))) with check ((EXISTS ( SELECT 1
   FROM pcs_avaliacoes a
  WHERE ((a.id = pcs_avaliacoes_itens.avaliacao_id) AND (a.tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR pcs_sou_gestor_de(a.colaborador_id))))));
create policy pcs_aval_itens_sel on public.pcs_avaliacoes_itens as PERMISSIVE for SELECT to public using ((EXISTS ( SELECT 1
   FROM pcs_avaliacoes a
  WHERE ((a.id = pcs_avaliacoes_itens.avaliacao_id) AND (a.tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR (a.colaborador_id = pcs_meu_colaborador()) OR pcs_sou_gestor_de(a.colaborador_id))))));
create policy pcs_aval_del on public.pcs_avaliacoes as PERMISSIVE for DELETE to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = ANY (ARRAY['rh'::text, 'diretoria'::text]))));
create policy pcs_aval_ins on public.pcs_avaliacoes as PERMISSIVE for INSERT to public with check (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = ANY (ARRAY['gestor'::text, 'rh'::text, 'diretoria'::text]))));
create policy pcs_aval_mod on public.pcs_avaliacoes as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR pcs_sou_gestor_de(colaborador_id)))) with check (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR pcs_sou_gestor_de(colaborador_id))));
create policy pcs_aval_sel on public.pcs_avaliacoes as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_aval_upd on public.pcs_avaliacoes as PERMISSIVE for UPDATE to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = ANY (ARRAY['gestor'::text, 'rh'::text, 'diretoria'::text])))) with check ((tenant_id = pcs_meu_tenant()));
create policy pcs_cargo_competencias_mod on public.pcs_cargo_competencias as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_cargo_competencias_sel on public.pcs_cargo_competencias as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_cargos_mod on public.pcs_cargos as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_cargos_sel on public.pcs_cargos as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_classes_mod on public.pcs_classes as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_classes_sel on public.pcs_classes as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_colab_mod on public.pcs_colaboradores as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_colab_sel on public.pcs_colaboradores as PERMISSIVE for SELECT to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR (id = pcs_meu_colaborador()) OR (gestor_id = pcs_meu_colaborador()))));
create policy pcs_comp_all on public.pcs_competencias as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = ANY (ARRAY['rh'::text, 'diretoria'::text])))) with check (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = ANY (ARRAY['rh'::text, 'diretoria'::text]))));
create policy pcs_comp_sel on public.pcs_competencias as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_competencias_mod on public.pcs_competencias as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_competencias_sel on public.pcs_competencias as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_config_mod on public.pcs_config as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_config_sel on public.pcs_config as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_faixas_mod on public.pcs_faixas as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_faixas_sel on public.pcs_faixas as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_movim_etapas_mod on public.pcs_movim_etapas as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR (pcs_meu_papel() = 'gestor'::text)))) with check (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR (pcs_meu_papel() = 'gestor'::text))));
create policy pcs_movim_etapas_sel on public.pcs_movim_etapas as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_movim_mod on public.pcs_movimentacoes as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR pcs_sou_gestor_de(colaborador_id)))) with check (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR pcs_sou_gestor_de(colaborador_id))));
create policy pcs_movim_sel on public.pcs_movimentacoes as PERMISSIVE for SELECT to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR (colaborador_id = pcs_meu_colaborador()) OR pcs_sou_gestor_de(colaborador_id))));
create policy pcs_notif_mod on public.pcs_notificacoes as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_notif_sel on public.pcs_notificacoes as PERMISSIVE for SELECT to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR (colaborador_alvo_id = pcs_meu_colaborador()))));
create policy pcs_restricoes_mod on public.pcs_restricoes as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_restricoes_sel on public.pcs_restricoes as PERMISSIVE for SELECT to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_eh_admin() OR pcs_sou_gestor_de(colaborador_id))));
create policy pcs_solic_del on public.pcs_solicitacoes as PERMISSIVE for DELETE to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = 'diretoria'::text)));
create policy pcs_solic_ins on public.pcs_solicitacoes as PERMISSIVE for INSERT to public with check (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = ANY (ARRAY['gestor'::text, 'rh'::text, 'diretoria'::text]))));
create policy pcs_solic_sel on public.pcs_solicitacoes as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_solic_upd on public.pcs_solicitacoes as PERMISSIVE for UPDATE to public using (((tenant_id = pcs_meu_tenant()) AND (pcs_meu_papel() = ANY (ARRAY['rh'::text, 'diretoria'::text])))) with check ((tenant_id = pcs_meu_tenant()));
create policy pcs_tabela_versoes_mod on public.pcs_tabela_versoes as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_tabela_versoes_sel on public.pcs_tabela_versoes as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));
create policy pcs_usuarios_mod on public.pcs_usuarios as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_usuarios_sel on public.pcs_usuarios as PERMISSIVE for SELECT to public using (((auth_id = auth.uid()) OR ((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())));
create policy pcs_vagas_mod on public.pcs_vagas as PERMISSIVE for ALL to public using (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin())) with check (((tenant_id = pcs_meu_tenant()) AND pcs_eh_admin()));
create policy pcs_vagas_sel on public.pcs_vagas as PERMISSIVE for SELECT to public using ((tenant_id = pcs_meu_tenant()));

-- 4) gatilhos
CREATE TRIGGER trg_pcs_aval_updated BEFORE UPDATE ON public.pcs_avaliacoes FOR EACH ROW EXECUTE FUNCTION pcs_set_updated_at();
CREATE TRIGGER trg_pcs_solic_updated BEFORE UPDATE ON public.pcs_solicitacoes FOR EACH ROW EXECUTE FUNCTION pcs_set_updated_at();

-- 5) sem acesso para quem não está logado (padrão da Agenda: "sem anon")
revoke all on
  public.pcs_afastamentos, public.pcs_auditoria, public.pcs_aval_faixas, public.pcs_avaliacao_itens, public.pcs_avaliacoes,
  public.pcs_avaliacoes_itens, public.pcs_cargo_competencias, public.pcs_cargos, public.pcs_classes, public.pcs_colaboradores,
  public.pcs_competencias, public.pcs_config, public.pcs_faixas, public.pcs_movim_etapas, public.pcs_movimentacoes,
  public.pcs_notificacoes, public.pcs_restricoes, public.pcs_solicitacoes, public.pcs_tabela_versoes, public.pcs_tenants,
  public.pcs_usuarios, public.pcs_vagas
  from anon;

-- CARREIRA PRO → banco da Gestão Empresarial e Financeiro (agenda-pro / vuwgxndahrzinfdlapxz)
-- Estrutura extraída em 18/10/2026 do banco antigo "Carreira PRO" (fwishtsueclpehucjmdj), que está VAZIO (0 linhas).
-- Só acréscimos (nenhuma tabela pcs_* existia no destino). Conferência: impressão digital da estrutura igual à origem.
-- Diferença proposital: a tabela não fica aberta para quem não está logado (anon) — o app só usa o banco depois do login.
-- APLICADO em 18/10/2026 no agenda-pro como migrations `carreira_001_estrutura` (este arquivo + RLS ligado + revoke anon,
-- para as tabelas nunca ficarem expostas entre um passo e outro) e `carreira_002_funcoes_e_acesso` (002 sem o RLS/revoke).
-- Conferido: impressão digital (colunas, regras, índices, funções, políticas, gatilhos) IGUAL à do banco antigo; anon sem privilégio.
-- Dados iniciais (18/10): escritório Artecon (CNPJ 79876769000128) e o login cleiver@ como Diretoria — o mesmo que o
-- "primeiro acesso" do app pede para rodar no SQL Editor. Teste de acesso: ele vê o próprio cadastro; outro login da Agenda vê 0.

-- 1) tabelas
create table if not exists public.pcs_afastamentos (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   colaborador_id uuid not null,   tipo text,   conta_como_efetivo boolean default true,   data_inicio date not null,   data_fim date,   observacao text,   criado_em timestamp with time zone default now());
create table if not exists public.pcs_auditoria (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   usuario_id uuid,   acao text,   entidade text,   entidade_id uuid,   dados_antes jsonb,   dados_depois jsonb,   ip text,   data timestamp with time zone default now());
create table if not exists public.pcs_aval_faixas (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   rotulo text not null,   score_min numeric(6,2) not null,   score_max numeric(6,2) not null,   elegivel boolean default false not null,   ordem integer default 0 not null,   created_at timestamp with time zone default now() not null);
create table if not exists public.pcs_avaliacao_itens (  id uuid default gen_random_uuid() not null,   avaliacao_id uuid not null,   competencia_id uuid,   nome text,   nota numeric(6,2),   peso numeric(6,2) default 1 not null,   comentario text);
create table if not exists public.pcs_avaliacoes (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   colaborador_id uuid not null,   ano_referencia integer not null,   avaliador_id uuid,   data_avaliacao date,   score_total numeric(5,2),   classificacao text,   status text default 'rascunho'::text,   observacoes text,   criado_em timestamp with time zone default now(),   periodo text,   escala_max numeric(6,2) default 5,   score numeric(6,2),   elegivel boolean,   solicitacao_id uuid,   created_at timestamp with time zone default now(),   updated_at timestamp with time zone default now());
create table if not exists public.pcs_avaliacoes_itens (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   avaliacao_id uuid not null,   competencia_id uuid not null,   nota numeric,   peso numeric default 1);
create table if not exists public.pcs_cargo_competencias (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   cargo_id uuid not null,   competencia_id uuid not null,   peso numeric default 1);
create table if not exists public.pcs_cargos (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   classe_id uuid not null,   ordem text,   nome text not null,   descricao_sumaria text,   descricao_detalhada text,   escolaridade_grau integer,   experiencia_grau integer,   grau_complexidade text,   resp_dados_conf integer,   resp_supervisao integer,   carreira_especifica boolean default false,   exige_vaga boolean default false,   nivel_hierarquico integer,   ativo boolean default true,   criado_em timestamp with time zone default now());
create table if not exists public.pcs_classes (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   ordem integer,   codigo text,   nome text not null,   descricao text,   ativo boolean default true,   criado_em timestamp with time zone default now());
create table if not exists public.pcs_colaboradores (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   auth_id uuid,   nome text not null,   cpf text,   matricula text,   email text,   departamento text,   classe_id uuid,   cargo_id uuid,   nivel_atual text,   salario_atual numeric(12,2),   data_admissao date,   data_ult_movim_horizontal date,   data_ult_movim_vertical date,   gestor_id uuid,   status text default 'ativo'::text,   data_fim_experiencia date,   foto_url text,   ativo boolean default true,   criado_em timestamp with time zone default now(),   data_desligamento date);
create table if not exists public.pcs_competencias (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   ordem integer,   nome text not null,   grupo text,   tipo text default 'desempenho'::text,   descricao text,   peso numeric default 1,   aplica_a text default 'todos'::text,   ativo boolean default true,   criado_em timestamp with time zone default now(),   cargo_id uuid,   classe_id uuid,   created_at timestamp with time zone default now());
create table if not exists public.pcs_config (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   intervalo_minimo_meses integer default 24,   prazo_solic_promocao_meses integer default 6,   prazo_transferencia_meses integer default 12,   score_min_horizontal numeric default 71,   score_min_vertical numeric default 86,   orcamento_promocoes_anual numeric,   percentual_reajuste_padrao numeric,   janela_adaptacao_dias_min integer default 30,   janela_adaptacao_dias_max integer default 90,   criado_em timestamp with time zone default now());
create table if not exists public.pcs_faixas (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   versao_id uuid not null,   cargo_id uuid not null,   nivel text not null,   valor numeric(12,2) not null,   provisorio boolean default false);
create table if not exists public.pcs_movim_etapas (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   movimentacao_id uuid not null,   etapa text,   responsavel_id uuid,   status text default 'pendente'::text,   data timestamp with time zone default now(),   comentario text);
create table if not exists public.pcs_movimentacoes (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   colaborador_id uuid not null,   tipo text not null,   modalidade text,   cargo_origem_id uuid,   nivel_origem text,   salario_origem numeric(12,2),   cargo_destino_id uuid,   nivel_destino text,   salario_destino numeric(12,2),   percentual_aumento numeric,   vaga_id uuid,   avaliacao_id uuid,   data_solicitacao date,   data_prevista_efetivacao date,   data_efetivacao date,   status text default 'solicitada'::text,   justificativa text,   motivo_rejeicao text,   aprov_superior_id uuid,   aprov_rh_id uuid,   aprov_diretoria_id uuid,   criado_em timestamp with time zone default now(),   criado_por uuid);
create table if not exists public.pcs_notificacoes (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   colaborador_alvo_id uuid,   papel_destinatario text,   tipo text,   titulo text,   mensagem text,   link_acao text,   lida boolean default false,   data_criacao timestamp with time zone default now());
create table if not exists public.pcs_restricoes (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   colaborador_id uuid not null,   tipo text,   artigo_violado text,   descricao text,   data_ocorrencia date not null,   data_fim_efeito date,   bloqueia_elegibilidade boolean default true,   ativa boolean default true,   criado_em timestamp with time zone default now());
create table if not exists public.pcs_solicitacoes (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   colaborador_id uuid not null,   tipo text not null,   cargo_origem_id uuid,   cargo_destino_id uuid,   nivel_origem text,   nivel_destino text,   salario_origem numeric(12,2),   salario_destino numeric(12,2),   percentual_aumento numeric(8,2),   justificativa text,   score numeric(6,2),   status text default 'solicitada'::text not null,   solicitante_id uuid,   data_solicitacao date default CURRENT_DATE not null,   rh_por uuid,   rh_em timestamp with time zone,   rh_parecer text,   aprovador_id uuid,   aprovado_em timestamp with time zone,   aprovacao_parecer text,   movimentacao_id uuid,   data_efetivacao date,   created_at timestamp with time zone default now() not null,   updated_at timestamp with time zone default now() not null);
create table if not exists public.pcs_tabela_versoes (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   descricao text,   percentual_aplicado numeric,   data_vigencia date not null,   base_versao_id uuid,   status text default 'vigente'::text,   criado_em timestamp with time zone default now(),   criado_por uuid);
create table if not exists public.pcs_tenants (  id uuid default gen_random_uuid() not null,   nome text not null,   cnpj text,   ativo boolean default true,   criado_em timestamp with time zone default now());
create table if not exists public.pcs_usuarios (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   auth_id uuid,   colaborador_id uuid,   papel text not null,   ativo boolean default true,   criado_em timestamp with time zone default now());
create table if not exists public.pcs_vagas (  id uuid default gen_random_uuid() not null,   tenant_id uuid not null,   classe_id uuid,   cargo_id uuid,   quantidade integer default 1,   tipo text,   status text default 'aberta'::text,   justificativa text,   solicitada_por uuid,   data_solicitacao date,   aprovada_por uuid,   data_aprovacao date,   criado_em timestamp with time zone default now());

-- 2) chaves e regras de valor
alter table public.pcs_afastamentos add constraint pcs_afastamentos_pkey PRIMARY KEY (id);
alter table public.pcs_auditoria add constraint pcs_auditoria_pkey PRIMARY KEY (id);
alter table public.pcs_aval_faixas add constraint pcs_aval_faixas_pkey PRIMARY KEY (id);
alter table public.pcs_avaliacao_itens add constraint pcs_avaliacao_itens_pkey PRIMARY KEY (id);
alter table public.pcs_avaliacoes_itens add constraint pcs_avaliacoes_itens_nota_check CHECK (((nota >= (0)::numeric) AND (nota <= (100)::numeric)));
alter table public.pcs_avaliacoes_itens add constraint pcs_avaliacoes_itens_pkey PRIMARY KEY (id);
alter table public.pcs_avaliacoes add constraint pcs_avaliacoes_classificacao_check CHECK ((classificacao = ANY (ARRAY['insatisfatorio'::text, 'regular'::text, 'bom'::text, 'muito_bom'::text])));
alter table public.pcs_avaliacoes add constraint pcs_avaliacoes_colaborador_id_ano_referencia_key UNIQUE (colaborador_id, ano_referencia);
alter table public.pcs_avaliacoes add constraint pcs_avaliacoes_pkey PRIMARY KEY (id);
alter table public.pcs_avaliacoes add constraint pcs_avaliacoes_score_total_check CHECK (((score_total >= (0)::numeric) AND (score_total <= (100)::numeric)));
alter table public.pcs_avaliacoes add constraint pcs_avaliacoes_status_check CHECK ((status = ANY (ARRAY['rascunho'::text, 'concluida'::text, 'homologada'::text])));
alter table public.pcs_cargo_competencias add constraint pcs_cargo_competencias_cargo_id_competencia_id_key UNIQUE (cargo_id, competencia_id);
alter table public.pcs_cargo_competencias add constraint pcs_cargo_competencias_pkey PRIMARY KEY (id);
alter table public.pcs_cargos add constraint pcs_cargos_pkey PRIMARY KEY (id);
alter table public.pcs_cargos add constraint pcs_cargos_tenant_id_ordem_key UNIQUE (tenant_id, ordem);
alter table public.pcs_classes add constraint pcs_classes_pkey PRIMARY KEY (id);
alter table public.pcs_classes add constraint pcs_classes_tenant_id_codigo_key UNIQUE (tenant_id, codigo);
alter table public.pcs_colaboradores add constraint pcs_colaboradores_nivel_atual_check CHECK ((nivel_atual = ANY (ARRAY['I'::text, 'II'::text, 'III'::text])));
alter table public.pcs_colaboradores add constraint pcs_colaboradores_pkey PRIMARY KEY (id);
alter table public.pcs_colaboradores add constraint pcs_colaboradores_status_check CHECK ((status = ANY (ARRAY['ativo'::text, 'experiencia'::text, 'afastado'::text, 'desligado'::text])));
alter table public.pcs_competencias add constraint pcs_competencias_aplica_a_check CHECK ((aplica_a = ANY (ARRAY['todos'::text, 'gestores'::text])));
alter table public.pcs_competencias add constraint pcs_competencias_pkey PRIMARY KEY (id);
alter table public.pcs_competencias add constraint pcs_competencias_tipo_check CHECK ((tipo = ANY (ARRAY['desempenho'::text, 'promocao'::text])));
alter table public.pcs_config add constraint pcs_config_pkey PRIMARY KEY (id);
alter table public.pcs_config add constraint pcs_config_tenant_id_key UNIQUE (tenant_id);
alter table public.pcs_faixas add constraint pcs_faixas_nivel_check CHECK ((nivel = ANY (ARRAY['I'::text, 'II'::text, 'III'::text])));
alter table public.pcs_faixas add constraint pcs_faixas_pkey PRIMARY KEY (id);
alter table public.pcs_faixas add constraint pcs_faixas_versao_id_cargo_id_nivel_key UNIQUE (versao_id, cargo_id, nivel);
alter table public.pcs_movim_etapas add constraint pcs_movim_etapas_pkey PRIMARY KEY (id);
alter table public.pcs_movim_etapas add constraint pcs_movim_etapas_status_check CHECK ((status = ANY (ARRAY['pendente'::text, 'aprovada'::text, 'rejeitada'::text])));
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_modalidade_check CHECK ((modalidade = ANY (ARRAY['mesma_carreira'::text, 'mudanca_carreira'::text])));
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_pkey PRIMARY KEY (id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_status_check CHECK ((status = ANY (ARRAY['solicitada'::text, 'aprov_superior'::text, 'avaliacao'::text, 'analise_rh'::text, 'aprov_diretoria'::text, 'em_adaptacao'::text, 'efetivada'::text, 'rejeitada'::text, 'cancelada'::text])));
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_tipo_check CHECK ((tipo = ANY (ARRAY['horizontal'::text, 'vertical'::text, 'transferencia'::text, 'reclassificacao'::text, 'ajuste_mercado'::text, 'admissao'::text, 'reajuste'::text])));
alter table public.pcs_notificacoes add constraint pcs_notificacoes_pkey PRIMARY KEY (id);
alter table public.pcs_restricoes add constraint pcs_restricoes_pkey PRIMARY KEY (id);
alter table public.pcs_restricoes add constraint pcs_restricoes_tipo_check CHECK ((tipo = ANY (ARRAY['advertencia_verbal'::text, 'advertencia_escrita'::text, 'suspensao'::text, 'justa_causa'::text])));
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_pkey PRIMARY KEY (id);
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_status_check CHECK ((status = ANY (ARRAY['solicitada'::text, 'em_analise'::text, 'aprovada'::text, 'rejeitada'::text, 'efetivada'::text, 'cancelada'::text])));
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_tipo_check CHECK ((tipo = ANY (ARRAY['horizontal'::text, 'vertical'::text])));
alter table public.pcs_tabela_versoes add constraint pcs_tabela_versoes_pkey PRIMARY KEY (id);
alter table public.pcs_tabela_versoes add constraint pcs_tabela_versoes_status_check CHECK ((status = ANY (ARRAY['rascunho'::text, 'vigente'::text, 'arquivada'::text])));
alter table public.pcs_tenants add constraint pcs_tenants_cnpj_key UNIQUE (cnpj);
alter table public.pcs_tenants add constraint pcs_tenants_pkey PRIMARY KEY (id);
alter table public.pcs_usuarios add constraint pcs_usuarios_papel_check CHECK ((papel = ANY (ARRAY['diretoria'::text, 'rh'::text, 'gestor'::text, 'colaborador'::text])));
alter table public.pcs_usuarios add constraint pcs_usuarios_pkey PRIMARY KEY (id);
alter table public.pcs_vagas add constraint pcs_vagas_pkey PRIMARY KEY (id);
alter table public.pcs_vagas add constraint pcs_vagas_status_check CHECK ((status = ANY (ARRAY['aberta'::text, 'preenchida'::text, 'cancelada'::text])));
alter table public.pcs_vagas add constraint pcs_vagas_tipo_check CHECK ((tipo = ANY (ARRAY['nova'::text, 'reposicao'::text])));

-- 3) ligações entre tabelas
alter table public.pcs_afastamentos add constraint pcs_afastamentos_colaborador_id_fkey FOREIGN KEY (colaborador_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_afastamentos add constraint pcs_afastamentos_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_auditoria add constraint pcs_auditoria_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_aval_faixas add constraint pcs_aval_faixas_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id) ON DELETE CASCADE;
alter table public.pcs_avaliacao_itens add constraint pcs_avaliacao_itens_avaliacao_id_fkey FOREIGN KEY (avaliacao_id) REFERENCES pcs_avaliacoes(id) ON DELETE CASCADE;
alter table public.pcs_avaliacao_itens add constraint pcs_avaliacao_itens_competencia_id_fkey FOREIGN KEY (competencia_id) REFERENCES pcs_competencias(id) ON DELETE SET NULL;
alter table public.pcs_avaliacoes_itens add constraint pcs_avaliacoes_itens_avaliacao_id_fkey FOREIGN KEY (avaliacao_id) REFERENCES pcs_avaliacoes(id) ON DELETE CASCADE;
alter table public.pcs_avaliacoes_itens add constraint pcs_avaliacoes_itens_competencia_id_fkey FOREIGN KEY (competencia_id) REFERENCES pcs_competencias(id);
alter table public.pcs_avaliacoes_itens add constraint pcs_avaliacoes_itens_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_avaliacoes add constraint pcs_avaliacoes_avaliador_id_fkey FOREIGN KEY (avaliador_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_avaliacoes add constraint pcs_avaliacoes_colaborador_id_fkey FOREIGN KEY (colaborador_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_avaliacoes add constraint pcs_avaliacoes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_cargo_competencias add constraint pcs_cargo_competencias_cargo_id_fkey FOREIGN KEY (cargo_id) REFERENCES pcs_cargos(id);
alter table public.pcs_cargo_competencias add constraint pcs_cargo_competencias_competencia_id_fkey FOREIGN KEY (competencia_id) REFERENCES pcs_competencias(id);
alter table public.pcs_cargo_competencias add constraint pcs_cargo_competencias_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_cargos add constraint pcs_cargos_classe_id_fkey FOREIGN KEY (classe_id) REFERENCES pcs_classes(id);
alter table public.pcs_cargos add constraint pcs_cargos_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_classes add constraint pcs_classes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_colaboradores add constraint pcs_colaboradores_cargo_id_fkey FOREIGN KEY (cargo_id) REFERENCES pcs_cargos(id);
alter table public.pcs_colaboradores add constraint pcs_colaboradores_classe_id_fkey FOREIGN KEY (classe_id) REFERENCES pcs_classes(id);
alter table public.pcs_colaboradores add constraint pcs_colaboradores_gestor_id_fkey FOREIGN KEY (gestor_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_colaboradores add constraint pcs_colaboradores_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_competencias add constraint pcs_competencias_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_config add constraint pcs_config_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_faixas add constraint pcs_faixas_cargo_id_fkey FOREIGN KEY (cargo_id) REFERENCES pcs_cargos(id);
alter table public.pcs_faixas add constraint pcs_faixas_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_faixas add constraint pcs_faixas_versao_id_fkey FOREIGN KEY (versao_id) REFERENCES pcs_tabela_versoes(id);
alter table public.pcs_movim_etapas add constraint pcs_movim_etapas_movimentacao_id_fkey FOREIGN KEY (movimentacao_id) REFERENCES pcs_movimentacoes(id) ON DELETE CASCADE;
alter table public.pcs_movim_etapas add constraint pcs_movim_etapas_responsavel_id_fkey FOREIGN KEY (responsavel_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_movim_etapas add constraint pcs_movim_etapas_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_aprov_diretoria_id_fkey FOREIGN KEY (aprov_diretoria_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_aprov_rh_id_fkey FOREIGN KEY (aprov_rh_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_aprov_superior_id_fkey FOREIGN KEY (aprov_superior_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_avaliacao_id_fkey FOREIGN KEY (avaliacao_id) REFERENCES pcs_avaliacoes(id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_cargo_destino_id_fkey FOREIGN KEY (cargo_destino_id) REFERENCES pcs_cargos(id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_cargo_origem_id_fkey FOREIGN KEY (cargo_origem_id) REFERENCES pcs_cargos(id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_colaborador_id_fkey FOREIGN KEY (colaborador_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_movimentacoes add constraint pcs_movimentacoes_vaga_id_fkey FOREIGN KEY (vaga_id) REFERENCES pcs_vagas(id);
alter table public.pcs_notificacoes add constraint pcs_notificacoes_colaborador_alvo_id_fkey FOREIGN KEY (colaborador_alvo_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_notificacoes add constraint pcs_notificacoes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_restricoes add constraint pcs_restricoes_colaborador_id_fkey FOREIGN KEY (colaborador_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_restricoes add constraint pcs_restricoes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_aprovador_id_fkey FOREIGN KEY (aprovador_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_cargo_destino_id_fkey FOREIGN KEY (cargo_destino_id) REFERENCES pcs_cargos(id);
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_cargo_origem_id_fkey FOREIGN KEY (cargo_origem_id) REFERENCES pcs_cargos(id);
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_colaborador_id_fkey FOREIGN KEY (colaborador_id) REFERENCES pcs_colaboradores(id) ON DELETE CASCADE;
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_movimentacao_id_fkey FOREIGN KEY (movimentacao_id) REFERENCES pcs_movimentacoes(id);
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_rh_por_fkey FOREIGN KEY (rh_por) REFERENCES pcs_colaboradores(id);
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_solicitante_id_fkey FOREIGN KEY (solicitante_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_solicitacoes add constraint pcs_solicitacoes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id) ON DELETE CASCADE;
alter table public.pcs_tabela_versoes add constraint pcs_tabela_versoes_base_versao_id_fkey FOREIGN KEY (base_versao_id) REFERENCES pcs_tabela_versoes(id);
alter table public.pcs_tabela_versoes add constraint pcs_tabela_versoes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_usuarios add constraint pcs_usuarios_colaborador_fk FOREIGN KEY (colaborador_id) REFERENCES pcs_colaboradores(id);
alter table public.pcs_usuarios add constraint pcs_usuarios_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);
alter table public.pcs_vagas add constraint pcs_vagas_aprovada_por_fkey FOREIGN KEY (aprovada_por) REFERENCES pcs_colaboradores(id);
alter table public.pcs_vagas add constraint pcs_vagas_cargo_id_fkey FOREIGN KEY (cargo_id) REFERENCES pcs_cargos(id);
alter table public.pcs_vagas add constraint pcs_vagas_classe_id_fkey FOREIGN KEY (classe_id) REFERENCES pcs_classes(id);
alter table public.pcs_vagas add constraint pcs_vagas_solicitada_por_fkey FOREIGN KEY (solicitada_por) REFERENCES pcs_colaboradores(id);
alter table public.pcs_vagas add constraint pcs_vagas_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES pcs_tenants(id);

-- 4) índices
CREATE INDEX idx_pcs_aval_colab ON public.pcs_avaliacoes USING btree (colaborador_id);
CREATE INDEX idx_pcs_aval_tenant ON public.pcs_avaliacoes USING btree (tenant_id);
CREATE INDEX idx_pcs_avalfx_tenant ON public.pcs_aval_faixas USING btree (tenant_id);
CREATE INDEX idx_pcs_avalit_aval ON public.pcs_avaliacao_itens USING btree (avaliacao_id);
CREATE INDEX idx_pcs_cargos_classe ON public.pcs_cargos USING btree (classe_id);
CREATE INDEX idx_pcs_colab_auth ON public.pcs_colaboradores USING btree (auth_id);
CREATE INDEX idx_pcs_colab_cargo ON public.pcs_colaboradores USING btree (cargo_id);
CREATE INDEX idx_pcs_colab_gestor ON public.pcs_colaboradores USING btree (gestor_id);
CREATE INDEX idx_pcs_comp_tenant ON public.pcs_competencias USING btree (tenant_id);
CREATE INDEX idx_pcs_faixas_cargo ON public.pcs_faixas USING btree (cargo_id);
CREATE INDEX idx_pcs_movim_colab ON public.pcs_movimentacoes USING btree (colaborador_id);
CREATE INDEX idx_pcs_notif_alvo ON public.pcs_notificacoes USING btree (colaborador_alvo_id);
CREATE INDEX idx_pcs_solic_colab ON public.pcs_solicitacoes USING btree (colaborador_id);
CREATE INDEX idx_pcs_solic_status ON public.pcs_solicitacoes USING btree (status);
CREATE INDEX idx_pcs_solic_tenant ON public.pcs_solicitacoes USING btree (tenant_id);

# Análise de IRRF · Artecon

App de análise de declarações IRPF: carteira de clientes, análises por exercício,
pendências, oportunidades, carnê-leão, renda variável e ganho de capital.

- **Frontend**: estático (HTML/CSS/JS + [supabase-js](https://supabase.com/docs/reference/javascript)), publicado via GitHub Pages.
- **Banco**: projeto Supabase **agenda-pro** (`vuwgxndahrzinfdlapxz`) — banco departamental
  "Gestão Empresarial e Financeiro". Todas as tabelas usam o prefixo `ir_`
  (`ir_clientes`, `ir_analises`, `ir_pendencias`, `ir_oportunidades`, `ir_carne_leao`,
  `ir_renda_variavel`, `ir_rv_saldo_prejuizo`, `ir_ganho_capital`, `ir_auditoria`, …).
- **Autenticação**: Supabase Auth (e-mail/senha) do projeto agenda-pro. A RLS de todas as
  tabelas `ir_` exige usuário autenticado (`authenticated`); não há cadastro aberto —
  contas são criadas pelo administrador no painel do Supabase (Authentication → Users).
  O modelo antigo de login próprio (`ir_usuarios`, senha em texto puro) foi abolido e a
  tabela permanece apenas por compatibilidade histórica.

## Configuração

A URL do projeto e a chave publicável (`sb_publishable_…`, segura para uso no navegador)
ficam no topo do `<script>` em `index.html` (`SUPA_URL` / `SUPA_KEY`). Para trocar a chave,
gere outra em Supabase → agenda-pro → Settings → API Keys.

## Cálculos embutidos

- **Carnê-leão**: tabela progressiva mensal por vigência (até 04/2023, 05/2023, 02/2024 e
  05/2025 em diante) + dedução por dependente (R$ 189,59). Atualizar `TABELAS_MENSAIS`
  quando a Receita publicar nova tabela.
- **Renda variável**: 15% (operações comuns) / 20% (day trade e FII), compensação de
  prejuízo e dedução do IRRF; controle de saldo de prejuízo por modalidade.
- **Ganho de capital**: alíquota progressiva 15%–22,5% (Lei 13.259/2016) e hipóteses de isenção.

## Módulos de operação e apoio

- **Dossiê** (`ir_dossie`): conferência por cliente/exercício (ficha × documento, status, risco de malha).
- **Workflow** (`ir_workflow`): tarefas com responsável, prioridade, prazo (alerta de vencido) e conclusão.
- **Documentos** (`ir_documentos` + bucket privado `ir-documentos` no Storage): upload até 50 MB,
  hash SHA-256 com alerta de duplicado, download por link assinado de 1 h.
- **Regras** (`ir_regras`): catálogo de regras de malha fina (há um conjunto padrão carregável pela UI);
  numa análise, "Aplicar regras" gera pendências vinculadas (`regra_id`/`analise_id`), sem duplicar.
- **Base de Conhecimento** (`ir_base_conhecimento`): consulta estilo "Perguntão" com busca por texto
  e exercício, e manutenção das entradas.

## Histórico

Este repositório abrigou uma cópia antiga do Rescisões Pro (hoje em
`departamento-pessoal/rescisoes/`) e, entre 17 e 28/10/2026, apenas um aviso de
redirecionamento.

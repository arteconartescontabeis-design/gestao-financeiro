# Artecon Propostas — memória do projeto

App de propostas de honorários, contratos e confissões de dívida da **Artecon Artes Contábeis** (Palhoça/SC). Tudo em português.

> Este repositório é **público**: nada de chaves, senhas, valores de honorários, nomes ou dados de clientes aqui.
> Tabelas de preço, planilhas de enquadramento e relatórios do Questor ficam fora do repositório.

## Estrutura
- `index.html` — o app inteiro (HTML + CSS + JS, arquivo único, sem build). Quebras de linha **CRLF**: mantenha.
  Modo nuvem (Supabase, quando o `CFG` está preenchido) ou modo local (localStorage, para teste).
  Camada de dados em `Local`/`Nuvem` (`DB.inserir`, `DB.alterar`, `DB.inserirVarios`), estado global em `S`, telas em `VIEWS`, botões em `ACOES` (`data-act`), navegação por `data-ir`/`ir()`.
- `sql/` — migrações e reversões, **rodadas pelo usuário** no SQL Editor do projeto `cobranca-pro`
  (numeração continua a dos arquivos antigos: 17 = contratos, 19 = confissões, 21 = cadastro único; reversões 96, 93, 92).
- `supabase/functions/prop-email` — Edge Function dos e-mails automáticos (fila `prop_fila_email`).
- Publicado em `https://arteconartescontabeis-design.github.io/gestao-financeiro/propostas/` (o repositório antigo `propostas` só redireciona).
- Banco: projeto Supabase `yeujqjtjqtegsnzwwazb` (o mesmo do Cobrança Pro), tabelas `prop_*` com RLS; login compartilhado com o Cobrança Pro.

## Regras de entrega
1. Toda melhoria incrementa a versão (`APP_VERSION`) e ganha um item no topo do `CHANGELOG` (aba Versões).
2. Mudança de estrutura passa por mockup/relatório e aprovação antes de ir para o app.
3. Entrega que toque RLS, gatilho, política ou contrato com o banco só sai depois de reproduzida e validada em PostgreSQL local
   (estado antes, rodar duas vezes, ciclo criar → excluir → regravar, reversão e reaplicação).
4. Scripts SQL idempotentes, com bloco de estado-antes, verificação (colunas `ok_*` = true) e reversão.
5. Soft delete + chave única + upsert do PostgREST não combinam: não usar upsert em tabela com exclusão lógica.
6. Varredura antes de entregar: eslint (0 erros) + Playwright em todas as telas, no computador e no celular (390 px sem rolagem lateral).
7. Nunca concluir sobre o estado do banco sem evidência (consulta ou print).

## Estado (20/10/2026)
- **v2.2.0 — cadastro único de clientes** (migração `sql/21_migracao_v2_2_0_cadastro_unico.sql`, reversão `sql/92_reversao_v2_2_0.sql`):
  - "Clientes da proposta" e "Contratantes" viraram um só cadastro (`prop_clientes`), no grupo Clientes do menu.
    Contratos e confissões continuam com a coluna `contratante_id`, que agora aponta para `prop_clientes`.
    `S.contratantes` é derivado de `S.clientes` (`cliCtt`: `nome` → `razao_social`) para o código de contratos e confissões não mudar.
    A tabela `prop_contratantes` ficou só para a reversão (correspondência em `prop_priv.migracao_v220_ctt` e `_ref`).
  - Colunas novas em `prop_clientes`: dados do contrato e da Receita, `regime` (simples, presumido, real, mei, imune), `atividade`,
    `apuracao`, `situacao` (ativa, sem_movimento, inativa), `matriz_id`, `codigo_questor`, `cob_cliente_id`, `departamentos`,
    `nivel_atual`, `honorario_atual`/`_ref`/`_origem`, `enquadramento` (jsonb com lançamentos e folha).
  - `prop_clientes_contatos`: quem recebe (e-mail/WhatsApp) e quem assina. O app mantém `prop_clientes.email/telefone/contato`
    como o contato principal, para as telas antigas (signatários) continuarem funcionando.
  - Guarda `prop_clientes_guarda`: matriz do mesmo escritório e não filial; não exclui cliente com contrato ou confissão em andamento
    nem matriz com filiais ativas (PROP055, PROP082–085).
  - RPC `prop_cobranca_clientes(p_tenant, p_meses)`: lê do Cobrança Pro clientes, contatos e soma mensal dos boletos
    (sem renegociada/cancelada). Exige vínculo nos dois apps (PROP090–092).
  - Importação com conferência: Cobrança Pro e planilha "Relação de Empresas e seus Regimes" do S3D (xlsx, lida com SheetJS do cdnjs).
    Honorário atual = valor mensal que se repete nos boletos; empate, o menor; sem repetição, a mediana.
    Filial S3D "Regime Normal" herda o regime da matriz; código do Questor da filial = `código da matriz/nº do estabelecimento`.
- **v2.3.0 — lotes de propostas** (migração `sql/22_migracao_v2_3_0_lotes.sql`, reversão `sql/91_reversao_v2_3_0.sql`; exige a 21):
  - `prop_lotes` (tipo reajuste | avulso | mensal; situação rascunho → gerado → descartado; `parametros` e `filtros` em jsonb) e
    `prop_propostas.lote_id` (não muda depois de criada; gatilho `prop_propostas_lote`, PROP103).
  - Guarda `prop_lotes_guarda` (PROP101/102): escritório, autoria e tipo não mudam; descartar só pela RPC
    `prop_lote_descartar` (só diretor, todas as propostas em rascunho e sem assinatura; exclui as propostas, PROP104).
  - Assistente em 4 passos (`VIEWS.loteNovo`, estado em `S.LT`): o que oferecer, quem recebe (filtros + seleção), prévia, gerar.
    As propostas saem pelo mesmo formato da proposta manual (`lotePropostaDe`), em rascunho, com aceite, e passam em `validarProposta`.
  - Reajuste: honorário atual × (1 + %), arredondamento centavos/R$ 1/R$ 5 (para o mais próximo); vigência e índice entram como
    cláusula adicional da seção 2. Serviço avulso: item pontual do catálogo, pagamento junto com o boleto, na aceitação ou parcelado.
  - "Mensal — 3 níveis" fica desabilitado até a tabela de preços (v2.5/v2.6).
- v2.1.x (contratos e confissões) e anteriores: ver aba Versões do app.

## Próximas entregas (decididas em 20/10/2026)
- v2.4.0 envio em massa por e-mail (fila do app, aos poucos) e WhatsApp pela fila do robô do Cobrança Pro, com assinatura do
  escritório em lote (mesma trilha da assinatura individual).
- v2.5.0 tabela de preços e catálogo (o app e os documentos mostram só os valores finais).
- v2.6.0 proposta por níveis (Essencial, Gestão, Estratégico) e importação dos relatórios do Questor para o enquadramento.
- v2.7.0 contrato herdando a proposta.
- Pendentes de decisão do responsável: excedente acima da última faixa de lançamentos, preços avulsos, definição de
  "pouco movimento", escala intermediária do preço por vínculo, tipo de assinatura digital do escritório.

## Testes
- Roteiro Playwright (fora do repositório) com Supabase falso em memória para o modo nuvem e dados da v2.1 para o modo local.
  Chromium do ambiente: `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`.

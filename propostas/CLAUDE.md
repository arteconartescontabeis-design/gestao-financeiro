# Artecon Propostas — memória do projeto

App de propostas de honorários, contratos e confissões de dívida da **Artecon Artes Contábeis** (Palhoça/SC). Tudo em português.

> Este repositório é **público**: nada de chaves, senhas, valores de honorários, nomes ou dados de clientes aqui.
> Tabelas de preço, planilhas de enquadramento e relatórios do Questor ficam fora do repositório.

## Estrutura
- `index.html` — o app inteiro (HTML + CSS + JS, arquivo único, sem build). Quebras de linha **CRLF**: mantenha.
  Modo nuvem (Supabase, quando o `CFG` está preenchido) ou modo local (localStorage, para teste).
  Camada de dados em `Local`/`Nuvem` (`DB.inserir`, `DB.alterar`, `DB.inserirVarios`), estado global em `S`, telas em `VIEWS`, botões em `ACOES` (`data-act`), navegação por `data-ir`/`ir()`.
- `sql/` — migrações e reversões, **rodadas pelo usuário** no SQL Editor do projeto `cobranca-pro`
  (numeração continua a dos arquivos antigos: 17 = contratos, 19 = confissões, 21 = cadastro único, 22 = lotes, 23 = envio em massa,
  24 = tabela de preços; reversões 96, 93, 92, 91, 90, 89 — a próxima migração é a 25 e a próxima reversão a 88).
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
8. Cópia de cada versão publicada no OneDrive (decidido em 22/10/2026): gerar `propostas-vX.Y.Z.zip` a partir do commit da `main`
   (pasta `propostas/` inteira + `LEIA-ME.txt` com data, commit, SQL a rodar e itens do changelog) e entregar ao usuário para guardar em
   OneDrive › `Aplicativo Criado Artecon/Propostas de Honorários/Versões Antigas`. O conector do Microsoft 365 não sobe o pacote
   (limite de 1 MB e o arquivo precisaria ir inteiro dentro da chamada; o app tem ~1,1 MB, o .zip ~560 KB por causa das imagens
   embutidas): o usuário salva e depois a pasta é conferida pela listagem do conector.

## Estado (23/10/2026)
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
- **v2.4.0 — assinatura em lote e envio em massa** (migração `sql/23_migracao_v2_4_0_envio_em_massa.sql`, reversão
  `sql/90_reversao_v2_4_0.sql`; exige a 21, a 22 e o Cobrança Pro com `cob_whats_destino_ok`):
  - Tela do lote (`VIEWS.lote` → `desenhaLoteEnvio`, estado em `S.LE`, dados de `DB.loteEnvio`) em 4 etapas: quem assina,
    assinatura do escritório, envio, acompanhamento. Só no modo nuvem.
  - Quem assina (`loteQuemAssina`): contatos marcados "Assina"; sem nenhum, o contato que recebe e-mail/WhatsApp, só com autorização
    gravada em `prop_lotes.parametros.autorizados` (`{ cliente_id: { por, em } }`). Os signatários são criados na hora do envio.
  - Escritório assina em lote pelo `prop_escritorio_assinar` (uma assinatura por proposta). Só sai envio para proposta assinada pelo escritório.
  - Canal escolhido no envio: só e-mail, só WhatsApp ou os dois. E-mail pelo navegador (`enviarLink`, 1 a cada 2 s, com "Parar").
    WhatsApp por `prop_whats_agendar` → tabela `prop_whats_envios` → `prop_whats_gotejar` (pg_cron a cada minuto) → `cob_whatsapp_fila`
    (robô do Cobrança Pro). Ritmo em `prop_tenants.escritorio`: `whats_intervalo_min` 3, `whats_limite_dia` 40, `whats_hora_ini` 8,
    `whats_hora_fim` 18, `whats_sabado` false. Só para celular cadastrado no Cobrança Pro para o cliente (aceita com ou sem 55).
  - `prop_link_signatario` agora mantém um link válido por canal; o gatilho `prop_assinatura_fecha_canais` encerra os outros links
    e cancela o WhatsApp pendente quando a pessoa assina.
  - Acompanhamento: lembrar quem não abriu (> 2 dias), reenviar/cancelar WhatsApp (`prop_whats_reagendar`/`prop_whats_cancelar`),
    planilha CSV sem links.
- **v2.5.0 — tabela de preços** (migração `sql/24_migracao_v2_5_0_tabela_precos.sql`, reversão `sql/89_reversao_v2_5_0.sql`):
  - `prop_tabelas_preco`: uma linha por versão (`vigencia` = data de início; vale a de maior vigência <= hoje), valores em `dados` jsonb:
    `faixas`, `precos[regime][atividade][faixa] = [fiscal, contabil]` (Essencial), `acrescimos[depto] = [gestao, estrategico]`,
    `params` (vínculo, sócios, contas, filial, pouco movimento, sem movimento, MEI, adicional de novembro, `exc` = degraus acima da última
    faixa, `vinc` = escala de funcionários) e `avulsos`. Guarda `prop_tabelas_preco_guarda`: só diretor grava (PROP120), versão não muda
    (PROP122), não apaga (PROP121), exclui só a que nenhuma proposta usou (`condicoes.tabela_preco_id`, PROP123).
  - **Os valores (R$) não ficam no repositório**: entram pelo app (Configurações › Tabela de preços › Importar planilha .xlsx, abas
    Tabela, Níveis, Parâmetros, Avulsos) e ficam só no banco. Exportar gera a mesma planilha.
  - Cálculo puro: `tpEstab` (um estabelecimento) e `tpCalcula` (matriz + filiais) → Essencial/Gestão/Estratégico com linhas por
    departamento e as regras aplicadas; `tpSugere` aplica "nunca abaixo de hoje"; `tpProjecao` faz a carteira por empresa.
  - Tela `VIEWS.tabela` (abas Tabela, Regras e valores, Avulsos, Simulador, Projeção, Versões, estado em `S.TP`) e `VIEWS.tabelaEditar`.
- v2.1.x (contratos e confissões) e anteriores: ver aba Versões do app.

## Regras de preço aprovadas (23/10/2026, apresentação "Proposta por níveis")
- **Nunca abaixo de hoje:** os honorários atuais não mudam; a tabela só projeta. Se a tabela der menos que o atual, o Essencial
  sugerido fica no valor de hoje e Gestão/Estratégico somam o mesmo acréscimo da tabela. O valor novo vale depois da assinatura.
- Acima da última faixa (900 lançamentos): degraus de +15%, +30%, +45% e +60% (até 2.000, 5.000, 10.000 e acima), por departamento.
- Filial: 50% do Fiscal e do Contábil da faixa dela. Filial com pouco movimento (até 100 fiscais e 100 contábeis, sem empregados):
  25% da tabela, com valor mínimo. Empresa sem movimento: valor fixo (filial: × % de filial).
- Escala de funcionários aplicada por faixa: 100% até 30, 90% de 31 a 60, 80% de 61 a 100, 70% acima de 100.
- Primeira versão da tabela gravada em produção em 23/10/2026 (vale a partir dessa data). O **valor por funcionário** dela foi
  alterado pelo responsável na tela de conferência e difere da planilha inicial de propósito (confirmado em 23/10/2026): não "corrigir".
  A fonte dos valores é o banco; para ter a planilha atual, use Exportar planilha no app.
- Avulsos: lista única, corrigida pelo mesmo fator da tabela. Assinatura do escritório: a eletrônica do app (ICP-Brasil só se exigirem).
- Premissas do cálculo a confirmar com o responsável: sócio com pró-labore além de 2 paga um valor próprio por sócio; o acréscimo de nível
  do Pessoal só entra com funcionários; MEI só tem o Essencial; Societário e Atendimento entram uma vez por empresa (na matriz).

## Decisões do responsável sobre assinatura (21/10/2026)
- **Proposta:** pode ser assinada só com CPF (nome, CPF, e-mail, cargo e declaração de poderes). A foto com documento é
  opcional e vem desmarcada (`exige_foto` false na proposta nova e no lote).
- **Contrato:** quando houver assinatura pelo link, a foto com o documento é **obrigatória**, sem opção de desligar.
- **Quem assina quando o cliente não tem contato marcado como "Assina"** (decidido em 21/10/2026): o pedido vai para o
  contato que recebe e-mail (opção "automático"), **mas só sai depois que o usuário autorizar** — a tela do lote lista esses
  clientes e o envio para eles exige uma autorização explícita (v2.4.0). Sem autorização, ficam como pendência.

## Próximas entregas (decididas em 20/10/2026)
- v2.6.0 proposta por níveis (Essencial, Gestão, Estratégico) e importação dos relatórios do Questor para o enquadramento.
- v2.7.0 contrato herdando a proposta.

## Testes
- Roteiro Playwright (fora do repositório) com Supabase falso em memória para o modo nuvem e dados da v2.1 para o modo local.
  Chromium do ambiente: `/opt/pw-browsers/chromium-1194/chrome-linux/chrome`.

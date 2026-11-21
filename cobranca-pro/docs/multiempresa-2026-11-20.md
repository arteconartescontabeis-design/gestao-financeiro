# Multiempresa + integração Questor Negócio — plano aprovado (20/11/2026)

> **CORTE CONCLUÍDO em 21/11/2026, 14:27 — fonte única LIGADA e primeira sincronização validada:**
> 25 baixas aplicadas (R$ 17.622,24; incluía 2 títulos vencidos já pagos no banco), 42 títulos novos
> importados (R$ 65.397,96), 15 clientes novos, 228 títulos adotaram o id da API, 0 erros. Validado
> também: captura agendada (pg_cron) funcionando, alerta por e-mail funcionando, e a agenda
> NÃO consegue acionar a fonte única (403 — só o diretor pelo app). O .CRT e o relatório do Questor
> instalado agora são contingência. Pendência operacional: as baixas contínuas dependem do diretor clicar
> "Sincronizar agora" — avaliar estender a agenda para sincronizar quando o modo for 'fonte'.
>
> **Horários definidos pelo usuário (21/11, v2.23.2 + questor-sync v1.5):** captura 10:00 e 16:00 (Brasília),
> sem e-mail; alerta diário 10:30 (ação 'alertar' — e-mail só se houver risco/erro, destino
> cob_automacao_config.questor_alerta_email); janela de envio mantida 08:00–20:00; aviso a vencer = 5 dias
> (o duplo aviso automático 5+1 dia é a v2.24, a fazer); robô do ARTEAPP01 "desativado até segunda ordem" —
> pelo app ficou 1×/dia às 03:00, e a desativação total é no servidor (Agendador de Tarefas → desabilitar
> "Artecon Robo Cobranca" + fechar o vigia). Obs.: todas as empresas do grupo usam o mesmo banco (Sicredi).

**Status (20/11/2026, madrugada): v2.19.0 → v2.21.0 CONCLUÍDAS E PUBLICADAS.** v2.20.0 (PR #17) e
v2.21.0 (PR #18) mescladas na main; GitHub Pages conferido servindo a v2.21.0. Todas as migrations aplicadas
no banco na ordem segura: v2.19.0, v2.20.0 (view), v2.21.0 parte A (antes do merge) e parte B
(`migration_v2_21_1`, depois do Pages servir a v2.21.0) — a unicidade do nosso número agora é por empresa.
Se alguém estava com o app aberto na v2.20 durante a troca, basta recarregar a página (F5).
**Próximos passos:** cadastrar as demais empresas em Sistema → Empresas e, com a chave x-api-key no Vault,
começar a v2.22.0 (integração Questor Negócio em modo paralelo).
Apresentação visual (mockups e tabelas): artefato no Claude — https://claude.ai/artifact/2sgN2wEk2EYyH2HzMgKnQU

## Decisões do usuário
1. **4 empresas do mesmo grupo**, com cadastro **aberto** (pode passar de 4). Cadastro na aba Sistema, depois.
2. Boletos vêm do Questor; a captura muda para a **API do Questor Negócio** (coleção oficial analisada,
   https://documenter.getpostman.com/view/2374833/2s93mAVLCQ).
3. O **mesmo cliente pode ser cobrado por mais de uma empresa** → cadastro de clientes continua único (tenant).
4. **Envio compartilhado**: mesmo número de WhatsApp e mesmo e-mail; muda só a assinatura da empresa dona do boleto.
5. **Todos os usuários veem todas as empresas** (sem restrição por empresa).
6. **Juros, multa e níveis 1/2/3 iguais** para todas (cob_politicas segue por tenant).
7. Conta do Questor Negócio: `arteconartes.questornegocio.com.br` — **uma conta só** para o grupo (confirmado);
   o **retorno bancário é processado dentro do Questor Negócio** (confirmado) → o .CRT pode sair do fluxo do app
   no corte; **não há ambiente de testes** → a v2.22.0 roda obrigatoriamente em modo paralelo antes do corte.

## Desenho
- **Um tenant só** (Grupo Artecon). Nível novo `cob_empresas` + `empresa_id` nas tabelas operacionais
  (parcelas, pagamentos, conciliações, confrontos, fila de envios, fila WhatsApp, eventos).
- Compartilhado (fica no tenant): clientes e contatos, templates, filas/sessão de envio, usuários, políticas,
  feriados, índices, auditoria.
- Seletor "Todas / empresa" no topo do app (lembrado por usuário); "Todas" = consolidado com quebra por empresa.
- Nosso número passa a ser único **por empresa** — mas só na v2.21.0 (ver aviso abaixo).

## ⚠ Aviso de sequência (não quebrar o app)
O app faz `upsert` com `onConflict: 'tenant_id,nosso_numero'` em `cob_parcelas`
(importações, boleto manual — index.html ~5601, 5609, 9915, 9919). O índice único
`cob_parcelas_tenant_id_nosso_numero_key` **não pode ser trocado antes** do app passar a enviar
`empresa_id` nesses upserts. A troca para `(tenant_id, empresa_id, nosso_numero)` acontece na
**v2.21.0**, migration + app juntos. A v2.19.0 de propósito não mexe nesse índice.

## Etapas
| Versão | Entrega | Situação |
|---|---|---|
| v2.19.0 | Banco: `cob_empresas` (com `padrao`, `questor_cnpj`), `empresa_id` + backfill para a Artecon, gatilho da empresa padrão no insert, trava de troca de empresa (diretor/robô), índices, `cob_parcelas.questor_id` | **concluída — aplicada no banco em 20/11** |
| v2.20.0 | App: tela Sistema → Empresas do grupo (só diretor), seletor "Todas as empresas" no topo (lembrado por usuário), filtro por empresa no Painel e em Conferir → Parcelas (com etiqueta), variáveis `{{empresa_cobradora}}`/`{{empresa_cnpj}}` nos modelos; migration `v2_20_0_view_empresa.sql` (view do Painel com `empresa_id`, security_invoker preservado) | **banco aplicado; app pronto — publicar `index.html`** |
| v2.21.0 | Importações lançam na empresa do seletor (senão a padrão); boleto manual com empresa na confirmação e checagem de duplicidade por empresa; Relatórios (4 abas) seguem o seletor; Painel em "Todas" com quebra por empresa; mensagens (e-mail, WhatsApp, cartão) assinadas pela empresa dona dos boletos (`v2210Emissora`; mista = padrão; Pix e logotipo só da padrão); índice do nosso número por empresa em 2 partes (A antes do merge — aplicada; B depois — `migration_v2_21_1`) | **concluída — publicada em 20/11 (PR #18), partes A e B aplicadas** |
| v2.22.0 | Integração Questor Negócio em **modo paralelo**: Edge Function `questor-sync` (publicada no Supabase) autentica com a chave do cofre (`segredo_servico('questor_api_key')`), lê títulos (janela −400d/+60d) e baixas (7d) por empresa (`questor_cnpj`) e compara com o app **sem gravar nada** — resumo por empresa (só na API, API liquidada × app aberta, divergência de valor, baixas) na tela Empresas e nas execuções (etapa/origem `questor_api`). Botões (só diretor): Testar conexão, Importar estabelecimentos (vincula CNPJs), Capturar agora. Migration `v2_22_0_questor_api.sql` aplicada (origem nova + chaves `questor_api_key`/`questor_api_url` na lista do cofre — registrar no artecon-supabase/docs/DECISOES.md). **Falta: o usuário cadastrar o segredo `questor_api_key` no Vault** (Dashboard → Integrations → Vault) | **publicada em 20/11 (PR #19); aguardando a chave no Vault** |
| v2.23.0 | **Fonte única com interruptor** (`cob_automacao_config.questor_api_modo`, padrão `paralelo`; só diretor liga via RPC `cob_questor_modo_set`, confirmando "FONTE"): ação `sincronizar` da `questor-sync` grava títulos novos (origem `questor_api`, cria cliente pelo CNPJ), adota o id da API nos títulos do CSV/remessa e aplica baixas (aberta liquidada na API → `cob_pagamentos` forma `boleto` + `paga`; estornadas puladas — v2.18); ação `boleto_pdf` → botão **2ª via (PDF)** em Conferir → Parcelas (boletos com `questor_id`). Migration `v2_23_0_questor_fonte.sql` aplicada. **Ligar a fonte só depois do paralelo rodar sem divergências.** Fora do escopo por limite externo: anexar o PDF no e-mail/WhatsApp (o hub de e-mail e o serviço artecon-whats não aceitam anexo PDF hoje) e agendamento automático (opções: robô chama a função com o token dele, ou pg_cron+pg_net com chave de serviço no Vault) | **concluída e publicada; interruptor em `paralelo`** |
| v2.23.0 | Corte: API vira a fonte (captura, baixas automáticas, 2ª via em PDF nos envios); relatório do Questor instalado e .CRT viram contingência; robô aposentado aos poucos | a fazer |

## API Questor Negócio — resumo do que importa
- Base: `https://arteconartes.questornegocio.com.br`. Autenticação: `GET /api/v1/Autenticacao/Autenticar`
  com header `x-api-key` → token JWT usado como `Authorization: Bearer`. Paginação `Pagina`/`QuantidadePagina`
  (máx. 500); envelope `{Sucesso, Dados, Erros[{Codigo, Descricao, Correcao}]}`.
- **A chave x-api-key vai para o Vault do Supabase** (mesmo caminho das chaves de e-mail, `segredo_servico`).
  Nunca no `index.html`, nunca em commit, nunca em mensagem.
- Endpoints que vamos usar:
  - `GET /api/v1/Estabelecimento` — estabelecimentos da conta → vínculo com `cob_empresas.questor_cnpj`.
  - `GET /api/v1/ContaReceber/ConsultarContasReceber?EstabelecimentosInscricaoFederal=…&DataVencimentoInicial=…&DataVencimentoFinal=…`
    — títulos com `Id`/`IntegracaoId`, `Valor`, `ValorRestante`, `DataVencimento`, `Parcela`, `DocumentoFiscal`,
    `NossoNumeroGeracao`/`NossoNumeroRetorno`, `ConvenioBoleto`, `SituacaoBoleto`
    (0 Salvo | 1 Falha | 2 Emitido | 3 Rejeitado | 4 Registrado | 5 Liquidado | 6 Baixado | 99 Sem Boleto),
    `EstabelecimentoInscricaoFederal` e o objeto `Pessoa` (CNPJ/CPF, razão social, contatos com e-mail/celular
    e marca "EnviaBoleto").
  - `GET /api/v1/ContaReceber/ConsultarBaixaContasReceber?…DataLancamentoInicial=…` — baixas
    (`ContaReceberId`, `BaixaArquivoRetorno`, `BaixaInternetBanking`, `ConvenioBoleto`) → pagamentos conciliados.
  - `GET /api/v1/ContaReceberVencidos/ConsultarPorEstabelecimento` — vencidos → confronto diário/níveis.
  - `POST /api/v1/Boleto/ConsultarParcelaAberta` — parcelas em aberto de um cliente (consulta pontual).
  - `POST /api/v1/Boleto/ReimprimirBoletoParcela` — **PDF da 2ª via em base64** → anexo no e-mail / arquivo no WhatsApp.
  - `GET /api/v1/Pessoa` — conferência de cadastro/contatos.
- De→para: `EstabelecimentoInscricaoFederal` → `empresa_id` (via `cob_empresas.questor_cnpj`);
  `Id`/`IntegracaoId` do título → `cob_parcelas.questor_id` (chave do upsert); `SituacaoBoleto` Falha/Rejeitado →
  aba Erros; baixas → `cob_pagamentos` respeitando o estorno da v2.18 (item `ignorada` não baixa de novo).
- Captura pode rodar em **Edge Function agendada do Supabase** (sem depender do ARTEAPP01), registrando em
  `cob_automacao_execucoes` para o painel.

## v2.20.0 — limites de propósito (para a v2.21.0)
- O seletor filtra **Painel** (títulos, recebimentos, envios do dia) e **Conferir → Parcelas**. Rotina (passos 1–5),
  filas de envio/ligação (RPCs `cob_fila_disparos_email` etc.), relatórios, confronto e robô continuam "todas" —
  o Painel avisa ao lado do carimbo de atualização.
- `{{empresa_cobradora}}`/`{{empresa_cnpj}}` valem nos **modelos personalizados** (`aplicarVariaveis`); os layouts
  fixos de e-mail/WhatsApp (v2.9.7/v2.10.0) seguem assinando "Artecon Artes Contábeis" — hoje todos os boletos
  são da Artecon; a troca entra na v2.21.0, quando os disparos saem separados por empresa.
- Empresa do disparo: resolvida em `v297Titulos` (parcelas do cliente); carteira mista = assinatura da padrão.

## Pendências (do usuário)
- Nome, CNPJ e apelido das outras 3+ empresas (cadastro será feito na tela da v2.20.0).
- Convênio bancário de cada empresa (para a detecção na transição).
- Chave x-api-key → direto no Vault quando a v2.22.0 for começar (nunca em texto aberto).

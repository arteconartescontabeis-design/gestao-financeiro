# Multiempresa + integração Questor Negócio — plano aprovado (20/11/2026)

**Status (20/11/2026, noite):** plano aprovado e em execução autorizada. **v2.20.0 publicada** (PR #17,
GitHub Pages conferido servindo v2.20.0). Migrations v2.19.0, v2.20.0 e **v2.21.0 parte A** (índice novo do
nosso número, convivendo com o antigo) **aplicadas no banco**. **App v2.21.0 pronto na branch** — sequência de
publicação: fazer o merge do v2.21.0 e, DEPOIS de publicado e recarregado, rodar a
`migration_v2_21_1_solta_indice_antigo.sql` (parte B). Nunca rodar a parte B antes do merge: o app v2.20
publicado depende do índice antigo para o upsert das importações.
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
| v2.21.0 | Importações lançam na empresa do seletor (senão a padrão); boleto manual com empresa na confirmação e checagem de duplicidade por empresa; Relatórios (4 abas) seguem o seletor; Painel em "Todas" com quebra por empresa; mensagens (e-mail, WhatsApp, cartão) assinadas pela empresa dona dos boletos (`v2210Emissora`; mista = padrão; Pix e logotipo só da padrão); índice do nosso número por empresa em 2 partes (A antes do merge — aplicada; B depois — `migration_v2_21_1`) | **app pronto na branch — publicar e rodar a parte B** |
| v2.22.0 | Integração Questor Negócio em **modo paralelo** (mesmo padrão do `sicredi_modo`): sincronização agendada por empresa (títulos, baixas, vencidos), comparação na aba Erros, nenhum envio depende dela | a fazer |
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

# Cobrança Pro — memória do projeto

App de cobrança da **Artecon** (escritório contábil). Tudo em português.

## Estrutura
- `index.html` — o app inteiro (HTML + CSS + JS, ~10,6 mil linhas). Supabase JS (anon key no cliente, protegido por RLS/RPC), SheetJS, e-mail pela Edge Function `mail-proxy`, fila de WhatsApp.
- Versão atual no rodapé/cabeçalho e na tabela "Versões" (`<tr><td><b>vX.Y.Z</b>…`). **Toda mudança ganha uma linha nova no topo dessa tabela** e o número de versão é atualizado nos **três** rótulos (`opacity:.7;">vX`, `vX · data` no rodapé e `Cobrança Pro vX · data` no Painel, classe `v2140-ver`). Comentários de código marcam a versão (`// v2.11.1: …`) e funções novas usam prefixo da versão (`v2111…`).
- Supabase: projeto `yeujqjtjqtegsnzwwazb`, tabelas `cob_*` (multi-tenant por `tenant_id`, RLS em todas). Mudanças de banco vão como `migration_vX_Y_Z_*.sql` (rodadas pelo usuário).
- Abas (trilho à esquerda): Painel (com seletor de período, padrão até hoje), Rotina (passos 1–5), Conferir (Parcelas com busca por título/cliente/valor/vencimento e **Lançar boleto manual**, origem `manual`; **Alterar/Excluir boleto** do selecionado — só diretor, só em aberto; excluir = status `cancelada` com motivo, eventos `parcela_alterada`/`parcela_excluida`), **Relatórios** em sub-abas (`v2130RelAba`: abertos, envios, recebimentos, geral), **Erros** (importações, falhas e diferenças Questor × app — `cardErros`/`navErros`), Clientes, Robô, Sistema. Telas novas entram em `ocultarTodosPaineis`, `V22_TELAS` e no trilho.
- Status de parcela: `aberta`, `paga`, `baixa_manual` (só via RPC `cob_baixa_manual`), `renegociada` (substituída por novos boletos; só diretor — gatilho `cob__trava_baixa_manual`), `cancelada`.
- `docs/robo/ciclo-do-robo.md` — o que o robô faz, passo a passo.
- `docs/sicredi/` — material da Sicredi (cartilha, coleção Postman sem credenciais, resumo da API).
- `docs/auditoria-2026-10-06.md` — varredura de erros/segurança e pendências.
- **`docs/situacao-e-pendencias-2026-10-06.md` — onde paramos e lista do que falta (comece por aqui ao retomar).**

## Robô (fora deste repositório)
- Servidor **ARTEDB01**, tarefa agendada "Artecon Robo Cobranca", Python 3.10, log em `C:\Artecon\Robo\logs`, pastas `C:\Artecon\Cobranca\{entrada,processados,relatorios}`.
- Vigia (`--loop`) sempre aberto + ciclo em processo separado; agenda 08:00 e 20:00; lê pedidos do app (`cob_automacao_config.pedido`) a cada minuto; grava sinal em `robo_sinal`/`robo_sinal_em` e etapas em `cob_automacao_execucoes`.
- **Clique na janela do vigia congela o robô** (modo "Selecionar" do console do Windows) — aperte Esc; desmarcar "Modo de Edição Rápida".
- Bug aberto (06/10/2026): etapa "pendentes" recusa o relatório porque o campo "data base juros" do Questor mostra o ano com 2 dígitos (`06/10/20`) → sem CSV, sem confronto, disparos não liberados. Corrigir no `questor.py`.

## Sicredi (API Cobrança)
- Base `https://api-parceiro.sicredi.com.br` (sandbox com `/sb`). OAuth2 password em `/auth/openapi/token` com `x-api-key` + `context: COBRANCA`; chamadas com `Authorization: Bearer`, `x-api-key`, `cooperativa`, `posto`.
- No app já existe a configuração (`sicredi_ativo`, `sicredi_modo` paralelo/fonte única, `sicredi_hora`) — hoje **desligada**. Detalhes em `docs/sicredi/README.md`.
- **Situação (06/10/2026): integração pausada** pelo usuário para análise. Decisões até aqui: escopo só remessa e retorno; fase 1 só consulta (liquidados/francesinha), sem instruções de alteração; enquanto isso o .CRT segue baixado manualmente no Internet Banking e salvo em `entrada`; nada de robô logando no site do banco. Logos 140×140 da App em `docs/sicredi/logo/`. Plano de segurança proposto (etapas A–E: travas no banco, 2 fatores, aprovação dupla, PIX/DMARC, política) aguardando decisão.
- Credenciais da Sicredi **nunca** no `index.html` nem em commit: cofre do Windows do servidor ou Vault do Supabase.

## Regras
- Cobrança em 3 níveis (`v2140Nivel`, pelo `diasAtrasoMax` do cliente): 1º até 29 dias, 2º 30–59 (aviso de suspensão), 3º 60+ (serviços suspensos). Textos em `V2140_NIVEIS`/`v2140Nivel`. 2º e 3º só saem se liberados em Configurações (`cob_politicas.nivel2_liberado`/`nivel3_liberado`, `v2160Niveis`, v2.16.0); bloqueado ou erro de leitura = cobrança normal (1º).
- Relatório de clientes suspensos por e-mail só para `@artecon.cnt.br` (dados de clientes).
- Modo de teste (`cob_politicas.teste_*`): em dúvida, **bloquear envio** — nunca tratar erro como "teste desligado".
- Todo dado do banco/arquivo que vai para `innerHTML` passa por `autoEsc`; nada de dado em `onclick="…'${x}'…"` sem `autoEsc(JSON.stringify(x))`.
- CSV exportado passa por `csvSeguro`.
- Segurança no banco (v2.17.0): parcela só muda cliente/vencimento/documento/nosso número por diretor ou robô (`cob_trava_parcela_campos`); fila do WhatsApp só aceita telefone ativo do cliente ou o de teste e não deixa trocar mensagem; execução "robo" só pelo usuário do robô (`cob_eh_robo`). Fonte da função de e-mail em `supabase/functions/mail-proxy/` — só envia para destinatário conhecido (cliente, teste, o próprio usuário, @artecon.cnt.br).

# Varredura de erros e segurança — 06/10/2026 (v2.11.1)

Escopo: `index.html` inteiro (3 revisões independentes: segurança, lógica parte 1 e parte 2) + banco Supabase
(advisors de segurança, funções `SECURITY DEFINER`, RLS) + execução real do robô de 06/10.

## ✅ Corrigido nesta versão (v2.11.1)

| Gravidade | Problema | Correção |
|---|---|---|
| **Alta** | Modo de teste: erro ao ler `cob_politicas` (rede, sessão) era tratado como "teste desligado" → cobrança ia para **clientes reais**; valor só era lido no login | Erro agora **bloqueia** o envio; modo de teste é relido do banco antes de cada envio e do lote |
| **Alta** | Envio em dobro: "Enviar todos" reativava no meio do lote; duplo clique no "Enviar" do cliente mandava duas vezes | Trava do lote até o fim; status "Enviando…" impede o segundo envio |
| **Alta** | XSS: nome do cliente dentro de `onclick` (painel Top 8 e Prioridades) — `&quot;` não escapado | `autoEsc(JSON.stringify(nome))` |
| Média | XSS: números do robô, do confronto, de recebimentos e telefone/status do WhatsApp iam crus para o HTML | Todos escapados; `v25FmtTel` só formata dígitos |
| Média | E-mail enviado mas registro no histórico falhou em silêncio → cliente voltava como "pendente" e era cobrado de novo | Aviso "e-mail ENVIADO, registro falhou — não reenvie hoje" |
| Média | Falha ao ler os títulos do cliente → cobrança saía sem tabela e com valor sem encargos | Envio daquele cliente falha com o motivo |
| Média | Painel Robô: ciclo com etapa em erro aparecia como "✅ concluído" (caso real de 06/10) | Amarelo, com a etapa e o motivo |
| Média | Pedido de ciclo: texto dizia "40 min" (limite é 100); "executando" eterno; "confira a tarefa" enquanto o robô estava ocupado | Limite certo; erro ao passar do limite; aviso de fila |
| Média | Scripts de CDN sem verificação de integridade | SRI (sha384) no supabase-js 2.117.2 e SheetJS 0.18.5 (testado no Chromium) |
| Média | Leitura paginada sem ordem estável (acima de 1.000 linhas repete/pula — `cob_parcelas` já tem 1.038) | `.order('id')` nas duas funções de paginação |
| Baixa | CSV exportado: célula `=…`, `+…`, `@…` virava fórmula no Excel | `csvSeguro` em todos os exportadores |
| Baixa | Sessão expirada/encerrada em outra aba continuava mostrando dados | Volta para a tela de login |
| Baixa | Execução "sem liquidações hoje" gravava `finalizado_em` (coluna inexistente) | `concluido_em` |
| Baixa | Parcelamento: última parcela podia sair negativa (ex.: R$ 0,11 em 7x) | Parcela base arredondada para baixo quando necessário |

## 🔒 Banco (Supabase) — conferido, sem falha grave

- RLS ligado em **todas** as tabelas; tabelas sem política (backups `cob_bkp_*`, `cob_seg_*`, `cob_automacao_segredos`, `cob_tenants`) ficam fechadas para a API — correto.
- Todas as funções `SECURITY DEFINER` da cobrança conferem o vínculo do usuário com o escritório; as de alçada conferem diretor;
  a senha do Questor só é lida pelo usuário do robô (`cob_questor_senha_get`).
- `cob__auditar_gatilho` recusa chamada direta (só gatilho).

## ⏳ Pendências — precisam da sua decisão (mexem no banco, no servidor ou em configuração)

| # | Item | Por quê | Como |
|---|---|---|---|
| 1 | **Robô: relatório de pendentes recusado** (bug real de 06/10) | Sem ele não há confronto nem liberação dos disparos | Corrigir `questor.py`: aceitar `DD/MM/AA` no campo "data base juros" (código do robô não está neste repositório) |
| 2 | **mail-proxy** aceita qualquer destinatário/HTML de qualquer usuário logado | Usuário logado poderia usar o remetente do escritório para qualquer e-mail | Edge Function validar destinatário contra `cob_clientes_contatos` do tenant (ou e-mail de teste) |
| 3 | `cob_whatsapp_fila` aceita telefone/mensagem livres | Mesmo motivo do item 2 | `CHECK (telefone ~ '^\d{10,13}$')` + validar cliente do tenant |
| 4 | `cob_automacao_execucoes` aceita INSERT de qualquer usuário do escritório | Usuário comum pode forjar uma "execução do robô" | Política de INSERT só para `origem = 'app'` e/ou só via RPC |
| 5 | Perfil de diretor checado só no app em: excluir boleto, perdão de saldo, cancelar fila do WhatsApp | A proteção real precisa estar no banco (conferir as políticas atuais) | Políticas RLS/RPC exigindo `cob_eh_diretor` |
| 6 | Supabase Auth: **proteção de senha vazada desligada** | Bloqueia senhas que já vazaram na internet | Painel Supabase → Authentication → Passwords → ligar "Leaked password protection" |
| 7 | 4 funções sem `search_path` fixo (`cob_chave_doc`, `cob_atualizar_valor`, `cob_set_updated_at`, `prop_ct_toca`) | Boa prática de segurança | `ALTER FUNCTION … SET search_path = public, pg_temp` |
| 8 | SheetJS 0.18.5 tem 2 CVEs (leitura de planilha maliciosa) | Os arquivos são do próprio escritório — risco baixo | Atualizar para 0.20.3 (cdn.sheetjs.com) com SRI |
| 9 | Fila de cobrança (Passo 3) lê clientes sem paginação | Só afeta acima de 1.000 clientes com atraso (hoje 270 clientes) | Paginar quando crescer |
| 10 | CSP (Content-Security-Policy) | Camada extra contra XSS | `<meta http-equiv="Content-Security-Policy">` após mapear os domínios usados |

Itens 2–7 são mudanças de banco/servidor: preparo as migrations quando você aprovar.

### Atualização 10/10/2026 — v2.17.0 (etapa A preparada)
| Item | Situação |
|---|---|
| 2 mail-proxy | **Pronto** em `supabase/functions/mail-proxy/index.ts` (v2): só envia para e-mail de cliente cadastrado, e-mail de teste, o próprio usuário ou @artecon.cnt.br. Falta publicar a função. |
| 3 fila do WhatsApp | **Pronto** na `migration_v2_17_0_seguranca_etapa_a.sql`: telefone 10–13 dígitos, só contato ativo do cliente (ou número de teste) e mensagem congelada depois de enfileirada. |
| 4 execuções do robô | **Pronto** na migration: "robo" só pelo usuário do robô (`cob_eh_robo`). |
| 5 diretor no banco | Parcelas: cliente/vencimento/documento/nosso número só diretor (gatilho `cob_trava_parcela_campos`). Pagamentos, exclusões e Configurações já eram só diretor; cancelar fila do WhatsApp continua liberado ao operador (só muda status). |
| 6 senha vazada | Continua com o usuário (1 clique no painel do Supabase). |
| 7 search_path | **Pronto** na migration para as 3 funções `cob_*` (`prop_ct_toca` é do projeto Propostas). |

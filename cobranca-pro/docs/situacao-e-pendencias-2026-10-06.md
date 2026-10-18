# Cobrança Pro — onde paramos e o que falta fazer

**Data:** 06/10/2026 · **Atualizado em 08/10/2026** · **Versão no ar:** v2.16.0 (v2.17.0 pronta para publicar)

> **08/10/2026 — v2.13.0 publicada:** busca de títulos em Parcelas (título, cliente, valor, vencimento), lançamento manual de boleto, relatórios em abas (Boletos em aberto com busca e gráficos, Envios de cobrança, Recebimentos, Visão geral) e seletor de período no Painel (padrão até hoje).
> **08/10/2026 (noite) — v2.14.0 publicada** (3 níveis de cobrança, lançamento pelo relatório do Questor, clientes suspensos, versão no Painel), com varredura e 4 correções antes do merge. **Textos dos avisos de suspensão (2º e 3º nível) aprovados pelo usuário.**
> **09/10/2026 — v2.15.0:** Conferir → Parcelas ganhou **Alterar boleto** e **Excluir boleto** (só diretor, só boletos em aberto; excluir vira "Cancelada", com motivo e histórico).
> **09/10/2026 — v2.16.0:** avisos de suspensão (2º e 3º nível) agora precisam ser **liberados em Configurações** — começam bloqueados até o texto ser revisado. Rodar `migration_v2_16_0_niveis_cobranca.sql`.
> **10/10/2026 — v2.17.0 (segurança, etapa A):** travas no banco e na função de e-mail preparadas — falta rodar `migration_v2_17_0_seguranca_etapa_a.sql` (e a da v2.16.0) e publicar `supabase/functions/mail-proxy`.
> **Robô:** recebidos só `questor.py` v0.2.4 e `sicredi.py` v0.1.1 (antigos). Para corrigir a data do relatório de pendentes falta o `questor.py` v0.6.0 e o `robo_cobranca.py` v2.6.0 que rodam no ARTEDB01.
> **Pendente:** a tabela de classificação de clientes (para ligar com o projeto Propostas) não chegou — reenviar.

---

## 1. O que foi feito hoje

### Robô (servidor ARTEDB01)
- **Causa da parada encontrada:** alguém clicou dentro da janela preta do robô e ela entrou em "Selecionar". Nesse modo o Windows congela o programa. O robô ficou parado das 22:17 de 05/10 até 08:40 de 06/10. Resolvido com **Esc**.
  **Prevenção:** clique com o botão direito na barra de título da janela → Propriedades → Opções → desmarcar "Modo de Edição Rápida".
- **Ciclo manual de 06/10** (08:43 a 09:06):
  - Os 3 retornos (.CRT) foram lidos e importados no Questor com PDF.
  - O arquivo `00749O06` deu baixa em 8 boletos, R$ 3.970,18.
  - O **relatório de pendentes falhou** porque a data saiu com o ano em 2 dígitos (veja o item A1).

### Ajustes de dados no banco (autorizados por cleiver@artecon.cnt.br)
- **6 baixas manuais por PIX**, lançadas pelo usuário: U16163, U16300, U16374, U16412, U16520 e U16642.
- **Panificadora Doce Vida:** U16157 e U16367 (R$ 39.049,42) marcadas como **Renegociada**, porque foram divididas em 4 boletos cada.
- **13 itens de retorno** (R$ 12.360,15, títulos já quitados no Questor que nunca foram cadastrados no app) marcados como **Ignorado**.
- Tudo ficou registrado na auditoria. Resultado: **0 itens de retorno pendentes**.

### App: v2.11.1 (segurança) e v2.12.0 (painel e relatórios)
- **Modo de teste:** se não for possível confirmar o estado, o envio é bloqueado. O estado é relido antes de cada envio.
- **Envio em dobro:** travado, tanto no "Enviar todos" quanto no duplo clique.
- **Outras correções de segurança:** proteção contra código embutido em nomes e dados (XSS), CSV protegido contra fórmulas, verificação de integridade dos scripts externos (SRI), sessão expirada volta ao login, paginação estável.
- **Painel:** mostra o valor atual e o valor com multa e juros lado a lado.
- **Aba Erros** (a antiga aba Relatórios) e **nova aba Relatórios**: envios de cobrança (por data, forma, destinatário e por cliente) e recebimentos.
- **Baixa manual:** nova opção **Renegociada** (só diretor).
- **Painel do robô:** um ciclo com etapa em erro aparece em amarelo, com o motivo.

### Documentação criada (pasta `docs/`)
- `robo/ciclo-do-robo.md`: o passo a passo do ciclo do robô.
- `sicredi/`: cartilha, coleção Postman sem credenciais, resumo da API e logos 140×140 da App.
- `auditoria-2026-10-06.md`: varredura de erros e segurança.

---

## 2. Onde paramos

| Assunto | Situação |
|---|---|
| Disparos de hoje | Pendências de retorno zeradas. **Falta refazer o confronto**: importar de novo o relatório do Questor em Conferir → Confronto. **Modo de teste continua ligado.** |
| Integração Sicredi | **Pausada para análise.** Decidido: escopo só de remessa e retorno; fase 1 apenas consulta (liquidados e francesinha); nada de robô entrando no site do banco. |
| Retorno do banco | Continua manual: baixar o .CRT no Internet Banking e salvar em `C:\Artecon\Cobranca\entrada`. |
| Plano de segurança (A–E) | Proposto, **aguardando decisão**. |

---

## 3. O que falta fazer

### A. Urgente (afeta a rotina diária)
| # | Tarefa | Quem | Observação |
|---|---|---|---|
| A1 | **Corrigir o robô:** o relatório de pendentes é recusado porque o campo "data base juros" vem com ano em 2 dígitos (`06/10/20`) | Claude, com o código do robô | Enviar `questor.py`, `sicredi.py` e o arquivo principal (**sem senhas**). Sem essa correção não há confronto automático nem liberação dos disparos. |
| A2 | Refazer o confronto de hoje e conferir "Disparos liberados" | Usuário | Conferir → Confronto com o Questor → importar o relatório |
| A3 | Desmarcar "Modo de Edição Rápida" na janela do robô | Usuário | Evita que o robô congele de novo |
| A4 | Panificadora: cadastrar os boletos **U16367-2, -3 e -4** se ainda forem cobrados | Usuário | Hoje só o U16367-1 está no app. Importar a remessa no Passo 1. |
| A5 | Desligar o modo de teste quando for enviar de verdade | Usuário | Configurações |

### B. Segurança (detalhes em `auditoria-2026-10-06.md`)
| # | Tarefa | Precisa de |
|---|---|---|
| B1 | Ligar a **proteção contra senha vazada** no Supabase (Authentication → Passwords) | Usuário, 1 clique |
| B2 | **(v2.17.0 — preparado, falta rodar)** Travas no banco: e-mail e WhatsApp só para contatos cadastrados; registros do robô só pelo robô; ações de diretor garantidas pelo banco; auditoria sem edição (**etapa A**) | Aprovar a migration |
| B3 | Verificação em duas etapas no login do app (**etapa B**) | Aprovar; cada usuário cadastra o celular |
| B4 | Aprovação dupla em baixa manual, perdão e renegociação (**etapa C**) | Definir quem aprova |
| B5 | Conferir a chave PIX antes do envio e checar SPF/DKIM/DMARC do domínio artecon.cnt.br (**etapa D**) | Acesso ao DNS, se precisar corrigir |
| B6 | Documento "Política de segurança da integração" (**etapa E**) | Revisar o texto |
| B7 | Atualizar o SheetJS para 0.20.3, aplicar CSP e fixar o `search_path` de 4 funções | Claude, quando aprovado |

### C. Integração Sicredi (quando for retomar)
| # | Tarefa | Quem |
|---|---|---|
| C1 | Criar a App no portal: OAuth + Cobrança, com o logo de `docs/sicredi/logo/` | Usuário |
| C2 | Abrir o chamado "Solicitar Access Token", ambiente Produção | Usuário |
| C3 | Separar código do beneficiário, cooperativa, posto e código de acesso da cobrança | Usuário (**não enviar por chat**) |
| C4 | Instalador que grava as credenciais cifradas no servidor e teste de conexão (só leitura) | Claude |
| C5 | Rodar algumas semanas em modo paralelo (API × .CRT) e só então substituir o .CRT | Os dois |
| C6 | Depois, se quiserem: emissão de boleto pela API no lugar da remessa .CRM, com aprovação de diretor | A decidir |

### D. Melhorias de menor prioridade
- Paginar a fila de cobrança (Passo 3) quando passar de 1.000 clientes com atraso.
- Corrigir o robô para que o pedido "Rodar ciclo completo" feito pelo app mude para "executando" e "concluído" (hoje fica "aguardando").
- Compartilhar a pasta `entrada` na rede para salvar o .CRT sem entrar no servidor por RDP.

---

## 4. Para retomar
Diga ao Claude: *"Retomar o Cobrança Pro a partir de `docs/situacao-e-pendencias-2026-10-06.md`"*. A memória do projeto (`CLAUDE.md`) aponta para este arquivo.

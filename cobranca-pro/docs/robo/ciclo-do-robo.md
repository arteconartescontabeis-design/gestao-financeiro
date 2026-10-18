# O que o robô faz — passo a passo do ciclo

O robô roda no servidor **ARTEDB01** (tarefa agendada **"Artecon Robo Cobranca"**, log diário em `C:\Artecon\Robo\logs`).
Ele tem duas partes:

- **Vigia**: programa leve que fica aberto o tempo todo (janela preta do Python). A cada minuto ele olha se o app pediu
  alguma coisa e, nos horários da agenda (hoje **08:00 e 20:00**), abre um ciclo.
- **Ciclo**: processo separado que faz o trabalho e fecha ao terminar (a memória volta para o Windows).

> ⚠️ Não clique dentro da janela preta do vigia. Clicar coloca a janela em "Selecionar" e o Windows **congela o robô**
> até alguém apertar Esc (foi o que parou o robô de 05/10 22:17 até 06/10 08:40). Desmarque "Modo de Edição Rápida"
> nas Propriedades da janela.

## O ciclo completo, em 9 passos

| # | Passo | O que acontece | Onde aparece no app | Se der errado |
|---|---|---|---|---|
| 1 | **Começa** | Avisa o app "ciclo em andamento", lê as pastas e a agenda das Configurações e a senha do Questor (cofre do app). | Painel Robô: "🔄 Ciclo em andamento — não conecte o RDP" | Sessão sem área de trabalho (RDP minimizado/fechado no X) → ciclo **adiado**, nova tentativa em 10 min |
| 2 | **Sicredi (API)** — *só se ligado* | Consulta os boletos liquidados do dia útil anterior e gera um .CRT igual ao do banco. Hoje está **desligado**. | Configurações → Automação → Integração Sicredi | Registra erro e segue com os .CRT da pasta |
| 3 | **Lê os retornos (.CRT)** | Para cada arquivo em `C:\Artecon\Cobranca\entrada`: lê o CNAB 400 e dá baixa no app nas parcelas pagas (valor recebido, juros, multa, tarifa de R$ 0,21). O que não casa vira **pendência do retorno**. | Execuções "retorno"; contagem "X de Y retornos processados" | Arquivo já lido antes = "já processado" (não é erro, não baixa duas vezes) |
| 4 | **Entra no Questor** | Abre o Financeiro do Questor e faz login com o usuário do robô. | — | **Login falhou** → o ciclo do Questor para **sem nova tentativa** e o painel mostra o motivo e o print. Use "Testar login no Questor" depois de corrigir |
| 5 | **Importa os retornos no Questor** | Para cada .CRT: importa no "Controle de Cabeçalho", responde **SIM** ao relatório e salva `NNNNNNNN_relatorio.pdf` em `relatorios`. Só então move o .CRT para `processados`. **~5 min por arquivo.** | Execuções "questor" (data da baixa e PDF) | Se falhar, o .CRT **fica na entrada** para o próximo ciclo (painel mostra ".CRT aguardando na entrada") |
| 6 | **Relatório de pendentes** | Emite no Questor *Inadimplentes e Contas a Receber* com data de hoje e exporta CSV + PDF (`pendentes_AAAAMMDD.csv`). Confere se as datas ficaram certas antes de usar. | Execução "pendentes" | Sem o CSV **não há confronto** (passos 7–8 não rodam) |
| 7 | **Confronto** | Compara os títulos do relatório do Questor com as parcelas abertas no app: conferidos, só no Questor, só no app, diferença de valor. | Conferir → Confronto com o Questor | Divergências ficam listadas para conferência |
| 8 | **Recebimentos caixa / PIX** | Se há parcelas "só no app" (o Questor já deu como pagas), emite o relatório *Recebimentos* e baixa no app o que bate exatamente (documento + valor). O resto vai para **a conferir**. Depois refaz o confronto. | Painel Robô → Recebimentos no caixa / PIX | Itens "a conferir" esperam baixa manual em Parcelas |
| 9 | **Liberação e fim** | Calcula o semáforo: **libera os disparos** só se o retorno do dia foi processado **sem pendências** e o confronto de hoje **conferiu**. Fecha o Questor e grava o sinal final (duração, retornos, memória, próximo horário). | Quadro "Disparos liberados / não liberados"; "✅ último ciclo concluído" | Motivos aparecem no quadro (ex.: "13 itens de retorno pendentes", "Nenhum confronto feito hoje") |

## Pedidos feitos pelo app (fora da agenda)

| Botão | Passos que roda | Tempo |
|---|---|---|
| **Rodar ciclo completo agora** | 1 a 9 | ~5 min por .CRT + relatório |
| **Conferir agora com o Questor** | 4, 6, 7, 8, 9 (não mexe nos .CRT) | 1–3 min |
| **Testar login no Questor** | só o 4 | 1–2 min |

O vigia lê o pedido em até 1 minuto. Enquanto um ciclo está rodando, o pedido espera na fila.

## Exemplo real — 06/10/2026

| Hora | Passo | Resultado |
|---|---|---|
| 08:42 | 3 — retornos | `00749O01` e `00749O02` já processados antes; `00749O06`: **8 boletos baixados, R$ 3.970,18**, 8 tarifas (R$ 1,68), 0 divergências |
| 08:43 | 4 — login | ❌ 1ª tentativa: janela de login do Questor não abriu → ciclo interrompido |
| 08:43 | 1 — novo ciclo | iniciado de novo (manual) |
| 08:52 / 08:57 / 09:03 | 5 — Questor | ✅ os 3 .CRT importados no Questor com PDF (baixas de 01/10, 02/10 e 06/10) |
| 09:06 | 6 — pendentes | ❌ o robô recusou o relatório: o campo "data base juros" ficou `06/10/20` (ano com 2 dígitos) em vez de `06/10/2026` → **sem CSV, sem confronto** |
| 09:06 | 9 — liberação | não liberado: 13 itens de retorno pendentes + nenhum confronto hoje. Duração total 23 min |

Correção necessária no robô (questor.py, conferência das datas do passo 6): o campo "data base juros" do Questor mostra o ano com
2 dígitos — a conferência precisa aceitar `DD/MM/AA` equivalente à data de hoje (ou o robô precisa digitar a data no formato que o
campo aceita). O código do robô não está neste repositório.

# Azure (recurso `artecon-voz`): chaves e custo

Recurso de Fala da Azure usado pelo Agenda (áudio do WhatsApp) e pelo Projeto Criança e pelo
Estudo da Reforma (voz gerada). Grupo `artecon-voz`, região Brazil South, plano **Gratuito (F0)**,
assinatura "Azure subscription 1".

## Cotas grátis (por mês, para o recurso inteiro)
- Transcrição (fala → texto): 5 h. Usada pelo serviço do WhatsApp no ARTEAPP01 (antes ARTEDB01).
- Voz (texto → fala): 500 mil caracteres. Usada ao gerar falas (Projeto Criança, Estudo).
- No F0, passando da cota a Azure **recusa** até o mês virar; não cobra.
- O portal mostra as duas em Consumo de IA → "Azure — voz e transcrição" e avisa (sino e
  e-mail) ao chegar em 80% e em 100% (`sql/nucleo_ia_fala_avisos.sql`). A voz gerada entra por
  **Lançar uso**.

## Onde está cada chave
| Chave | Onde está | Para quê |
|---|---|---|
| CHAVE 1 | Servidor do WhatsApp (hoje ARTEAPP01; antes ARTEDB01), cofre do Windows `ArteconRobo` → `AZURE_FALA_CHAVE` — **no ARTEAPP01 ainda não guardada (21/10/2026)** | Transcrever o áudio do WhatsApp |
| CHAVE 1 | Ambiente "Default" do Claude, segredo de rede "Azure voz" (só o endereço `brazilsouth.tts.speech.microsoft.com`) | Gerar falas (Projeto Criança, Estudo) |
| CHAVE 2 | Só no portal da Azure | Reservada para o Corretor de Vídeos do Radar (ainda não existe) |

Regras: a chave nunca vai para arquivo, GitHub, e-mail ou WhatsApp. No servidor, só pelo
`guardar-chave-azure.bat`.

## Se uma chave vazar (trocar)
1. Portal da Azure → `artecon-voz` → Chaves e Ponto de Extremidade → **Regenerar** a chave que vazou.
2. Se foi a CHAVE 1: rodar o `guardar-chave-azure.bat` no servidor do WhatsApp (ARTEAPP01) com a nova (mesmo usuário do
   Windows do serviço) e reiniciar o serviço; e trocar o segredo "Azure voz" no ambiente do Claude
   (claude.ai → Claude Code → ambiente Default → segredos de rede).
3. Para trocar sem parar nada: passe tudo para a CHAVE 2 primeiro, regenere a CHAVE 1 e depois volte.

## Custo: antes de 08/11/2026 (fim da avaliação grátis)
1. Portal da Azure → **Assinaturas** → "Azure subscription 1" → **Atualizar** para "Pagamento conforme
   o uso". O plano F0 do `artecon-voz` continua grátis; sem isso, o recurso para.
2. **Gerenciamento de Custos → Orçamentos → Adicionar**: escopo "Azure subscription 1", mensal,
   valor R$ 10 (ou US$ 2, conforme a moeda da conta), alertas em 50%, 80% e 100% do valor **real** para `cleiver@artecon.cnt.br`.
   Com tudo no F0 o gasto fica em R$ 0; qualquer valor no alerta quer dizer que algo pago foi criado.
3. Não mudar o `artecon-voz` para o plano Standard (S0): ele cobra por uso e não recusa ao passar da cota.

# Estudo da Reforma — módulos completos (aba Módulos, Estudo 1.5.0 / Agenda 2.9.0)

Pedido do usuário (24/10/2026): estudo mais completo, exemplos por inteiro, exercícios de assinalar e avaliação
que pode ser refeita. Combinado:

- Nota de referência **70%**, que **não bloqueia** o treinamento. A avaliação é **opcional**: aparece na trilha numa barra
  separada ("Avaliações"), fora do % de conclusão.
- Entregas em etapas: **Etapa 1** Módulos 3, 6 e 7 · **Etapa 2** Módulos 1, 2, 4 e 5 · **Etapa 3** Módulos 8 e 9 e revisão.
- **Áudio dos exemplos novos: só depois que o usuário aprovar o texto de cada etapa** (cota da Azure; lançar o uso no portal).

## Onde fica
- O conteúdo vai no `dados.json` do armazenamento privado `estudo` (nunca no GitHub: o repositório é público), na chave
  `modulos` → `{ "m3": {...}, "m6": {...} }`. Para trocar: baixar o `dados.json` pela função `estudo-carga`, mexer só em
  `modulos` e subir de volta (ver CLAUDE.md).
- Notas: tabela `agenda_estudo_avaliacoes` (`sql/agenda_estudo_avaliacoes.sql`). Cada entrega é uma linha; o app mostra a
  melhor nota e o histórico. Respostas dos exercícios de fixação ficam só no aparelho (`localStorage`).

## Formato de um módulo
```json
{
  "id": "m3", "titulo": "...", "objetivo": "1–2 frases",
  "conteudo":   [ { "titulo": "Seção", "html": "<p>...</p>" } ],
  "exemplos":   [ { "id": "m3-e1", "titulo": "...", "html": "enunciado, passo a passo em tabela, resultado, regra" } ],
  "exercicios": [ { "id": "m3-x01", "pergunta": "...", "alternativas": ["", "", "", ""], "correta": 0,
                    "explicacao": "...", "fonte": "LC 214/2025, art. 27 · [FG aula 2]" } ],
  "avaliacao":  [ mesmo formato, ids "m3-a01"... ]
}
```
Quantidades: 6–12 seções, 4–6 exemplos, 8–10 exercícios, 20–25 questões no banco da avaliação (o app sorteia 10 e
embaralha as alternativas). HTML permitido: `p ul ol li table thead tbody tr th td b strong i em h4 br span`, com `class`
só em `p`/`span`: `fonte` (origem), `ia` (complemento do estudo, destaque roxo) e `desat` (desatualizado, destaque amarelo).
Perguntas e alternativas são texto puro (o app escapa).

## Regras do conteúdo (Prompt Mestre do usuário)
Não inventar; toda afirmação vem das fontes (programa no OneDrive "Reforma Tributária - Programa de Estudo", apostilas e
exercícios dos cursos, análises das aulas). Marcar a origem com [FG], [CM], [N] e [IA] (complemento). Sinalizar o que está
desatualizado na data. Preservar exceções. Refazer toda conta (Python) e registrar quando a conta da fonte não fecha.
Escrever com as próprias palavras.

## Áudio dos exemplos (Estudo 1.7.0 / Agenda 2.11.0)
- Aprovado pelo usuário em 24/10/2026 para a Etapa 1: 18 exemplos (Módulos 3, 6 e 7), cerca de 90 min, ~60 mil caracteres
  falados (lançar no portal: Consumo de IA → app `estudo`, voz).
- Roteiro: um texto por exemplo, escrito para ouvir (sem siglas de fonte, sem "P1", todo número igual ao do exemplo; um
  conferidor checa os números). Fala: as mesmas regras do roteiro dos 40 áudios (voz Azure pt-BR-FranciscaNeural).
- No `dados.json`: `faixas["faixa:ex-m6-e1"] = { arq: "audio/ex-m6-e1.mp3", titulo: "Exemplo 1: ...", grupo: "Módulo 6",
  tema: "Exemplos resolvidos", seg, html }`. O app mostra o botão no exemplo quando a faixa existe; não entra nas trilhas.
- Mudou o texto de um exemplo depois do áudio: refazer o roteiro e o áudio daquele exemplo (ou avisar que o áudio é da versão
  anterior).

## Situação dos 9 módulos (25/10/2026)
| Módulo | Versão | Etapa |
|---|---|---|
| 3 | 1.3 | Etapa 1 (duas revisões técnicas) + revisão geral |
| 6, 7 | 1.4 | Etapa 1 (duas revisões técnicas) + revisão geral |
| 1 | 1.2 | Etapa 2 + revisão geral (duas passadas) |
| 2, 4, 5 | 1.1 | Etapa 2 + revisão geral |
| 8, 9 | 1.0 | Etapa 3 (aguardando revisão técnica) |

- Etapas 2 e 3 foram escritas com as lições da revisão da Etapa 1 na especificação: seção "Situação desta versão",
  premissas antes das contas, vereditos condicionais, regra das fontes e um script de contas por módulo (`<id>_contas.py`,
  guardado no armazenamento em `ferramentas/etapa2/` e `ferramentas/etapa3/`).
- **Revisão geral de coerência** (25/10/2026): leitura cruzada dos 9 módulos (mesmo fato com números diferentes, mesmo
  exemplo do curso com resultados diferentes, remissões, questões contraditórias). 31 achados, 29 aplicados, sem mudar
  gabarito; questões parecidas entre bancos de módulos diferentes ficaram (não se contradizem). Relatórios em
  `revisao/achados_coerencia_*.md` no armazenamento.
- Memórias de cálculo (planilhas) e relatórios de cada etapa: pasta `revisao/` do armazenamento.
- Áudio dos exemplos: Etapa 1 pronta; Etapas 2 e 3 só depois da aprovação do texto.

## Regra das fontes (usuário, 24/10/2026)
- O que está nos portais dos cursos (Nutror e Hotmart: aulas, apostilas, exercícios) vale como **verdadeiro**. Quando a lei
  consultada disser outra coisa, o texto segue o curso e registra a diferença numa nota (ex.: redução do art. 38-B — curso 60%,
  LC 123 consultada 50%).
- Exceção: ato oficial **publicado depois** do material do curso (resolução, manual, notícia da Receita) prevalece e o texto avisa
  que mudou. Foi o caso do calendário do Simples para 2027 (Res. CGSN 194/2026 e manual do regime regular de 07/10/2026).

## Revisão técnica (Etapa 1)
- 24/10/2026: revisão documental do relatório da Etapa 1 (calendário, multas, premissas, cenários). Os módulos foram para a
  **versão 1.2**: calendário oficial de 2027, base legal da multa "reduzida a 75%", premissas antes dos resultados, farmácia com e
  sem crédito de estoque (veredito condicional), linha do tempo cartão × crediário e a seção "Situação desta versão" com o que
  ainda falta confirmar. Memória de cálculo em planilha à parte (fora do GitHub).
- Cada módulo leva `versao`; ao mexer no texto, subir a versão e anotar na seção "Situação desta versão".

# Estudo da Reforma — atualização semanal das aulas novas (Agenda 2.10.0 / Estudo 1.6.0)

Pedido do usuário (24/10/2026): toda semana verificar se os cursos publicaram aulas novas e atualizar o Estudo.
Quem **já começou** a trilha vê a aula como **"Atualização para revisar"** (quadro no topo da trilha, botão
"Marcar como vista", fora do % de conclusão). Quem **não começou** recebe a aula direto na lista da trilha.
Fonte escolhida pelo usuário: só as **aulas novas dos cursos** (Caio Melo/Hotmart e Fellipe Guerra/Nutror).
Publicação **automática**. Quando: **segunda-feira, por volta das 7h** (horário de Brasília).

## Como funciona
- A rotina roda na sessão do Claude que montou o Estudo (agendamento semanal). Ela abre as plataformas com o login do
  escritório guardado num perfil de navegador **fora do GitHub** (área de trabalho da sessão; nunca versionar cookies
  nem senhas) e compara a lista de aulas com a da semana anterior.
- Aula nova vira, no `dados.json` do armazenamento privado:
  - `videos["video:cm:<hash>"]` (ou `video:fg:<id>`) com `novo: "AAAA-MM-DD"`;
  - o id entra em `videos` ou `opcionais` das trilhas certas;
  - `atualizacoes[]`: `{ id, iso, data, titulo, html, video, trilhas }` (o `html` segue as regras de `docs/estudo-modulos.md`).
- O app: `trilhaVisivel()` tira da lista (e do %) as aulas publicadas depois do início da pessoa na trilha, e
  `htmlAtualizacoes()` mostra essas aulas no quadro. "Marcar como vista" grava o item `atualizacao:<id>` em
  `agenda_estudo_progresso`. Selo "novo" por 30 dias.
- Vídeos não são baixados nem gravados. O resumo usa título, descrição e material anexo da aula (quando houver).
  A análise dos trechos continua pela tela, no Chrome do usuário (como nos lotes).
- Se o login de uma plataforma expirar, a rotina avisa o usuário e segue com a outra.
